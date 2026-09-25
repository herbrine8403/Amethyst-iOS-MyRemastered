// SimpleFPEWrapper - SimpleFPEWrapper/backend/capabilities.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "../init.h"
#include "../log.h"
#include "../fpe/fpe.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>

bool sfpewBackendIsES() {
    // -1 until a context has answered; never cached from a failed query, so an
    // early call cannot pin the wrong answer for the process lifetime.
    static int cached = -1;
    if (cached < 0) {
        const GLubyte* raw =
            g_glFuncs.glGetString != nullptr ? g_glFuncs.glGetString(GL_VERSION) : nullptr;
        if (raw == nullptr) return false;
        cached = std::strstr((const char*)raw, "OpenGL ES") != nullptr ? 1 : 0;
    }
    return cached != 0;
}

// Whether the backend accepts GL_BGRA pixel and vertex formats natively.
// GLES never does (the policy this wrapper is built around). A DESKTOP
// version string normally means it does - but not when the "desktop GL" is
// itself a translation layer that forwards to GLES: MobileGlues reports a
// desktop version yet rewrites GL_BGRA to GL_RGBA without reordering the
// bytes, which shipped exactly that red/blue swap on device. Its version
// string carries "MobileGlues", so it is recognized and treated like GLES.
//
// The conservative direction is CONVERT: RGBA bytes are correct for every
// backend, native BGRA only for some. An unanswerable query (no current
// context yet) therefore reports "does not take BGRA" and is not cached.
namespace {
// MobileGlues has no glMultiDrawArrays at all up to and including V1.3.5 -
// GLES has no such entry point to forward to and that release does not
// emulate it, so the call silently draws nothing. Its indexed relatives
// (glMultiDrawElements, ...BaseVertex, ...Indirect) ARE implemented, and
// every other backend this runs on has the whole family.
//
// The version is not in any string the API exposes, but MobileGlues injects
// it into every shader it compiles as MG_MOBILEGLUES_VERSION (1350 = V1.3.5;
// see its README, "For Shader Developers"). So the probe is a shader: write
// the macro to a transform-feedback varying, run one point with the
// rasterizer off, and read the number back. A backend that is not
// MobileGlues never defines the macro and reports zero - but it is only
// asked at all once the version string has already named MobileGlues.
constexpr int kMobileGluesMultiDrawArraysFixedIn = 1360; // first release with it

int probeMobileGluesVersion() {
    auto& f = g_glFuncs;
    if (f.glCreateShader == nullptr || f.glShaderSource == nullptr ||
        f.glCompileShader == nullptr || f.glCreateProgram == nullptr ||
        f.glAttachShader == nullptr || f.glLinkProgram == nullptr ||
        f.glGetProgramiv == nullptr || f.glTransformFeedbackVaryings == nullptr ||
        f.glBeginTransformFeedback == nullptr || f.glEndTransformFeedback == nullptr ||
        f.glBindBufferBase == nullptr || f.glGenBuffers == nullptr ||
        f.glBufferData == nullptr || f.glMapBufferRange == nullptr ||
        f.glUnmapBuffer == nullptr || f.glDrawArrays == nullptr || f.glEnable == nullptr ||
        f.glDisable == nullptr || f.glDeleteShader == nullptr || f.glDeleteProgram == nullptr ||
        f.glDeleteBuffers == nullptr || f.glGetIntegerv == nullptr ||
        f.glGenVertexArrays == nullptr || f.glBindVertexArray == nullptr ||
        f.glDeleteVertexArrays == nullptr) {
        return -1;
    }

    static const char* source =
        "#version 300 es\n"
        "#ifdef MG_MOBILEGLUES_VERSION\n"
        "#define MG_PROBE float(MG_MOBILEGLUES_VERSION)\n"
        "#else\n"
        "#define MG_PROBE 0.0\n"
        "#endif\n"
        "flat out float mgVersion;\n"
        "void main() {\n"
        "    mgVersion = MG_PROBE;\n"
        "    gl_Position = vec4(0.0, 0.0, 0.0, 1.0);\n"
        "    gl_PointSize = 1.0;\n"
        "}\n";

    // Everything this touches is put back before returning.
    GLint savedProgram = 0, savedVao = 0, savedArrayBuffer = 0, savedTfBuffer = 0;
    f.glGetIntegerv(GL_CURRENT_PROGRAM, &savedProgram);
    f.glGetIntegerv(0x85B5 /* GL_VERTEX_ARRAY_BINDING */, &savedVao);
    f.glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &savedArrayBuffer);
    f.glGetIntegerv(0x8C8F /* GL_TRANSFORM_FEEDBACK_BUFFER_BINDING */, &savedTfBuffer);
    const bool savedDiscard =
        f.glIsEnabled != nullptr && f.glIsEnabled(0x8C89 /* GL_RASTERIZER_DISCARD */) == GL_TRUE;
    while (f.glGetError() != GL_NO_ERROR) {}

