// SimpleFPEWrapper - SimpleFPEWrapper/shader/shaderobjects.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

// plans/09 9.2: GL 2.0 shader objects and the ARB_shader_objects aliases
// LWJGL-era applications resolve. glShaderSource keeps the caller's
// original text (GetShaderSource returns it per spec). glCompileShader
// uploads that original directly when its dialect and #version are already
// acceptable to the backend; otherwise it feeds the translated source to
// the GLES backend and falls back to the original only when translation
// fails.
//
// Shader records are process-global like display-list definitions:
// share-group relationships are invisible to the wrapper (see
// docs/context-model.md).

#include "translator.h"
#include "../init.h"
#include "../log.h"
#include "../fpe/fpe.hpp"
#include "../fpe/drawing1x.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

struct shader_record_t {
    GLenum stage = 0;
    std::string original;
    std::string translate_log;
    bool translated = false;
    // The source was classified as directly acceptable to the backend
    // (dialect + #version <= backend shading-language capability). This
    // remains true even after a later link re-uploads a translated form for
    // a program that is not entirely pass-through.
    bool native_passthrough = false;
    // Standalone glslang link failed but the TU parses: unresolved
    // cross-TU symbols. GL 2.1 resolves those at glLinkProgram, so
    // COMPILE_STATUS reports success and translation reruns at link with
    // every TU of the stage (GLES has no notion of this).
    bool deferred = false;
    // What the BACKEND object currently holds: the app's original source
    // (translation failed, or a mixed-program fallback at link) rather
    // than translated ESSL. Programs sharing the shader consult this at
    // link time to upload whichever form their own consistency needs.
    bool backend_uploaded_original = false;
    // Like backend_uploaded_original, but specifically the original was
    // uploaded because it is a native pass-through form, not a fallback.
    bool backend_holds_native = false;
    // GLSL 1.20 uniform initializers scraped by the translator; applied
    // with glUniform* after every successful link of a containing program.
    std::vector<SFPEW::Shader::uniform_initializer_t> uniform_inits;
};

// Logical program state: the wrapper tracks attachments itself because
// GLES rejects two shaders of one stage on a program, while GL 2.1 allows
// any number of compilation units per stage. Only the first TU of each
// stage is attached to the backend; a combined translation is compiled
// into it at link time when needed.
struct program_record_t {
    std::vector<GLuint> shaders;          // logical attach order
    std::vector<GLuint> backend_attached; // subset attached to the backend
    bool force_link_fail = false;         // combined translation failed
    bool stage_combined[2] = {false, false}; // [0]=vertex, [1]=fragment
    std::string link_log;
    std::vector<SFPEW::Shader::uniform_initializer_t> combined_inits;
};

std::mutex g_shader_mutex; // guards both maps; never held across backend calls
std::unordered_map<GLuint, shader_record_t>& shaderRecords() {
    static std::unordered_map<GLuint, shader_record_t> records;
    return records;
}
std::unordered_map<GLuint, program_record_t>& programRecords() {
    static std::unordered_map<GLuint, program_record_t> records;
    return records;
}

bool contains(const std::vector<GLuint>& v, GLuint x) {
    return std::find(v.begin(), v.end(), x) != v.end();
}

const char* shaderStageLabel(GLenum stage) {
    return stage == GL_VERTEX_SHADER ? "vertex" : "fragment";
}

std::string backendShaderInfoLog(GLuint shader) {
    if (g_glFuncs.glGetShaderiv == nullptr || g_glFuncs.glGetShaderInfoLog == nullptr) return {};
    GLint length = 0;
    g_glFuncs.glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &length);
    if (length <= 1) return {};
    std::string log((size_t)length - 1, '\0');
    GLsizei written = 0;
    g_glFuncs.glGetShaderInfoLog(shader, (GLsizei)length, &written, log.data());
    log.resize((size_t)std::max(written, 0));
    return log;
}

// Called after every backend glCompileShader so a shader that fails on the
// driver is reported immediately, regardless of whether it went through the
// native pass-through path or the translator. The backend log is included;
// SFPEW_DUMP_SHADERS also writes the source for offline inspection.
void reportBackendCompileFailure(GLuint shader, GLenum stage, const char* path,
                                 const std::string& source) {
    if (g_glFuncs.glGetShaderiv == nullptr) return;
    GLint status = GL_FALSE;
    g_glFuncs.glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (status == GL_TRUE) return;

    const std::string log = backendShaderInfoLog(shader);
    SFPEW_LOGE("shader %u [%s] %s compile failed", shader, shaderStageLabel(stage), path);
    if (!log.empty()) SFPEW_LOGE("backend log:\n%s", log.c_str());
    if (!source.empty()) SFPEW_LOGE("source:\n%s", source.c_str());

    const char* dump_dir = std::getenv("SFPEW_DUMP_SHADERS");
    if (dump_dir != nullptr && dump_dir[0] != '\0') {
        char dump_path[512];
        std::snprintf(dump_path, sizeof(dump_path), "%s/sfpew_failed_shader_%u.txt", dump_dir,
                      shader);
        if (FILE* f = std::fopen(dump_path, "w")) {
            std::fprintf(f, "=== compile path ===\n%s\n=== backend log ===\n%s\n=== source ===\n%s\n",
                         path, log.c_str(), source.c_str());
            std::fclose(f);
        }
    }
}

