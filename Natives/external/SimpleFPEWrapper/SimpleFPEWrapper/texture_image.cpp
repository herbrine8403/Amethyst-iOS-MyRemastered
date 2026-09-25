// SimpleFPEWrapper - SimpleFPEWrapper/texture_image.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "GL/gl.h"
#include "init.h"
#include "log.h"
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include "fpe/fpe.hpp"
#include "fpe/drawing1x.h"
#include "fpe/list.h"
#include "fpe/imaging.h"

namespace {
struct ProxyTexture2DLevel {
    GLsizei width = 0;
    GLsizei height = 0;
    GLint internalFormat = 0;
    GLint border = 0;
    bool supported = false;
};

struct ProxyTexture2DCache {
    EGLContext context = EGL_NO_CONTEXT;
    std::unordered_map<GLint, ProxyTexture2DLevel> levels;
};

thread_local ProxyTexture2DCache proxyTexture2DCache;

std::unordered_map<GLint, ProxyTexture2DLevel>& getProxyTexture2DLevels() {
    const EGLContext context = (EGLContext)glstate_t::cached_context();
    if (proxyTexture2DCache.context != context) {
        proxyTexture2DCache.context = context;
        proxyTexture2DCache.levels.clear();
    }
    return proxyTexture2DCache.levels;
}

bool isProxyTextureInternalFormat(GLint internalFormat) {
    switch (internalFormat) {
    case 1:
    case 2:
    case 3:
    case 4:
    case GL_COLOR_INDEX:
    case GL_DEPTH_COMPONENT:
    case GL_RED:
    case GL_GREEN:
    case GL_BLUE:
    case GL_ALPHA:
    case GL_RGB:
    case GL_RGBA:
    case GL_LUMINANCE:
    case GL_LUMINANCE_ALPHA:
    case GL_INTENSITY:
    case GL_ALPHA4:
    case GL_ALPHA8:
    case GL_ALPHA12:
    case GL_ALPHA16:
    case GL_LUMINANCE4:
    case GL_LUMINANCE8:
    case GL_LUMINANCE12:
    case GL_LUMINANCE16:
    case GL_LUMINANCE4_ALPHA4:
    case GL_LUMINANCE6_ALPHA2:
    case GL_LUMINANCE8_ALPHA8:
    case GL_LUMINANCE12_ALPHA4:
    case GL_LUMINANCE12_ALPHA12:
    case GL_LUMINANCE16_ALPHA16:
    case GL_INTENSITY4:
    case GL_INTENSITY8:
    case GL_INTENSITY12:
    case GL_INTENSITY16:
    case GL_R3_G3_B2:
    case GL_RGB4:
    case GL_RGB5:
    case GL_RGB8:
    case GL_RGB10:
    case GL_RGB12:
    case GL_RGB16:
    case GL_RGBA2:
    case GL_RGBA4:
    case GL_RGB5_A1:
    case GL_RGBA8:
    case GL_RGB10_A2:
    case GL_RGBA12:
    case GL_RGBA16:
        return true;
    default:
        return false;
    }
}

bool isProxyTextureFormat(GLenum format) {
    switch (format) {
    case GL_COLOR_INDEX:
    case GL_STENCIL_INDEX:
    case GL_DEPTH_COMPONENT:
    case GL_RED:
    case GL_GREEN:
    case GL_BLUE:
    case GL_ALPHA:
    case GL_RGB:
    case GL_RGBA:
    case GL_LUMINANCE:
    case GL_LUMINANCE_ALPHA:
    case GL_BGR:
    case GL_BGRA:
        return true;
    default:
        return false;
    }
}

bool isProxyTextureTypeCompatible(GLenum format, GLenum type) {
    switch (type) {
    case GL_BYTE:
    case GL_UNSIGNED_BYTE:
    case GL_SHORT:
    case GL_UNSIGNED_SHORT:
    case GL_INT:
    case GL_UNSIGNED_INT:
    case GL_FLOAT:
        return true;
    case GL_BITMAP:
        return format == GL_COLOR_INDEX || format == GL_STENCIL_INDEX;
    case GL_UNSIGNED_BYTE_3_3_2:
    case GL_UNSIGNED_BYTE_2_3_3_REV:
    case GL_UNSIGNED_SHORT_5_6_5:
    case GL_UNSIGNED_SHORT_5_6_5_REV:
        return format == GL_RGB || format == GL_BGR;
    case GL_UNSIGNED_SHORT_4_4_4_4:
    case GL_UNSIGNED_SHORT_4_4_4_4_REV:
    case GL_UNSIGNED_SHORT_5_5_5_1:
    case GL_UNSIGNED_SHORT_1_5_5_5_REV:
    case GL_UNSIGNED_INT_8_8_8_8:
    case GL_UNSIGNED_INT_8_8_8_8_REV:
    case GL_UNSIGNED_INT_10_10_10_2:
    case GL_UNSIGNED_INT_2_10_10_10_REV:
        return format == GL_RGBA || format == GL_BGRA;
    default:
        return false;
    }
}

bool getProxyTextureLevelParameter(GLint level, GLenum pname, GLint& value) {
    auto& levels = getProxyTexture2DLevels();
    const auto it = levels.find(level);
    const ProxyTexture2DLevel* state = it == levels.end() ? nullptr : &it->second;
    const bool supported = state != nullptr && state->supported;

    switch (pname) {
    case GL_TEXTURE_WIDTH:
        value = supported ? state->width : 0;
        return true;
    case GL_TEXTURE_HEIGHT:
        value = supported ? state->height : 0;
        return true;
    case GL_TEXTURE_DEPTH:
        value = supported ? 1 : 0;
        return true;
    case GL_TEXTURE_INTERNAL_FORMAT:
        value = supported ? state->internalFormat : 0;
        return true;
    case GL_TEXTURE_BORDER:
        value = supported ? state->border : 0;
        return true;
    case GL_TEXTURE_RED_SIZE:
    case GL_TEXTURE_GREEN_SIZE:
    case GL_TEXTURE_BLUE_SIZE:
    case GL_TEXTURE_ALPHA_SIZE:
    case GL_TEXTURE_LUMINANCE_SIZE:
    case GL_TEXTURE_INTENSITY_SIZE:
    case GL_TEXTURE_COMPRESSED:
    case GL_TEXTURE_COMPRESSED_IMAGE_SIZE:
        value = 0;
        return true;
    default:
        return false;
    }
}
} // namespace

namespace {
// The scratch GL objects this file reuses across calls, plus the texture
// names GL_GENERATE_MIPMAP is enabled on. All of it is dropped when the
// current context changes, the same reset proxyTexture2DCache above and
// textureMetadata() below do: a GL name means nothing outside the context
// that generated it, and a stale one resolves to whatever the NEW context
// has under that number - measured, glGetTexImage and the mipmap repair
// rewriting the color attachment of the app's own framebuffers in a second
// context (plans/17 P8). The retired context's objects are abandoned rather
// than deleted, since deleting a name here would delete this context's
// object. Contexts that share a namespace pay a rebuild they would not have
// needed; that is the same trade the two caches above already make.
// Intermediate for repairMipmapChain2D's two-hop blits. Mesa silently DROPS
// a glBlitFramebuffer whose source and destination are levels of the same
// texture (llvmpipe: no GL error, no write), and a conservative mobile driver
// may do the same, so every level is built source level -> scratch ->
// destination level. Sized for the largest destination level and reallocated
// only when the chain's size or internal format changes.
struct mip_scratch_t {
    GLuint tex = 0;
    GLsizei w = 0, h = 0;
    GLint internalformat = 0;
};

struct texture_scratch_t {
    EGLContext context = EGL_NO_CONTEXT;
    std::unordered_map<GLuint, bool> generate_mipmap_textures;
    mip_scratch_t mip;
    GLuint blit_fbos[2] = {0, 0}; // the two framebuffers that repair blits through
    GLuint read_fbo = 0;          // glGetTexImage's readback framebuffer
};

thread_local texture_scratch_t textureScratchStorage;

texture_scratch_t& textureScratch() {
    const EGLContext context = (EGLContext)glstate_t::cached_context();
    if (textureScratchStorage.context != context) {
        textureScratchStorage = {};
        textureScratchStorage.context = context;
    }
    return textureScratchStorage;
}
} // namespace