    int version = -1;
    GLuint shader = f.glCreateShader(GL_VERTEX_SHADER);
    GLuint program = f.glCreateProgram();
    GLuint buffer = 0, vao = 0;
    f.glGenBuffers(1, &buffer);
    f.glGenVertexArrays(1, &vao);
    if (shader != 0 && program != 0 && buffer != 0 && vao != 0) {
        f.glShaderSource(shader, 1, &source, nullptr);
        f.glCompileShader(shader);
        f.glAttachShader(program, shader);
        static const char* varying = "mgVersion";
        f.glTransformFeedbackVaryings(program, 1, &varying, 0x8C8C /* INTERLEAVED_ATTRIBS */);
        f.glLinkProgram(program);
        GLint linked = GL_FALSE;
        f.glGetProgramiv(program, GL_LINK_STATUS, &linked);
        if (linked == GL_TRUE) {
            f.glBindVertexArray(vao);
            f.glBindBuffer(0x8C8E /* GL_TRANSFORM_FEEDBACK_BUFFER */, buffer);
            f.glBufferData(0x8C8E, (GLsizeiptr)sizeof(GLfloat), nullptr, 0x88E1 /* STREAM_READ */);
            f.glBindBufferBase(0x8C8E, 0, buffer);
            f.glUseProgram(program);
            f.glEnable(0x8C89 /* GL_RASTERIZER_DISCARD */);
            f.glBeginTransformFeedback(GL_POINTS);
            f.glDrawArrays(GL_POINTS, 0, 1);
            f.glEndTransformFeedback();
            f.glDisable(0x8C89);
            if (f.glGetError() == GL_NO_ERROR) {
                void* mapped = f.glMapBufferRange(0x8C8E, 0, (GLsizeiptr)sizeof(GLfloat),
                                                  GL_MAP_READ_BIT);
                if (mapped != nullptr) {
                    GLfloat value = 0.0f;
                    std::memcpy(&value, mapped, sizeof value);
                    f.glUnmapBuffer(0x8C8E);
                    version = (int)(value + 0.5f);
                }
            }
            f.glBindBufferBase(0x8C8E, 0, 0);
        }
    }

    if (buffer != 0) f.glDeleteBuffers(1, &buffer);
    if (program != 0) f.glDeleteProgram(program);
    if (shader != 0) f.glDeleteShader(shader);
    f.glBindVertexArray((GLuint)savedVao);
    if (vao != 0) f.glDeleteVertexArrays(1, &vao);
    f.glBindBuffer(0x8C8E, (GLuint)savedTfBuffer);
    f.glBindBuffer(GL_ARRAY_BUFFER, (GLuint)savedArrayBuffer);
    f.glUseProgram((GLuint)savedProgram);
    if (savedDiscard) f.glEnable(0x8C89); else f.glDisable(0x8C89);
    sfpewInvalidateImmediateDrawState();
    while (f.glGetError() != GL_NO_ERROR) {}
    return version;
}
} // namespace

// True when the backend cannot be asked to draw with glMultiDrawArrays.
bool sfpewBackendLacksMultiDrawArrays() {
    static int cached = -1;
    if (cached < 0) {
        // Lets the indexed path be exercised on a backend that has the array
        // form, which is the only way to test it away from the device.
        const char* forced = getenv("SFPEW_NO_MULTIDRAWARRAYS");
        if (forced != nullptr && forced[0] != '\0' && !(forced[0] == '0' && forced[1] == '\0')) {
            cached = 1;
            SFPEW_LOGI("glMultiDrawArrays avoided by SFPEW_NO_MULTIDRAWARRAYS");
            return true;
        }
        const GLubyte* raw =
            g_glFuncs.glGetString != nullptr ? g_glFuncs.glGetString(GL_VERSION) : nullptr;
        if (raw == nullptr) return true; // unknown backend: take the safe path, do not cache
        const char* version = (const char*)raw;
        if (std::strstr(version, "MobileGlues") == nullptr) {
            cached = 0;
        } else {
            const int probed = probeMobileGluesVersion();
            // A probe that could not run leaves the version unknown, and the
            // releases known to lack the entry point are the ones in the
            // field: assume it is missing rather than draw nothing.
            cached = (probed >= kMobileGluesMultiDrawArraysFixedIn) ? 0 : 1;
            SFPEW_LOGI("backend \"%s\": MG_MOBILEGLUES_VERSION probe returned %d; "
                       "glMultiDrawArrays %s",
                       version, probed, cached != 0 ? "avoided" : "used");
        }
    }
    return cached != 0;
}