std::string backendProgramInfoLog(GLuint program) {
    if (g_glFuncs.glGetProgramiv == nullptr || g_glFuncs.glGetProgramInfoLog == nullptr) return {};
    GLint length = 0;
    g_glFuncs.glGetProgramiv(program, GL_INFO_LOG_LENGTH, &length);
    if (length <= 1) return {};
    std::string log((size_t)length - 1, '\0');
    GLsizei written = 0;
    g_glFuncs.glGetProgramInfoLog(program, (GLsizei)length, &written, log.data());
    log.resize((size_t)std::max(written, 0));
    return log;
}

void reportBackendLinkFailure(GLuint program) {
    if (g_glFuncs.glGetProgramiv == nullptr) return;
    GLint status = GL_FALSE;
    g_glFuncs.glGetProgramiv(program, GL_LINK_STATUS, &status);
    if (status == GL_TRUE) return;

    const std::string log = backendProgramInfoLog(program);
    SFPEW_LOGE("program %u link failed", program);
    if (!log.empty()) SFPEW_LOGE("backend log:\n%s", log.c_str());
}

} // namespace

GLuint glCreateShader(GLenum type) {
    if (!sfpewEnsureBackend() || g_glFuncs.glCreateShader == nullptr) return 0;
    if (type != GL_VERTEX_SHADER && type != GL_FRAGMENT_SHADER) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return 0;
    }
    const GLuint shader = g_glFuncs.glCreateShader(type);
    if (shader != 0) {
        std::lock_guard<std::mutex> lock(g_shader_mutex);
        shaderRecords()[shader] = shader_record_t{};
        shaderRecords()[shader].stage = type;
    }
    return shader;
}

void glDeleteShader(GLuint shader) {
    if (!sfpewEnsureBackend() || g_glFuncs.glDeleteShader == nullptr) return;
    g_glFuncs.glDeleteShader(shader);
    std::lock_guard<std::mutex> lock(g_shader_mutex);
    shaderRecords().erase(shader);
}

void glShaderSource(GLuint shader, GLsizei count, const GLchar* const* string, const GLint* length) {
    if (!sfpewEnsureBackend()) return;
    if (count < 0) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    if (string == nullptr) return;

    // Concatenate per spec; negative/absent lengths mean NUL-terminated.
    std::string source;
    for (GLsizei i = 0; i < count; ++i) {
        if (string[i] == nullptr) continue;
        if (length != nullptr && length[i] >= 0)
            source.append(string[i], (size_t)length[i]);
        else
            source.append(string[i]);
    }

    std::lock_guard<std::mutex> lock(g_shader_mutex);
    auto it = shaderRecords().find(shader);
    if (it == shaderRecords().end()) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return;
    }
    it->second.original = std::move(source);
    it->second.translated = false;
    it->second.native_passthrough = false;
    it->second.backend_holds_native = false;
    it->second.translate_log.clear();
}

void glCompileShader(GLuint shader) {
    if (!sfpewEnsureBackend() || g_glFuncs.glCompileShader == nullptr ||
        g_glFuncs.glShaderSource == nullptr) {
        return;
    }
    std::string original;
    GLenum stage = 0;
    {
        std::lock_guard<std::mutex> lock(g_shader_mutex);
        auto it = shaderRecords().find(shader);
        if (it == shaderRecords().end()) {
            g_glstate.set_error(GL_INVALID_OPERATION);
            return;
        }
        original = it->second.original;
        stage = it->second.stage;
    }

    auto target = SFPEW::Shader::detect_backend_target();
    if (SFPEW::Shader::shader_can_passthrough(original, target)) {
        const char* text = original.c_str();
        const GLint text_length = (GLint)original.size();
        g_glFuncs.glShaderSource(shader, 1, &text, &text_length);
        g_glFuncs.glCompileShader(shader);
        reportBackendCompileFailure(shader, stage, "native passthrough", original);
        std::lock_guard<std::mutex> lock(g_shader_mutex);
        auto it = shaderRecords().find(shader);
        if (it != shaderRecords().end()) {
            it->second.translated = false;
            it->second.deferred = false;
            it->second.native_passthrough = true;
            it->second.backend_uploaded_original = true;
            it->second.backend_holds_native = true;
            it->second.translate_log.clear();
            it->second.uniform_inits.clear();
        }
        return;
    }

    auto result = SFPEW::Shader::translate(stage, original, target);
    const bool defer = !result.ok && result.parse_ok;
    if (!result.ok && !defer) {
        SFPEW_LOGW("shader %u: translation failed, passing original through:\n%s", shader,
                   result.log.c_str());
        // SFPEW_DUMP_SHADERS=<dir>: write the failing source + diagnostics
        // to a file for offline debugging (on-device logs truncate).
        const char* dump_dir = std::getenv("SFPEW_DUMP_SHADERS");
        if (dump_dir != nullptr && dump_dir[0] != '\0') {
            char path[512];
            std::snprintf(path, sizeof(path), "%s/sfpew_failed_shader_%u.txt", dump_dir, shader);
            if (FILE* f = std::fopen(path, "w")) {
                std::fprintf(f, "=== translator log ===\n%s\n=== original source ===\n%s\n",
                             result.log.c_str(), original.c_str());
                std::fclose(f);
            }
        }
    }

    if (!defer) {
        // Deferred TUs are compiled into the backend at link time only; a
        // standalone-incomplete TU has nothing valid to upload here.
        const std::string& upload = result.ok ? result.essl : original;
        const char* text = upload.c_str();
        const GLint text_length = (GLint)upload.size();
        g_glFuncs.glShaderSource(shader, 1, &text, &text_length);
        g_glFuncs.glCompileShader(shader);
        reportBackendCompileFailure(shader, stage,
                                    result.ok ? "translated ESSL" : "original fallback", original);
    }

    std::lock_guard<std::mutex> lock(g_shader_mutex);
    auto it = shaderRecords().find(shader);
    if (it != shaderRecords().end()) {
        it->second.translated = result.ok;
        it->second.deferred = defer;
        it->second.native_passthrough = false;
        it->second.backend_uploaded_original = !defer && !result.ok;
        it->second.backend_holds_native = false;
        it->second.translate_log = defer ? std::string() : std::move(result.log);
        it->second.uniform_inits = std::move(result.uniform_initializers);
    }
}

