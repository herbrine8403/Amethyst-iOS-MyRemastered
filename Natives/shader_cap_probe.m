// shader_cap_probe.m — ★ [SHADER-CAP] GL 能力运行时探测 + 诚实扩展上报 + GL 入口映射
//
// 设计纪律(与仓库既有「宣布扩展 ≠ 实现扩展」一致):
//   1) 探测 **只读**: 对候选 GL 入口逐个解析(dlsym 渲染器句柄), 结果打 [SHADER-CAP] 日志;
//   2) 上报 **由探测驱动**: 只有「该扩展要求的全部入口都解析到 + 相关 limit 查询为正」
//      才把扩展名补进 glGetString(GL_EXTENSIONS) / glGetStringi / GL_NUM_EXTENSIONS;
//   3) 入口映射 **只做同名/EXT 别名转发**: core 名缺失而 EXT 名存在时才接一层转发,
//      绝不伪造实现; core 名称本身就存在时本模块完全不介入(行为不变)。
//   4) 默认不改现有行为, 且可整体关闭(见头文件环境变量)。
//
// 作者注: 本文件是纯 C(编译为 ObjC 只为用 NSLog)。所有 GL 类型自给自足, 不依赖 GLES 头。

#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "shader_cap_probe.h"

#pragma mark - GL 类型(自给自足)

typedef unsigned int  ame_GLenum;
typedef unsigned int  ame_GLuint;
typedef int           ame_GLint;
typedef int           ame_GLsizei;
typedef long          ame_GLintptr;
typedef long          ame_GLsizeiptr;
typedef unsigned int  ame_GLbitfield;
typedef unsigned char ame_GLboolean;
typedef float         ame_GLfloat;

typedef const unsigned char *(*ame_sc_gs_fn)(unsigned int);
typedef const unsigned char *(*ame_sc_gsi_fn)(unsigned int, unsigned int);
typedef void (*ame_sc_gi_fn)(unsigned int, int *);

#pragma mark - GL 常量(自给自足,避免依赖 GLES 头)

#define SC_GL_VENDOR                               0x1F00
#define SC_GL_RENDERER                             0x1F01
#define SC_GL_VERSION                              0x1F02
#define SC_GL_EXTENSIONS                           0x1F03
#define SC_GL_NUM_EXTENSIONS                       0x821D
#define SC_GL_MAX_IMAGE_UNITS                      0x8F38
#define SC_GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS   0x90DD
#define SC_GL_MAX_UNIFORM_BUFFER_BINDINGS          0x8A2F
#define SC_GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT       0x84FF
#define SC_GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS     0x8B4D
#define SC_GL_MAX_IMAGE_SAMPLES                    0x906D
#define SC_GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS   0x90EB

#pragma mark - 全局状态

static ame_sc_resolve_fn sc_resolve = NULL;

static ame_sc_gs_fn  sc_real_gs  = NULL;   // 渲染器真实 glGetString
static ame_sc_gsi_fn sc_real_gsi = NULL;   // 渲染器真实 glGetStringi
static ame_sc_gi_fn  sc_real_gi  = NULL;   // 渲染器真实 glGetIntegerv

static int sc_ran = 0;                     // 探测是否已成功执行
static const char *sc_real_ext_string = NULL;   // 渲染器原本上报的 GL_EXTENSIONS(可 NULL)
static int  sc_num_ext = -1;                    // 渲染器原本上报的 GL_NUM_EXTENSIONS(可 -1)

static int  sc_extra_count = 0;
static const char *sc_extra_names[64];
static char sc_ext_string[32768];
static int  sc_ext_string_ready = 0;

static int sc_lim_image_units   = -1;
static int sc_lim_ssbo_bindings = -1;
static int sc_lim_ubo_bindings  = -1;
static int sc_lim_aniso         = -1;
static int sc_lim_comb_tex      = -1;
static int sc_lim_image_samples = -1;
static int sc_lim_compute_invoc = -1;

#pragma mark - 环境开关