bool sfpewBackendTakesBgra() {
    static int cached = -1;
    if (cached < 0) {
        const GLubyte* raw =
            g_glFuncs.glGetString != nullptr ? g_glFuncs.glGetString(GL_VERSION) : nullptr;
        if (raw == nullptr) return false;
        const char* version = (const char*)raw;
        const bool es = std::strstr(version, "OpenGL ES") != nullptr;
        const bool translator = std::strstr(version, "MobileGlues") != nullptr;
        cached = (!es && !translator) ? 1 : 0;
        // Once, with the evidence: which backend this is and what was
        // decided for it. The device round that motivated this feature
        // would have been one log line instead of an rdc excavation.
        SFPEW_LOGI("backend \"%s\": BGRA uploads %s", version,
                   cached != 0 ? "passed through natively" : "converted to RGBA");
    }
    return cached != 0;
}

// The desktop GL level the wrapper presents when the backend is GLES.
// Desktop GL loaders parse "<major>.<minor>" out of GL_VERSION and abort on
// "OpenGL ES ...", and the numeric queries must agree with the string, so
// both go through here. The mapping is the industry-standard equivalence
// (ES 3.0 = GL 3.3, ES 3.1 = GL 4.3, ES 3.2 = GL 4.5); it never downgrades
// what the backend can do and the backend's own version string stays
// visible in the suffix. Returns false for a desktop backend, whose version
// already parses and is reported verbatim.
bool sfpewDesktopGLVersion(int* major, int* minor) {
    static int cached_major = 0, cached_minor = 0, cached_is_es = -1;
    if (cached_is_es < 0) {
        const GLubyte* raw =
            g_glFuncs.glGetString != nullptr ? g_glFuncs.glGetString(GL_VERSION) : nullptr;
        if (raw == nullptr) return false; // no context yet: do not cache
        const char* es = std::strstr((const char*)raw, "OpenGL ES ");
        if (es == nullptr) {
            cached_is_es = 0;
        } else {
            int es_major = 3, es_minor = 0;
            std::sscanf(es + 10, "%d.%d", &es_major, &es_minor);
            if (es_major > 3 || (es_major == 3 && es_minor >= 2)) {
                cached_major = 4;
                cached_minor = 5;
            } else if (es_major == 3 && es_minor == 1) {
                cached_major = 4;
                cached_minor = 3;
            } else {
                cached_major = 3;
                cached_minor = 3;
            }
            cached_is_es = 1;
        }
    }
    if (cached_is_es != 1) return false;
    if (major != nullptr) *major = cached_major;
    if (minor != nullptr) *minor = cached_minor;
    return true;
}

// GL_ARB_texture_border_clamp: core on every desktop GL back to 1.3 - below
// this wrapper's 3.2 floor, so a desktop backend always has it. Confirmed on
// this machine's own desktop backend (NVIDIA, GL 3.3 core) that a modern
// driver does not bother re-advertising a promotion that old in its own
// GL_EXTENSIONS string, so passthrough alone could never surface it to an
// app checking for the name. GLES is not uniform the same way: neither
// GL_CLAMP_TO_BORDER nor GL_TEXTURE_BORDER_COLOR is in ES 3.0 or 3.1 core,
// only ES 3.2 or GL_EXT_texture_border_clamp/GL_OES_texture_border_clamp
// layered on top - so unlike every other entry in kDesktopExtensions below,
// this one is not true for every backend the wrapper's stated floor allows,
// and has to ask the real backend rather than assume it.
bool sfpewTextureBorderClampSupported() {
    static int cached = -1;
    if (cached < 0) {
        // SFPEW_TEST_FORCE_NO_TEXTURE_BORDER_CLAMP=1: pretend the real
        // backend lacks it, exercising the GL_INVALID_ENUM path and the
        // extension string's absence on a machine whose real backend (ES
        // 3.2, or desktop) always has it - the only way to test either
        // away from an actual ES 3.0/3.1 device, same reasoning as
        // SFPEW_NO_MULTIDRAWARRAYS above and SFPEW_TEST_FORCE_BGRA_COPY
        // elsewhere in this file.
        const char* forced = getenv("SFPEW_TEST_FORCE_NO_TEXTURE_BORDER_CLAMP");
        if (forced != nullptr && forced[0] != '\0' && forced[0] != '0') {
            cached = 0;
            return false;
        }

        const GLubyte* raw =
            g_glFuncs.glGetString != nullptr ? g_glFuncs.glGetString(GL_VERSION) : nullptr;
        if (raw == nullptr) return false; // no context yet: do not cache

        if (!sfpewBackendIsES()) {
            cached = 1;
            return true;
        }

        int major = 0, minor = 0;
        sfpewDesktopGLVersion(&major, &minor); // backend is ES, just confirmed above
        if (major == 4 && minor == 5) {
            cached = 1; // ES 3.2 core (sfpewDesktopGLVersion's ES 3.2+ mapping)
        } else {
            const GLubyte* ext = g_glFuncs.glGetString(GL_EXTENSIONS);
            cached = (ext != nullptr &&
                      (std::strstr((const char*)ext, "GL_EXT_texture_border_clamp") != nullptr ||
                       std::strstr((const char*)ext, "GL_OES_texture_border_clamp") != nullptr))
                         ? 1
                         : 0;
        }
    }
    return cached != 0;
}
