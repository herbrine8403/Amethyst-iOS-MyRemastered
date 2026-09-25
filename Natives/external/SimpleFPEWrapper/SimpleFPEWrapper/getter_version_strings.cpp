// SimpleFPEWrapper - SimpleFPEWrapper/getter_version_strings.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "GL/gl.h"
#include "init.h"
#include "log.h"
#include "version.h"
#include "fpe/fpe.hpp"

// The DESKTOP extension surface the wrapper implements. LWJGL-era engines
// parse this list (not the backend's GL_OES_* one) to switch on their
// FBO/shader/VBO paths, and resolve the corresponding EXT/ARB entry
// points through {egl,glX}GetProcAddress (lookup.cpp aliases them).
const char* const kDesktopExtensions[] = {
    "GL_ARB_compatibility",
    "GL_ARB_transpose_matrix",
    // FCL-ecosystem probe tokens (pre-dating this list; keep for launchers
    // that detect the wrapper's desktop-GL level by these).
    "OpenGL11",
    "OpenGL12",
    "OpenGL13",
    "OpenGL14",
    "OpenGL15",
    "OpenGL20",
    "OpenGL21",
    "GL_ARB_multitexture",
    "GL_ARB_texture_env_add",
    "GL_ARB_texture_env_combine",
    "GL_ARB_texture_env_crossbar",
    "GL_ARB_texture_env_dot3",
    "GL_ARB_texture_cube_map",
    "GL_ARB_texture_non_power_of_two",
    "GL_ARB_texture_mirrored_repeat",
    "GL_ARB_texture_compression",
    "GL_ARB_depth_texture",
    "GL_ARB_shadow",
    "GL_ARB_vertex_buffer_object",
    "GL_ARB_pixel_buffer_object",
    "GL_ARB_vertex_array_bgra",
    "GL_ARB_shader_objects",
    "GL_ARB_vertex_shader",
    "GL_ARB_fragment_shader",
    "GL_ARB_shading_language_100",
    "GL_ARB_draw_buffers",
    "GL_ARB_point_parameters",
    "GL_ARB_point_sprite",
    "GL_ARB_window_pos",
    "GL_ARB_occlusion_query2",
    "GL_ARB_imaging",
    "GL_ARB_framebuffer_object",
    "GL_ARB_texture_float",
    "GL_ARB_half_float_pixel",
    "GL_EXT_framebuffer_object",
    "GL_EXT_framebuffer_blit",
    "GL_EXT_packed_depth_stencil",
    "GL_EXT_blend_func_separate",
    "GL_EXT_blend_minmax",
    "GL_EXT_blend_subtract",
    "GL_EXT_blend_color",
    "GL_EXT_fog_coord",
    "GL_EXT_secondary_color",
    "GL_EXT_color_table",
    "GL_EXT_color_subtable",
    "GL_EXT_convolution",
    "GL_EXT_histogram",
    "GL_EXT_texture_lod_bias",
    "GL_EXT_bgra",
    "GL_EXT_multi_draw_arrays",
    "GL_EXT_stencil_wrap",
    "GL_EXT_separate_specular_color",
    "GL_EXT_texture3D",
    "GL_EXT_packed_pixels",
    "GL_EXT_texture_edge_clamp",
    "GL_EXT_texture_compression_s3tc",
    "GL_EXT_texture_env_combine",
    "GL_SGI_color_table",
    "GL_SGI_color_matrix",
    "GL_SGIS_generate_mipmap",
    "GL_SGIS_texture_edge_clamp",
    "GL_NV_texgen_reflection",
};
// Exported (init.h) rather than left with the default internal linkage a
// namespace-scope const/constexpr would otherwise get: glGetIntegerv's
// GL_NUM_EXTENSIONS case (fpe/ffp_state_query.cpp) needs the count too.
extern const GLint kDesktopExtensionCount =
    (GLint)(sizeof(kDesktopExtensions) / sizeof(kDesktopExtensions[0]));

GLenum glGetError() {
    // Wrapper-detected errors take priority over backend errors: legacy
    // paths validate before any backend call, so ours happened first.
    auto& state = g_glstate;
    if (state.first_error != GL_NO_ERROR) {
        const GLenum error = state.first_error;
        state.first_error = GL_NO_ERROR;
        return error;
    }
    if (!sfpewEnsureBackend() || g_glFuncs.glGetError == nullptr) return GL_NO_ERROR;
    return g_glFuncs.glGetError();
}

inline bool containsMobileGLDev(const std::string& str) {
    return str.find("MobileGL-Dev") != std::string::npos;
}

