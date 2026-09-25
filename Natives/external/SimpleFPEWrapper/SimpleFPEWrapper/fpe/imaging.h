// SimpleFPEWrapper - SimpleFPEWrapper/fpe/imaging.h
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#pragma once

#include "types.h"

// Runs the enabled GL_ARB_imaging stages over a tightly packed RGBA float
// image. Convolution may reduce the dimensions. False means every stage was
// disabled and the caller's existing fast path can remain untouched.
bool sfpewImagingTransfer(GLfloat* rgba, GLsizei* width, GLsizei* height);
bool sfpewImagingActive();
bool sfpewImagingSink();
bool sfpewImagingDecodePixels(GLsizei width, GLsizei height, GLenum format, GLenum type,
                              const GLvoid* pixels, std::vector<GLfloat>* rgba,
                              GLsizei* output_width, GLsizei* output_height);
bool sfpewImagingReadRgba(GLint x, GLint y, GLsizei width, GLsizei height,
                          std::vector<GLfloat>* rgba, GLsizei* output_width,
                          GLsizei* output_height);
bool sfpewImagingReadPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format,
                            GLenum type, GLvoid* pixels);

// defects-plan-3.md: GL 2.1's basic (non-ARB_imaging) pixel transfer -
// GL_*_SCALE/GL_*_BIAS and GL_MAP_COLOR/GL_MAP_STENCIL's pixel maps -
// applied to the READ direction (glReadPixels, glCopyPixels), which had
// none of it: sfpewImagingReadRgba/ReadPixels above only ever ran the
// ARB_imaging-specific stages, gated on ARB_imaging state alone, so an app
// that set GL_RED_SCALE without ever touching a color table/convolution/
// histogram got it silently ignored on readback (the write direction,
// glDrawPixels, already applies this same transfer unconditionally - see
// its own decode loop in pixelops.cpp). Color reuses this file's existing
// encode/decode/readFramebuffer machinery with the basic step spliced in
// first, spec order (3.6.3); depth and stencil (glCopyPixels only, in
// pixelops.cpp - GL_MAP_STENCIL is not a color-table concept this file
// otherwise deals with) are separate, since GLES/desktop have no shared
// "arbitrary pixel format" encoder for those the way color tables do.
// Each *Active() check lets a caller's existing fast (real backend call,
// or blit) path stay exactly as it was in the overwhelmingly common case
// where the corresponding transfer is at its default (no-op) values -
// only a caller that actually set a non-default scale/bias/map pays for
// the CPU round trip.
bool sfpewBasicColorTransferActive();
// Exposed alongside sfpewFullColorReadPixels below (not just kept file-
// local like sfpewImagingReadRgba's own analogous helper) because
// glCopyPixels(GL_COLOR) in pixelops.cpp needs the raw transferred RGBA
// float buffer itself, to feed into its own quad-drawer - not a buffer
// already encoded into a caller's requested pixel format/type.
//
// `force`: read (and apply the - possibly no-op - transfer) even when
// neither transfer stage is active. glCopyPixels needs this when source
// and destination are the same framebuffer: GLES's glBlitFramebuffer
// spec requires "GL_INVALID_OPERATION is generated if the source and
// destination buffers are identical" (no desktop-GL equivalent, and no
// overlap exemption - a same-buffer copy is illegal on GLES regardless
// of whether the two rectangles overlap), so the CPU round trip this
// function already does for an active transfer is reused here purely for
// its side effect of never touching glBlitFramebuffer, not because a
// transfer is actually needed.
bool sfpewFullColorReadRgba(GLint x, GLint y, GLsizei width, GLsizei height,
                            std::vector<GLfloat>* rgba, GLsizei* output_width,
                            GLsizei* output_height, bool force = false);
// `force` has the same meaning here, for glReadPixels' second reason to want
// the CPU round trip with no transfer active (plans/17 P1): a format/type
// pair the backend would reject outright has no other encoder.
bool sfpewFullColorReadPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format,
                              GLenum type, GLvoid* pixels, bool force = false);
bool sfpewDepthPixelTransferActive();
bool sfpewDepthPixelTransferReadPixels(GLint x, GLint y, GLsizei width, GLsizei height,
                                       GLenum format, GLenum type, GLvoid* pixels);