static int sc_env_enabled(const char *name, int dflt) {
    const char *v = getenv(name);
    if (v == NULL || v[0] == '\0') return dflt;
    return !(v[0] == '0' && v[1] == '\0');
}

static int sc_enabled(void)        { return sc_env_enabled("AMETHYST_SHADER_CAP", 1); }
static int sc_report_enabled(void) { return sc_env_enabled("AMETHYST_SHADER_CAP_REPORT", 1); }
static int sc_log_enabled(void)    { return sc_env_enabled("AMETHYST_SHADER_CAP_LOG", 1); }

#pragma mark - 候选入口表

enum {
    SC_BufferStorage,
    SC_BufferStorageEXT,
    SC_NamedBufferStorage,
    SC_NamedBufferStorageEXT,
    SC_BindBufferBase,
    SC_BindBufferBaseEXT,
    SC_BindBufferRange,
    SC_BindBufferRangeEXT,
    SC_ShaderStorageBlockBinding,
    SC_ShaderStorageBlockBindingEXT,
    SC_GetProgramResourceIndex,
    SC_GetProgramResourceiv,
    SC_BindImageTexture,
    SC_BindImageTextureEXT,
    SC_TexStorage2D,
    SC_TexStorage2DEXT,
    SC_TexStorage3D,
    SC_TexStorage3DEXT,
    SC_GenSamplers,
    SC_BindSampler,
    SC_SamplerParameteri,
    SC_SamplerParameterf,
    SC_SamplerParameterfv,
    SC_SamplerParameteriv,
    SC_GetSamplerParameteriv,
    SC_DeleteSamplers,
    SC_GenFramebuffers,
    SC_BindFramebuffer,
    SC_FramebufferTexture2D,
    SC_RenderbufferStorageMultisample,
    SC_DrawBuffers,
    SC_DrawArraysInstanced,
    SC_DrawElementsInstanced,
    SC_VertexAttribDivisor,
    SC_BindVertexArray,
    SC_TexParameterf,
    SC_TexParameteri,
    SC_MapBufferRange,
    SC_ClearBufferfv,
    SC_ClearBufferfi,
    SC_DispatchCompute,
    SC_DispatchComputeIndirect,
    SC_PatchParameteri,
    SC_GetStringi,
    SC_ENTRY_COUNT
};

static const char *const sc_entry_names[SC_ENTRY_COUNT] = {
    "glBufferStorage",
    "glBufferStorageEXT",
    "glNamedBufferStorage",
    "glNamedBufferStorageEXT",
    "glBindBufferBase",
    "glBindBufferBaseEXT",
    "glBindBufferRange",
    "glBindBufferRangeEXT",
    "glShaderStorageBlockBinding",
    "glShaderStorageBlockBindingEXT",
    "glGetProgramResourceIndex",
    "glGetProgramResourceiv",
    "glBindImageTexture",
    "glBindImageTextureEXT",
    "glTexStorage2D",
    "glTexStorage2DEXT",
    "glTexStorage3D",
    "glTexStorage3DEXT",
    "glGenSamplers",
    "glBindSampler",
    "glSamplerParameteri",
    "glSamplerParameterf",
    "glSamplerParameterfv",
    "glSamplerParameteriv",
    "glGetSamplerParameteriv",
    "glDeleteSamplers",
    "glGenFramebuffers",
    "glBindFramebuffer",
    "glFramebufferTexture2D",
    "glRenderbufferStorageMultisample",
    "glDrawBuffers",
    "glDrawArraysInstanced",
    "glDrawElementsInstanced",
    "glVertexAttribDivisor",
    "glBindVertexArray",
    "glTexParameterf",
    "glTexParameteri",
    "glMapBufferRange",
    "glClearBufferfv",
    "glClearBufferfi",
    "glDispatchCompute",
    "glDispatchComputeIndirect",
    "glPatchParameteri",
    "glGetStringi",
};

static void *sc_entry_ptr[SC_ENTRY_COUNT];

#define SC_HAVE(i) (sc_entry_ptr[(i)] != NULL)