void glGetShaderiv(GLuint shader, GLenum pname, GLint* params) {
    if (params == nullptr || !sfpewEnsureBackend() || g_glFuncs.glGetShaderiv == nullptr) return;
    if (pname == GL_COMPILE_STATUS) {
        std::lock_guard<std::mutex> lock(g_shader_mutex);
        auto it = shaderRecords().find(shader);
        if (it != shaderRecords().end() && it->second.deferred) {
            *params = GL_TRUE; // resolved at link time (GL 2.1 multi-TU)
            return;
        }
    }
    g_glFuncs.glGetShaderiv(shader, pname, params);
    if (pname == GL_INFO_LOG_LENGTH) {
        // Callers size their read buffer from this: it must cover the
        // translator diagnostics glGetShaderInfoLog prepends, or the log
        // comes back truncated after a few characters.
        std::lock_guard<std::mutex> lock(g_shader_mutex);
        auto it = shaderRecords().find(shader);
        if (it != shaderRecords().end() && !it->second.translate_log.empty()) {
            *params += (GLint)(it->second.translate_log.size() +
                               sizeof("[SFPEW translator]\n\n"));
        }
    }
}

namespace {

void applyOneInitializer(const SFPEW::Shader::uniform_initializer_t& init, GLint loc) {
    using base_t = SFPEW::Shader::uniform_initializer_t::base_t;
    const GLsizei count = (GLsizei)init.array_size;
    if (init.columns > 1) {
        if (init.base != base_t::f32) return;
        const GLfloat* v = init.f.data();
        switch (init.columns * 10 + init.vecsize) {
        case 22: if (g_glFuncs.glUniformMatrix2fv) g_glFuncs.glUniformMatrix2fv(loc, count, GL_FALSE, v); break;
        case 33: if (g_glFuncs.glUniformMatrix3fv) g_glFuncs.glUniformMatrix3fv(loc, count, GL_FALSE, v); break;
        case 44: if (g_glFuncs.glUniformMatrix4fv) g_glFuncs.glUniformMatrix4fv(loc, count, GL_FALSE, v); break;
        case 23: if (g_glFuncs.glUniformMatrix2x3fv) g_glFuncs.glUniformMatrix2x3fv(loc, count, GL_FALSE, v); break;
        case 24: if (g_glFuncs.glUniformMatrix2x4fv) g_glFuncs.glUniformMatrix2x4fv(loc, count, GL_FALSE, v); break;
        case 32: if (g_glFuncs.glUniformMatrix3x2fv) g_glFuncs.glUniformMatrix3x2fv(loc, count, GL_FALSE, v); break;
        case 34: if (g_glFuncs.glUniformMatrix3x4fv) g_glFuncs.glUniformMatrix3x4fv(loc, count, GL_FALSE, v); break;
        case 42: if (g_glFuncs.glUniformMatrix4x2fv) g_glFuncs.glUniformMatrix4x2fv(loc, count, GL_FALSE, v); break;
        case 43: if (g_glFuncs.glUniformMatrix4x3fv) g_glFuncs.glUniformMatrix4x3fv(loc, count, GL_FALSE, v); break;
        default: break;
        }
        return;
    }
    if (init.base == base_t::f32) {
        const GLfloat* v = init.f.data();
        switch (init.vecsize) {
        case 1: if (g_glFuncs.glUniform1fv) g_glFuncs.glUniform1fv(loc, count, v); break;
        case 2: if (g_glFuncs.glUniform2fv) g_glFuncs.glUniform2fv(loc, count, v); break;
        case 3: if (g_glFuncs.glUniform3fv) g_glFuncs.glUniform3fv(loc, count, v); break;
        case 4: if (g_glFuncs.glUniform4fv) g_glFuncs.glUniform4fv(loc, count, v); break;
        default: break;
        }
        return;
    }
    if (init.base == base_t::u32 && g_glFuncs.glUniform1uiv != nullptr) {
        const GLuint* v = (const GLuint*)init.i.data();
        switch (init.vecsize) {
        case 1: g_glFuncs.glUniform1uiv(loc, count, v); break;
        case 2: if (g_glFuncs.glUniform2uiv) g_glFuncs.glUniform2uiv(loc, count, v); break;
        case 3: if (g_glFuncs.glUniform3uiv) g_glFuncs.glUniform3uiv(loc, count, v); break;
        case 4: if (g_glFuncs.glUniform4uiv) g_glFuncs.glUniform4uiv(loc, count, v); break;
        default: break;
        }
        return;
    }
    const GLint* v = init.i.data();
    switch (init.vecsize) {
    case 1: if (g_glFuncs.glUniform1iv) g_glFuncs.glUniform1iv(loc, count, v); break;
    case 2: if (g_glFuncs.glUniform2iv) g_glFuncs.glUniform2iv(loc, count, v); break;
    case 3: if (g_glFuncs.glUniform3iv) g_glFuncs.glUniform3iv(loc, count, v); break;
    case 4: if (g_glFuncs.glUniform4iv) g_glFuncs.glUniform4iv(loc, count, v); break;
    default: break;
    }
}

// GL 2.1 semantics: uniform initializers define the post-link values. The
// translated ESSL cannot carry them, so set them here through the uniform
// API. Application values are overwritten exactly like a real relink.
void applyUniformInitializers(GLuint program,
                              const std::vector<SFPEW::Shader::uniform_initializer_t>& inits) {
    if (inits.empty() || g_glFuncs.glGetUniformLocation == nullptr ||
        g_glFuncs.glUseProgram == nullptr || g_glFuncs.glGetIntegerv == nullptr) {
        return;
    }
    GLint previous = 0;
    g_glFuncs.glGetIntegerv(GL_CURRENT_PROGRAM, &previous);
    sfpewInvalidateImmediateDrawState();
    g_glFuncs.glUseProgram(program);
    for (const auto& init : inits) {
        const GLint loc = g_glFuncs.glGetUniformLocation(program, init.name.c_str());
        if (loc >= 0) applyOneInitializer(init, loc);
    }
    sfpewInvalidateImmediateDrawState();
    g_glFuncs.glUseProgram((GLuint)previous);
}

void appendUnique(std::vector<SFPEW::Shader::uniform_initializer_t>& all,
                  const std::vector<SFPEW::Shader::uniform_initializer_t>& more) {
    for (const auto& init : more) {
        const auto same_name = [&](const auto& other) { return other.name == init.name; };
        if (std::none_of(all.begin(), all.end(), same_name)) all.push_back(init);
    }
}

int stageIndex(GLenum stage) { return stage == GL_VERTEX_SHADER ? 0 : 1; }

// Comment-insensitive token search (GL 2.1 requires a link error when the
// vertex stage never writes gl_Position; GLES does not check).
bool mentionsToken(const std::string& src, const char* token) {
    const size_t token_len = std::strlen(token);
    for (size_t i = 0; i < src.size();) {
        if (src[i] == '/' && i + 1 < src.size() && (src[i + 1] == '/' || src[i + 1] == '*')) {
            if (src[i + 1] == '/') {
                i = src.find('\n', i);
            } else {
                i = src.find("*/", i + 2);
                if (i != std::string::npos) i += 2;
            }
            if (i == std::string::npos) break;
            continue;
        }
        if (std::strncmp(src.c_str() + i, token, token_len) == 0 &&
            (i == 0 || !(std::isalnum((unsigned char)src[i - 1]) || src[i - 1] == '_')) &&
            (i + token_len >= src.size() ||
             !(std::isalnum((unsigned char)src[i + token_len]) || src[i + token_len] == '_'))) {
            return true;
        }
        ++i;
    }
    return false;
}

} // namespace

