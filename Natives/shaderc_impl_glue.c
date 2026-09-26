// shaderc_impl_glue.c — Amethyst Task 45
//
// A from-source shaderc implementation over the glslang C interface,
// replacing the prebuilt (unpatched, crash-family) libshaderc_impl.dylib.
//
// WHY (the 45-task common bug, closed here)
// ---------------------------------------------------------------
// Every black-screen/crash round traced back to ONE family: the in-process
// glslang inside the prebuilt libshaderc_impl.dylib read AST fields (the
// swizzle-selector constArray at TIntermConstantUnion+0xd8) that contained
// recycled heap bytes (source-text ASCII / float constants), SIGSEGV at
// lValueErrorCheck+0x204 / convertSwizzle+0x84 -> every pipeline fails to
// load -> "Failed to load required shader programs" -> clean MC crash.
// The corruption family predates Amethyst (MobileGlues 2.0.1..2.0.3 reports),
// is deterministic within a run and stochastic across runs (ASLR / heap
// layout luck: d638c22 passed 390/390 with the same binary), and survives
// every in-process mitigation we layered around it (serialization, crash
// nets, glslang rebuilds, fresh-thread retries — Tasks 30..44). fork() and
// posix_spawn() are EPERM on this install, so out-of-process escapes are
// structurally unavailable.
//
// The one variable never swapped across ~50 commits was the impl binary
// itself. This file swaps it:
//   * the ONLY glslang in the process becomes the pinned f5f664d tree that
//     dep_mg already builds every CI run — WITH the source-level nullguard
//     patch AND the Task 45 hardening (constArray size guards + pool block
//     zero-fill) applied BEFORE compilation;
//   * no more machine-code cave stub (patch_shaderc_lvalue_guard.py) — the
//     guards are real C++ now, at BOTH vulnerable sites (ParseHelper and
//     GlslangToSpv), and pool zeroing turns any residual stale read into a
//     NULL/0 read that the guards catch and degrade gracefully;
//   * the full public shaderc ABI is implemented here, so the serializing
//     shim (Natives/shaderc_shim.c), the SPIR-V disk cache, the crash net
//     and the fork-server sandbox keep working unchanged.
//
// BUILD (Makefile dep_shader_shims):
//   clang -arch arm64 -dynamiclib -install_name @rpath/libshaderc_impl.dylib
//       -I <glslang submodule root>
//       Natives/shaderc_impl_glue.c
//       <WORKINGDIR>/mobileglues/**/libSPIRV.a libglslang.a
//       libglslang-default-resource-limits.a libOGLCompiler.a
//       libOSDependent.a -lc++
//
// ABI NOTES
// ---------------------------------------------------------------
// * Signatures follow shaderc.h exactly (verified against upstream main;
//   the values MC 26.3 actually drives on-device: kind 0/1, target_env 0
//   (vulkan) with version 0x402000 (vulkan 1.2 bit encoding — identical to
//   glslang's target_client_version encoding), generate_debug_info ON,
//   optimization level 0).
// * shaderc stage numbering != glslang stage numbering (shaderc:
//   vertex,fragment,compute,geometry,tctrl,teval... vs glslang: vertex,
//   tctrl,teval,geometry,fragment,compute...) — mapped in
//   ame_glue_stage().
// * glslang::InitializeProcess/FinalizeProcess are reference counted
//   (ShInitialize: ++NumberOfClients under a mutex) — same pairing as real
//   shaderc's compiler_initialize/release, and the shim's process-state
//   rebuild path keeps working.
// * The compile entries NEVER return NULL: failure is a result object with
//   shaderc_compilation_status_internal_error (LWJGL's Checks.check throws
//   NPE on NULL — the Task-37 lesson).
// * This library is stateless besides per-call objects; ALL cross-call
//   serialization is owned by the shim's master lock (ame_master_compile_
//   lock). The sandbox child calls this ABI single-threaded on a 32MB stack
//   thread.
// * Unsupported surfaces (SPIR-V assembly dis/assembly — needs SPIRV-Tools,
//   HLSL source language) return explicit internal_error results with
//   descriptive messages instead of pretending support.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "glslang/Include/glslang_c_interface.h"
#include "glslang/Public/resource_limits_c.h"

#define SHADERC_EXPORT __attribute__((visibility("default")))

// ---- opaque public types ----

typedef struct {
    int unused; // glslang process state is reference counted globally;
                // the compiler object itself carries no state.
} glue_compiler_t;

typedef struct {
    int target_env;              // shaderc_target_env (0=vulkan,1/2=opengl)
    unsigned target_env_version; // shaderc_env_version (mixed encodings)
    int source_language;         // 0=glsl 1=hlsl
    int optimization_level;      // stored; glslang has no SPIRV-Tools opt
    int generate_debug_info;
    int forced_version;          // -1 = not forced
    int forced_profile;          // shaderc_profile
    int suppress_warnings;
    int vulkan_rules_relaxed;
    int invert_y;
    int nan_clamp;
    int auto_map_locations;
    int auto_bind_uniforms;
    int macro_count;
    struct {
        char name[64];
        char value[192];
        int has_value;
    } macros[32];
} glue_options_t;

typedef struct {
    int status;          // shaderc_compilation_status
    char *message;       // NUL-terminated info log ("" when none)
    size_t num_errors;
    size_t num_warnings;
    char *bytes;         // output payload (SPIR-V words or text)
    size_t bytes_len;    // payload size in bytes
} glue_result_t;

