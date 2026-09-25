// SimpleFPEWrapper - SimpleFPEWrapper/fbo.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

// Desktop framebuffer/renderbuffer/buffer entry points that need more
// than a name alias on a GLES backend (lookup.cpp maps the EXT/ARB
// spellings here or straight onto the backend table):
//  - glRenderbufferStorage: desktop code passes unsized or desktop-only
//    internalformats; ES 3.0 requires sized ones.
//  - glFramebufferTexture1D/3D: 1D textures live as 2D height-1 in this
//    wrapper; 3D attachment maps onto glFramebufferTextureLayer.
//  - glMapBuffer/glGetBufferSubData: ES 3.0 only has glMapBufferRange.

#include "GL/gl.h"
#include "init.h"
#include "log.h"
#include "fpe/drawing1x.h"
#include "fpe/fpe.hpp"

#include <cstring>

namespace {

GLenum mapRenderbufferInternalFormat(GLenum internalformat) {
    switch (internalformat) {
    case GL_DEPTH_COMPONENT:
        return GL_DEPTH_COMPONENT24;
    case 0x81A7 /* GL_DEPTH_COMPONENT32 */:
        return 0x8CAC /* GL_DEPTH_COMPONENT32F */;
    case 0x84F9 /* GL_DEPTH_STENCIL */:
        return 0x88F0 /* GL_DEPTH24_STENCIL8 */;
    case GL_STENCIL_INDEX:
        return 0x8D48 /* GL_STENCIL_INDEX8 */;
    case GL_RGB:
        return GL_RGB8;
    case GL_RGBA:
    case 2:
    case 4:
        return GL_RGBA8;
    case GL_RGBA12:
    case GL_RGBA16:
        // No unorm16 renderbuffers in core ES 3.0; 8 bits per channel is
        // the closest portable storage.
        return GL_RGBA8;
    case GL_RGB10:
    case GL_RGB12:
    case GL_RGB16:
        return GL_RGB8;
    default:
        return internalformat; // sized formats pass through
    }
}

} // namespace

void glRenderbufferStorage(GLenum target, GLenum internalformat, GLsizei width, GLsizei height) {
    if (!sfpewEnsureBackend() || g_glFuncs.glRenderbufferStorage == nullptr) return;
    g_glFuncs.glRenderbufferStorage(target, mapRenderbufferInternalFormat(internalformat), width,
                                    height);
}

void glRenderbufferStorageMultisample(GLenum target, GLsizei samples, GLenum internalformat,
                                      GLsizei width, GLsizei height) {
    if (!sfpewEnsureBackend() || g_glFuncs.glRenderbufferStorageMultisample == nullptr) return;
    g_glFuncs.glRenderbufferStorageMultisample(
        target, samples, mapRenderbufferInternalFormat(internalformat), width, height);
}

void glFramebufferTexture1D(GLenum target, GLenum attachment, GLenum textarget, GLuint texture,
                            GLint level) {
    if (!sfpewEnsureBackend() || g_glFuncs.glFramebufferTexture2D == nullptr) return;
    // 1D textures are stored as 2D height-1 textures by glTexImage1D.
    (void)textarget;
    g_glFuncs.glFramebufferTexture2D(target, attachment, GL_TEXTURE_2D, texture, level);
}

void glFramebufferTexture3D(GLenum target, GLenum attachment, GLenum textarget, GLuint texture,
                            GLint level, GLint zoffset) {
    if (!sfpewEnsureBackend() || g_glFuncs.glFramebufferTextureLayer == nullptr) return;
    (void)textarget;
    g_glFuncs.glFramebufferTextureLayer(target, attachment, texture, level, zoffset);
}

// Both of these act through the CURRENTLY BOUND buffer, so they owe the entry
// barrier the rest of the buffer surface takes (the contract note above
// glBufferData in fpe/vertexpointer.cpp). Without it, everything after any
// fixed-function draw addresses the wrapper's immediate ring instead of the
// app's buffer, the deferred draw-state restore still being held: the size
// query answers for the ring, and the map either fails outright (the ring is
// already persistently mapped) or hands the app a pointer into wrapper memory.
void* glMapBuffer(GLenum target, GLenum access) {
    if (!sfpewEnsureBackend() || g_glFuncs.glMapBufferRange == nullptr ||
        g_glFuncs.glGetBufferParameteriv == nullptr) {
        return nullptr;
    }
    (void)g_glstate; // entry strict resolve
    sfpewEntryBarrier();
    GLint size = 0;
    g_glFuncs.glGetBufferParameteriv(target, 0x8764 /* GL_BUFFER_SIZE */, &size);
    if (size <= 0) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return nullptr;
    }
    GLbitfield bits = 0;
    switch (access) {
    case 0x88B8 /* GL_READ_ONLY */:
        bits = 0x0001 /* GL_MAP_READ_BIT */;
        break;
    case 0x88B9 /* GL_WRITE_ONLY */:
        bits = 0x0002 /* GL_MAP_WRITE_BIT */;
        break;
    case 0x88BA /* GL_READ_WRITE */:
        bits = 0x0003;
        break;
    default:
        g_glstate.set_error(GL_INVALID_ENUM);
        return nullptr;
    }
    return g_glFuncs.glMapBufferRange(target, 0, size, bits);
}

void glGetBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, void* data) {
    if (data == nullptr || size <= 0) return;
    if (!sfpewEnsureBackend() || g_glFuncs.glMapBufferRange == nullptr ||
        g_glFuncs.glUnmapBuffer == nullptr) {
        return;
    }
    (void)g_glstate; // entry strict resolve
    sfpewEntryBarrier();
    void* mapped = g_glFuncs.glMapBufferRange(target, offset, size, 0x0001 /* GL_MAP_READ_BIT */);
    if (mapped == nullptr) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return;
    }
    std::memcpy(data, mapped, (size_t)size);
    g_glFuncs.glUnmapBuffer(target);
}