namespace {
// Texture image metadata recorded at definition time. ES 3.0 has no
// glGetTexLevelParameter, so the wrapper answers the level properties it can
// know without retaining a second copy of the texture payload.
struct texture_size_t { GLsizei width = 0, height = 0; };
struct texture_level_t {
    GLsizei width = 0;
    GLsizei height = 0;
    GLsizei depth = 1; // GL_TEXTURE_DEPTH; meaningless (stays 1) off GL_TEXTURE_3D
    GLint internal_format = 0;
    GLint border = 0;
    bool compressed = false;
    GLsizei compressed_size = 0;
};
struct texture_metadata_cache_t {
    EGLContext context = EGL_NO_CONTEXT;
    // Keyed on texture name alone: this is only ever written/read for
    // GL_TEXTURE_2D (see repairMipmapChain2D), never for another target, so
    // there is no cross-target collision to guard against.
    std::unordered_map<GLuint, texture_size_t> sizes;
    // defects-plan-2.md 2.7: keyed on (name, target), not name alone - a 2D
    // texture and a 3D/cube texture can share a name over their lifetimes
    // (GL only forbids rebinding one already-used name to a *different*
    // target, not reusing a deleted name for any target), and a cube map's
    // six faces collapse onto one GL_TEXTURE_CUBE_MAP entry per level - spec
    // requires every face at a given level to share the same size/format
    // for cube completeness, so there is nothing to distinguish between
    // them (see textureMetadataTarget() below, the same face-collapsing
    // rule swizzleTargetFor() applies for GL_TEXTURE_SWIZZLE_RGBA).
    std::unordered_map<uint64_t, std::unordered_map<GLint, texture_level_t>> levels;
    // Texture objects whose GL_TEXTURE_SWIZZLE_RGBA the WRAPPER wrote, for
    // the legacy-internalformat emulation or GL_DEPTH_TEXTURE_MODE. Same key
    // as .levels. Re-specifying such an object with a format that needs no
    // swizzle has to take that swizzle back off (plans/17 P17), and tracking
    // which ones the wrapper imposed is what keeps the reset off a swizzle
    // the app set for itself - image specification does not touch texture
    // parameter state in GL.
    std::unordered_set<uint64_t> wrapper_swizzled;
};

// Collapses a cube face target to GL_TEXTURE_CUBE_MAP and a GL_TEXTURE_1D
// target to GL_TEXTURE_2D (the storage it actually shares, see
// hijack_fpe_states's GL_TEXTURE_1D case) - the metadata key only needs to
// distinguish storage, not every alias GL accepts for it. Defined ahead of
// swizzleTargetFor()'s own copy of the cube-face half of this rule further
// down in this file; kept separate rather than reordered, since that one is
// scoped to its own BGRA-upload section and this one predates it.
GLenum textureMetadataTarget(GLenum target) {
    if (target >= GL_TEXTURE_CUBE_MAP_POSITIVE_X && target <= GL_TEXTURE_CUBE_MAP_NEGATIVE_Z)
        return GL_TEXTURE_CUBE_MAP;
    if (target == GL_TEXTURE_1D) return GL_TEXTURE_2D;
    return target;
}

uint64_t textureMetadataKey(GLuint texture, GLenum target) {
    return (static_cast<uint64_t>(texture) << 32) |
           static_cast<uint64_t>(textureMetadataTarget(target));
}
// A raw pointer behind a lazy heap allocation, not a thread_local
// texture_metadata_cache_t directly: the struct carries two
// std::unordered_maps, and this library is always reached via dlopen (the
// test harness here, and the MobileGlues plugin path on Android), where a
// dlopen'd module's static TLS block is a small, fixed-size reservation that
// a pair of unordered_map control blocks eats into for no benefit - the maps
// themselves live on the heap either way.
thread_local texture_metadata_cache_t* textureMetadataCachePtr = nullptr;

texture_metadata_cache_t& textureMetadata() {
    if (textureMetadataCachePtr == nullptr) textureMetadataCachePtr = new texture_metadata_cache_t();
    auto& textureMetadataCache = *textureMetadataCachePtr;
    const EGLContext context = (EGLContext)glstate_t::cached_context();
    if (textureMetadataCache.context != context) {
        textureMetadataCache = {};
        textureMetadataCache.context = context;
    }
    return textureMetadataCache;
}

void rememberTextureLevel(GLuint texture, GLenum target, GLint level, GLsizei width, GLsizei height,
                          GLint internal_format, GLint border, bool compressed,
                          GLsizei compressed_size, GLsizei depth = 1) {
    if (texture == 0 || level < 0) return;
    auto& metadata = textureMetadata();
    metadata.levels[textureMetadataKey(texture, target)][level] =
        {width, height, depth, internal_format, border, compressed, compressed_size};
    // .sizes is 2D-only (see the field comment); a non-2D target has
    // nothing to record there.
    if (level == 0 && textureMetadataTarget(target) == GL_TEXTURE_2D)
        metadata.sizes[texture] = {width, height};
}

const texture_level_t* findTextureLevel(GLuint texture, GLenum target, GLint level) {
    auto& levels = textureMetadata().levels;
    const auto texture_it = levels.find(textureMetadataKey(texture, target));
    if (texture_it == levels.end()) return nullptr;
    const auto level_it = texture_it->second.find(level);
    return level_it == texture_it->second.end() ? nullptr : &level_it->second;
}

void rememberWrapperSwizzle(GLuint texture, GLenum target) {
    if (texture != 0) textureMetadata().wrapper_swizzled.insert(textureMetadataKey(texture, target));
}

// Whether the wrapper had imposed a swizzle on this object, forgetting it in
// the same breath: every caller is about to replace or drop it.
bool takeWrapperSwizzle(GLuint texture, GLenum target) {
    if (texture == 0) return false;
    return textureMetadata().wrapper_swizzled.erase(textureMetadataKey(texture, target)) != 0;
}
} // namespace

void sfpewRememberTextureSize(GLuint texture, GLsizei width, GLsizei height) {
    if (texture != 0) textureMetadata().sizes[texture] = {width, height};
}

// texture_metadata_cache_t is file-local here; glDeleteTextures lives in
// texture_binding.cpp and needs to reach into it to drop a deleted name's
// cached size/level data, hence this small accessor rather than exposing
// the cache's internals across the file boundary.
void sfpewForgetTextureMetadata(GLuint texture) {
    auto& metadata = textureMetadata();
    metadata.sizes.erase(texture);
    // .levels and .wrapper_swizzled are keyed on (name, target), so one name
    // can hold an entry per target it was ever used with - erasing by the
    // bare name matched none of them and left a recycled name answering with
    // the deleted texture's levels.
    for (auto it = metadata.levels.begin(); it != metadata.levels.end();) {
        if ((it->first >> 32) == texture)
            it = metadata.levels.erase(it);
        else
            ++it;
    }
    for (auto it = metadata.wrapper_swizzled.begin(); it != metadata.wrapper_swizzled.end();) {
        if ((*it >> 32) == texture)
            it = metadata.wrapper_swizzled.erase(it);
        else
            ++it;
    }
}

void sfpewSetGenerateMipmap(GLenum, GLuint texture, bool enable) {
    if (texture == 0) return;
    auto& textures = textureScratch().generate_mipmap_textures;
    if (enable)
        textures[texture] = true;
    else
        textures.erase(texture);
}