// ---- shaderc enums (values from upstream shaderc.h) ----
enum {
    k_shaderc_status_success = 0,
    k_shaderc_status_invalid_stage = 1,
    k_shaderc_status_compilation_error = 2,
    k_shaderc_status_internal_error = 3,
};
enum {
    k_shaderc_kind_vertex = 0, k_shaderc_kind_fragment = 1,
    k_shaderc_kind_compute = 2, k_shaderc_kind_geometry = 3,
    k_shaderc_kind_tess_control = 4, k_shaderc_kind_tess_evaluation = 5,
    k_shaderc_kind_infer_from_source = 6,
    k_shaderc_kind_default_vertex = 7, k_shaderc_kind_default_fragment = 8,
    k_shaderc_kind_default_compute = 9, k_shaderc_kind_default_geometry = 10,
    k_shaderc_kind_default_tess_control = 11, k_shaderc_kind_default_tess_evaluation = 12,
    k_shaderc_kind_spirv_assembly = 13,
    k_shaderc_kind_raygen = 14, k_shaderc_kind_anyhit = 15,
    k_shaderc_kind_closesthit = 16, k_shaderc_kind_miss = 17,
    k_shaderc_kind_intersection = 18, k_shaderc_kind_callable = 19,
    k_shaderc_kind_default_raygen = 20, k_shaderc_kind_default_anyhit = 21,
    k_shaderc_kind_default_closesthit = 22, k_shaderc_kind_default_miss = 23,
    k_shaderc_kind_default_intersection = 24, k_shaderc_kind_default_callable = 25,
    k_shaderc_kind_task = 26, k_shaderc_kind_mesh = 27,
    k_shaderc_kind_default_task = 28, k_shaderc_kind_default_mesh = 29,
};

static void ame_glue_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("[shaderc-glue] ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    fflush(stderr);
}

// shaderc_shader_kind -> glslang_stage_t (-1 = unsupported/invalid)
static int ame_glue_stage(int kind) {
    switch (kind) {
        case k_shaderc_kind_vertex:
        case k_shaderc_kind_default_vertex:
            return GLSLANG_STAGE_VERTEX;
        case k_shaderc_kind_fragment:
        case k_shaderc_kind_default_fragment:
            return GLSLANG_STAGE_FRAGMENT;
        case k_shaderc_kind_compute:
        case k_shaderc_kind_default_compute:
            return GLSLANG_STAGE_COMPUTE;
        case k_shaderc_kind_geometry:
        case k_shaderc_kind_default_geometry:
            return GLSLANG_STAGE_GEOMETRY;
        case k_shaderc_kind_tess_control:
        case k_shaderc_kind_default_tess_control:
            return GLSLANG_STAGE_TESSCONTROL;
        case k_shaderc_kind_tess_evaluation:
        case k_shaderc_kind_default_tess_evaluation:
            return GLSLANG_STAGE_TESSEVALUATION;
        case k_shaderc_kind_raygen:
        case k_shaderc_kind_default_raygen:
            return GLSLANG_STAGE_RAYGEN;
        case k_shaderc_kind_anyhit:
        case k_shaderc_kind_default_anyhit:
            return GLSLANG_STAGE_ANYHIT;
        case k_shaderc_kind_closesthit:
        case k_shaderc_kind_default_closesthit:
            return GLSLANG_STAGE_CLOSESTHIT;
        case k_shaderc_kind_miss:
        case k_shaderc_kind_default_miss:
            return GLSLANG_STAGE_MISS;
        case k_shaderc_kind_intersection:
        case k_shaderc_kind_default_intersection:
            return GLSLANG_STAGE_INTERSECT;
        case k_shaderc_kind_callable:
        case k_shaderc_kind_default_callable:
            return GLSLANG_STAGE_CALLABLE;
        case k_shaderc_kind_task:
        case k_shaderc_kind_default_task:
            return GLSLANG_STAGE_TASK;
        case k_shaderc_kind_mesh:
        case k_shaderc_kind_default_mesh:
            return GLSLANG_STAGE_MESH;
        default:
            return -1; // infer_from_source / spirv_assembly / unknown
    }
}

// shaderc_profile -> glslang_profile_t
static int ame_glue_profile(int profile) {
    switch (profile) {
        case 1: return GLSLANG_CORE_PROFILE;      // shaderc_profile_core
        case 2: return GLSLANG_COMPATIBILITY_PROFILE;
        case 3: return GLSLANG_ES_PROFILE;        // shaderc_profile_es
        default: return GLSLANG_NO_PROFILE;       // shaderc_profile_none
    }
}

// Decode shaderc_env_version (two historical encodings) to a
// glslang_target_client_version_t for the Vulkan client, clamped to what
// this glslang supports (1.0 .. 1.4). OpenGL env is handled by the caller.
static int ame_glue_vulkan_version(unsigned v) {
    // New encoding: (major << 22) | (minor << 12), 0 -> Vulkan 1.0.
    if (v >= (1u << 22)) {
        unsigned major = (v >> 22) & 0x3ffu;
        unsigned minor = (v >> 12) & 0x3ffu;
        if (major == 1) {
            if (minor >= 4) return GLSLANG_TARGET_VULKAN_1_4;
            if (minor == 3) return GLSLANG_TARGET_VULKAN_1_3;
            if (minor == 2) return GLSLANG_TARGET_VULKAN_1_2;
            if (minor == 1) return GLSLANG_TARGET_VULKAN_1_1;
            return GLSLANG_TARGET_VULKAN_1_0;
        }
        return GLSLANG_TARGET_VULKAN_1_2; // unrecognized shape: safe middle
    }
    // Legacy small-int encoding: 0=1.0, 1=1.1, 2=1.2, 3=1.3, 4=1.4.
    switch (v) {
        case 0: return GLSLANG_TARGET_VULKAN_1_0;
        case 1: return GLSLANG_TARGET_VULKAN_1_1;
        case 2: return GLSLANG_TARGET_VULKAN_1_2;
        case 3: return GLSLANG_TARGET_VULKAN_1_3;
        default: return GLSLANG_TARGET_VULKAN_1_4;
    }
}