#pragma mark - 真实实现解析

static void sc_ensure_real_gs(void) {
    if (sc_real_gs == NULL && sc_resolve != NULL)
        sc_real_gs = (ame_sc_gs_fn)sc_resolve("glGetString");
}

static void sc_ensure_real_gsi(void) {
    if (sc_real_gsi == NULL && sc_resolve != NULL)
        sc_real_gsi = (ame_sc_gsi_fn)sc_resolve("glGetStringi");
}

static void sc_ensure_real_gi(void) {
    if (sc_real_gi == NULL && sc_resolve != NULL)
        sc_real_gi = (ame_sc_gi_fn)sc_resolve("glGetIntegerv");
}

static int sc_query_int(unsigned int pname) {
    if (sc_real_gi == NULL) return -1;
    int v = -1;
    sc_real_gi(pname, &v);
    return v;
}

static int sc_real_ext_count(void) {
    if (sc_num_ext >= 0) return sc_num_ext;
    int n = sc_query_int(SC_GL_NUM_EXTENSIONS);
    if (n >= 0) sc_num_ext = n;
    return sc_num_ext;
}

#pragma mark - core -> EXT 别名转发(仅在 core 缺失时)

static void *sc_t_bufstorage     = NULL;
static void *sc_t_namedbufstorage = NULL;
static void *sc_t_bbase          = NULL;
static void *sc_t_brange         = NULL;
static void *sc_t_ssbb           = NULL;
static void *sc_t_bindimage      = NULL;
static void *sc_t_texst2d        = NULL;
static void *sc_t_texst3d        = NULL;

static void ame_sc_glBufferStorage(ame_GLenum target, ame_GLsizeiptr size,
                                   const void *data, ame_GLbitfield flags) {
    if (sc_t_bufstorage)
        ((void (*)(ame_GLenum, ame_GLsizeiptr, const void *, ame_GLbitfield))sc_t_bufstorage)
            (target, size, data, flags);
}

static void ame_sc_glNamedBufferStorage(ame_GLuint buffer, ame_GLsizeiptr size,
                                        const void *data, ame_GLbitfield flags) {
    if (sc_t_namedbufstorage)
        ((void (*)(ame_GLuint, ame_GLsizeiptr, const void *, ame_GLbitfield))sc_t_namedbufstorage)
            (buffer, size, data, flags);
}

static void ame_sc_glBindBufferBase(ame_GLenum target, ame_GLuint index, ame_GLuint buffer) {
    if (sc_t_bbase)
        ((void (*)(ame_GLenum, ame_GLuint, ame_GLuint))sc_t_bbase)(target, index, buffer);
}

static void ame_sc_glBindBufferRange(ame_GLenum target, ame_GLuint index, ame_GLuint buffer,
                                     ame_GLintptr offset, ame_GLsizeiptr size) {
    if (sc_t_brange)
        ((void (*)(ame_GLenum, ame_GLuint, ame_GLuint, ame_GLintptr, ame_GLsizeiptr))sc_t_brange)
            (target, index, buffer, offset, size);
}

static void ame_sc_glShaderStorageBlockBinding(ame_GLuint program, ame_GLuint storageBlockIndex,
                                               ame_GLuint storageBlockBinding) {
    if (sc_t_ssbb)
        ((void (*)(ame_GLuint, ame_GLuint, ame_GLuint))sc_t_ssbb)
            (program, storageBlockIndex, storageBlockBinding);
}

static void ame_sc_glBindImageTexture(ame_GLuint unit, ame_GLuint texture, ame_GLint level,
                                      ame_GLboolean layered, ame_GLint layer, ame_GLenum access,
                                      ame_GLenum format) {
    if (sc_t_bindimage)
        ((void (*)(ame_GLuint, ame_GLuint, ame_GLint, ame_GLboolean, ame_GLint, ame_GLenum, ame_GLenum))sc_t_bindimage)
            (unit, texture, level, layered, layer, access, format);
}