namespace {
// SFPEW_MANUAL_MIPGEN: unset/1 = backend call then repair (default);
// 0 = plain backend call; "only" = repair without the backend call, a test
// hook that simulates the stale-level driver so the blit chain has to
// produce every level by itself (levels must already be allocated).
int manualMipmapRepairMode() {
    static const int mode = [] {
        const char* v = getenv("SFPEW_MANUAL_MIPGEN");
        if (v == nullptr) return 1;
        if (v[0] == '0' && v[1] == '\0') return 0;
        if (std::strcmp(v, "only") == 0) return 2;
        return 1;
    }();
    return mode;
}

// The mobile driver was caught leaving the HIGH mip levels of a 2400x1080
// render target STALE across glGenerateMipmap calls - on-device probes of the
// Derivative shader pack showed level 4 tracking the freshly rendered base
// while level 8 still held an image from seconds earlier, on two different GL
// backend implementations over the same GLES driver. The pack's auto-exposure
// averages the scene from level 6 of that chain, so stale-bright levels crush
// the exposure and the screen goes dead dark until the leftover content
// happens to match the view again. A single mipgen call cannot produce
// fresh-4/stale-8 (8 derives from 4), so the driver demonstrably stopped
// partway; rebuild the whole chain ourselves, one LINEAR blit per level.
//
// The backend's glGenerateMipmap has ALREADY run when this is called: it
// allocates any missing levels (a blit cannot) and remains the result for
// any level this repair cannot reach - stopping early is never worse than
// the plain call. Depth/integer chains fail the completeness or blit checks
// on the first level and fall through to that intact result.

// glTexStorage2D wants a SIZED internal format; legacy chains report the
// unsized names (or the GL 1.x component counts).
GLint sizedInternalFormat(GLint internalformat) {
    switch (internalformat) {
    case GL_RGBA: case 4: return GL_RGBA8;
    case GL_RGB: case 3: return GL_RGB8;
    case GL_RG: return GL_RG8;
    case GL_RED: return GL_R8;
    default: return internalformat;
    }
}

bool ensureMipScratch(GLsizei w, GLsizei h, GLint internalformat) {
    if (g_glFuncs.glTexStorage2D == nullptr || g_glFuncs.glGenTextures == nullptr ||
        g_glFuncs.glDeleteTextures == nullptr || g_glFuncs.glBindTexture == nullptr)
        return false;
    auto& s = textureScratch().mip;
    if (s.tex != 0 && s.w == w && s.h == h && s.internalformat == internalformat) return true;
    if (s.tex != 0) {
        g_glFuncs.glDeleteTextures(1, &s.tex);
        s = {};
    }
    GLint prev = 0;
    g_glFuncs.glGetIntegerv(0x8069 /* GL_TEXTURE_BINDING_2D */, &prev);
    g_glFuncs.glGenTextures(1, &s.tex);
    if (s.tex == 0) return false;
    g_glFuncs.glBindTexture(GL_TEXTURE_2D, s.tex);
    while (g_glFuncs.glGetError() != GL_NO_ERROR) {}
    g_glFuncs.glTexStorage2D(GL_TEXTURE_2D, 1, (GLenum)internalformat, w, h);
    const bool ok = g_glFuncs.glGetError() == GL_NO_ERROR;
    g_glFuncs.glBindTexture(GL_TEXTURE_2D, (GLuint)prev);
    if (!ok) {
        g_glFuncs.glDeleteTextures(1, &s.tex);
        s = {};
        return false;
    }
    s.w = w;
    s.h = h;
    s.internalformat = internalformat;
    return true;
}

void repairMipmapChain2D() {
    if (g_glFuncs.glBlitFramebuffer == nullptr || g_glFuncs.glGenFramebuffers == nullptr ||
        g_glFuncs.glFramebufferTexture2D == nullptr ||
        g_glFuncs.glCheckFramebufferStatus == nullptr || g_glFuncs.glBindFramebuffer == nullptr ||
        g_glFuncs.glGetIntegerv == nullptr || g_glFuncs.glGetError == nullptr ||
        g_glFuncs.glGetTexLevelParameteriv == nullptr)
        return;
    const GLuint texture = sfpewLogicalTextureBinding(GL_TEXTURE_2D);
    if (texture == 0) return;

    GLsizei width = 0, height = 0;
    const auto& texture_sizes = textureMetadata().sizes;
    const auto size_it = texture_sizes.find(texture);
    if (size_it != texture_sizes.end()) {
        width = size_it->second.width;
        height = size_it->second.height;
    } else {
        GLint w = 0, h = 0;
        g_glFuncs.glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &w);
        g_glFuncs.glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &h);
        width = w;
        height = h;
    }
    if (width <= 1 && height <= 1) return;

    while (g_glFuncs.glGetError() != GL_NO_ERROR) {}

    GLint internalformat = 0;
    g_glFuncs.glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_INTERNAL_FORMAT,
                                       &internalformat);
    if (internalformat == 0) return;
    if (!ensureMipScratch(std::max<GLsizei>(width >> 1, 1), std::max<GLsizei>(height >> 1, 1),
                          sizedInternalFormat(internalformat)))
        return;

    GLint prev_read = 0, prev_draw = 0;
    g_glFuncs.glGetIntegerv(0x8CAA /* GL_READ_FRAMEBUFFER_BINDING */, &prev_read);
    g_glFuncs.glGetIntegerv(0x8CA6 /* GL_DRAW_FRAMEBUFFER_BINDING */, &prev_draw);
    // Scissor clips glBlitFramebuffer writes; the repair must cover the level.
    const bool scissor =
        g_glFuncs.glIsEnabled != nullptr && g_glFuncs.glIsEnabled(GL_SCISSOR_TEST) == GL_TRUE;
    if (scissor && g_glFuncs.glDisable != nullptr) g_glFuncs.glDisable(GL_SCISSOR_TEST);

    auto& scratch = textureScratch();
    GLuint* const blit_fbos = scratch.blit_fbos;
    if (blit_fbos[0] == 0) g_glFuncs.glGenFramebuffers(2, blit_fbos);
    if (blit_fbos[0] != 0 && blit_fbos[1] != 0) {
        // Fresh FBOs read from and draw to COLOR_ATTACHMENT0 by default.
        g_glFuncs.glBindFramebuffer(0x8CA8 /* GL_READ_FRAMEBUFFER */, blit_fbos[0]);
        g_glFuncs.glBindFramebuffer(0x8CA9 /* GL_DRAW_FRAMEBUFFER */, blit_fbos[1]);
        GLsizei pw = width > 0 ? width : 1, ph = height > 0 ? height : 1;
        for (GLint level = 1; pw > 1 || ph > 1; ++level) {
            const GLsizei lw = std::max<GLsizei>(width >> level, 1);
            const GLsizei lh = std::max<GLsizei>(height >> level, 1);
            // Hop 1: previous level, downsampled into the scratch corner.
            g_glFuncs.glFramebufferTexture2D(0x8CA8, 0x8CE0 /* GL_COLOR_ATTACHMENT0 */,
                                             GL_TEXTURE_2D, texture, level - 1);
            g_glFuncs.glFramebufferTexture2D(0x8CA9, 0x8CE0, GL_TEXTURE_2D, scratch.mip.tex, 0);
            if (g_glFuncs.glCheckFramebufferStatus(0x8CA8) != GL_FRAMEBUFFER_COMPLETE ||
                g_glFuncs.glCheckFramebufferStatus(0x8CA9) != GL_FRAMEBUFFER_COMPLETE)
                break;
            g_glFuncs.glBlitFramebuffer(0, 0, pw, ph, 0, 0, lw, lh, GL_COLOR_BUFFER_BIT,
                                        GL_LINEAR);
            if (g_glFuncs.glGetError() != GL_NO_ERROR) break;
            // Hop 2: scratch corner into the destination level, 1:1.
            g_glFuncs.glFramebufferTexture2D(0x8CA8, 0x8CE0, GL_TEXTURE_2D, scratch.mip.tex, 0);
            g_glFuncs.glFramebufferTexture2D(0x8CA9, 0x8CE0, GL_TEXTURE_2D, texture, level);
            if (g_glFuncs.glCheckFramebufferStatus(0x8CA8) != GL_FRAMEBUFFER_COMPLETE ||
                g_glFuncs.glCheckFramebufferStatus(0x8CA9) != GL_FRAMEBUFFER_COMPLETE)
                break;
            g_glFuncs.glBlitFramebuffer(0, 0, lw, lh, 0, 0, lw, lh, GL_COLOR_BUFFER_BIT,
                                        GL_NEAREST);
            if (g_glFuncs.glGetError() != GL_NO_ERROR) break;
            pw = lw;
            ph = lh;
        }
        g_glFuncs.glFramebufferTexture2D(0x8CA8, 0x8CE0, GL_TEXTURE_2D, 0, 0);
        g_glFuncs.glFramebufferTexture2D(0x8CA9, 0x8CE0, GL_TEXTURE_2D, 0, 0);
        g_glFuncs.glBindFramebuffer(0x8CA8, (GLuint)prev_read);
        g_glFuncs.glBindFramebuffer(0x8CA9, (GLuint)prev_draw);
    }
    if (scissor && g_glFuncs.glEnable != nullptr) g_glFuncs.glEnable(GL_SCISSOR_TEST);
    while (g_glFuncs.glGetError() != GL_NO_ERROR) {}
}
} // namespace

void sfpewMaybeGenerateMipmap(GLenum target) {
    if (target == GL_TEXTURE_1D) target = GL_TEXTURE_2D;
    if (target != GL_TEXTURE_2D || g_glFuncs.glGenerateMipmap == nullptr) return;
    const GLuint bound = sfpewLogicalTextureBinding(GL_TEXTURE_2D);
    if (bound != 0 && textureScratch().generate_mipmap_textures.count(bound) != 0) {
        g_glFuncs.glGenerateMipmap(GL_TEXTURE_2D);
        if (manualMipmapRepairMode() != 0) repairMipmapChain2D();
    }
}

// GL 3.0 / ES 2.0 core. Not a passthrough: after the backend call the 2D
// chain is rebuilt level by level (see repairMipmapChain2D above). The flush
// keeps any batched immediate-mode drawing ordered before the mipgen reads
// its base level; texture/FBO state is read directly and restored.
void glGenerateMipmap(GLenum target) {
    if (!sfpewEnsureBackend() || g_glFuncs.glGenerateMipmap == nullptr) return;
    sfpewTextureStateBarrier();
    const int mode = manualMipmapRepairMode();
    if (mode != 2) g_glFuncs.glGenerateMipmap(target);
    if (target == GL_TEXTURE_2D && mode != 0) repairMipmapChain2D();
}

// GL_TEXTURE_1D does not exist on GLES: 1D textures are stored as Nx1 2D
// textures. Any wrap mode samples row 0 of an Nx1 texture, so generated
// shaders need no coordinate rewrite. (plans/05, 5.4)
void glTexImage1D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLint border,
                  GLenum format, GLenum type, const GLvoid* pixels) {
    auto& gs = g_glstate;
    if (target != GL_TEXTURE_1D && target != GL_PROXY_TEXTURE_1D) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (target == GL_PROXY_TEXTURE_1D) return; // no proxy bookkeeping for 1D
    glTexImage2D(GL_TEXTURE_2D, level, internalformat, width, 1, border, format, type, pixels);
}

void glTexSubImage1D(GLenum target, GLint level, GLint xoffset, GLsizei width, GLenum format,
                     GLenum type, const GLvoid* pixels) {
    auto& gs = g_glstate;
    if (target != GL_TEXTURE_1D) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    glTexSubImage2D(GL_TEXTURE_2D, level, xoffset, 0, width, 1, format, type, pixels);
}

namespace {

bool isGenericCompressedFormat(GLenum format) {
    switch (format) {
    case GL_COMPRESSED_ALPHA:
    case GL_COMPRESSED_LUMINANCE:
    case GL_COMPRESSED_LUMINANCE_ALPHA:
    case GL_COMPRESSED_INTENSITY:
    case GL_COMPRESSED_RGB:
    case GL_COMPRESSED_RGBA:
    case 0x8C48: // GL_COMPRESSED_SRGB
    case 0x8C49: // GL_COMPRESSED_SRGB_ALPHA
    case 0x8C4A: // GL_COMPRESSED_SLUMINANCE
    case 0x8C4B: // GL_COMPRESSED_SLUMINANCE_ALPHA
        return true;
    default:
        return false;
    }
}

bool isBlockCompressedFormat(GLenum format) {
    // Every format guaranteed by ES 3.0, plus the formats commonly exposed
    // by desktop drivers, uses a block at least four texels high. Keep the
    // range tests explicit so newly added formats do not accidentally become
    // a driver call with a one-row payload.
    if ((format >= 0x9270 && format <= 0x9279) || // ETC2 / EAC
        (format >= 0x83F0 && format <= 0x83F3) || // S3TC / DXT
        (format >= 0x8C4C && format <= 0x8C4F) || // sRGB S3TC
        (format >= 0x8C70 && format <= 0x8C73) || // LATC
        (format >= 0x8DBB && format <= 0x8DBE) || // RGTC
        (format >= 0x8E8C && format <= 0x8E8F) || // BPTC
        (format >= 0x93B0 && format <= 0x93BD) || // linear ASTC
        (format >= 0x93D0 && format <= 0x93DD) || // sRGB ASTC
        format == 0x86B0 || format == 0x86B1 ||   // FXT1
        format == 0x8D64) {                       // ETC1
        return true;
    }
    // Unknown compressed formats are conservatively block-compressed. A
    // guessed layout can make a driver read beyond the supplied payload.
    return true;
}

// A compiled pixel command holds the data as it was AT COMPILE TIME (GL 2.1
// 4.4.6), so the list owns a copy of the payload. With GL_PIXEL_UNPACK_BUFFER
// bound `data` is a byte offset into that buffer and not an address at all,
// and the recorder's pointer capture used to memcpy straight from it
// (plans/17 P14, SIGSEGV); read the bytes out of the buffer instead. A
// readback the driver refuses records NOTHING, the same answer
// fpe/list_capture.cpp gives when it cannot snapshot a draw's vertex data
// (plans/15) - a list holding an offset it can no longer resolve is worse
// than a list missing the command.
bool captureCompressedListPayload(GLsizei imageSize, const GLvoid** data,
                                  std::vector<uint8_t>* storage) {
    if (!sfpewEnsureBackend() || g_glFuncs.glGetIntegerv == nullptr) return true;
    GLint pbo = 0;
    g_glFuncs.glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pbo);
    if (pbo == 0) return true; // client memory: the recorder's own copy is correct
    if (imageSize <= 0) {
        *data = nullptr;
        return true;
    }
    if (g_glFuncs.glMapBufferRange == nullptr || g_glFuncs.glUnmapBuffer == nullptr ||
        g_glFuncs.glGetBufferParameteriv == nullptr) {
        SFPEW_LOGW("compressed upload: backend cannot map buffers; the unpack-buffer payload "
                   "cannot be compiled into a display list");
        return false;
    }
    sfpewEntryBarrier();
    const size_t offset = (size_t)(uintptr_t)*data;
    GLint buffer_size = 0;
    g_glFuncs.glGetBufferParameteriv(GL_PIXEL_UNPACK_BUFFER, GL_BUFFER_SIZE, &buffer_size);
    if (buffer_size <= 0 || offset > (size_t)buffer_size ||
        (size_t)imageSize > (size_t)buffer_size - offset) {
        SFPEW_LOGW("compressed upload: unpack buffer %d has no %d bytes at offset %zu; not "
                   "recording", pbo, imageSize, offset);
        return false;
    }
    const void* mapped = g_glFuncs.glMapBufferRange(GL_PIXEL_UNPACK_BUFFER, (GLintptr)offset,
                                                    (GLsizeiptr)imageSize, GL_MAP_READ_BIT);
    if (mapped == nullptr) {
        while (g_glFuncs.glGetError() != GL_NO_ERROR) {} // eat the failed map's error
        SFPEW_LOGW("compressed upload: unpack buffer %d refused a READ mapping; not recording",
                   pbo);
        return false;
    }
    storage->assign((const uint8_t*)mapped, (const uint8_t*)mapped + imageSize);
    if (g_glFuncs.glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER) == GL_FALSE) {
        SFPEW_LOGW("compressed upload: unpack buffer %d reported data loss while reading; not "
                   "recording", pbo);
        return false;
    }
    *data = storage->data();
    return true;
}