void glAttachShader(GLuint program, GLuint shader) {
    if (!sfpewEnsureBackend() || g_glFuncs.glAttachShader == nullptr) return;

    GLenum stage = 0;
    {
        std::lock_guard<std::mutex> lock(g_shader_mutex);
        auto sit = shaderRecords().find(shader);
        if (sit != shaderRecords().end()) {
            stage = sit->second.stage;
            auto& rec = programRecords()[program];
            if (contains(rec.shaders, shader)) {
                g_glstate.set_error(GL_INVALID_OPERATION); // already attached
                return;
            }
            bool stage_taken = false;
            for (GLuint other : rec.shaders) {
                auto oit = shaderRecords().find(other);
                stage_taken = stage_taken ||
                              (oit != shaderRecords().end() && oit->second.stage == stage);
            }
            rec.shaders.push_back(shader);
            if (stage_taken) return; // logical only: GLES forbids a second TU per stage
            rec.backend_attached.push_back(shader);
        }
    }
    g_glFuncs.glAttachShader(program, shader);
}

void glDetachShader(GLuint program, GLuint shader) {
    if (!sfpewEnsureBackend() || g_glFuncs.glDetachShader == nullptr) return;
    {
        std::lock_guard<std::mutex> lock(g_shader_mutex);
        auto pit = programRecords().find(program);
        if (pit != programRecords().end() && contains(pit->second.shaders, shader)) {
            auto& rec = pit->second;
            rec.shaders.erase(std::find(rec.shaders.begin(), rec.shaders.end(), shader));
            auto bit = std::find(rec.backend_attached.begin(), rec.backend_attached.end(), shader);
            if (bit == rec.backend_attached.end()) return; // was logical-only
            rec.backend_attached.erase(bit);
        }
    }
    g_glFuncs.glDetachShader(program, shader);
}