static void ame_sc_glTexStorage2D(ame_GLenum target, ame_GLsizei levels, ame_GLenum internalformat,
                                  ame_GLsizei width, ame_GLsizei height) {
    if (sc_t_texst2d)
        ((void (*)(ame_GLenum, ame_GLsizei, ame_GLenum, ame_GLsizei, ame_GLsizei))sc_t_texst2d)
            (target, levels, internalformat, width, height);
}

static void ame_sc_glTexStorage3D(ame_GLenum target, ame_GLsizei levels, ame_GLenum internalformat,
                                  ame_GLsizei width, ame_GLsizei height, ame_GLsizei depth) {
    if (sc_t_texst3d)
        ((void (*)(ame_GLenum, ame_GLsizei, ame_GLenum, ame_GLsizei, ame_GLsizei, ame_GLsizei))sc_t_texst3d)
            (target, levels, internalformat, width, height, depth);
}

typedef struct {
    const char *core;
    const char *ext;
    void       *fn;
    void      **target;
} sc_alias_t;

static const sc_alias_t sc_aliases[] = {
    { "glBufferStorage",             "glBufferStorageEXT",             (void *)ame_sc_glBufferStorage,             &sc_t_bufstorage      },
    { "glNamedBufferStorage",        "glNamedBufferStorageEXT",        (void *)ame_sc_glNamedBufferStorage,        &sc_t_namedbufstorage },
    { "glBindBufferBase",            "glBindBufferBaseEXT",            (void *)ame_sc_glBindBufferBase,            &sc_t_bbase           },
    { "glBindBufferRange",           "glBindBufferRangeEXT",           (void *)ame_sc_glBindBufferRange,           &sc_t_brange          },
    { "glShaderStorageBlockBinding", "glShaderStorageBlockBindingEXT", (void *)ame_sc_glShaderStorageBlockBinding, &sc_t_ssbb            },
    { "glBindImageTexture",          "glBindImageTextureEXT",          (void *)ame_sc_glBindImageTexture,          &sc_t_bindimage       },
    { "glTexStorage2D",              "glTexStorage2DEXT",              (void *)ame_sc_glTexStorage2D,              &sc_t_texst2d         },
    { "glTexStorage3D",              "glTexStorage3DEXT",              (void *)ame_sc_glTexStorage3D,              &sc_t_texst3d         },
};
#define SC_ALIAS_COUNT (sizeof(sc_aliases) / sizeof(sc_aliases[0]))

static void *sc_resolve_alias(const char *name) {
    if (sc_resolve == NULL) return NULL;
    for (size_t i = 0; i < SC_ALIAS_COUNT; i++) {
        const sc_alias_t *a = &sc_aliases[i];
        if (strcmp(name, a->core) != 0) continue;
        // core 名本身已有实现 -> 不介入(行为与原路径完全一致)
        if (sc_resolve(a->core) != NULL) return NULL;
        if (*a->target == NULL) {
            void *t = sc_resolve(a->ext);
            if (t == NULL) return NULL;   // EXT 也没有 -> 不伪造
            *a->target = t;
        }
        if (sc_log_enabled())
            NSLog(@"[SHADER-CAP] alias map %s -> %s (impl=%p)", a->core, a->ext, *a->target);
        return a->fn;
    }
    return NULL;
}

#pragma mark - 扩展上报包装(glGetString / glGetStringi / glGetIntegerv)

static const char *ame_sc_glGetString(unsigned int name) {
    if (sc_real_gs == NULL) return NULL;
    const unsigned char *r = sc_real_gs(name);
    if (name == SC_GL_EXTENSIONS) {
        ame_shader_cap_probe_run_once();
        if (sc_report_enabled() && sc_ext_string_ready && sc_real_ext_string != NULL)
            return sc_ext_string;
    } else if (name == SC_GL_VERSION) {
        ame_shader_cap_probe_run_once();
    }
    return (const char *)r;
}