// The captured payload is client memory by replay time, so an unpack buffer
// the app happens to have bound at glCallList must not turn it back into an
// offset. Restored right after: the binding is the app's.
struct unpack_buffer_release_t {
    GLint pbo = 0;
    unpack_buffer_release_t() {
        if (g_glFuncs.glGetIntegerv == nullptr || g_glFuncs.glBindBuffer == nullptr) return;
        g_glFuncs.glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pbo);
        if (pbo != 0) g_glFuncs.glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    }
    ~unpack_buffer_release_t() {
        if (pbo != 0) g_glFuncs.glBindBuffer(GL_PIXEL_UNPACK_BUFFER, (GLuint)pbo);
    }
};

void replayCompressedTexImage1D(GLenum target, GLint level, GLenum internalformat, GLsizei width,
                                GLint border, GLsizei imageSize, const GLvoid* data) {
    if (!sfpewEnsureBackend()) return;
    unpack_buffer_release_t released;
    SELF_CALL(glCompressedTexImage1D, target, level, internalformat, width, border, imageSize, data)
}

void replayCompressedTexSubImage1D(GLenum target, GLint level, GLint xoffset, GLsizei width,
                                   GLenum format, GLsizei imageSize, const GLvoid* data) {
    if (!sfpewEnsureBackend()) return;
    unpack_buffer_release_t released;
    SELF_CALL(glCompressedTexSubImage1D, target, level, xoffset, width, format, imageSize, data)
}

void replayCompressedTexImage2D(GLenum target, GLint level, GLenum internalformat, GLsizei width,
                                GLsizei height, GLint border, GLsizei imageSize,
                                const GLvoid* data) {
    if (!sfpewEnsureBackend()) return;
    unpack_buffer_release_t released;
    SELF_CALL(glCompressedTexImage2D, target, level, internalformat, width, height, border,
              imageSize, data)
}

void replayCompressedTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset,
                                   GLsizei width, GLsizei height, GLenum format, GLsizei imageSize,
                                   const GLvoid* data) {
    if (!sfpewEnsureBackend()) return;
    unpack_buffer_release_t released;
    SELF_CALL(glCompressedTexSubImage2D, target, level, xoffset, yoffset, width, height, format,
              imageSize, data)
}

} // namespace

// LIST_RECORD's gate and its record-then-maybe-return, with the two things
// the compressed family needs on top: the recorded payload comes from
// captureCompressedListPayload above, and the command replays through the
// trampolines that release the unpack binding.
#define SFPEW_RECORD_COMPRESSED(replay, dataIndex, ...)                                            \
    std::vector<uint8_t> sfpew_payload;                                                            \
    const GLvoid* sfpew_data = data;                                                               \
    if (!disableRecording && DisplayListManager::shouldRecord()) {                                 \
        if (captureCompressedListPayload(imageSize, &sfpew_data, &sfpew_payload)) {                \
            displayListManager.record<replay>(                                                     \
                {{dataIndex, static_cast<size_t>(imageSize > 0 ? imageSize : 0)}}, __VA_ARGS__);   \
        }                                                                                          \
        if (DisplayListManager::shouldFinish()) return;                                            \
    }

void glCopyTexImage1D(GLenum target, GLint level, GLenum internalformat, GLint x, GLint y,
                      GLsizei width, GLint border) {
    auto& gs = g_glstate;
    if (target != GL_TEXTURE_1D) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (border != 0 || level < 0 || width < 0) {
        gs.set_error(GL_INVALID_VALUE);
        return;
    }
    LIST_RECORD(glCopyTexImage1D, {}, target, level, internalformat, x, y, width, border)
    SELF_CALL(glCopyTexImage2D, GL_TEXTURE_2D, level, internalformat, x, y, width, 1, border)
}

void glCopyTexSubImage1D(GLenum target, GLint level, GLint xoffset, GLint x, GLint y,
                         GLsizei width) {
    auto& gs = g_glstate;
    if (target != GL_TEXTURE_1D) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (level < 0 || xoffset < 0 || width < 0) {
        gs.set_error(GL_INVALID_VALUE);
        return;
    }
    LIST_RECORD(glCopyTexSubImage1D, {}, target, level, xoffset, x, y, width)
    SELF_CALL(glCopyTexSubImage2D, GL_TEXTURE_2D, level, xoffset, 0, x, y, width, 1)
}

void glCopyTexImage2D(GLenum target, GLint level, GLenum internalformat, GLint x, GLint y,
                      GLsizei width, GLsizei height, GLint border) {
    if (level < 0 || width < 0 || height < 0 || border != 0) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    LIST_RECORD(glCopyTexImage2D, {}, target, level, internalformat, x, y, width, height, border)
    sfpewEntryBarrier();
    if (!sfpewEnsureBackend() || g_glFuncs.glCopyTexImage2D == nullptr) return;
    if (sfpewImagingActive()) {
        std::vector<GLfloat> rgba;
        GLsizei output_width = width, output_height = height;
        if (!sfpewImagingReadRgba(x, y, width, height, &rgba, &output_width, &output_height))
            return;
        if (!sfpewImagingSink() && rgba.empty() && width != 0 && height != 0) return;
        sfpew_imaging_upload_t tight;
        sfpewBeginTightImagingUpload(&tight);
        struct guard_t {
            sfpew_imaging_upload_t& tight;
            guard_t(sfpew_imaging_upload_t& value) : tight(value) { sfpewPushImagingBypass(); }
            ~guard_t() {
                sfpewPopImagingBypass();
                sfpewFinishImagingUpload(tight);
            }
        } guard(tight);
        if (sfpewImagingSink()) {
            SELF_CALL(glTexImage2D, target, level, internalformat, output_width, output_height,
                      border, GL_RGBA, GL_FLOAT, nullptr)
        } else {
            SELF_CALL(glTexImage2D, target, level, internalformat, output_width, output_height,
                      border, GL_RGBA, GL_FLOAT, rgba.data())
        }
        return;
    }
    g_glFuncs.glCopyTexImage2D(target, level, internalformat, x, y, width, height, border);
    // defects-plan-2.md 2.7: glCopyTexImage2D can target a cube face too.
    if (target == GL_TEXTURE_2D ||
        (target >= GL_TEXTURE_CUBE_MAP_POSITIVE_X && target <= GL_TEXTURE_CUBE_MAP_NEGATIVE_Z)) {
        rememberTextureLevel(sfpewLogicalTextureBinding(textureMetadataTarget(target)), target, level,
                             width, height, internalformat, border, false, 0);
    }
    sfpewMaybeGenerateMipmap(target);
}

void glCopyTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint x, GLint y,
                         GLsizei width, GLsizei height) {
    if (level < 0 || width < 0 || height < 0) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    LIST_RECORD(glCopyTexSubImage2D, {}, target, level, xoffset, yoffset, x, y, width, height)
    sfpewEntryBarrier();
    if (!sfpewEnsureBackend() || g_glFuncs.glCopyTexSubImage2D == nullptr) return;
    if (sfpewImagingActive()) {
        std::vector<GLfloat> rgba;
        GLsizei output_width = width, output_height = height;
        if (!sfpewImagingReadRgba(x, y, width, height, &rgba, &output_width, &output_height))
            return;
        if (sfpewImagingSink() || (rgba.empty() && width != 0 && height != 0)) return;
        sfpew_imaging_upload_t tight;
        sfpewBeginTightImagingUpload(&tight);
        struct guard_t {
            sfpew_imaging_upload_t& tight;
            guard_t(sfpew_imaging_upload_t& value) : tight(value) { sfpewPushImagingBypass(); }
            ~guard_t() {
                sfpewPopImagingBypass();
                sfpewFinishImagingUpload(tight);
            }
        } guard(tight);
        SELF_CALL(glTexSubImage2D, target, level, xoffset, yoffset, output_width, output_height,
                  GL_RGBA, GL_FLOAT, rgba.data())
        return;
    }
    g_glFuncs.glCopyTexSubImage2D(target, level, xoffset, yoffset, x, y, width, height);
    sfpewMaybeGenerateMipmap(target);
}