void glDeleteProgram(GLuint program) {
    if (!sfpewEnsureBackend() || g_glFuncs.glDeleteProgram == nullptr) return;
    g_glFuncs.glDeleteProgram(program);
    // Same name-recycling rule as buffers: once deleted, the name may be
    // handed to the app's next glCreateProgram, and a stale internal_programs
    // entry would make the program shadow zero out the app's own program.
    g_glstate_c.internal_programs.erase(static_cast<int>(program));
    sfpewForgetUserProgram(program);
    std::lock_guard<std::mutex> lock(g_shader_mutex);
    programRecords().erase(program);
}

void glLinkProgram(GLuint program) {
    if (!sfpewEnsureBackend() || g_glFuncs.glLinkProgram == nullptr) return;

    // Snapshot the per-stage TU lists; translation runs outside the lock.
    struct stage_work_t {
        std::vector<GLuint> tus;
        std::vector<std::string> sources;
        std::vector<uint8_t> translated;        // parallel to tus
        std::vector<uint8_t> deferred;          // parallel to tus
        std::vector<uint8_t> backend_original;  // parallel to tus
        std::vector<uint8_t> native;            // parallel to tus
        std::vector<uint8_t> backend_native;    // parallel to tus
        std::vector<unsigned> version;          // parallel to tus
        bool needs_combined = false;
    } work[2];
    bool tracked = false;
    bool all_native = false;
    {
        std::lock_guard<std::mutex> lock(g_shader_mutex);
        auto pit = programRecords().find(program);
        if (pit != programRecords().end()) {
            tracked = true;
            auto& rec = pit->second;
            rec.force_link_fail = false;
            rec.link_log.clear();
            rec.combined_inits.clear();
            rec.stage_combined[0] = rec.stage_combined[1] = false;
            for (GLuint sh : rec.shaders) {
                auto sit = shaderRecords().find(sh);
                if (sit == shaderRecords().end()) continue;
                auto& w = work[stageIndex(sit->second.stage)];
                w.tus.push_back(sh);
                w.sources.push_back(sit->second.original);
                w.translated.push_back(sit->second.translated ? 1 : 0);
                w.deferred.push_back(sit->second.deferred ? 1 : 0);
                w.backend_original.push_back(sit->second.backend_uploaded_original ? 1 : 0);
                w.native.push_back(sit->second.native_passthrough ? 1 : 0);
                w.backend_native.push_back(sit->second.backend_holds_native ? 1 : 0);
                const auto lang = SFPEW::Shader::detect_shader_language(sit->second.original);
                w.version.push_back(lang.valid ? lang.version : 0u);
                w.needs_combined = w.needs_combined || sit->second.deferred;
            }
            for (auto& w : work) w.needs_combined = w.needs_combined || w.tus.size() > 1;
            // GL 2.1: a program with a vertex stage whose shaders never
            // write gl_Position must fail to link. GLES never checks.
            if (!work[0].sources.empty()) {
                bool writes_position = false;
                for (const auto& src : work[0].sources)
                    writes_position = writes_position || mentionsToken(src, "gl_Position");
                if (!writes_position) {
                    rec.force_link_fail = true;
                    rec.link_log += "[SFPEW] vertex shaders never write gl_Position\n";
                }
            }
            all_native = tracked;
            unsigned program_version = 0;
            for (const auto& w : work) {
                if (w.needs_combined) {
                    all_native = false;
                    break;
                }
                for (size_t i = 0; i < w.tus.size(); ++i) {
                    if (w.native[i] == 0 || w.version[i] == 0) {
                        all_native = false;
                        break;
                    }
                    if (program_version == 0) {
                        program_version = w.version[i];
                    } else if (program_version != w.version[i]) {
                        all_native = false;
                        break;
                    }
                }
                if (!all_native) break;
            }
        }
    }

    for (int s = 0; s < 2; ++s) {
        auto& w = work[s];
        if (!w.needs_combined) continue;
        const GLenum stage = s == 0 ? GL_VERTEX_SHADER : GL_FRAGMENT_SHADER;
        auto result =
            SFPEW::Shader::translate(stage, w.sources, SFPEW::Shader::detect_backend_target());

        std::lock_guard<std::mutex> lock(g_shader_mutex);
        auto& rec = programRecords()[program];
        rec.stage_combined[s] = true;
        if (!result.ok) {
            rec.force_link_fail = true;
            const std::string stage_name = s == 0 ? "vertex" : "fragment";
            rec.link_log += "[SFPEW translator, " + stage_name + " stage]\n" + result.log + "\n";
            SFPEW_LOGE("program %u [%s] combined translation failed", program,
                       stage_name.c_str());
            if (!result.log.empty()) SFPEW_LOGE("%s", result.log.c_str());
            continue;
        }
        // Compile the combined ESSL into the stage's one backend-attached
        // TU (attach the first if a detach removed the primary).
        GLuint primary = 0;
        for (GLuint sh : w.tus) {
            if (contains(rec.backend_attached, sh)) { primary = sh; break; }
        }
        if (primary == 0) {
            primary = w.tus.front();
            rec.backend_attached.push_back(primary);
            g_glFuncs.glAttachShader(program, primary);
        }
        const char* text = result.essl.c_str();
        const GLint text_length = (GLint)result.essl.size();
        g_glFuncs.glShaderSource(primary, 1, &text, &text_length);
        g_glFuncs.glCompileShader(primary);
        reportBackendCompileFailure(primary, stage, "combined ESSL (link)", result.essl);
        appendUnique(rec.combined_inits, result.uniform_initializers);
        for (GLuint sh : w.tus) {
            auto sit = shaderRecords().find(sh);
            if (sit != shaderRecords().end()) {
                sit->second.backend_uploaded_original = false;
                sit->second.backend_holds_native = false;
            }
        }
    }

    // Program-level pass-through: only when every attached shader is native,
    // all declared versions match, and no stage needs a combined TU. Restore
    // any shader that a previous mixed-program link has since re-uploaded in
    // translated form.
    if (all_native && g_glFuncs.glShaderSource != nullptr &&
        g_glFuncs.glCompileShader != nullptr) {
        for (int s = 0; s < 2; ++s) {
            auto& w = work[s];
            const GLenum stage = s == 0 ? GL_VERTEX_SHADER : GL_FRAGMENT_SHADER;
            for (size_t i = 0; i < w.tus.size(); ++i) {
                if (w.backend_native[i]) continue;
                const char* text = w.sources[i].c_str();
                const GLint text_length = (GLint)w.sources[i].size();
                g_glFuncs.glShaderSource(w.tus[i], 1, &text, &text_length);
                g_glFuncs.glCompileShader(w.tus[i]);
                reportBackendCompileFailure(w.tus[i], stage, "native recompile (link)",
                                            w.sources[i]);
                std::lock_guard<std::mutex> lock(g_shader_mutex);
                auto sit = shaderRecords().find(w.tus[i]);
                if (sit != shaderRecords().end()) {
                    sit->second.backend_uploaded_original = true;
                    sit->second.backend_holds_native = true;
                }
            }
        }
        g_glFuncs.glLinkProgram(program);
    } else if (tracked && !all_native && g_glFuncs.glShaderSource != nullptr &&
               g_glFuncs.glCompileShader != nullptr) {
        // A program that is not entirely pass-through must use one uniform
        // translated target version. Native-eligible shaders are translated
        // here as well; if that fails they stay in their original form and
        // the backend sees the version mismatch, with the diagnostics kept
        // for the caller.
        const auto target = SFPEW::Shader::detect_backend_target();
        for (int s = 0; s < 2; ++s) {
            auto& w = work[s];
            if (w.needs_combined) continue; // already compiled by the combined path
            const GLenum stage = s == 0 ? GL_VERTEX_SHADER : GL_FRAGMENT_SHADER;
            for (size_t i = 0; i < w.tus.size(); ++i) {
                if (w.translated[i] && !w.backend_original[i] && !w.backend_native[i])
                    continue;
                auto result = SFPEW::Shader::translate(stage, w.sources[i], target);
                if (!result.ok) {
                    std::lock_guard<std::mutex> lock(g_shader_mutex);
                    auto pit = programRecords().find(program);
                    if (pit != programRecords().end()) {
                        pit->second.link_log += "[SFPEW translator, shader " +
                                                std::to_string(w.tus[i]) + "]\n" +
                                                result.log + "\n";
                    }
                    SFPEW_LOGE("shader %u [%s] link-time translation failed", w.tus[i],
                               shaderStageLabel(stage));
                    if (!result.log.empty()) SFPEW_LOGE("%s", result.log.c_str());
                    continue;
                }
                const char* text = result.essl.c_str();
                const GLint text_length = (GLint)result.essl.size();
                g_glFuncs.glShaderSource(w.tus[i], 1, &text, &text_length);
                g_glFuncs.glCompileShader(w.tus[i]);
                reportBackendCompileFailure(w.tus[i], stage, "mixed-program ESSL (link)",
                                            result.essl);
                std::lock_guard<std::mutex> lock(g_shader_mutex);
                auto sit = shaderRecords().find(w.tus[i]);
                if (sit != shaderRecords().end()) {
                    sit->second.translated = true;
                    sit->second.deferred = false;
                    sit->second.backend_uploaded_original = false;
                    sit->second.backend_holds_native = false;
                    sit->second.translate_log.clear();
                    sit->second.uniform_inits = std::move(result.uniform_initializers);
                }
            }
        }
        g_glFuncs.glLinkProgram(program);
    } else {
        g_glFuncs.glLinkProgram(program);
    }

    // A (re)link resets every uniform in the program to zero and may move
    // locations, so the per-program feed cache (resolved locations AND
    // last-sent values) is stale wholesale: keeping it would elide the
    // next send of a value the link just wiped.
    sfpewForgetUserProgram(program);

    GLint status = GL_FALSE;
    if (g_glFuncs.glGetProgramiv != nullptr)
        g_glFuncs.glGetProgramiv(program, GL_LINK_STATUS, &status);
    reportBackendLinkFailure(program);
    if (status != GL_TRUE) return;
    if (all_native) return;

    // Gather the initializers that apply to this link: per-TU values for
    // fast-path stages, the combined translation's values otherwise.
    std::vector<SFPEW::Shader::uniform_initializer_t> inits;
    {
        std::lock_guard<std::mutex> lock(g_shader_mutex);
        auto pit = programRecords().find(program);
        if (pit != programRecords().end()) {
            if (pit->second.force_link_fail) return;
            appendUnique(inits, pit->second.combined_inits);
            for (GLuint sh : pit->second.shaders) {
                auto sit = shaderRecords().find(sh);
                if (sit == shaderRecords().end()) continue;
                if (pit->second.stage_combined[stageIndex(sit->second.stage)]) continue;
                appendUnique(inits, sit->second.uniform_inits);
            }
        }
    }
    if (!tracked && g_glFuncs.glGetAttachedShaders != nullptr) {
        // Program attached before the wrapper tracked it: backend truth.
        GLuint shaders[8] = {};
        GLsizei count = 0;
        g_glFuncs.glGetAttachedShaders(program, 8, &count, shaders);
        std::lock_guard<std::mutex> lock(g_shader_mutex);
        for (GLsizei i = 0; i < count; ++i) {
            auto sit = shaderRecords().find(shaders[i]);
            if (sit != shaderRecords().end()) appendUnique(inits, sit->second.uniform_inits);
        }
    }
    applyUniformInitializers(program, inits);
}