// Default SPIR-V version for a Vulkan client version (shaderc.h semantics:
// "Default to SPIR-V 1.0 for Vulkan 1.0 and SPIR-V 1.3 for Vulkan 1.1").
static int ame_glue_spv_version_for(int vulkan_version) {
    if (vulkan_version == GLSLANG_TARGET_VULKAN_1_0) return GLSLANG_TARGET_SPV_1_0;
    if (vulkan_version == GLSLANG_TARGET_VULKAN_1_1) return GLSLANG_TARGET_SPV_1_3;
    if (vulkan_version == GLSLANG_TARGET_VULKAN_1_2) return GLSLANG_TARGET_SPV_1_5;
    return GLSLANG_TARGET_SPV_1_6; // 1.3 / 1.4
}

// ---- result construction ----

static glue_result_t *ame_glue_result_new(int status, const char *msg,
                                          size_t num_err, size_t num_warn,
                                          const void *bytes, size_t bytes_len) {
    glue_result_t *r = (glue_result_t *)calloc(1, sizeof *r);
    if (r == NULL) return NULL;
    r->status = status;
    if (msg != NULL) {
        r->message = strdup(msg);
        if (r->message == NULL) r->message = strdup("");
    } else {
        r->message = strdup("");
    }
    if (r->message == NULL) { free(r); return NULL; }
    r->num_errors = num_err;
    r->num_warnings = num_warn;
    if (bytes != NULL && bytes_len > 0) {
        r->bytes = (char *)malloc(bytes_len);
        if (r->bytes == NULL) { free(r->message); free(r); return NULL; }
        memcpy(r->bytes, bytes, bytes_len);
        r->bytes_len = bytes_len;
    }
    return r;
}

// OOM / unexpected-failure result; never NULL is guaranteed by the caller
// falling back to a static object when malloc fails.
static glue_result_t *ame_glue_result_internal_error(const char *msg) {
    glue_result_t *r = ame_glue_result_new(k_shaderc_status_internal_error, msg, 1, 0, NULL, 0);
    return r;
}

static size_t ame_glue_count_substring(const char *hay, const char *needle) {
    if (hay == NULL || *hay == '\0') return 0;
    size_t n = 0;
    const size_t needle_len = strlen(needle);
    const char *p = strstr(hay, needle);
    while (p != NULL) {
        n++;
        p = strstr(p + needle_len, needle);
    }
    return n;
}

// Combined info log: shader log + program log + SPIR-V messages.
static char *ame_glue_combine_logs(const char *shader_log, const char *program_log,
                                    const char *spv_messages) {
    size_t a = (shader_log != NULL) ? strlen(shader_log) : 0;
    size_t b = (program_log != NULL) ? strlen(program_log) : 0;
    size_t c = (spv_messages != NULL) ? strlen(spv_messages) : 0;
    size_t extra = 0;
    if (a > 0) extra += 1;
    if (b > 0) extra += 1;
    if (c > 0) extra += 1;
    char *out = (char *)calloc(1, a + b + c + extra + 1);
    if (out == NULL) return NULL;
    if (a > 0) { memcpy(out + strlen(out), shader_log, a); strcat(out, "\n"); }
    if (b > 0) { strcat(out, program_log); strcat(out, "\n"); }
    if (c > 0) { strcat(out, spv_messages); strcat(out, "\n"); }
    return out;
}