void glCompressedTexImage1D(GLenum target, GLint level, GLenum internalformat, GLsizei width,
                            GLint border, GLsizei imageSize, const GLvoid* data) {
    auto& gs = g_glstate;
    if (target != GL_TEXTURE_1D && target != GL_PROXY_TEXTURE_1D) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (border != 0 || imageSize < 0 || level < 0 || width < 0) {
        gs.set_error(GL_INVALID_VALUE);
        return;
    }
    if (isGenericCompressedFormat(internalformat)) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    SFPEW_RECORD_COMPRESSED(replayCompressedTexImage1D, 6, target, level, internalformat, width,
                            border, imageSize, sfpew_data)
    sfpewEntryBarrier();
    if (target == GL_PROXY_TEXTURE_1D) return;

    // A 1D image is represented by a one-row 2D image here. No block format
    // exposed by either backend floor can represent that height.
    if (isBlockCompressedFormat(internalformat)) {
        gs.set_error(GL_INVALID_OPERATION);
        return;
    }
    if (!sfpewEnsureBackend() || g_glFuncs.glCompressedTexImage2D == nullptr) return;
    g_glFuncs.glCompressedTexImage2D(GL_TEXTURE_2D, level, internalformat, width, 1, border,
                                     imageSize, data);
    rememberTextureLevel(sfpewLogicalTextureBinding(GL_TEXTURE_2D), GL_TEXTURE_2D, level, width, 1,
                         static_cast<GLint>(internalformat), border, true, imageSize);
    sfpewMaybeGenerateMipmap(GL_TEXTURE_2D);
}

void glCompressedTexSubImage1D(GLenum target, GLint level, GLint xoffset, GLsizei width,
                               GLenum format, GLsizei imageSize, const GLvoid* data) {
    auto& gs = g_glstate;
    if (target != GL_TEXTURE_1D) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (imageSize < 0 || level < 0 || xoffset < 0 || width < 0) {
        gs.set_error(GL_INVALID_VALUE);
        return;
    }
    if (isGenericCompressedFormat(format)) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    SFPEW_RECORD_COMPRESSED(replayCompressedTexSubImage1D, 6, target, level, xoffset, width, format,
                            imageSize, sfpew_data)
    sfpewEntryBarrier();
    if (isBlockCompressedFormat(format)) {
        gs.set_error(GL_INVALID_OPERATION);
        return;
    }
    if (!sfpewEnsureBackend() || g_glFuncs.glCompressedTexSubImage2D == nullptr) return;
    g_glFuncs.glCompressedTexSubImage2D(GL_TEXTURE_2D, level, xoffset, 0, width, 1, format,
                                        imageSize, data);
    sfpewMaybeGenerateMipmap(GL_TEXTURE_2D);
}

void glGetCompressedTexImage(GLenum target, GLint level, GLvoid* pixels) {
    auto& gs = g_glstate;
    if (pixels == nullptr) return;
    switch (target) {
    case GL_TEXTURE_1D:
    case GL_TEXTURE_2D:
    case GL_TEXTURE_3D:
    case GL_TEXTURE_CUBE_MAP_POSITIVE_X:
    case GL_TEXTURE_CUBE_MAP_NEGATIVE_X:
    case GL_TEXTURE_CUBE_MAP_POSITIVE_Y:
    case GL_TEXTURE_CUBE_MAP_NEGATIVE_Y:
    case GL_TEXTURE_CUBE_MAP_POSITIVE_Z:
    case GL_TEXTURE_CUBE_MAP_NEGATIVE_Z:
        break;
    default:
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (level < 0) {
        gs.set_error(GL_INVALID_VALUE);
        return;
    }
    sfpewEntryBarrier();
    if (!sfpewEnsureBackend()) return;

    // GLES 3.0 has no texture readback. Retaining every compressed payload on
    // the CPU would double the footprint of the largest texture allocations,
    // so GLES fails loudly while desktop GL forwards exactly.
    if (!sfpewBackendIsES() && g_glFuncs.glGetCompressedTexImage != nullptr) {
        const GLenum backend_target = target == GL_TEXTURE_1D ? GL_TEXTURE_2D : target;
        g_glFuncs.glGetCompressedTexImage(backend_target, level, pixels);
        return;
    }
    gs.set_error(GL_INVALID_OPERATION);
}

void glCompressedTexImage2D(GLenum target, GLint level, GLenum internalformat, GLsizei width,
                            GLsizei height, GLint border, GLsizei imageSize, const GLvoid* data) {
    auto& gs = g_glstate;
    const bool is_cube_face =
        target >= GL_TEXTURE_CUBE_MAP_POSITIVE_X && target <= GL_TEXTURE_CUBE_MAP_NEGATIVE_Z;
    if (target != GL_TEXTURE_2D && target != GL_PROXY_TEXTURE_2D && !is_cube_face) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (border != 0 || imageSize < 0 || level < 0 || width < 0 || height < 0) {
        gs.set_error(GL_INVALID_VALUE);
        return;
    }
    if (isGenericCompressedFormat(internalformat)) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    SFPEW_RECORD_COMPRESSED(replayCompressedTexImage2D, 7, target, level, internalformat, width,
                            height, border, imageSize, sfpew_data)
    sfpewEntryBarrier();
    // Unlike GL_PROXY_TEXTURE_1D (an emulated target with no backend storage
    // to test at all), GL_PROXY_TEXTURE_2D is real on desktop but absent from
    // GLES entirely - forwarding it would ask an ES backend to validate a
    // target it does not define. Matching the 1D wrapper's own proxy
    // handling, validate the arguments above and stop rather than either
    // guessing an answer or forwarding to a backend that may not have it.
    if (target == GL_PROXY_TEXTURE_2D) return;
    if (!sfpewEnsureBackend() || g_glFuncs.glCompressedTexImage2D == nullptr) return;
    g_glFuncs.glCompressedTexImage2D(target, level, internalformat, width, height, border,
                                     imageSize, data);
    rememberTextureLevel(sfpewLogicalTextureBinding(textureMetadataTarget(target)), target, level,
                         width, height, static_cast<GLint>(internalformat), border, true, imageSize);
    sfpewMaybeGenerateMipmap(target);
}

void glCompressedTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset,
                               GLsizei width, GLsizei height, GLenum format, GLsizei imageSize,
                               const GLvoid* data) {
    auto& gs = g_glstate;
    const bool is_cube_face =
        target >= GL_TEXTURE_CUBE_MAP_POSITIVE_X && target <= GL_TEXTURE_CUBE_MAP_NEGATIVE_Z;
    if (target != GL_TEXTURE_2D && !is_cube_face) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (imageSize < 0 || level < 0 || xoffset < 0 || yoffset < 0 || width < 0 || height < 0) {
        gs.set_error(GL_INVALID_VALUE);
        return;
    }
    if (isGenericCompressedFormat(format)) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    SFPEW_RECORD_COMPRESSED(replayCompressedTexSubImage2D, 8, target, level, xoffset, yoffset,
                            width, height, format, imageSize, sfpew_data)
    sfpewEntryBarrier();
    if (!sfpewEnsureBackend() || g_glFuncs.glCompressedTexSubImage2D == nullptr) return;
    g_glFuncs.glCompressedTexSubImage2D(target, level, xoffset, yoffset, width, height, format,
                                        imageSize, data);
    sfpewMaybeGenerateMipmap(target);
}

#undef SFPEW_RECORD_COMPRESSED

namespace {

// Legacy desktop internalformats have no GLES3 equivalent. Map them onto
// R8/RG8 storage plus a texture swizzle that reproduces the fixed-function
// sampling semantics (plans/05, 5.3).
struct legacy_format_mapping_t {
    GLint internalformat;
    GLenum format;
    GLint swizzle[4];
};

bool mapLegacyInternalFormat(GLint internalformat, legacy_format_mapping_t& out) {
    switch (internalformat) {
    case GL_ALPHA:
    case GL_ALPHA4:
    case GL_ALPHA8:
    case GL_ALPHA12:
    case GL_ALPHA16:
        out = {GL_R8, GL_RED, {GL_ZERO, GL_ZERO, GL_ZERO, GL_RED}};
        return true;
    case GL_LUMINANCE:
    case GL_LUMINANCE4:
    case GL_LUMINANCE8:
    case GL_LUMINANCE12:
    case GL_LUMINANCE16:
    case 1:
        out = {GL_R8, GL_RED, {GL_RED, GL_RED, GL_RED, GL_ONE}};
        return true;
    case GL_LUMINANCE_ALPHA:
    case GL_LUMINANCE4_ALPHA4:
    case GL_LUMINANCE6_ALPHA2:
    case GL_LUMINANCE8_ALPHA8:
    case GL_LUMINANCE12_ALPHA4:
    case GL_LUMINANCE12_ALPHA12:
    case GL_LUMINANCE16_ALPHA16:
    case 2:
        out = {GL_RG8, GL_RG, {GL_RED, GL_RED, GL_RED, GL_GREEN}};
        return true;
    case GL_INTENSITY:
    case GL_INTENSITY4:
    case GL_INTENSITY8:
    case GL_INTENSITY12:
    case GL_INTENSITY16:
        out = {GL_R8, GL_RED, {GL_RED, GL_RED, GL_RED, GL_RED}};
        return true;
    case 3:
        out = {GL_RGB8, GL_RGB, {GL_RED, GL_GREEN, GL_BLUE, GL_ONE}};
        return true;
    case 4:
        out = {GL_RGBA8, GL_RGBA, {GL_RED, GL_GREEN, GL_BLUE, GL_ALPHA}};
        return true;
    // GL 2.1 sRGB internalformats (EXT_texture_sRGB) onto the ES3 natives.
    case GL_SRGB:
    case GL_SRGB8:
        out = {GL_SRGB8, GL_RGB, {GL_RED, GL_GREEN, GL_BLUE, GL_ONE}};
        return true;
    case GL_SRGB_ALPHA:
    case GL_SRGB8_ALPHA8:
        out = {GL_SRGB8_ALPHA8, GL_RGBA, {GL_RED, GL_GREEN, GL_BLUE, GL_ALPHA}};
        return true;
    default:
        return false;
    }
}

GLenum swizzleTargetFor(GLenum target) {
    if (target >= GL_TEXTURE_CUBE_MAP_POSITIVE_X && target <= GL_TEXTURE_CUBE_MAP_NEGATIVE_Z)
        return GL_TEXTURE_CUBE_MAP;
    return target;
}

// GL_ARB_depth_texture / GLES3+desktop-GL3 core natively accept these as
// internalformat, so mapLegacyInternalFormat above has no case for them -
// they need only the GL_DEPTH_TEXTURE_MODE swizzle below, not a storage
// rewrite.
bool isDepthTextureInternalFormat(GLint internalformat) {
    switch (internalformat) {
    case GL_DEPTH_COMPONENT:
    case GL_DEPTH_COMPONENT16:
    case GL_DEPTH_COMPONENT24:
    case GL_DEPTH_COMPONENT32F:
        return true;
    default:
        return false;
    }
}

// Duplicated from ordered_passthrough.cpp (which owns glGetTexParameterfv/iv,
// the read-side counterpart of this) rather than exposed cross-TU:
// sfpewApplyDepthTextureModeSwizzle below only needs a read of the depth-mode
// map, and this accessor is small enough that a second copy is simpler than
// a new export for it.
GLenum depthTextureMode(GLuint texture) {
    const auto& modes = g_glstate_c.texture_depth_mode;
    const auto it = modes.find(texture);
    return it == modes.end() ? GL_LUMINANCE : it->second;
}

// GL_DEPTH_TEXTURE_MODE (GL_ARB_depth_texture) sampling semantics as a
// GL_TEXTURE_SWIZZLE_RGBA array. GL_RED is the core GLES3/GL3 default
// (introduced when the fixed mode was deprecated) - depth sampled straight
// into .r with no replication.
void depthTextureModeSwizzle(GLenum mode, GLint (&out)[4]) {
    switch (mode) {
    case GL_INTENSITY:
        out[0] = out[1] = out[2] = out[3] = GL_RED;
        return;
    case GL_ALPHA:
        out[0] = out[1] = out[2] = GL_ZERO;
        out[3] = GL_RED;
        return;
    case GL_RED:
        out[0] = GL_RED; out[1] = GL_GREEN; out[2] = GL_BLUE; out[3] = GL_ALPHA;
        return;
    case GL_LUMINANCE:
    default:
        out[0] = out[1] = out[2] = GL_RED;
        out[3] = GL_ONE;
        return;
    }
}

// GL_BGRA uploads: GLES3 has no core BGRA path; swap on the CPU.
// Tightly-packed rows are assumed (the common LWJGL/awt case); exotic
// unpack state falls back to passthrough with a log line.
} // namespace