static const char *ame_sc_glGetStringi(unsigned int name, unsigned int index) {
    ame_shader_cap_probe_run_once();
    if (name == SC_GL_EXTENSIONS && sc_report_enabled()) {
        int rc = sc_real_ext_count();
        if (rc > 0 && (int)index >= rc && (int)index < rc + sc_extra_count)
            return sc_extra_names[(int)index - rc];
    }
    if (sc_real_gsi == NULL) return NULL;
    return (const char *)sc_real_gsi(name, index);
}

static void ame_sc_glGetIntegerv(unsigned int pname, int *params) {
    if (sc_real_gi == NULL) return;
    sc_real_gi(pname, params);
    if (params == NULL) return;
    ame_shader_cap_probe_run_once();
    // 只在「渲染器确实支持 glGetStringi 枚举」时才抬高 NUM_EXTENSIONS —— 否则多出来的
    // index 无法被枚举到（glGetStringi 会落回真实实现返回 NULL），抬高计数反而有害。
    if (pname == SC_GL_NUM_EXTENSIONS && sc_report_enabled() &&
        sc_real_gsi != NULL && sc_extra_count > 0 &&
        *params >= 0 && *params < 1000000)
        *params = *params + sc_extra_count;
}

#pragma mark - 扩展判定(全部由探测结果驱动)

static int sc_has_token(const char *list, const char *name) {
    if (list == NULL || name == NULL || name[0] == '\0') return 0;
    size_t n = strlen(name);
    const char *p = list;
    while ((p = strstr(p, name)) != NULL) {
        char before = (p == list) ? ' ' : p[-1];
        char after = p[n];
        if ((before == ' ' || before == '\0') && (after == ' ' || after == '\0')) return 1;
        p += n;
    }
    return 0;
}

static void sc_add_extra(const char *name) {
    if (sc_extra_count >= (int)(sizeof(sc_extra_names) / sizeof(sc_extra_names[0]))) return;
    if (sc_has_token(sc_real_ext_string, name)) return;      // 渲染器已自报
    for (int i = 0; i < sc_extra_count; i++)
        if (strcmp(sc_extra_names[i], name) == 0) return;
    sc_extra_names[sc_extra_count++] = name;
}

static void sc_decide_ext(const char *ext, int ok, const char *why) {
    if (ok && sc_has_token(sc_real_ext_string, ext)) {
        if (sc_log_enabled())
            NSLog(@"[SHADER-CAP] report %s = YES (渲染器已自报, 无需补报)", ext);
        return;
    }
    if (sc_log_enabled())
        NSLog(@"[SHADER-CAP] report %s = %s (%s)", ext, ok ? "YES" : "NO", why);
    if (ok) sc_add_extra(ext);
}