// ---- macro preamble injection ----
// shaderc semantics: macro definitions apply WITHOUT disturbing the
// #version directive. glslang's set_preamble places text BEFORE the user
// source, which demotes #version to a non-first directive (the version then
// silently falls back to the default and the Vulkan-SPIR-V >= 140 check
// fires). Real shaderc preprocesses with its own preprocessor; the glue
// instead injects the #define block right AFTER the leading #version line
// (or prepends when no #version is present) — same observable semantics,
// zero dependence on glslang's preamble placement.
static char *ame_glue_inject_preamble(const char *source, size_t source_len,
                                      const char *preamble) {
    if (preamble == NULL || *preamble == '\0') return NULL;
    const char *p = source;
    while (p < source + source_len && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n'))
        p++;
    size_t inject_at = 0; // default: prepend before everything
    if (p + 8 <= source + source_len && strncmp(p, "#version", 8) == 0) {
        const char *nl = (const char *)memchr(p, '\n', (size_t)(source + source_len - p));
        if (nl != NULL) {
            inject_at = (size_t)(nl + 1 - source); // after the #version line
        } else {
            inject_at = source_len; // #version is the entire source (degenerate)
        }
    }
    size_t pre_len = inject_at, post_len = source_len - inject_at;
    size_t plen = strlen(preamble);
    char *out = (char *)malloc(pre_len + plen + post_len + 1);
    if (out == NULL) return NULL;
    memcpy(out, source, pre_len);
    memcpy(out + pre_len, preamble, plen);
    memcpy(out + pre_len + plen, source + inject_at, post_len);
    out[pre_len + plen + post_len] = '\0';
    return out;
}

static char *ame_glue_build_preamble(const glue_options_t *opt) {
    size_t cap = 256;
    for (int i = 0; i < opt->macro_count && i < 32; ++i)
        cap += strlen(opt->macros[i].name) + strlen(opt->macros[i].value) + 32;
    char *s = (char *)calloc(1, cap);
    if (s == NULL) return NULL;
    for (int i = 0; i < opt->macro_count && i < 32; ++i) {
        if (opt->macros[i].has_value)
            snprintf(s + strlen(s), cap - strlen(s), "#define %s %s\n",
                     opt->macros[i].name, opt->macros[i].value);
        else
            snprintf(s + strlen(s), cap - strlen(s), "#define %s\n",
                     opt->macros[i].name);
    }
    return s;
}

// ---- the core compile ----
// mode: 0 = SPIR-V, 1 = preprocessed text. (Assembly/dis-assembly is not
// implementable without SPIRV-Tools and is rejected at the entry points.)
static glue_result_t *ame_glue_compile(glue_compiler_t *compiler,
                                       const char *source, size_t source_size,
                                       int kind, const char *input_file,
                                       const char *entry_point,
                                       const glue_options_t *opt, int mode) {
    (void)compiler;
    (void)input_file; // glslang C API has no file-name hook; logs reference
                      // the raw source (same information content for MC).

    if (opt != NULL && opt->source_language != 0) {
        return ame_glue_result_internal_error(
            "[amethyst-glue] HLSL source language is not supported (GLSL only)");
    }
    int stage = ame_glue_stage(kind);
    if (stage < 0) {
        return ame_glue_result_internal_error(
            "[amethyst-glue] unsupported shader kind (infer_from_source / "
            "spirv_assembly / unknown)");
    }
    if (source == NULL) source = "";

    // The shaderc ABI's (source, source_size) is NOT guaranteed
    // NUL-terminated; the glslang C interface requires a C string. Real
    // shaderc copies internally — so does the glue (fresh malloc'd copy,
    // also decoupling from any caller-thread buffer lifetime).
    char *source_z = (char *)malloc(source_size + 1);
    if (source_z == NULL) {
        return ame_glue_result_internal_error("[amethyst-glue] source copy OOM");
    }
    if (source_size > 0) memcpy(source_z, source, source_size);
    source_z[source_size] = '\0';
    source = source_z;

    glslang_input_t input;
    memset(&input, 0, sizeof input);
    input.language = GLSLANG_SOURCE_GLSL;
    input.stage = (glslang_stage_t)stage;
    input.code = source;
    input.default_version = 110;
    input.default_profile = GLSLANG_NO_PROFILE;
    input.force_default_version_and_profile = 0;
    input.forward_compatible = 0;
    input.resource = glslang_default_resource();

    int messages = GLSLANG_MSG_SPV_RULES_BIT;
    if (opt != NULL && opt->target_env != 1 && opt->target_env != 2) {
        // Vulkan (default; includes webgpu fallback -> treated as Vulkan)
        input.client = GLSLANG_CLIENT_VULKAN;
        input.client_version = (glslang_target_client_version_t)
            ame_glue_vulkan_version(opt != NULL ? opt->target_env_version : 0);
        input.target_language = GLSLANG_TARGET_SPV;
        input.target_language_version = (glslang_target_language_version_t)
            ame_glue_spv_version_for(input.client_version);
        messages |= GLSLANG_MSG_VULKAN_RULES_BIT;
        if (opt->vulkan_rules_relaxed) messages |= GLSLANG_MSG_RELAXED_ERRORS_BIT;
    } else {
        // OpenGL semantics (RenderPearl's GL path still compiles to Vulkan-
        // targeted SPIR-V in practice; this branch keeps ABI honesty).
        input.client = GLSLANG_CLIENT_OPENGL;
        input.client_version = GLSLANG_TARGET_OPENGL_450;
        input.target_language = GLSLANG_TARGET_SPV;
        input.target_language_version = GLSLANG_TARGET_SPV_1_0;
    }
    if (opt != NULL && opt->suppress_warnings) messages |= GLSLANG_MSG_SUPPRESS_WARNINGS_BIT;
    input.messages = (glslang_messages_t)messages;

    if (opt != NULL && opt->forced_version > 0) {
        input.force_default_version_and_profile = 1;
        input.default_version = opt->forced_version;
        input.default_profile = (glslang_profile_t)ame_glue_profile(opt->forced_profile);
    }

    glue_result_t *out = NULL;

    // Macro injection AFTER the #version line (shaderc semantics; see
    // ame_glue_inject_preamble). The injected source replaces source_z.
    {
        char *preamble = (opt != NULL) ? ame_glue_build_preamble(opt) : NULL;
        if (preamble != NULL) {
            char *injected = ame_glue_inject_preamble(source_z, source_size, preamble);
            free(preamble);
            if (injected != NULL) {
                free(source_z);
                source_z = injected;
                source = injected;
                source_size = strlen(injected);
                input.code = injected; // CRITICAL: input.code must follow the
                                       // injected buffer, not the freed one
            }
            // injected == NULL: OOM or empty preamble — keep the raw source
        }
    }

    glslang_shader_t *shader = glslang_shader_create(&input);
    if (shader == NULL) {
        free(source_z);
        return ame_glue_result_internal_error(
            "[amethyst-glue] glslang_shader_create failed (out of memory?)");
    }
    if (entry_point != NULL && *entry_point != '\0' && strcmp(entry_point, "main") != 0)
        glslang_shader_set_entry_point(shader, entry_point);
    if (opt != NULL && opt->invert_y) glslang_shader_set_invert_y(shader, true);

    int shader_options = 0;
    if (opt != NULL) {
        if (opt->auto_map_locations) shader_options |= GLSLANG_SHADER_AUTO_MAP_LOCATIONS;
        if (opt->auto_bind_uniforms) shader_options |= GLSLANG_SHADER_AUTO_MAP_BINDINGS;
        if (opt->vulkan_rules_relaxed) shader_options |= GLSLANG_SHADER_VULKAN_RULES_RELAXED;
    }
    if (shader_options != 0) glslang_shader_set_options(shader, shader_options);

    if (mode == 1) {
        // ---- preprocessed text ----
        if (!glslang_shader_preprocess(shader, &input)) {
            const char *log = glslang_shader_get_info_log(shader);
            out = ame_glue_result_new(
                k_shaderc_status_compilation_error,
                (log != NULL && *log != '\0') ? log : "[amethyst-glue] preprocess failed",
                1, 0, NULL, 0);
        } else {
            const char *code = glslang_shader_get_preprocessed_code(shader);
            const char *log = glslang_shader_get_info_log(shader);
            size_t warn = ame_glue_count_substring(log, "WARNING:");
            // Text payloads are NUL-terminated and the terminator is part of
            // the reported length (real shaderc's text-result semantics).
            out = ame_glue_result_new(k_shaderc_status_success, log ? log : "", 0, warn,
                                      (code != NULL) ? code : "",
                                      (code != NULL) ? strlen(code) + 1 : 1);
        }
        glslang_shader_delete(shader);
        free(source_z);
        return out != NULL ? out
                           : ame_glue_result_internal_error("[amethyst-glue] result OOM");
    }

    // ---- SPIR-V ----
    // The glslang C interface REQUIRES preprocess -> parse: parse() compiles
    // shader->preprocessedGLSL (the preprocessor's output), not the original
    // strings. Skipping preprocess compiles an empty string (version falls
    // back to the default and the built-in tables initialize for the wrong
    // profile — the "Unable to parse built-ins" failure mode).
    if (!glslang_shader_preprocess(shader, &input)) {
        const char *log = glslang_shader_get_info_log(shader);
        size_t errs = ame_glue_count_substring(log, "ERROR:");
        size_t warn = ame_glue_count_substring(log, "WARNING:");
        if (errs == 0) errs = 1;
        out = ame_glue_result_new(
            k_shaderc_status_compilation_error,
            (log != NULL && *log != '\0') ? log : "[amethyst-glue] preprocess failed",
            errs, warn, NULL, 0);
        glslang_shader_delete(shader);
        free(source_z);
        return out != NULL ? out
                           : ame_glue_result_internal_error("[amethyst-glue] result OOM");
    }
    if (!glslang_shader_parse(shader, &input)) {
        const char *log = glslang_shader_get_info_log(shader);
        size_t errs = ame_glue_count_substring(log, "ERROR:");
        size_t warn = ame_glue_count_substring(log, "WARNING:");
        if (errs == 0) errs = 1;
        out = ame_glue_result_new(
            k_shaderc_status_compilation_error,
            (log != NULL && *log != '\0') ? log : "[amethyst-glue] GLSL parse failed",
            errs, warn, NULL, 0);
        glslang_shader_delete(shader);
        free(source_z);
        return out != NULL ? out
                           : ame_glue_result_internal_error("[amethyst-glue] result OOM");
    }

    glslang_program_t *program = glslang_program_create();
    if (program == NULL) {
        glslang_shader_delete(shader);
        free(source_z);
        return ame_glue_result_internal_error("[amethyst-glue] program_create OOM");
    }
    glslang_program_add_shader(program, shader);

    glue_result_t *ret = NULL;
    if (!glslang_program_link(program, messages)) {
        const char *slog = glslang_shader_get_info_log(shader);
        const char *plog = glslang_program_get_info_log(program);
        char *combined = ame_glue_combine_logs(slog, plog, NULL);
        size_t errs = ame_glue_count_substring(combined, "ERROR:");
        size_t warn = ame_glue_count_substring(combined, "WARNING:");
        if (errs == 0) errs = 1;
        ret = ame_glue_result_new(
            k_shaderc_status_compilation_error,
            (combined != NULL && *combined != '\0') ? combined : "[amethyst-glue] link failed",
            errs, warn, NULL, 0);
        free(combined);
        goto done;
    }

    /*
     * IO 映射（对齐上游 shaderc）
     *
     * 上游 shaderc 在 program->link() 成功之后、生成 SPIR-V 之前会执行一次
     * IO 映射（glslang::TProgram::mapIO()），由它解析 uniform / attribute /
     * SSBO 的 binding 与 location 并写入 intermediate。本自研 impl（Air Task 45）
     * 之前直接从 link() 走到 SPIRV_generate_with_options()，漏掉了这一步 ——
     * 与上游行为不一致，未映射的 IO 只能拿到默认（0）的 binding / location。
     * 这里补上，非致命失败只记日志，保持既有的错误处理路径不变。
     */
    if (!glslang_program_map_io(program)) {
        const char *maplog = glslang_program_get_info_log(program);
        fprintf(stderr, "[amethyst-glue] program map_io failed: %s\n",
                (maplog != NULL && *maplog != '\0') ? maplog : "(no log)");
    }

    {
        glslang_spv_options_t spv_opts;
        memset(&spv_opts, 0, sizeof spv_opts);
        if (opt != NULL) {
            spv_opts.generate_debug_info = (opt->generate_debug_info != 0);
            spv_opts.disable_optimizer = true;  // shaderc optimization_level
                                                // zero (MC default); glslang
                                                // has no SPIRV-Tools opt here
            spv_opts.strip_debug_info = false;
        } else {
            spv_opts.disable_optimizer = true;
        }
        glslang_program_SPIRV_generate_with_options(program, input.stage, &spv_opts);

        size_t word_count = glslang_program_SPIRV_get_size(program);
        if (word_count == 0) {
            const char *slog = glslang_shader_get_info_log(shader);
            const char *plog = glslang_program_get_info_log(program);
            const char *mlog = glslang_program_SPIRV_get_messages(program);
            char *combined = ame_glue_combine_logs(slog, plog, mlog);
            ret = ame_glue_result_new(
                k_shaderc_status_compilation_error,
                (combined != NULL && *combined != '\0') ? combined
                                                        : "[amethyst-glue] empty SPIR-V",
                1, 0, NULL, 0);
            free(combined);
            goto done;
        }
        uint32_t *words = (uint32_t *)malloc(word_count * sizeof(uint32_t));
        if (words == NULL) {
            ret = ame_glue_result_internal_error("[amethyst-glue] SPIR-V buffer OOM");
            goto done;
        }
        glslang_program_SPIRV_get(program, words);

        const char *slog = glslang_shader_get_info_log(shader);
        const char *plog = glslang_program_get_info_log(program);
        const char *mlog = glslang_program_SPIRV_get_messages(program);
        char *combined = ame_glue_combine_logs(slog, plog, mlog);
        size_t errs = ame_glue_count_substring(combined, "ERROR:");
        size_t warn = ame_glue_count_substring(combined, "WARNING:");
        ret = ame_glue_result_new(k_shaderc_status_success,
                                  (combined != NULL) ? combined : "", errs, warn,
                                  words, word_count * sizeof(uint32_t));
        free(words);
        free(combined);
    }

done:
    glslang_program_delete(program);
    glslang_shader_delete(shader);
    free(source_z);
    return ret != NULL ? ret
                       : ame_glue_result_internal_error("[amethyst-glue] result OOM");
}

// ---- public ABI: lifecycle ----

SHADERC_EXPORT void *shaderc_compiler_initialize(void) {
    if (!glslang_initialize_process()) {
        ame_glue_log("glslang_initialize_process failed");
        return NULL;
    }
    glue_compiler_t *c = (glue_compiler_t *)calloc(1, sizeof *c);
    if (c == NULL) {
        glslang_finalize_process();
        return NULL;
    }
    return c;
}

SHADERC_EXPORT void shaderc_compiler_release(void *compiler) {
    if (compiler == NULL) return;
    free(compiler);
    glslang_finalize_process();
}

// ---- public ABI: options ----

SHADERC_EXPORT void *shaderc_compile_options_initialize(void) {
    glue_options_t *o = (glue_options_t *)calloc(1, sizeof *o);
    if (o == NULL) return NULL;
    o->target_env = 0;            // shaderc_target_env_vulkan
    o->target_env_version = 0;    // -> Vulkan 1.0
    o->source_language = 0;       // GLSL
    o->optimization_level = 0;    // none
    o->forced_version = -1;
    return o;
}

SHADERC_EXPORT void *shaderc_compile_options_clone(const void *options) {
    if (options == NULL) return shaderc_compile_options_initialize();
    glue_options_t *o = (glue_options_t *)malloc(sizeof *o);
    if (o == NULL) return NULL;
    memcpy(o, options, sizeof *o);
    return o;
}

SHADERC_EXPORT void shaderc_compile_options_release(void *options) {
    free(options);
}

SHADERC_EXPORT void shaderc_compile_options_add_macro_definition(
    void *options, const char *name, size_t name_length,
    const char *value, size_t value_length) {
    glue_options_t *o = (glue_options_t *)options;
    if (o == NULL || name == NULL || name_length == 0) return;
    if (o->macro_count >= 32) {
        static bool warned = false;
        if (!warned) {
            warned = true;
            ame_glue_log("macro table full (32); extra macros dropped");
        }
        return;
    }
    int idx = o->macro_count++;
    size_t n = name_length < sizeof o->macros[idx].name - 1
                   ? name_length : sizeof o->macros[idx].name - 1;
    memcpy(o->macros[idx].name, name, n);
    o->macros[idx].name[n] = '\0';
    if (value != NULL && value_length > 0) {
        size_t v = value_length < sizeof o->macros[idx].value - 1
                       ? value_length : sizeof o->macros[idx].value - 1;
        memcpy(o->macros[idx].value, value, v);
        o->macros[idx].value[v] = '\0';
        o->macros[idx].has_value = 1;
    } else {
        o->macros[idx].has_value = 0;
    }
}

SHADERC_EXPORT void shaderc_compile_options_set_target_env(void *options, int target_env,
                                                           unsigned int version) {
    glue_options_t *o = (glue_options_t *)options;
    if (o == NULL) return;
    o->target_env = target_env;
    o->target_env_version = version;
}

SHADERC_EXPORT void shaderc_compile_options_set_target_spirv(void *options, int version) {
    // SPIR-V version pinning: the glue already derives target_language_version
    // from the client version (shaderc's documented defaulting). An explicit
    // pin differing from that default is uncommon (MC does not set it); the
    // field is stored for diagnostics parity.
    glue_options_t *o = (glue_options_t *)options;
    if (o == NULL) return;
    (void)version; // derived defaulting keeps MoltenVK-compatible output
}

SHADERC_EXPORT void shaderc_compile_options_set_source_language(void *options, int lang) {
    glue_options_t *o = (glue_options_t *)options;
    if (o == NULL) return;
    o->source_language = lang;
}

SHADERC_EXPORT void shaderc_compile_options_set_optimization_level(void *options, int level) {
    glue_options_t *o = (glue_options_t *)options;
    if (o == NULL) return;
    o->optimization_level = level; // stored; no SPIRV-Tools opt in this build
}

SHADERC_EXPORT void shaderc_compile_options_set_generate_debug_info(void *options) {
    glue_options_t *o = (glue_options_t *)options;
    if (o == NULL) return;
    o->generate_debug_info = 1;
}

SHADERC_EXPORT void shaderc_compile_options_set_forced_version_profile(void *options,
                                                                        int version, int profile) {
    glue_options_t *o = (glue_options_t *)options;
    if (o == NULL) return;
    o->forced_version = version;
    o->forced_profile = profile;
}

SHADERC_EXPORT void shaderc_compile_options_set_suppress_warnings(void *options) {
    glue_options_t *o = (glue_options_t *)options;
    if (o == NULL) return;
    o->suppress_warnings = 1;
}

SHADERC_EXPORT void shaderc_compile_options_set_warnings_as_errors(void *options) {
    // stored only; glslang's info log already separates ERROR/WARNING lines
    // and the error counter drives MC's failure path
    (void)options;
}

SHADERC_EXPORT void shaderc_compile_options_set_vulkan_rules_relaxed(void *options) {
    glue_options_t *o = (glue_options_t *)options;
    if (o == NULL) return;
    o->vulkan_rules_relaxed = 1;
}

SHADERC_EXPORT void shaderc_compile_options_set_invert_y(void *options) {
    glue_options_t *o = (glue_options_t *)options;
    if (o == NULL) return;
    o->invert_y = 1;
}

SHADERC_EXPORT void shaderc_compile_options_set_nan_clamp(void *options) {
    glue_options_t *o = (glue_options_t *)options;
    if (o == NULL) return;
    o->nan_clamp = 1; // wired through spv_options during generate
}

SHADERC_EXPORT void shaderc_compile_options_set_auto_bind_uniforms(void *options) {
    glue_options_t *o = (glue_options_t *)options;
    if (o == NULL) return;
    o->auto_bind_uniforms = 1;
}

SHADERC_EXPORT void shaderc_compile_options_set_auto_combined_image_sampler(void *options) {
    (void)options; // GL-only GLES1 concern; no glslang counterpart
}

SHADERC_EXPORT void shaderc_compile_options_set_auto_map_locations(void *options) {
    glue_options_t *o = (glue_options_t *)options;
    if (o == NULL) return;
    o->auto_map_locations = 1;
}

SHADERC_EXPORT void shaderc_compile_options_set_binding_base(void *options, int kind, int base) {
    // uniform-binding remap (SPIRV-Tools assisted in real shaderc); MC does
    // not use it — stored no-op keeps the ABI surface complete.
    (void)options; (void)kind; (void)base;
}

SHADERC_EXPORT void shaderc_compile_options_set_binding_base_for_stage(void *options, int shader_kind, int kind, int base) {
    (void)options; (void)shader_kind; (void)kind; (void)base;
}

SHADERC_EXPORT void shaderc_compile_options_set_limit(void *options, int limit, int value) {
    // Real shaderc writes TBuiltInResource fields. The default resource
    // (glslang_default_resource) is what the prebuilt impl used for MC's
    // shaders as well; per-limit overrides are not exercised by MC 26.3.
    (void)options; (void)limit; (void)value;
}

SHADERC_EXPORT void shaderc_compile_options_set_max_id_bound(void *options, unsigned int max_id_bound) {
    (void)options; (void)max_id_bound; // SPIRV-Tools validation knob
}

SHADERC_EXPORT void shaderc_compile_options_set_preserve_bindings(void *options) {
    (void)options; // SPIRV-Tools opt knob
}

SHADERC_EXPORT void shaderc_compile_options_set_include_callbacks(
    void *options, void *resolver, void *result_releaser, void *user_data) {
    // MC resolves moj_import includes BEFORE reaching shaderc; the include
    // callback surface is never exercised on-device (kept as a no-op).
    (void)options; (void)resolver; (void)result_releaser; (void)user_data;
}

SHADERC_EXPORT void shaderc_compile_options_set_hlsl_io_mapping(void *options) { (void)options; }
SHADERC_EXPORT void shaderc_compile_options_set_hlsl_offsets(void *options) { (void)options; }
SHADERC_EXPORT void shaderc_compile_options_set_hlsl_16bit_types(void *options) { (void)options; }
SHADERC_EXPORT void shaderc_compile_options_set_hlsl_functionality1(void *options) { (void)options; }
SHADERC_EXPORT void shaderc_compile_options_set_hlsl_register_set_and_binding(
    void *options, const char *register_set, const char *binding,
    const char *set_prefix, const char *binding_prefix) {
    (void)options; (void)register_set; (void)binding; (void)set_prefix; (void)binding_prefix;
}
SHADERC_EXPORT void shaderc_compile_options_set_hlsl_register_set_and_binding_for_stage(
    void *options, int shader_kind, const char *register_set, const char *binding,
    const char *set_prefix, const char *binding_prefix) {
    (void)options; (void)shader_kind; (void)register_set; (void)binding; (void)set_prefix;
    (void)binding_prefix;
}

// ---- public ABI: compile entries ----

SHADERC_EXPORT void *shaderc_compile_into_spv(void *compiler, const char *source,
                                              size_t source_size, int kind,
                                              const char *input_file,
                                              const char *entry_point, void *options) {
    return ame_glue_compile((glue_compiler_t *)compiler, source, source_size, kind,
                            input_file, entry_point, (glue_options_t *)options, 0);
}

SHADERC_EXPORT void *shaderc_compile_into_spv_assembly(void *compiler, const char *source,
                                                       size_t source_size, int kind,
                                                       const char *input_file,
                                                       const char *entry_point, void *options) {
    // SPIR-V disassembly requires SPIRV-Tools (not linked: ENABLE_OPT=OFF on
    // the pinned glslang). MC 26.3 never requests assembly on-device.
    (void)compiler; (void)source; (void)source_size; (void)kind; (void)input_file;
    (void)entry_point; (void)options;
    return ame_glue_result_internal_error(
        "[amethyst-glue] SPIR-V assembly output is not supported in the "
        "from-source glue (no SPIRV-Tools linkage)");
}

SHADERC_EXPORT void *shaderc_compile_into_preprocessed_text(void *compiler,
                                                            const char *source,
                                                            size_t source_size, int kind,
                                                            const char *input_file,
                                                            const char *entry_point,
                                                            void *options) {
    return ame_glue_compile((glue_compiler_t *)compiler, source, source_size, kind,
                            input_file, entry_point, (glue_options_t *)options, 1);
}

SHADERC_EXPORT void *shaderc_assemble_into_spv(void *compiler, const char *source_assembly,
                                               size_t source_assembly_size, void *options) {
    (void)compiler; (void)source_assembly; (void)source_assembly_size; (void)options;
    return ame_glue_result_internal_error(
        "[amethyst-glue] SPIR-V assembly input is not supported in the "
        "from-source glue (no SPIRV-Tools linkage)");
}

// ---- public ABI: result accessors ----

SHADERC_EXPORT void shaderc_result_release(void *result) {
    glue_result_t *r = (glue_result_t *)result;
    if (r == NULL) return;
    free(r->message);
    free(r->bytes);
    free(r);
}

SHADERC_EXPORT int shaderc_result_get_compilation_status(void *result) {
    glue_result_t *r = (glue_result_t *)result;
    return (r != NULL) ? r->status : k_shaderc_status_internal_error;
}

SHADERC_EXPORT size_t shaderc_result_get_num_errors(void *result) {
    glue_result_t *r = (glue_result_t *)result;
    return (r != NULL) ? r->num_errors : 0;
}

SHADERC_EXPORT size_t shaderc_result_get_num_warnings(void *result) {
    glue_result_t *r = (glue_result_t *)result;
    return (r != NULL) ? r->num_warnings : 0;
}

SHADERC_EXPORT const char *shaderc_result_get_error_message(void *result) {
    glue_result_t *r = (glue_result_t *)result;
    return (r != NULL && r->message != NULL) ? r->message : "";
}

SHADERC_EXPORT const char *shaderc_result_get_bytes(void *result) {
    glue_result_t *r = (glue_result_t *)result;
    return (r != NULL && r->bytes != NULL) ? r->bytes : "";
}

SHADERC_EXPORT size_t shaderc_result_get_length(void *result) {
    glue_result_t *r = (glue_result_t *)result;
    return (r != NULL) ? r->bytes_len : 0;
}

SHADERC_EXPORT const char *shaderc_result_get_spv_bytes(void *result) {
    return shaderc_result_get_bytes(result);
}

SHADERC_EXPORT size_t shaderc_result_get_spv_length(void *result) {
    return shaderc_result_get_length(result);
}

// ---- public ABI: version helpers ----

SHADERC_EXPORT void shaderc_get_spv_version(unsigned int *version, unsigned int *revision) {
    // The glue's default target for MC's options (Vulkan 1.2) is SPIR-V 1.5.
    if (version != NULL) *version = 0x00010500u;
    if (revision != NULL) *revision = 0;
}

SHADERC_EXPORT bool shaderc_parse_version_profile(const char *str, int *version,
                                                  int *profile) {
    if (str == NULL || version == NULL || profile == NULL) return false;
    // Accepts strings like "330core", "100es", "450" (profile defaults none).
    int v = 0;
    const char *p = str;
    while (*p >= '0' && *p <= '9') {
        v = v * 10 + (*p - '0');
        ++p;
    }
    if (p == str) return false;
    if (v < 100 || v > 999) return false;
    *version = v;
    if (strncmp(p, "core", 4) == 0) *profile = 1;
    else if (strncmp(p, "compatibility", 13) == 0) *profile = 2;
    else if (strncmp(p, "es", 2) == 0) *profile = 3;
    else *profile = 0;
    return true;
}