// Reusable trigger for both glTexImage2D (a depth texture just got uploaded)
// and glTexParameter* (GL_DEPTH_TEXTURE_MODE changed on an already-uploaded
// one). GL_ARB_shadow's GL_TEXTURE_COMPARE_MODE turned out NOT to need a
// third trigger through here: a sampler2DShadow's texture() call returns a
// plain float, so GL_TEXTURE_SWIZZLE_RGBA (whatever it is set to) never
// reaches the shader for a shadow-sampled unit - fpe_shadergen.cpp handles
// that case with its own shader-side vec4 broadcast instead. See
// glstate.cpp's resync_texture_shadow_sample() and the texture_shadow_sample
// codegen branch in fpe_shadergen.cpp's add_fs_body.
void sfpewApplyDepthTextureModeSwizzle(GLenum target, GLuint texture) {
    if (texture == 0 || g_glFuncs.glTexParameteriv == nullptr) return;
    const texture_level_t* level0 = findTextureLevel(texture, target, 0);
    if (level0 == nullptr || !isDepthTextureInternalFormat(level0->internal_format)) return;
    GLint swizzle[4];
    depthTextureModeSwizzle(depthTextureMode(texture), swizzle);
    g_glFuncs.glTexParameteriv(swizzleTargetFor(target), GL_TEXTURE_SWIZZLE_RGBA, swizzle);
    rememberWrapperSwizzle(texture, target);
}

// Reorder a GL_BGRA upload into tightly packed RGBA bytes, reading the source
// the way the backend would have: through the bound pixel unpack buffer when
// one is bound (mapped for reading - the bytes never pass through the wrapper
// otherwise), and honouring GL_UNPACK_ROW_LENGTH / SKIP_ROWS / SKIP_PIXELS.
// The tight-row shortcut this replaces broke every sub-rectangle upload out
// of a larger image, which is exactly how Minecraft stitches its atlases.
//
// On success the unpack state that would misread the TIGHT result is cleared
// and any unpack buffer is unbound; sfpewFinishBgraUpload restores both after
// the caller's backend upload. Alignment needs no handling: both source and
// result rows are whole 4-byte pixels.
bool sfpewPrepareBgraUpload(GLsizei width, GLsizei height, GLenum type, const void* pixels,
                            sfpew_bgra_upload_t* out) {
    *out = {};
    if (width <= 0 || height <= 0) return false;
    if (type != GL_UNSIGNED_BYTE && type != GL_UNSIGNED_INT_8_8_8_8 &&
        type != GL_UNSIGNED_INT_8_8_8_8_REV) {
        return false;
    }
    if (g_glFuncs.glGetIntegerv == nullptr || g_glFuncs.glPixelStorei == nullptr) return false;

    GLint row_length = 0, skip_rows = 0, skip_pixels = 0, pbo = 0;
    g_glFuncs.glGetIntegerv(GL_UNPACK_ROW_LENGTH, &row_length);
    g_glFuncs.glGetIntegerv(GL_UNPACK_SKIP_ROWS, &skip_rows);
    g_glFuncs.glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &skip_pixels);
    g_glFuncs.glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pbo);
    if (row_length < 0 || skip_rows < 0 || skip_pixels < 0) return false;

    const size_t row_px = row_length > 0 ? (size_t)row_length : (size_t)width;
    if (row_px < (size_t)width + (size_t)skip_pixels &&
        !(row_length > 0 && (size_t)row_length >= (size_t)width)) {
        // A row the caller described as narrower than the rectangle it is
        // uploading; let the backend produce whatever error it would have.
        if (row_length > 0) return false;
    }
    const size_t start = ((size_t)skip_rows * row_px + (size_t)skip_pixels) * 4u;
    const size_t needed = start + (((size_t)height - 1u) * row_px + (size_t)width) * 4u;

    const uint8_t* source = nullptr;
    GLuint copy_scratch = 0;
    if (pbo != 0) {
        if (g_glFuncs.glMapBufferRange == nullptr || g_glFuncs.glUnmapBuffer == nullptr)
            return false;
        // SFPEW_TEST_FORCE_BGRA_COPY=1: pretend the direct mapping failed,
        // exercising the copy path below on drivers whose direct mapping
        // succeeds. The copy path exists FOR drivers where it does not
        // (mobile refuses READ mappings of *_DRAW buffers), so without this
        // it would only ever run on the machines that need it least.
        static const bool force_copy_path = [] {
            const char* v = getenv("SFPEW_TEST_FORCE_BGRA_COPY");
            return v != nullptr && v[0] != '\0' && v[0] != '0';
        }();
        source = force_copy_path
                     ? nullptr
                     : static_cast<const uint8_t*>(g_glFuncs.glMapBufferRange(
                           GL_PIXEL_UNPACK_BUFFER, (GLintptr)(uintptr_t)pixels,
                           (GLsizeiptr)needed, GL_MAP_READ_BIT));
        if (source == nullptr) {
            // Mobile drivers routinely refuse a READ mapping of a buffer
            // whose usage hint was *_DRAW (the natural hint for an upload
            // PBO). Reading it back through a copy into a *_READ scratch is
            // the path those drivers do serve. This runs once per upload of
            // a shape the wrapper cannot otherwise reach, not per frame.
            while (g_glFuncs.glGetError() != GL_NO_ERROR) {} // eat the failed map's error
            if (g_glFuncs.glCopyBufferSubData == nullptr || g_glFuncs.glGenBuffers == nullptr ||
                g_glFuncs.glDeleteBuffers == nullptr || g_glFuncs.glBindBuffer == nullptr ||
                g_glFuncs.glBufferData == nullptr) {
                return false;
            }
            g_glFuncs.glGenBuffers(1, &copy_scratch);
            g_glFuncs.glBindBuffer(GL_COPY_WRITE_BUFFER, copy_scratch);
            g_glFuncs.glBufferData(GL_COPY_WRITE_BUFFER, (GLsizeiptr)needed, nullptr,
                                   GL_STREAM_READ);
            g_glFuncs.glCopyBufferSubData(GL_PIXEL_UNPACK_BUFFER, GL_COPY_WRITE_BUFFER,
                                          (GLintptr)(uintptr_t)pixels, 0, (GLsizeiptr)needed);
            source = static_cast<const uint8_t*>(g_glFuncs.glMapBufferRange(
                GL_COPY_WRITE_BUFFER, 0, (GLsizeiptr)needed, GL_MAP_READ_BIT));
            if (source == nullptr) {
                SFPEW_LOGW("BGRA upload: unpack buffer %d unmappable even via copy; "
                           "conversion impossible", pbo);
                g_glFuncs.glBindBuffer(GL_COPY_WRITE_BUFFER, 0);
                g_glFuncs.glDeleteBuffers(1, &copy_scratch);
                return false;
            }
        }
    } else {
        if (pixels == nullptr) return false;
        source = static_cast<const uint8_t*>(pixels);
    }

    thread_local std::vector<uint8_t> scratch;
    scratch.resize((size_t)width * (size_t)height * 4u);
    for (size_t row = 0; row < (size_t)height; ++row) {
        const uint8_t* in = source + start + row * row_px * 4u;
        uint8_t* line = scratch.data() + row * (size_t)width * 4u;
        if (type == GL_UNSIGNED_INT_8_8_8_8) {
            // Big-endian component packing: bytes in memory are A,R,G,B on a
            // little-endian host.
            for (size_t px = 0; px < (size_t)width * 4u; px += 4) {
                line[px + 0] = in[px + 1];
                line[px + 1] = in[px + 2];
                line[px + 2] = in[px + 3];
                line[px + 3] = in[px + 0];
            }
        } else {
            // GL_UNSIGNED_BYTE and _REV both lay the bytes out B,G,R,A.
            for (size_t px = 0; px < (size_t)width * 4u; px += 4) {
                line[px + 0] = in[px + 2];
                line[px + 1] = in[px + 1];
                line[px + 2] = in[px + 0];
                line[px + 3] = in[px + 3];
            }
        }
    }

    if (copy_scratch != 0) {
        g_glFuncs.glUnmapBuffer(GL_COPY_WRITE_BUFFER);
        g_glFuncs.glBindBuffer(GL_COPY_WRITE_BUFFER, 0);
        g_glFuncs.glDeleteBuffers(1, &copy_scratch);
        g_glFuncs.glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        out->rebind_pbo = (GLuint)pbo;
    } else if (pbo != 0) {
        g_glFuncs.glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER);
        g_glFuncs.glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        out->rebind_pbo = (GLuint)pbo;
    }
    if (row_length != 0) g_glFuncs.glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    if (skip_rows != 0) g_glFuncs.glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
    if (skip_pixels != 0) g_glFuncs.glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
    out->row_length = row_length;
    out->skip_rows = skip_rows;
    out->skip_pixels = skip_pixels;
    out->pixels = scratch.data();
    return true;
}