const GLubyte* glGetString(GLenum name) {
    if (!sfpewEnsureBackend() || g_glFuncs.glGetString == nullptr) return nullptr;

    // we only wrap GL_VERSION GL_RENDERER GL_VENDOR
    // Backend glGetString returns null without a current context; report
    // that to the caller and, crucially, never let it poison the caches.
    switch (name) {
    case GL_VERSION: {
        static std::string cachedVersionString;
        if (cachedVersionString.empty()) {
            const GLubyte* backend = g_glFuncs.glGetString(GL_VERSION);
            if (!backend) return nullptr;
            int major = 0, minor = 0;
            if (sfpewDesktopGLVersion(&major, &minor)) {
                // Desktop-parseable level first, then who is answering and
                // out of which build, backend identity last.
                cachedVersionString = std::to_string(major) + "." + std::to_string(minor) + " " +
                                      kSfpewProjectName + " " + sfpewVersionAndCommit() + " (" +
                                      (const char*)backend + ")";
            } else {
                // A desktop backend's own string already parses, so it stays
                // first and the wrapper appends itself - with the commit,
                // same as above: which build answered is the question a
                // report has to be able to settle either way.
                cachedVersionString = std::string((const char*)backend) + " (with " +
                                      kSfpewProjectFullName + " " + sfpewVersionAndCommit() + ")";
            }
        }
        return (const GLubyte*)cachedVersionString.c_str();
    }
    case GL_SHADING_LANGUAGE_VERSION: {
        // Must pair with the GL level above: GL 3.3 -> GLSL 3.30, GL 4.x ->
        // GLSL 4.x0. The translator accepts any input version regardless.
        static std::string cachedGlslString;
        if (cachedGlslString.empty()) {
            int major = 0, minor = 0;
            if (sfpewDesktopGLVersion(&major, &minor)) {
                const GLubyte* backend = g_glFuncs.glGetString(GL_SHADING_LANGUAGE_VERSION);
                cachedGlslString = std::to_string(major) + "." + std::to_string(minor) +
                                   "0 SFPEW (" + (backend ? (const char*)backend : "") + ")";
            } else {
                const GLubyte* backend = g_glFuncs.glGetString(GL_SHADING_LANGUAGE_VERSION);
                if (!backend) return nullptr;
                cachedGlslString = (const char*)backend;
            }
        }
        return (const GLubyte*)cachedGlslString.c_str();
    }
    case GL_EXTENSIONS: {
        // ADDITIVE surface: everything the backend really exposes, plus the
        // desktop extensions the wrapper implements on top. The backend's
        // own capability set (full ES 3.2 / GL 4.6) must stay visible.
        static std::string cachedExtensionString;
        if (cachedExtensionString.empty()) {
            const GLubyte* backend = g_glFuncs.glGetString(GL_EXTENSIONS);
            if (!backend) return nullptr;
            std::string joined((const char*)backend);
            for (GLint i = 0; i < kDesktopExtensionCount; ++i) {
                if (joined.find(kDesktopExtensions[i]) != std::string::npos) continue;
                joined += ' ';
                joined += kDesktopExtensions[i];
            }
            // Not in kDesktopExtensions above: unlike every entry there, this
            // one is not true for every backend the wrapper's floor allows
            // (see sfpewTextureBorderClampSupported's comment), so it is
            // appended only when the real backend actually has it.
            if (sfpewTextureBorderClampSupported() &&
                joined.find("GL_ARB_texture_border_clamp") == std::string::npos) {
                joined += " GL_ARB_texture_border_clamp";
            }
            cachedExtensionString = std::move(joined);
        }
        return (const GLubyte*)cachedExtensionString.c_str();
    }
    case GL_RENDERER: {
        static std::string cachedRendererString;
        if (cachedRendererString.empty()) {
            const GLubyte* backend = g_glFuncs.glGetString(GL_RENDERER);
            if (!backend) return nullptr;
            cachedRendererString = std::string((const char*)backend) + " (" + kSfpewProjectName +
                                   " " + sfpewVersionString() + ")";
        }
        return (const GLubyte*)cachedRendererString.c_str();
    }
    case GL_VENDOR: {
        static std::string cachedVendorString;
        if (cachedVendorString.empty()) {
            const GLubyte* backend = g_glFuncs.glGetString(GL_VENDOR);
            if (!backend) return nullptr;
            cachedVendorString = std::string((const char*)backend);
            if (!containsMobileGLDev(cachedVendorString)) {
                cachedVendorString += " (SFPEW: MobileGL-Dev)";
            }
        }
        return (const GLubyte*)cachedVendorString.c_str();
    }
    default:
        return g_glFuncs.glGetString(name);
    }
}

const GLubyte* glGetStringi(GLenum name, GLuint index) {
    if (!sfpewEnsureBackend() || g_glFuncs.glGetStringi == nullptr) return nullptr;

    if (name != GL_EXTENSIONS) {
        return g_glFuncs.glGetStringi(name, index);
    }
    // Additive like glGetString(GL_EXTENSIONS): the wrapper's desktop
    // extensions first, then everything the backend exposes. The
    // border-clamp name rides just after the fixed list, present only when
    // sfpewTextureBorderClampSupported() says the real backend has it - see
    // the GL_EXTENSIONS case of glGetString above.
    const bool borderClamp = sfpewTextureBorderClampSupported();
    const GLuint prefixCount = (GLuint)kDesktopExtensionCount + (borderClamp ? 1u : 0u);
    if (index < (GLuint)kDesktopExtensionCount)
        return (const GLubyte*)kDesktopExtensions[index];
    if (borderClamp && index < prefixCount)
        return (const GLubyte*)"GL_ARB_texture_border_clamp";
    return g_glFuncs.glGetStringi(name, index - prefixCount);
}