static void sc_decide_all(void) {
    sc_decide_ext("GL_ARB_shader_storage_buffer_object",
        SC_HAVE(SC_BindBufferBase) &&
        (SC_HAVE(SC_BufferStorage) || SC_HAVE(SC_BufferStorageEXT)) &&
        SC_HAVE(SC_ShaderStorageBlockBinding) && sc_lim_ssbo_bindings > 0,
        "需 glBindBufferBase+glBufferStorage+glShaderStorageBlockBinding 且 MAX_SHADER_STORAGE_BUFFER_BINDINGS>0");

    sc_decide_ext("GL_ARB_shader_image_load_store",
        SC_HAVE(SC_BindImageTexture) &&
        (SC_HAVE(SC_TexStorage2D) || SC_HAVE(SC_TexStorage3D)) && sc_lim_image_units > 0,
        "需 glBindImageTexture+glTexStorage2D/3D 且 MAX_IMAGE_UNITS>0");

    sc_decide_ext("GL_ARB_sampler_objects",
        SC_HAVE(SC_GenSamplers) && SC_HAVE(SC_BindSampler) && SC_HAVE(SC_DeleteSamplers),
        "需 glGenSamplers+glBindSampler+glDeleteSamplers (硬件采样器/SEPARATE_HARDWARE_SAMPLERS 的真实语义)");

    sc_decide_ext("GL_ARB_texture_filter_anisotropic",
        SC_HAVE(SC_TexParameterf) && sc_lim_aniso > 1,
        "需 glTexParameterf 且 MAX_TEXTURE_MAX_ANISOTROPY_EXT>1");
    sc_decide_ext("GL_EXT_texture_filter_anisotropic",
        SC_HAVE(SC_TexParameterf) && sc_lim_aniso > 1,
        "需 glTexParameterf 且 MAX_TEXTURE_MAX_ANISOTROPY_EXT>1");

    sc_decide_ext("GL_ARB_buffer_storage",
        SC_HAVE(SC_BufferStorage) || SC_HAVE(SC_BufferStorageEXT),
        "需 glBufferStorage / glBufferStorageEXT");

    sc_decide_ext("GL_ARB_texture_storage",
        SC_HAVE(SC_TexStorage2D) || SC_HAVE(SC_TexStorage2DEXT),
        "需 glTexStorage2D / glTexStorage2DEXT");
    sc_decide_ext("GL_EXT_texture_storage",
        SC_HAVE(SC_TexStorage2D) || SC_HAVE(SC_TexStorage2DEXT),
        "需 glTexStorage2D / glTexStorage2DEXT");

    sc_decide_ext("GL_ARB_uniform_buffer_object",
        SC_HAVE(SC_BindBufferBase) && sc_lim_ubo_bindings > 0,
        "需 glBindBufferBase 且 MAX_UNIFORM_BUFFER_BINDINGS>0");

    sc_decide_ext("GL_ARB_vertex_array_object",
        SC_HAVE(SC_BindVertexArray), "需 glBindVertexArray");

    sc_decide_ext("GL_ARB_draw_buffers",
        SC_HAVE(SC_DrawBuffers), "需 glDrawBuffers (MRT)");

    sc_decide_ext("GL_ARB_draw_instanced",
        SC_HAVE(SC_DrawArraysInstanced), "需 glDrawArraysInstanced");
    sc_decide_ext("GL_ARB_instanced_arrays",
        SC_HAVE(SC_VertexAttribDivisor), "需 glVertexAttribDivisor");

    sc_decide_ext("GL_ARB_framebuffer_object",
        SC_HAVE(SC_GenFramebuffers) && SC_HAVE(SC_BindFramebuffer),
        "需 glGenFramebuffers+glBindFramebuffer");
    sc_decide_ext("GL_EXT_framebuffer_object",
        SC_HAVE(SC_GenFramebuffers) && SC_HAVE(SC_BindFramebuffer),
        "需 glGenFramebuffers+glBindFramebuffer");

    sc_decide_ext("GL_ARB_multisample",
        SC_HAVE(SC_RenderbufferStorageMultisample), "需 glRenderbufferStorageMultisample");
    sc_decide_ext("GL_EXT_framebuffer_multisample",
        SC_HAVE(SC_RenderbufferStorageMultisample), "需 glRenderbufferStorageMultisample");

    sc_decide_ext("GL_ARB_map_buffer_range",
        SC_HAVE(SC_MapBufferRange), "需 glMapBufferRange");

    // ★ 明确「证据不足以判定」的项: 一律不报(写进日志备查)。
    if (sc_log_enabled()) {
        NSLog(@"[SHADER-CAP] report GL_ARB_compute_shader = %s (glDispatchCompute=%s; MAX_COMPUTE_WORK_GROUP_INVOCATIONS=%d)",
              (SC_HAVE(SC_DispatchCompute) && sc_lim_compute_invoc > 0) ? "YES" : "NO",
              SC_HAVE(SC_DispatchCompute) ? "present" : "absent", sc_lim_compute_invoc);
        NSLog(@"[SHADER-CAP] report tesselation 证据: glPatchParameteri=%s (本次不碰)",
              SC_HAVE(SC_PatchParameteri) ? "present" : "absent");
        NSLog(@"[SHADER-CAP] report GL_ARB_direct_state_access / GL_ARB_texture_float / GL_ARB_depth_texture "
              @"/ GL_ARB_shadow / GL_EXT_framebuffer_sRGB = NOT REPORTED (无足够运行时证据, 见报告待验证清单)");
    }
}