void sfpewFinishBgraUpload(const sfpew_bgra_upload_t& upload) {
    if (g_glFuncs.glPixelStorei != nullptr) {
        if (upload.row_length != 0) g_glFuncs.glPixelStorei(GL_UNPACK_ROW_LENGTH, upload.row_length);
        if (upload.skip_rows != 0) g_glFuncs.glPixelStorei(GL_UNPACK_SKIP_ROWS, upload.skip_rows);
        if (upload.skip_pixels != 0)
            g_glFuncs.glPixelStorei(GL_UNPACK_SKIP_PIXELS, upload.skip_pixels);
    }
    if (upload.rebind_pbo != 0 && g_glFuncs.glBindBuffer != nullptr)
        g_glFuncs.glBindBuffer(GL_PIXEL_UNPACK_BUFFER, upload.rebind_pbo);
}

namespace {

// The compiled form of glTexImage2D: its payload is tight by then, so the
// unpack state at glCallList - a bound unpack buffer above all, which would
// read the captured client pointer back as an offset - must not reach it.
void replayTexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei width,
                      GLsizei height, GLint border, GLenum format, GLenum type,
                      GLboolean swap_bytes, const GLvoid* pixels) {
    sfpew_list_unpack_replay_t unpack(swap_bytes != GL_FALSE, false);
    SELF_CALL(glTexImage2D, target, level, internalformat, width, height, border, format, type,
              pixels)
}

} // namespace

void glTexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border,
                  GLenum format, GLenum type, const GLvoid* pixels) {
    if (!sfpewEnsureBackend() || g_glFuncs.glTexImage2D == nullptr || g_glFuncs.glGetIntegerv == nullptr) return;
    // Restores unpack state and any unbound pixel buffer once the upload
    // below - whichever return path it takes - is done.
    struct bgra_upload_guard_t {
        sfpew_bgra_upload_t state{};
        bool active = false;
        ~bgra_upload_guard_t() {
            if (active) sfpewFinishBgraUpload(state);
        }
    } bgraUpload;
    struct imaging_upload_guard_t {
        sfpew_imaging_upload_t state{};
        bool active = false;
        ~imaging_upload_guard_t() {
            if (active) sfpewFinishImagingUpload(state);
        }
    } imagingUpload;
    (void)g_glstate; // entry strict resolve; the binding/proxy shadows read the snapshot
    sfpewEntryBarrier();
    // plans/17 P15. A proxy target records no payload: GL requires it to
    // ignore the pixels entirely, so an application is free to hand it a
    // pointer that must never be dereferenced.
    if (!disableRecording && DisplayListManager::shouldRecord()) {
        std::vector<uint8_t> payload;
        const bool captured =
            target == GL_PROXY_TEXTURE_2D ||
            sfpewCaptureListPixelUpload("glTexImage2D", width, height, format, type, pixels,
                                        &payload);
        if (captured) {
            displayListManager.record<replayTexImage2D>(
                {{9, payload.size()}}, target, level, internalformat, width, height, border,
                format, type,
                static_cast<GLboolean>(g_glstate.pixel_store_unpack_swap_bytes ? GL_TRUE
                                                                              : GL_FALSE),
                payload.empty() ? nullptr : static_cast<const GLvoid*>(payload.data()));
        }
        if (DisplayListManager::shouldFinish()) return;
    }
    if (target != GL_PROXY_TEXTURE_2D && sfpewImagingActive() &&
        (pixels != nullptr || sfpewUnpackPboBound())) {
        imagingUpload.active =
            sfpewPrepareImagingUpload(width, height, format, type, pixels, &imagingUpload.state);
        if (imagingUpload.active) {
            if (!imagingUpload.state.valid) return;
            format = GL_RGBA;
            type = GL_FLOAT;
            width = imagingUpload.state.width;
            height = imagingUpload.state.height;
            if (imagingUpload.state.sink) {
                pixels = nullptr;
            } else {
                pixels = imagingUpload.state.rgba.data();
            }
        }
    }
    if (target != GL_PROXY_TEXTURE_2D) {
        // Desktop GL takes GL_BGRA as-is; on GLES every BGRA source - client
        // memory or a pixel unpack buffer - is reordered into tight RGBA by
        // sfpewPrepareBgraUpload, which also neutralizes the unpack state the
        // tight result would be misread under. The guard restores both after
        // the backend call below.
        if (format == GL_BGRA && !sfpewBackendTakesBgra()) {
            if (pixels == nullptr && !sfpewUnpackPboBound()) {
                // Pure allocation: nothing to reorder.
                format = GL_RGBA;
                type = GL_UNSIGNED_BYTE;
                if (internalformat == GL_BGRA) internalformat = GL_RGBA8;
            } else if (sfpewPrepareBgraUpload(width, height, type, pixels, &bgraUpload.state)) {
                bgraUpload.active = true;
                pixels = bgraUpload.state.pixels;
                format = GL_RGBA;
                type = GL_UNSIGNED_BYTE;
                if (internalformat == GL_BGRA) internalformat = GL_RGBA8;
            } else {
                // Conversion genuinely impossible (exotic type, or a buffer
                // no mapping path can read). Pass it through in the ONE form
                // EXT_texture_format_BGRA8888 defines - internalformat and
                // format both GL_BGRA, type UNSIGNED_BYTE - so a backend
                // with that extension renders it correctly instead of
                // byte-copying BGRA bytes into RGBA storage. Without the
                // extension this errors, exactly like the raw passthrough
                // did.
                SFPEW_LOGW("glTexImage2D: GL_BGRA upload (type 0x%x) could not be converted; "
                           "passing through as EXT_texture_format_BGRA8888", type);
                internalformat = GL_BGRA;
            }
        }

        legacy_format_mapping_t mapping{};
        if (mapLegacyInternalFormat(internalformat, mapping)) {
            // PBO uploads keep their data GPU-side; format rewriting is safe
            // (no dereference) but the BGRA swap above already bailed out.
            // Rewrite the caller's legacy format pair too: GL_ALPHA/
            // GL_LUMINANCE* client data is single/dual channel and GLES3
            // only accepts it through RED/RG uploads.
            GLenum upload_format = format;
            if (format == GL_ALPHA || format == GL_LUMINANCE) upload_format = GL_RED;
            else if (format == GL_LUMINANCE_ALPHA) upload_format = GL_RG;
            g_glFuncs.glTexImage2D(target, level, mapping.internalformat, width, height, border,
                                   upload_format, type, pixels);
            const GLuint bound = sfpewLogicalTextureBinding(textureMetadataTarget(target));
            // defects-plan-2.md 2.7: glTexImage2D also uploads cube faces -
            // these fell out of texture_metadata_cache_t entirely before,
            // same gap as glGetTexImage's 3D/cube case (defects-plan.md 1.2).
            if (target == GL_TEXTURE_2D ||
                (target >= GL_TEXTURE_CUBE_MAP_POSITIVE_X && target <= GL_TEXTURE_CUBE_MAP_NEGATIVE_Z)) {
                rememberTextureLevel(bound, target, level, width, height, internalformat, border,
                                     false, 0);
            }
            if (g_glFuncs.glTexParameteriv != nullptr) {
                g_glFuncs.glTexParameteriv(swizzleTargetFor(target), GL_TEXTURE_SWIZZLE_RGBA, mapping.swizzle);
                rememberWrapperSwizzle(bound, target);
            }
            sfpewMaybeGenerateMipmap(target);
            return;
        }

        g_glFuncs.glTexImage2D(target, level, internalformat, width, height, border, format, type, pixels);
        if (target == GL_TEXTURE_2D ||
            (target >= GL_TEXTURE_CUBE_MAP_POSITIVE_X && target <= GL_TEXTURE_CUBE_MAP_NEGATIVE_Z)) {
            const GLuint bound = sfpewLogicalTextureBinding(textureMetadataTarget(target));
            rememberTextureLevel(bound, target, level, width, height, internalformat, border, false, 0);
            // GL_DEPTH_COMPONENT/16/24/32F pass straight through above (no
            // legacy-format rewrite exists for them); they still need the
            // GL_DEPTH_TEXTURE_MODE swizzle applied post-upload.
            if (level == 0 && isDepthTextureInternalFormat(internalformat))
                sfpewApplyDepthTextureModeSwizzle(target, bound);
            // plans/17 P17: this format needs no swizzle, but the object may
            // still carry one from the legacy internalformat (or depth mode)
            // it was defined with before - it would silently rewrite every
            // sample of the image just uploaded. Only a swizzle the wrapper
            // imposed is taken back; the app's own is its business.
            else if (level == 0 && g_glFuncs.glTexParameteriv != nullptr &&
                     takeWrapperSwizzle(bound, target)) {
                static const GLint identity[4] = {GL_RED, GL_GREEN, GL_BLUE, GL_ALPHA};
                g_glFuncs.glTexParameteriv(swizzleTargetFor(target), GL_TEXTURE_SWIZZLE_RGBA,
                                           identity);
            }
        }
        sfpewMaybeGenerateMipmap(target);
        return;
    }

    // Proxy textures only test whether an allocation would be accepted. Do not let a
    // backend inspect or copy the caller's pixels for a target that has no storage.
    g_glFuncs.glTexImage2D(target, level, internalformat, width, height, border, format, type, nullptr);

    if (level < 0) return;

    ProxyTexture2DLevel state;
    state.width = width;
    state.height = height;
    state.internalFormat = internalformat;
    state.border = border;

    GLint maxTextureSize = 0;
    g_glFuncs.glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTextureSize);
    GLint maxLevelSize = maxTextureSize;
    for (GLint currentLevel = 0; currentLevel < level && maxLevelSize > 0; ++currentLevel) {
        maxLevelSize >>= 1;
    }

    const bool dimensionsSupported = maxLevelSize > 0 && width >= 0 && height >= 0 && width <= maxLevelSize &&
                                     height <= maxLevelSize;
    const bool internalFormatSupported = isProxyTextureInternalFormat(internalformat);
    state.supported = border == 0 && dimensionsSupported && internalFormatSupported &&
                      isProxyTextureFormat(format) && isProxyTextureTypeCompatible(format, type);
    getProxyTexture2DLevels()[level] = state;
}