// Depth read + GL_DEPTH_SCALE/BIAS + clamp, as a tightly packed float
// buffer - the piece glCopyPixels(GL_DEPTH) needs to feed into the
// existing depth quad-drawer instead of a raw blit. False means the
// backend/allocation failed (GL error already set); true always resizes
// `out` to width*height on success.
bool sfpewReadTransformedDepth(GLint x, GLint y, GLsizei width, GLsizei height,
                               std::vector<GLfloat>* out);

struct sfpew_imaging_upload_t {
    std::vector<GLfloat> rgba;
    GLsizei width = 0, height = 0;
    GLint alignment = 4, row_length = 0, skip_rows = 0, skip_pixels = 0, unpack_pbo = 0;
    bool unpack_swap_bytes = false;
    bool valid = false;
    bool sink = false;
    bool neutralized = false;
};

bool sfpewPrepareImagingUpload(GLsizei width, GLsizei height, GLenum format, GLenum type,
                               const GLvoid* pixels, sfpew_imaging_upload_t* upload);
bool sfpewBeginTightImagingUpload(sfpew_imaging_upload_t* upload);
void sfpewFinishImagingUpload(const sfpew_imaging_upload_t& upload);
void sfpewPushImagingBypass();
void sfpewPopImagingBypass();

#ifdef __cplusplus
extern "C" {
#endif

void glColorTable(GLenum target, GLenum internalformat, GLsizei width, GLenum format,
                  GLenum type, const GLvoid* table);
void glColorSubTable(GLenum target, GLsizei start, GLsizei count, GLenum format,
                     GLenum type, const GLvoid* data);
void glColorTableParameterfv(GLenum target, GLenum pname, const GLfloat* params);
void glColorTableParameteriv(GLenum target, GLenum pname, const GLint* params);
void glCopyColorTable(GLenum target, GLenum internalformat, GLint x, GLint y, GLsizei width);
void glCopyColorSubTable(GLenum target, GLsizei start, GLint x, GLint y, GLsizei width);
void glGetColorTable(GLenum target, GLenum format, GLenum type, GLvoid* table);
void glGetColorTableParameterfv(GLenum target, GLenum pname, GLfloat* params);
void glGetColorTableParameteriv(GLenum target, GLenum pname, GLint* params);

void glConvolutionFilter1D(GLenum target, GLenum internalformat, GLsizei width, GLenum format,
                           GLenum type, const GLvoid* image);
void glConvolutionFilter2D(GLenum target, GLenum internalformat, GLsizei width, GLsizei height,
                           GLenum format, GLenum type, const GLvoid* image);
void glConvolutionParameterf(GLenum target, GLenum pname, GLfloat param);
void glConvolutionParameterfv(GLenum target, GLenum pname, const GLfloat* params);
void glConvolutionParameteri(GLenum target, GLenum pname, GLint param);
void glConvolutionParameteriv(GLenum target, GLenum pname, const GLint* params);
void glCopyConvolutionFilter1D(GLenum target, GLenum internalformat, GLint x, GLint y,
                               GLsizei width);
void glCopyConvolutionFilter2D(GLenum target, GLenum internalformat, GLint x, GLint y,
                               GLsizei width, GLsizei height);
void glGetConvolutionFilter(GLenum target, GLenum format, GLenum type, GLvoid* image);
void glGetConvolutionParameterfv(GLenum target, GLenum pname, GLfloat* params);
void glGetConvolutionParameteriv(GLenum target, GLenum pname, GLint* params);
void glSeparableFilter2D(GLenum target, GLenum internalformat, GLsizei width, GLsizei height,
                         GLenum format, GLenum type, const GLvoid* row, const GLvoid* column);
void glGetSeparableFilter(GLenum target, GLenum format, GLenum type, GLvoid* row,
                          GLvoid* column, GLvoid* span);

void glHistogram(GLenum target, GLsizei width, GLenum internalformat, GLboolean sink);
void glGetHistogram(GLenum target, GLboolean reset, GLenum format, GLenum type, GLvoid* values);
void glGetHistogramParameterfv(GLenum target, GLenum pname, GLfloat* params);
void glGetHistogramParameteriv(GLenum target, GLenum pname, GLint* params);
void glResetHistogram(GLenum target);

void glMinmax(GLenum target, GLenum internalformat, GLboolean sink);
void glGetMinmax(GLenum target, GLboolean reset, GLenum format, GLenum type, GLvoid* values);
void glGetMinmaxParameterfv(GLenum target, GLenum pname, GLfloat* params);
void glGetMinmaxParameteriv(GLenum target, GLenum pname, GLint* params);
void glResetMinmax(GLenum target);

#ifdef __cplusplus
}
#endif