static void sc_build_ext_string(void) {
    size_t cap = sizeof(sc_ext_string);
    sc_ext_string[0] = '\0';
    if (sc_real_ext_string != NULL && sc_real_ext_string[0] != '\0')
        strncat(sc_ext_string, sc_real_ext_string, cap - 1);
    for (int i = 0; i < sc_extra_count; i++) {
        size_t used = strlen(sc_ext_string);
        if (used >= cap - 1) break;
        strncat(sc_ext_string, (used > 0 ? " " : ""), cap - used - 1);
        used = strlen(sc_ext_string);
        if (used >= cap - 1) break;
        strncat(sc_ext_string, sc_extra_names[i], cap - used - 1);
    }
    sc_ext_string_ready = 1;
}

#pragma mark - 探测

static void sc_probe_procs(void) {
    for (int i = 0; i < SC_ENTRY_COUNT; i++) {
        sc_entry_ptr[i] = sc_resolve(sc_entry_names[i]);
        if (sc_log_enabled())
            NSLog(@"[SHADER-CAP] proc %-34s = %s", sc_entry_names[i],
                  sc_entry_ptr[i] != NULL ? "PRESENT" : "absent");
    }
}

static void sc_log_extensions(void) {
    const unsigned char *exts = sc_real_gs(SC_GL_EXTENSIONS);
    sc_real_ext_string = (exts != NULL) ? (const char *)exts : NULL;
    if (exts != NULL) {
        NSLog(@"[SHADER-CAP] extensions(glGetString) = %s", (const char *)exts);
    } else {
        NSLog(@"[SHADER-CAP] extensions(glGetString) = (null)");
    }

    int n = sc_real_ext_count();
    if (sc_log_enabled()) {
        if (n > 0 && sc_real_gsi != NULL) {
            NSLog(@"[SHADER-CAP] GL_NUM_EXTENSIONS = %d (via glGetStringi)", n);
            char line[1024];
            for (int i = 0; i < n; i += 8) {
                line[0] = '\0';
                for (int j = i; j < i + 8 && j < n; j++) {
                    const unsigned char *e = sc_real_gsi(SC_GL_EXTENSIONS, (unsigned int)j);
                    if (e == NULL) continue;
                    size_t used = strlen(line);
                    if (used >= sizeof(line) - 1) break;
                    snprintf(line + used, sizeof(line) - used, "%s%s",
                             used > 0 ? " " : "", (const char *)e);
                }
                NSLog(@"[SHADER-CAP] ext[%d..%d] %s", i, i + 7, line);
            }
        } else {
            NSLog(@"[SHADER-CAP] GL_NUM_EXTENSIONS unavailable (glGetStringi=%p, n=%d)",
                  (void *)sc_real_gsi, n);
        }
    }
}