// defects-plan-2.md 2.7: glTexImage3D was entirely unwrapped before this -
// not in lookup.cpp's GETPROC table, so eglGetProcAddress("glTexImage3D")
// fell straight through to the real backend (both floors have it
// natively, ES 3.0 core and GL 3.2 core) with zero wrapper-side
// bookkeeping. Deliberately minimal, unlike glTexImage2D above: no BGRA
// conversion, no legacy-internal-format rewriting, no ARB_imaging hook -
// those exist for glTexImage2D because that is the path every legacy
// texture upload actually takes; a 3D upload choosing one of those same
// formats is a vanishingly rare combination not worth this function's
// complexity. Passes straight through and only adds the metadata
// glGetTexLevelParameteriv's ES fallback needs.
void glTexImage3D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height,
                  GLsizei depth, GLint border, GLenum format, GLenum type, const GLvoid* pixels) {
    if (!sfpewEnsureBackend() || g_glFuncs.glTexImage3D == nullptr) return;
    sfpewEntryBarrier();
    g_glFuncs.glTexImage3D(target, level, internalformat, width, height, depth, border, format, type,
                           pixels);
    if (target == GL_TEXTURE_3D) {
        rememberTextureLevel(sfpewLogicalTextureBinding(GL_TEXTURE_3D), target, level, width, height,
                             internalformat, border, false, 0, depth);
    }
}

void glGetTexImage(GLenum target, GLint level, GLenum format, GLenum type, GLvoid* pixels) {
    if (pixels == nullptr) return;
    if (!sfpewEnsureBackend() || g_glFuncs.glGenFramebuffers == nullptr ||
        g_glFuncs.glFramebufferTexture2D == nullptr || g_glFuncs.glReadPixels == nullptr) {
        return;
    }
    auto& gs = g_glstate;
    if (target == GL_TEXTURE_1D) target = GL_TEXTURE_2D; // Nx1 emulation

    // GL_TEXTURE_3D and the six cube faces: same "GLES has no texture
    // readback" ceiling as glGetCompressedTexImage - unlike the per-level
    // SIZE query (glGetTexLevelParameteriv), which texture_metadata_cache_t
    // now covers for these targets too (defects-plan-2.md 2.7), reading
    // pixel data back needs a GLES readback path that does not exist for
    // any target, not even 2D's own FBO+glReadPixels trick. Forward exactly
    // on desktop, where glGetTexImage handles every target and size
    // natively; refuse loudly on GLES rather than guessing a size or
    // reading the wrong slice.
    switch (target) {
    case GL_TEXTURE_3D:
    case GL_TEXTURE_CUBE_MAP_POSITIVE_X:
    case GL_TEXTURE_CUBE_MAP_NEGATIVE_X:
    case GL_TEXTURE_CUBE_MAP_POSITIVE_Y:
    case GL_TEXTURE_CUBE_MAP_NEGATIVE_Y:
    case GL_TEXTURE_CUBE_MAP_POSITIVE_Z:
    case GL_TEXTURE_CUBE_MAP_NEGATIVE_Z:
        if (!sfpewBackendIsES() && g_glFuncs.glGetTexImage != nullptr) {
            g_glFuncs.glGetTexImage(target, level, format, type, pixels);
            return;
        }
        gs.set_error(GL_INVALID_OPERATION);
        return;
    default:
        break;
    }

    if (target != GL_TEXTURE_2D) {
        SFPEW_LOGW("glGetTexImage: target 0x%x not supported", target);
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    const GLuint texture = sfpewLogicalTextureBinding(GL_TEXTURE_2D);
    const auto& texture_sizes = textureMetadata().sizes;
    const auto size_it = texture_sizes.find(texture);
    if (texture == 0 || size_it == texture_sizes.end()) {
        gs.set_error(GL_INVALID_OPERATION);
        return;
    }
    const GLsizei width = std::max<GLsizei>(size_it->second.width >> level, 1);
    const GLsizei height = std::max<GLsizei>(size_it->second.height >> level, 1);

    // Read through a scratch FBO; the wrapper glReadPixels handles BGRA.
    GLint prev_read = 0, prev_draw = 0;
    g_glFuncs.glGetIntegerv(0x8CAA /* GL_READ_FRAMEBUFFER_BINDING */, &prev_read);
    g_glFuncs.glGetIntegerv(0x8CA6 /* GL_DRAW_FRAMEBUFFER_BINDING */, &prev_draw);
    GLuint& scratch_fbo = textureScratch().read_fbo;
    if (scratch_fbo == 0) g_glFuncs.glGenFramebuffers(1, &scratch_fbo);
    g_glFuncs.glBindFramebuffer(0x8CA8 /* GL_READ_FRAMEBUFFER */, scratch_fbo);
    g_glFuncs.glFramebufferTexture2D(0x8CA8, 0x8CE0 /* GL_COLOR_ATTACHMENT0 */, GL_TEXTURE_2D,
                                     texture, level);
    glReadPixels(0, 0, width, height, format, type, pixels);
    g_glFuncs.glFramebufferTexture2D(0x8CA8, 0x8CE0, GL_TEXTURE_2D, 0, 0);
    g_glFuncs.glBindFramebuffer(0x8CA8, prev_read);
    g_glFuncs.glBindFramebuffer(0x8CA9 /* GL_DRAW_FRAMEBUFFER */, prev_draw);
}

void glGetTexLevelParameteriv(GLenum target, GLint level, GLenum pname, GLint* params) {
    if (params == nullptr) return;
    auto& gs = g_glstate;
    sfpewEntryBarrier();
    if (!sfpewEnsureBackend()) return;

    if (target == GL_PROXY_TEXTURE_1D) target = GL_PROXY_TEXTURE_2D;
    if (target == GL_PROXY_TEXTURE_2D) {
        GLint value = 0;
        if (getProxyTextureLevelParameter(level, pname, value)) {
            *params = value;
            return;
        }
        if (g_glFuncs.glGetTexLevelParameteriv != nullptr)
            g_glFuncs.glGetTexLevelParameteriv(target, level, pname, params);
        else
            gs.set_error(GL_INVALID_OPERATION);
        return;
    }

    if (target == GL_TEXTURE_1D) target = GL_TEXTURE_2D;
    if (!sfpewBackendIsES() && g_glFuncs.glGetTexLevelParameteriv != nullptr) {
        g_glFuncs.glGetTexLevelParameteriv(target, level, pname, params);
        return;
    }

    // ES 3.0 has no level query. The N x 1 texture paths, glTexImage3D, and
    // the six cube faces (defects-plan-2.md 2.7) record the properties
    // observable without retaining image bytes; unknown targets/levels are
    // refused instead of returning an invented value.
    const bool is_cube_face =
        target >= GL_TEXTURE_CUBE_MAP_POSITIVE_X && target <= GL_TEXTURE_CUBE_MAP_NEGATIVE_Z;
    if (target != GL_TEXTURE_2D && target != GL_TEXTURE_3D && !is_cube_face) {
        gs.set_error(GL_INVALID_OPERATION);
        return;
    }
    if (level < 0) {
        gs.set_error(GL_INVALID_VALUE);
        return;
    }
    const GLenum binding_point = textureMetadataTarget(target);
    const texture_level_t* info =
        findTextureLevel(sfpewLogicalTextureBinding(binding_point), target, level);
    if (info == nullptr) {
        gs.set_error(GL_INVALID_OPERATION);
        return;
    }
    switch (pname) {
    case GL_TEXTURE_WIDTH: *params = info->width; break;
    case GL_TEXTURE_HEIGHT: *params = info->height; break;
    case GL_TEXTURE_DEPTH: *params = info->depth; break;
    case GL_TEXTURE_INTERNAL_FORMAT: *params = info->internal_format; break;
    case GL_TEXTURE_BORDER: *params = info->border; break;
    case GL_TEXTURE_COMPRESSED: *params = info->compressed ? GL_TRUE : GL_FALSE; break;
    case GL_TEXTURE_COMPRESSED_IMAGE_SIZE:
        if (!info->compressed) {
            gs.set_error(GL_INVALID_OPERATION);
            return;
        }
        *params = info->compressed_size;
        break;
    default:
        gs.set_error(GL_INVALID_OPERATION);
        break;
    }
}

void glGetTexLevelParameterfv(GLenum target, GLint level, GLenum pname, GLfloat* params) {
    if (params == nullptr) return;
    GLint value = 0;
    glGetTexLevelParameteriv(target, level, pname, &value);
    *params = static_cast<GLfloat>(value);
}