void glGetProgramiv(GLuint program, GLenum pname, GLint* params) {
    if (params == nullptr || !sfpewEnsureBackend() || g_glFuncs.glGetProgramiv == nullptr) return;
    {
        std::lock_guard<std::mutex> lock(g_shader_mutex);
        auto pit = programRecords().find(program);
        if (pit != programRecords().end()) {
            if (pname == GL_LINK_STATUS && pit->second.force_link_fail) {
                *params = GL_FALSE;
                return;
            }
            if (pname == GL_ATTACHED_SHADERS) {
                *params = (GLint)pit->second.shaders.size();
                return;
            }
        }
    }
    g_glFuncs.glGetProgramiv(program, pname, params);
    if (pname == GL_INFO_LOG_LENGTH) {
        std::lock_guard<std::mutex> lock(g_shader_mutex);
        auto pit = programRecords().find(program);
        if (pit != programRecords().end() && !pit->second.link_log.empty()) {
            *params += (GLint)(pit->second.link_log.size() + 1);
        }
    }
}

void glGetAttachedShaders(GLuint program, GLsizei maxCount, GLsizei* count, GLuint* shaders) {
    if (!sfpewEnsureBackend() || g_glFuncs.glGetAttachedShaders == nullptr) return;
    if (maxCount < 0) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    {
        std::lock_guard<std::mutex> lock(g_shader_mutex);
        auto pit = programRecords().find(program);
        if (pit != programRecords().end()) {
            GLsizei n = 0;
            for (GLuint sh : pit->second.shaders) {
                if (n >= maxCount || shaders == nullptr) break;
                shaders[n++] = sh;
            }
            if (count != nullptr) *count = n;
            return;
        }
    }
    g_glFuncs.glGetAttachedShaders(program, maxCount, count, shaders);
}