void ame_shader_cap_probe_run_once(void) {
    if (sc_ran) return;
    if (!sc_enabled()) return;
    if (sc_resolve == NULL) return;
    sc_ensure_real_gs();
    sc_ensure_real_gsi();
    sc_ensure_real_gi();
    if (sc_real_gs == NULL) return;

    const unsigned char *ver = sc_real_gs(SC_GL_VERSION);
    if (ver == NULL) return;   // 无当前上下文 -> 不置位, 下次再试

    sc_ran = 1;
    NSLog(@"[SHADER-CAP] ===== GL capability probe (once) =====");
    NSLog(@"[SHADER-CAP] renderer=%s", getenv("AMETHYST_RENDERER") ?: "<unset>");
    const unsigned char *vnd = sc_real_gs(SC_GL_VENDOR);
    const unsigned char *ren = sc_real_gs(SC_GL_RENDERER);
    NSLog(@"[SHADER-CAP] VENDOR=%s", vnd ? (const char *)vnd : "(null)");
    NSLog(@"[SHADER-CAP] RENDERER=%s", ren ? (const char *)ren : "(null)");
    NSLog(@"[SHADER-CAP] VERSION=%s", (const char *)ver);

    sc_probe_procs();

    sc_lim_image_units   = sc_query_int(SC_GL_MAX_IMAGE_UNITS);
    sc_lim_ssbo_bindings = sc_query_int(SC_GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS);
    sc_lim_ubo_bindings  = sc_query_int(SC_GL_MAX_UNIFORM_BUFFER_BINDINGS);
    sc_lim_aniso         = sc_query_int(SC_GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT);
    sc_lim_comb_tex      = sc_query_int(SC_GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS);
    sc_lim_image_samples = sc_query_int(SC_GL_MAX_IMAGE_SAMPLES);
    sc_lim_compute_invoc = sc_query_int(SC_GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS);

    if (sc_log_enabled()) {
        NSLog(@"[SHADER-CAP] limit MAX_IMAGE_UNITS=%d", sc_lim_image_units);
        NSLog(@"[SHADER-CAP] limit MAX_SHADER_STORAGE_BUFFER_BINDINGS=%d", sc_lim_ssbo_bindings);
        NSLog(@"[SHADER-CAP] limit MAX_UNIFORM_BUFFER_BINDINGS=%d", sc_lim_ubo_bindings);
        NSLog(@"[SHADER-CAP] limit MAX_TEXTURE_MAX_ANISOTROPY_EXT=%d", sc_lim_aniso);
        NSLog(@"[SHADER-CAP] limit MAX_COMBINED_TEXTURE_IMAGE_UNITS=%d", sc_lim_comb_tex);
        NSLog(@"[SHADER-CAP] limit MAX_IMAGE_SAMPLES=%d", sc_lim_image_samples);
        NSLog(@"[SHADER-CAP] limit MAX_COMPUTE_WORK_GROUP_INVOCATIONS=%d", sc_lim_compute_invoc);
    }

    sc_log_extensions();
    sc_decide_all();
    if (sc_report_enabled()) sc_build_ext_string();

    if (sc_log_enabled()) {
        if (sc_extra_count == 0) {
            NSLog(@"[SHADER-CAP] extras(none) -- 没有可诚实补报的扩展");
        } else {
            for (int i = 0; i < sc_extra_count; i++)
                NSLog(@"[SHADER-CAP] extra[%d] = %s", i, sc_extra_names[i]);
        }
    }
    NSLog(@"[SHADER-CAP] ===== probe done (extras=%d) =====", sc_extra_count);
}

#pragma mark - 对外入口

void ame_shader_cap_setup(ame_sc_resolve_fn resolve) {
    if (resolve == NULL) return;
    if (!sc_enabled()) return;
    sc_resolve = resolve;
    sc_ensure_real_gs();
    sc_ensure_real_gsi();
    sc_ensure_real_gi();
    NSLog(@"[SHADER-CAP] setup: resolve=%p glGetString=%p glGetStringi=%p glGetIntegerv=%p",
          (void *)resolve, (void *)sc_real_gs, (void *)sc_real_gsi, (void *)sc_real_gi);
}

void *ame_shader_cap_resolve_entry(const char *name) {
    if (name == NULL || sc_resolve == NULL || !sc_enabled()) return NULL;

    // (1) 上报相关包装 —— 只在真正解析到渲染器实现时才接管。
    if (sc_report_enabled()) {
        if (strcmp(name, "glGetString") == 0) {
            sc_ensure_real_gs();
            return sc_real_gs != NULL ? (void *)ame_sc_glGetString : NULL;
        }
        if (strcmp(name, "glGetStringi") == 0) {
            sc_ensure_real_gsi();
            return sc_real_gsi != NULL ? (void *)ame_sc_glGetStringi : NULL;
        }
        if (strcmp(name, "glGetIntegerv") == 0) {
            sc_ensure_real_gi();
            return sc_real_gi != NULL ? (void *)ame_sc_glGetIntegerv : NULL;
        }
    }

    // (2) core -> EXT 别名映射。
    return sc_resolve_alias(name);
}