// Two renaming layers can separate the app's spelling from the linked
// program: SPIRV-Cross prefixes keyword/builtin collisions with '_'
// ("step" -> "_step", members too), and the translator renames legacy
// identifiers that became builtins ("texture" -> "fpe_id_texture" for
// OptiFine's `uniform sampler2D texture;`). The app still asks with the
// original name; probe the alternate spellings before reporting a miss.
GLint glGetUniformLocation(GLuint program, const GLchar* name) {
    if (!sfpewEnsureBackend() || g_glFuncs.glGetUniformLocation == nullptr) return -1;
    const GLint loc = g_glFuncs.glGetUniformLocation(program, name);
    if (loc >= 0 || name == nullptr || name[0] == '\0') return loc;
    const std::string original(name);
    for (const char* prefix : {"_", "fpe_id_"}) {
        const GLint ploc =
            g_glFuncs.glGetUniformLocation(program, (prefix + original).c_str());
        if (ploc >= 0) return ploc;
        const size_t dot = original.rfind('.');
        if (dot == std::string::npos) continue;
        const std::string member =
            original.substr(0, dot + 1) + prefix + original.substr(dot + 1);
        const GLint mloc = g_glFuncs.glGetUniformLocation(program, member.c_str());
        if (mloc >= 0) return mloc;
    }
    return -1;
}

GLint glGetAttribLocation(GLuint program, const GLchar* name) {
    if (!sfpewEnsureBackend() || g_glFuncs.glGetAttribLocation == nullptr) return -1;
    const GLint loc = g_glFuncs.glGetAttribLocation(program, name);
    if (loc >= 0 || name == nullptr || name[0] == '\0') return loc;
    for (const char* prefix : {"_", "fpe_id_"}) {
        const GLint ploc =
            g_glFuncs.glGetAttribLocation(program, (prefix + std::string(name)).c_str());
        if (ploc >= 0) return ploc;
    }
    return -1;
}

void glGetProgramInfoLog(GLuint program, GLsizei bufSize, GLsizei* length, GLchar* infoLog) {
    if (infoLog == nullptr || bufSize <= 0) return;
    if (!sfpewEnsureBackend() || g_glFuncs.glGetProgramInfoLog == nullptr) return;

    std::string combined;
    {
        std::lock_guard<std::mutex> lock(g_shader_mutex);
        auto pit = programRecords().find(program);
        if (pit != programRecords().end()) combined = pit->second.link_log;
    }
    GLsizei backend_length = 0;
    std::vector<GLchar> backend_log((size_t)bufSize);
    g_glFuncs.glGetProgramInfoLog(program, bufSize, &backend_length, backend_log.data());
    combined.append(backend_log.data(), (size_t)std::max(backend_length, 0));

    const GLsizei n = (GLsizei)std::min((size_t)bufSize - 1, combined.size());
    std::memcpy(infoLog, combined.data(), (size_t)n);
    infoLog[n] = '\0';
    if (length != nullptr) *length = n;
}

void glGetShaderSource(GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* source) {
    if (source == nullptr || bufSize <= 0) return;
    std::lock_guard<std::mutex> lock(g_shader_mutex);
    auto it = shaderRecords().find(shader);
    if (it == shaderRecords().end()) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return;
    }
    // Per spec: the caller's ORIGINAL source, not what the backend compiled.
    const std::string& text = it->second.original;
    const GLsizei n = (GLsizei)std::min((size_t)bufSize - 1, text.size());
    std::memcpy(source, text.data(), (size_t)n);
    source[n] = '\0';
    if (length != nullptr) *length = n;
}

void glGetShaderInfoLog(GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* infoLog) {
    if (infoLog == nullptr || bufSize <= 0) return;
    if (!sfpewEnsureBackend() || g_glFuncs.glGetShaderInfoLog == nullptr) return;

    std::string combined;
    {
        std::lock_guard<std::mutex> lock(g_shader_mutex);
        auto it = shaderRecords().find(shader);
        if (it != shaderRecords().end() && !it->second.translate_log.empty()) {
            combined = "[SFPEW translator]\n" + it->second.translate_log + "\n";
        }
    }
    GLsizei backend_length = 0;
    std::vector<GLchar> backend_log((size_t)bufSize);
    g_glFuncs.glGetShaderInfoLog(shader, bufSize, &backend_length, backend_log.data());
    combined.append(backend_log.data(), (size_t)std::max(backend_length, 0));

    const GLsizei n = (GLsizei)std::min((size_t)bufSize - 1, combined.size());
    std::memcpy(infoLog, combined.data(), (size_t)n);
    infoLog[n] = '\0';
    if (length != nullptr) *length = n;
}

// --- ARB_shader_objects aliases -----------------------------------------
// GLhandleARB and GLuint share the value space here; the ARB pname values
// are numerically identical to their core equivalents.

extern "C" {

GLuint sfpewCreateShaderObjectARB(GLenum type) { return glCreateShader(type); }
GLuint sfpewCreateProgramObjectARB(void) {
    if (!sfpewEnsureBackend() || g_glFuncs.glCreateProgram == nullptr) return 0;
    return g_glFuncs.glCreateProgram();
}

void sfpewDeleteObjectARB(GLuint object) {
    if (!sfpewEnsureBackend()) return;
    if (g_glFuncs.glIsShader != nullptr && g_glFuncs.glIsShader(object)) {
        glDeleteShader(object);
    } else {
        glDeleteProgram(object);
    }
}

void sfpewAttachObjectARB(GLuint program, GLuint shader) { glAttachShader(program, shader); }

void sfpewDetachObjectARB(GLuint program, GLuint shader) { glDetachShader(program, shader); }

void sfpewGetObjectParameterivARB(GLuint object, GLenum pname, GLint* params) {
    if (params == nullptr || !sfpewEnsureBackend()) return;
    if (g_glFuncs.glIsShader != nullptr && g_glFuncs.glIsShader(object)) {
        glGetShaderiv(object, pname, params);
    } else {
        glGetProgramiv(object, pname, params);
    }
}

void sfpewGetInfoLogARB(GLuint object, GLsizei maxLength, GLsizei* length, GLchar* infoLog) {
    if (!sfpewEnsureBackend()) return;
    if (g_glFuncs.glIsShader != nullptr && g_glFuncs.glIsShader(object)) {
        glGetShaderInfoLog(object, maxLength, length, infoLog);
    } else {
        glGetProgramInfoLog(object, maxLength, length, infoLog);
    }
}

GLuint sfpewGetHandleARB(GLenum pname) {
    if (pname != 0x8B8D /* GL_PROGRAM_OBJECT_ARB */) return 0;
    (void)g_glstate; // entry strict resolve; the program shadow reads the snapshot
    return (GLuint)sfpewLogicalProgram();
}

} // extern "C"
