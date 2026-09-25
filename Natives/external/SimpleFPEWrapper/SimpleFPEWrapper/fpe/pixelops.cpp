// SimpleFPEWrapper - SimpleFPEWrapper/fpe/pixelops.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

// CPU pixel paths (plans/08, 8.2/8.4): glBitmap, glDrawPixels and
// glCopyPixels on a shared screen-aligned quad drawer. The drawer owns a
// tiny dedicated program (outside the FPE program cache), an empty VAO
// (corners derive from gl_VertexID) and one scratch texture; current
// blend/depth/scissor state applies to the emitted quad exactly as the
// spec asks.

#include "fpe.hpp"
#include "list.h"
#include "drawing1x.h"
#include "imaging.h"
#include "../log.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <new>
#include <type_traits>
#include <vector>

namespace {

constexpr char kQuadVS[] = "#version 300 es\n"
                           "precision highp float;\n"
                           "uniform vec4 uRect;  // NDC x0,y0,x1,y1\n"
                           "uniform float uDepth; // NDC z\n"
                           "out vec2 vUV;\n"
                           "void main() {\n"
                           "    vec2 corner = vec2(float(gl_VertexID & 1), float((gl_VertexID >> 1) & 1));\n"
                           "    vUV = corner;\n"
                           "    gl_Position = vec4(mix(uRect.xy, uRect.zw, corner), uDepth, 1.0);\n"
                           "}\n";

constexpr char kQuadFS[] = "#version 300 es\n"
                           "precision highp float;\n"
                           "uniform sampler2D uTex;\n"
                           "uniform vec4 uColor; // bitmap ink\n"
                           "uniform int uMode;   // 0 = color, 1 = bitmap, 2 = depth, 3 = stencil bit-plane\n"
                           // defects-plan-2.md 2.5: which bit of the 8-bit
                           // stencil index (uTex.r, an exact GL_R8 round trip
                           // for every 0-255 value) this pass paints, and
                           // whether it paints where that bit is 1 or 0 - see
                           // drawStencilBitplanes, which runs 16 passes (two
                           // per bit) so every fragment's stencil ends up
                           // exactly right regardless of what was there
                           // before, with no pre-clear needed.
                           "uniform int uBitIndex;\n"
                           "uniform int uWantBit;\n"
                           "in vec2 vUV;\n"
                           "out vec4 FragColor;\n"
                           "void main() {\n"
                           // gl_FragDepth is written on every path, not only
                           // inside the uMode==2 branch below: some drivers
                           // treat a conditionally-written gl_FragDepth as
                           // though it were never written for that draw call
                           // at all (silently keeping the rasterizer's own
                           // interpolated depth instead), even though uMode
                           // is a uniform and every fragment of a given draw
                           // takes the same branch. Defaulting it here first
                           // to the ordinary interpolated depth keeps the
                           // color/bitmap paths exactly as before.
                           "    gl_FragDepth = gl_FragCoord.z;\n"
                           "    vec4 texel = texture(uTex, vUV);\n"
                           "    if (uMode == 1) {\n"
                           "        if (texel.r < 0.5) discard;\n"
                           "        FragColor = uColor;\n"
                           "    } else if (uMode == 2) {\n"
                           "        gl_FragDepth = clamp(texel.r, 0.0, 1.0);\n"
                           "        FragColor = vec4(0.0);\n"
                           "    } else if (uMode == 3) {\n"
                           "        uint stencilByte = uint(texel.r * 255.0 + 0.5);\n"
                           "        int bit = int((stencilByte >> uint(uBitIndex)) & 1u);\n"
                           "        if (bit != uWantBit) discard;\n"
                           "        FragColor = vec4(0.0);\n"
                           "    } else {\n"
                           "        FragColor = texel * uColor;\n"
                           "    }\n"
                           "}\n";

enum class quad_mode_t : GLint { color = 0, bitmap = 1, depth = 2, stencil = 3 };

struct quad_drawer_t {
    GLuint program = 0;
    GLuint vao = 0;
    GLuint texture = 0;
    GLint loc_rect = -1, loc_depth = -1, loc_color = -1, loc_mode = -1, loc_tex = -1;
    GLint loc_bit_index = -1, loc_want_bit = -1;
    bool init_failed = false;
};

quad_drawer_t& drawer() {
    // Per-context: GL object names are context-scoped.
    static thread_local struct {
        EGLContext context = EGL_NO_CONTEXT;
        quad_drawer_t d{};
    } cache;
    const EGLContext current =
        sfpewCurrentContext();
    if (cache.context != current) {
        cache.context = current;
        cache.d = {};
    }
    return cache.d;
}

GLuint compileStage(GLenum type, const char* src) {
    const GLuint shader = g_glFuncs.glCreateShader(type);
    if (shader == 0) return 0;
    g_glFuncs.glShaderSource(shader, 1, &src, nullptr);
    g_glFuncs.glCompileShader(shader);
    GLint ok = GL_FALSE;
    g_glFuncs.glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (ok != GL_TRUE) {
        char info[512] = {};
        if (g_glFuncs.glGetShaderInfoLog != nullptr)
            g_glFuncs.glGetShaderInfoLog(shader, sizeof(info), nullptr, info);
        SFPEW_LOGE("pixel-path quad shader failed: %s", info);
        g_glFuncs.glDeleteShader(shader);
        return 0;
    }
    return shader;
}

bool ensureDrawer(quad_drawer_t& d) {
    if (d.program != 0) return true;
    if (d.init_failed) return false;
    if (g_glFuncs.glCreateShader == nullptr || g_glFuncs.glCreateProgram == nullptr ||
        g_glFuncs.glGenVertexArrays == nullptr || g_glFuncs.glGenTextures == nullptr) {
        d.init_failed = true;
        return false;
    }

    const GLuint vs = compileStage(GL_VERTEX_SHADER, kQuadVS);
    const GLuint fs = compileStage(GL_FRAGMENT_SHADER, kQuadFS);
    if (vs == 0 || fs == 0) {
        if (vs != 0) g_glFuncs.glDeleteShader(vs);
        if (fs != 0) g_glFuncs.glDeleteShader(fs);
        d.init_failed = true;
        return false;
    }
    const GLuint program = g_glFuncs.glCreateProgram();
    if (program != 0) g_glstate_c.internal_programs.insert((int)program);
    g_glFuncs.glAttachShader(program, vs);
    g_glFuncs.glAttachShader(program, fs);
    g_glFuncs.glLinkProgram(program);
    g_glFuncs.glDeleteShader(vs);
    g_glFuncs.glDeleteShader(fs);
    GLint linked = GL_FALSE;
    g_glFuncs.glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (linked != GL_TRUE) {
        SFPEW_LOGE("pixel-path quad program failed to link");
        g_glFuncs.glDeleteProgram(program);
        d.init_failed = true;
        return false;
    }
    d.program = program;
    d.loc_rect = g_glFuncs.glGetUniformLocation(program, "uRect");
    d.loc_depth = g_glFuncs.glGetUniformLocation(program, "uDepth");
    d.loc_color = g_glFuncs.glGetUniformLocation(program, "uColor");
    d.loc_mode = g_glFuncs.glGetUniformLocation(program, "uMode");
    d.loc_tex = g_glFuncs.glGetUniformLocation(program, "uTex");
    d.loc_bit_index = g_glFuncs.glGetUniformLocation(program, "uBitIndex");
    d.loc_want_bit = g_glFuncs.glGetUniformLocation(program, "uWantBit");
    g_glFuncs.glGenVertexArrays(1, &d.vao);
    g_glFuncs.glGenTextures(1, &d.texture);
    return d.vao != 0 && d.texture != 0;
}

// Every buffer these paths upload is one they built themselves: tightly
// packed, in client memory. The caller's unpack layout describes THEIR image,
// not this one - left in place it makes the driver stride past the end of a
// private buffer, and a bound GL_PIXEL_UNPACK_BUFFER turns that buffer's
// address into an offset into the buffer object, so the upload fails
// outright. Neutralized for the length of the upload and restored on every
// path out. GL_UNPACK_SWAP_BYTES/LSB_FIRST need no handling: glPixelStorei
// keeps those two wrapper-side and never forwards them to the backend
// (ordered_passthrough.cpp).
struct private_unpack_guard_t {
    GLint alignment = 4, row_length = 0, skip_rows = 0, skip_pixels = 0;
    GLint image_height = 0, skip_images = 0, pbo = 0;
    bool active = false;

    private_unpack_guard_t() {
        if (g_glFuncs.glGetIntegerv == nullptr || g_glFuncs.glPixelStorei == nullptr) return;
        active = true;
        g_glFuncs.glGetIntegerv(GL_UNPACK_ALIGNMENT, &alignment);
        g_glFuncs.glGetIntegerv(GL_UNPACK_ROW_LENGTH, &row_length);
        g_glFuncs.glGetIntegerv(GL_UNPACK_SKIP_ROWS, &skip_rows);
        g_glFuncs.glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &skip_pixels);
        g_glFuncs.glGetIntegerv(GL_UNPACK_IMAGE_HEIGHT, &image_height);
        g_glFuncs.glGetIntegerv(GL_UNPACK_SKIP_IMAGES, &skip_images);
        if (g_glFuncs.glBindBuffer != nullptr) {
            g_glFuncs.glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pbo);
            if (pbo != 0) g_glFuncs.glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        }
        g_glFuncs.glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        g_glFuncs.glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
        g_glFuncs.glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
        g_glFuncs.glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
        g_glFuncs.glPixelStorei(GL_UNPACK_IMAGE_HEIGHT, 0);
        g_glFuncs.glPixelStorei(GL_UNPACK_SKIP_IMAGES, 0);
    }

    ~private_unpack_guard_t() {
        if (!active) return;
        g_glFuncs.glPixelStorei(GL_UNPACK_ALIGNMENT, alignment);
        g_glFuncs.glPixelStorei(GL_UNPACK_ROW_LENGTH, row_length);
        g_glFuncs.glPixelStorei(GL_UNPACK_SKIP_ROWS, skip_rows);
        g_glFuncs.glPixelStorei(GL_UNPACK_SKIP_PIXELS, skip_pixels);
        g_glFuncs.glPixelStorei(GL_UNPACK_IMAGE_HEIGHT, image_height);
        g_glFuncs.glPixelStorei(GL_UNPACK_SKIP_IMAGES, skip_images);
        if (pbo != 0) g_glFuncs.glBindBuffer(GL_PIXEL_UNPACK_BUFFER, static_cast<GLuint>(pbo));
    }

    private_unpack_guard_t(const private_unpack_guard_t&) = delete;
    private_unpack_guard_t& operator=(const private_unpack_guard_t&) = delete;
};

// glDrawPixels/glCopyPixels produce fragments directly from the pixel
// rectangle; culling applies to facets (glCullFace: "triangles,
// quadrilaterals, polygons, and rectangles" - the primitives, not a pixel
// rectangle), so it must have no say over whether one appears. The
// screen-aligned quad standing in for it does have a winding - one that flips
// with the sign of a glPixelZoom factor - so culling is turned off for the
// draw instead of the winding being normalized by sign: normalizing only
// answers glFrontFace, and would still leave the rectangle culled under
// glCullFace(GL_FRONT_AND_BACK).
struct no_cull_guard_t {
    bool restore = false;

    no_cull_guard_t() {
        if (g_glFuncs.glIsEnabled == nullptr || g_glFuncs.glEnable == nullptr ||
            g_glFuncs.glDisable == nullptr || g_glFuncs.glIsEnabled(GL_CULL_FACE) == GL_FALSE) {
            return;
        }
        restore = true;
        g_glFuncs.glDisable(GL_CULL_FACE);
    }

    ~no_cull_guard_t() {
        if (restore) g_glFuncs.glEnable(GL_CULL_FACE);
    }

    no_cull_guard_t(const no_cull_guard_t&) = delete;
    no_cull_guard_t& operator=(const no_cull_guard_t&) = delete;
};

// Draws `pixels` (tightly packed) as a screen-aligned quad anchored at
// window coords (x0,y0) spanning (wpx,hpx) window pixels; bitmap mode
// discards zero texels and paints with `color`.
void drawQuad(const void* pixels, GLsizei tex_w, GLsizei tex_h, GLenum tex_format,
              GLenum tex_type, GLfloat x0, GLfloat y0, GLfloat wpx, GLfloat hpx,
              GLfloat depth, quad_mode_t mode, const glm::vec4& color) {
    auto& d = drawer();
    if (!ensureDrawer(d)) return;

    fpe_backend_draw_state_guard_t backend_state;

    GLint viewport[4] = {0, 0, 1, 1};
    g_glFuncs.glGetIntegerv(GL_VIEWPORT, viewport);
    if (viewport[2] <= 0 || viewport[3] <= 0) return;

    // Preserve unit-0 texture binding through the wrapper entry points so
    // the logical shadows stay coherent.
    const GLenum caller_active = sfpewLogicalActiveTexture();
    glActiveTexture(GL_TEXTURE0);
    const GLuint unit_zero_binding = sfpewLogicalTextureBinding(GL_TEXTURE_2D);
    g_glFuncs.glBindTexture(GL_TEXTURE_2D, d.texture);

    {
        private_unpack_guard_t unpack;
        const GLint internal_format = tex_format == GL_RED
                                          ? (tex_type == GL_FLOAT ? GL_R32F : GL_R8)
                                          : (tex_type == GL_FLOAT ? GL_RGBA32F : GL_RGBA8);
        g_glFuncs.glTexImage2D(GL_TEXTURE_2D, 0, internal_format, tex_w, tex_h, 0, tex_format,
                               tex_type, pixels);
        g_glFuncs.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        g_glFuncs.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    }

    const auto to_ndc_x = [&](GLfloat wx) { return (wx - viewport[0]) / viewport[2] * 2.0f - 1.0f; };
    const auto to_ndc_y = [&](GLfloat wy) { return (wy - viewport[1]) / viewport[3] * 2.0f - 1.0f; };

    sfpewInvalidateImmediateDrawState();
    g_glFuncs.glUseProgram(d.program);
    sfpewBackendBindVertexArray(d.vao);
    g_glFuncs.glUniform4f(d.loc_rect, to_ndc_x(x0), to_ndc_y(y0), to_ndc_x(x0 + wpx), to_ndc_y(y0 + hpx));
    g_glFuncs.glUniform1f(d.loc_depth, depth * 2.0f - 1.0f);
    g_glFuncs.glUniform4f(d.loc_color, color.r, color.g, color.b, color.a);
    g_glFuncs.glUniform1i(d.loc_mode, static_cast<GLint>(mode));
    g_glFuncs.glUniform1i(d.loc_tex, 0);

    no_cull_guard_t no_cull;
    const auto& caller_mask = g_glstate_c.fpe_state.color_buffer.color_mask;
    // A fragment's gl_FragDepth write only reaches the depth buffer while
    // depth testing is enabled - with GL_DEPTH_TEST off (the GL default),
    // the write is silently dropped and this quad draws nothing observable.
    // GL_ALWAYS makes every fragment pass regardless of what was already in
    // the buffer, so this is purely a depth WRITE, not a depth-tested draw;
    // the caller's own test state is restored immediately after.
    GLboolean caller_depth_test = GL_FALSE;
    GLint caller_depth_func = GL_LESS;
    if (mode == quad_mode_t::depth) {
        if (g_glFuncs.glIsEnabled != nullptr)
            caller_depth_test = g_glFuncs.glIsEnabled(GL_DEPTH_TEST);
        if (g_glFuncs.glGetIntegerv != nullptr)
            g_glFuncs.glGetIntegerv(GL_DEPTH_FUNC, &caller_depth_func);
        if (g_glFuncs.glEnable != nullptr) g_glFuncs.glEnable(GL_DEPTH_TEST);
        if (g_glFuncs.glDepthFunc != nullptr) g_glFuncs.glDepthFunc(GL_ALWAYS);
        if (g_glFuncs.glColorMask != nullptr)
            g_glFuncs.glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
    }
    g_glFuncs.glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    if (mode == quad_mode_t::depth) {
        if (g_glFuncs.glColorMask != nullptr)
            g_glFuncs.glColorMask(caller_mask[0], caller_mask[1], caller_mask[2], caller_mask[3]);
        if (g_glFuncs.glDepthFunc != nullptr)
            g_glFuncs.glDepthFunc(static_cast<GLenum>(caller_depth_func));
        if (caller_depth_test == GL_FALSE && g_glFuncs.glDisable != nullptr)
            g_glFuncs.glDisable(GL_DEPTH_TEST);
    }

    // Restore unit-0 binding and the caller's active unit.
    g_glFuncs.glBindTexture(GL_TEXTURE_2D, unit_zero_binding);
    glActiveTexture(caller_active);
}

// defects-plan-2.md 2.5: glDrawPixels(GL_STENCIL_INDEX, ...). No portable
// way exists to write a per-fragment-VARYING stencil value in one pass on
// either backend floor - the fixed-function stencil test's REPLACE always
// writes the single glStencilFunc `ref` for every fragment that passes in
// a draw call, not something a fragment shader can vary per pixel (no
// stencil-export extension is assumed here). So this runs 16 passes: for
// each of the 8 bits, one pass paints (REPLACEs, through a 1-bit
// glStencilMask) that bit to 1 wherever the source byte has it set, and a
// second paints it to 0 wherever the source has it clear - together every
// fragment's bit ends up exactly right regardless of what the stencil
// buffer held before, with no pre-clear of the destination region needed.
// A dedicated function, not 16 calls into drawQuad above: drawQuad's own
// per-call overhead (texture re-upload, unpack-state save/restore) would
// otherwise repeat 16 times for what is genuinely one upload.
//
// Matches drawQuad's depth-mode precedent for how much of the caller's own
// fragment-test state to honor: none. Depth mode forces GL_ALWAYS instead
// of composing with the caller's depth func; this forces GL_STENCIL_TEST
// enabled with GL_ALWAYS and its own glStencilOp instead of composing with
// the caller's stencil func/ops, for the same reason - an unconditional
// "write these values into this rectangle," not a tested draw. If the
// current framebuffer has no stencil attachment at all, glStencilMask's
// bits and the REPLACE writes simply land nowhere, matching how a
// color-only default framebuffer already treats a depth write it has no
// buffer for - no explicit presence check needed.
void drawStencilBitplanes(const GLubyte* stencil_bytes, GLsizei tex_w, GLsizei tex_h, GLfloat x0,
                          GLfloat y0, GLfloat wpx, GLfloat hpx, GLfloat depth) {
    auto& d = drawer();
    if (!ensureDrawer(d)) return;
    if (g_glFuncs.glStencilFunc == nullptr || g_glFuncs.glStencilOp == nullptr ||
        g_glFuncs.glStencilMask == nullptr || g_glFuncs.glEnable == nullptr ||
        g_glFuncs.glIsEnabled == nullptr || g_glFuncs.glGetIntegerv == nullptr) {
        return;
    }

    fpe_backend_draw_state_guard_t backend_state;

    GLint viewport[4] = {0, 0, 1, 1};
    g_glFuncs.glGetIntegerv(GL_VIEWPORT, viewport);
    if (viewport[2] <= 0 || viewport[3] <= 0) return;

    const GLenum caller_active = sfpewLogicalActiveTexture();
    glActiveTexture(GL_TEXTURE0);
    const GLuint unit_zero_binding = sfpewLogicalTextureBinding(GL_TEXTURE_2D);
    g_glFuncs.glBindTexture(GL_TEXTURE_2D, d.texture);

    // stencil_bytes is this function's own tightly packed buffer (built by
    // glDrawPixels below, not the caller's raw pointer), so the caller's whole
    // unpack layout has to stand aside for it - see private_unpack_guard_t.
    {
        private_unpack_guard_t unpack;
        g_glFuncs.glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, tex_w, tex_h, 0, GL_RED, GL_UNSIGNED_BYTE,
                               stencil_bytes);
        g_glFuncs.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        g_glFuncs.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    }

    const auto to_ndc_x = [&](GLfloat wx) { return (wx - viewport[0]) / viewport[2] * 2.0f - 1.0f; };
    const auto to_ndc_y = [&](GLfloat wy) { return (wy - viewport[1]) / viewport[3] * 2.0f - 1.0f; };

    sfpewInvalidateImmediateDrawState();
    g_glFuncs.glUseProgram(d.program);
    sfpewBackendBindVertexArray(d.vao);
    g_glFuncs.glUniform4f(d.loc_rect, to_ndc_x(x0), to_ndc_y(y0), to_ndc_x(x0 + wpx), to_ndc_y(y0 + hpx));
    g_glFuncs.glUniform1f(d.loc_depth, depth * 2.0f - 1.0f);
    g_glFuncs.glUniform1i(d.loc_mode, static_cast<GLint>(quad_mode_t::stencil));
    g_glFuncs.glUniform1i(d.loc_tex, 0);

    const GLboolean caller_stencil_test = g_glFuncs.glIsEnabled(GL_STENCIL_TEST);
    GLint caller_func = GL_ALWAYS, caller_ref = 0, caller_value_mask = 0xFF, caller_write_mask = 0xFF;
    GLint caller_fail = GL_KEEP, caller_zfail = GL_KEEP, caller_zpass = GL_KEEP;
    g_glFuncs.glGetIntegerv(GL_STENCIL_FUNC, &caller_func);
    g_glFuncs.glGetIntegerv(GL_STENCIL_REF, &caller_ref);
    g_glFuncs.glGetIntegerv(GL_STENCIL_VALUE_MASK, &caller_value_mask);
    g_glFuncs.glGetIntegerv(GL_STENCIL_WRITEMASK, &caller_write_mask);
    g_glFuncs.glGetIntegerv(GL_STENCIL_FAIL, &caller_fail);
    g_glFuncs.glGetIntegerv(GL_STENCIL_PASS_DEPTH_FAIL, &caller_zfail);
    g_glFuncs.glGetIntegerv(GL_STENCIL_PASS_DEPTH_PASS, &caller_zpass);
    const auto& caller_mask = g_glstate_c.fpe_state.color_buffer.color_mask;

    g_glFuncs.glEnable(GL_STENCIL_TEST);
    g_glFuncs.glStencilOp(GL_REPLACE, GL_REPLACE, GL_REPLACE);
    if (g_glFuncs.glColorMask != nullptr)
        g_glFuncs.glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);

    no_cull_guard_t no_cull;
    for (int bit = 0; bit < 8; ++bit) {
        g_glFuncs.glUniform1i(d.loc_bit_index, bit);
        g_glFuncs.glStencilMask(static_cast<GLuint>(1 << bit));
        for (int want = 0; want <= 1; ++want) {
            g_glFuncs.glUniform1i(d.loc_want_bit, want);
            g_glFuncs.glStencilFunc(GL_ALWAYS, want != 0 ? 0xFF : 0x00, 0xFF);
            g_glFuncs.glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        }
    }

    if (g_glFuncs.glColorMask != nullptr)
        g_glFuncs.glColorMask(caller_mask[0], caller_mask[1], caller_mask[2], caller_mask[3]);
    g_glFuncs.glStencilOp(static_cast<GLenum>(caller_fail), static_cast<GLenum>(caller_zfail),
                          static_cast<GLenum>(caller_zpass));
    g_glFuncs.glStencilFunc(static_cast<GLenum>(caller_func), caller_ref,
                            static_cast<GLuint>(caller_value_mask));
    g_glFuncs.glStencilMask(static_cast<GLuint>(caller_write_mask));
    if (caller_stencil_test == GL_FALSE) g_glFuncs.glDisable(GL_STENCIL_TEST);

    g_glFuncs.glBindTexture(GL_TEXTURE_2D, unit_zero_binding);
    glActiveTexture(caller_active);
}

} // namespace

namespace {

// Full-screen pass over an EXISTING texture (0 selects a lazy 1x1 white),
// output scaled by `color`. Blend/FBO state is the caller's responsibility;
// program/VAO/texture bindings are restored like drawQuad does.
void drawFullscreenTexture(GLuint texture, const glm::vec4& color) {
    auto& d = drawer();
    if (!ensureDrawer(d)) return;

    static thread_local GLuint white_tex = 0;
    if (texture == 0) {
        if (white_tex == 0) {
            g_glFuncs.glGenTextures(1, &white_tex);
            const GLubyte white[4] = {255, 255, 255, 255};
            g_glFuncs.glBindTexture(GL_TEXTURE_2D, white_tex);
            private_unpack_guard_t unpack;
            g_glFuncs.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE,
                                   white);
            g_glFuncs.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            g_glFuncs.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        }
        texture = white_tex;
    }

    GLint prev_program = 0, prev_vao = 0, prev_tex = 0, prev_active = GL_TEXTURE0;
    g_glFuncs.glGetIntegerv(GL_CURRENT_PROGRAM, &prev_program);
    g_glFuncs.glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &prev_vao);
    g_glFuncs.glGetIntegerv(GL_ACTIVE_TEXTURE, &prev_active);
    g_glFuncs.glActiveTexture(GL_TEXTURE0);
    g_glFuncs.glGetIntegerv(GL_TEXTURE_BINDING_2D, &prev_tex);

    g_glFuncs.glBindTexture(GL_TEXTURE_2D, texture);
    sfpewInvalidateImmediateDrawState();
    g_glFuncs.glUseProgram(d.program);
    sfpewBackendBindVertexArray(d.vao);
    g_glFuncs.glUniform4f(d.loc_rect, -1.0f, -1.0f, 1.0f, 1.0f);
    g_glFuncs.glUniform1f(d.loc_depth, 0.0f);
    g_glFuncs.glUniform4f(d.loc_color, color.r, color.g, color.b, color.a);
    g_glFuncs.glUniform1i(d.loc_mode, 0);
    g_glFuncs.glUniform1i(d.loc_tex, 0);
    {
        // An accumulation-buffer operation is no more a facet than a pixel
        // rectangle is; same reasoning as no_cull_guard_t's own comment.
        no_cull_guard_t no_cull;
        g_glFuncs.glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }

    g_glFuncs.glBindTexture(GL_TEXTURE_2D, (GLuint)prev_tex);
    g_glFuncs.glActiveTexture((GLenum)prev_active);
    sfpewInvalidateImmediateDrawState();
    g_glFuncs.glUseProgram(prev_program);
    sfpewBackendBindVertexArray(prev_vao);
}

} // namespace

#define sfpewDrawTextureQuad drawFullscreenTexture

// --- Accumulation buffer emulation (plans/10, 10.4) ---------------------
// An RGBA16F color attachment sized to the current viewport stands in for
// the accumulation buffer; ops render through the shared quad drawer with
// blend state providing the arithmetic. Sized-to-viewport is a documented
// approximation (the real accum buffer matches the full framebuffer).

namespace {

struct accum_state_t {
    GLuint fbo = 0;
    GLuint texture = 0;      // RGBA16F accumulation storage
    GLuint scratch_tex = 0;  // framebuffer snapshot for ACCUM/LOAD
    GLsizei width = 0, height = 0;
    glm::vec4 clear_value{0.0f};
};

accum_state_t& accumState() {
    static thread_local struct {
        EGLContext context = EGL_NO_CONTEXT;
        accum_state_t s{};
    } cache;
    const EGLContext current =
        sfpewCurrentContext();
    if (cache.context != current) {
        cache.context = current;
        cache.s = {};
    }
    return cache.s;
}

bool ensureAccum(accum_state_t& a, GLsizei width, GLsizei height) {
    if (g_glFuncs.glGenFramebuffers == nullptr || g_glFuncs.glFramebufferTexture2D == nullptr ||
        g_glFuncs.glGenTextures == nullptr) {
        return false;
    }
    if (a.fbo != 0 && a.width == width && a.height == height) return true;
    if (a.fbo == 0) g_glFuncs.glGenFramebuffers(1, &a.fbo);
    if (a.texture == 0) g_glFuncs.glGenTextures(1, &a.texture);
    if (a.scratch_tex == 0) {
        g_glFuncs.glGenTextures(1, &a.scratch_tex);
        // Sampled straight off its level 0, which glCopyTexImage2D respecifies
        // per snapshot: at the default GL_NEAREST_MIPMAP_LINEAR min filter the
        // texture is mipmap-incomplete, so every GL_ACCUM/GL_LOAD would read
        // black instead of the framebuffer.
        g_glFuncs.glBindTexture(GL_TEXTURE_2D, a.scratch_tex);
        g_glFuncs.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        g_glFuncs.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    }
    g_glFuncs.glBindTexture(GL_TEXTURE_2D, a.texture);
    {
        // Null data is an offset of zero into a bound unpack buffer, not "no
        // data", so this allocation needs the caller's unpack state out of the
        // way exactly as much as one carrying pixels does.
        private_unpack_guard_t unpack;
        g_glFuncs.glTexImage2D(GL_TEXTURE_2D, 0, 0x881A /* GL_RGBA16F */, width, height, 0, GL_RGBA,
                               0x140B /* GL_HALF_FLOAT */, nullptr);
    }
    g_glFuncs.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    g_glFuncs.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    g_glFuncs.glBindFramebuffer(0x8D40 /* GL_FRAMEBUFFER */, a.fbo);
    g_glFuncs.glFramebufferTexture2D(0x8D40, 0x8CE0 /* GL_COLOR_ATTACHMENT0 */, GL_TEXTURE_2D,
                                     a.texture, 0);
    a.width = width;
    a.height = height;
    return true;
}

// Snapshot of blend/FBO state around accumulation passes.
struct accum_backend_guard_t {
    GLint draw_fbo = 0, read_fbo = 0;
    GLboolean blend = GL_FALSE;
    GLint src_rgb = GL_ONE, dst_rgb = GL_ZERO, src_a = GL_ONE, dst_a = GL_ZERO;

    accum_backend_guard_t() {
        g_glFuncs.glGetIntegerv(0x8CA6 /* GL_DRAW_FRAMEBUFFER_BINDING */, &draw_fbo);
        g_glFuncs.glGetIntegerv(0x8CAA /* GL_READ_FRAMEBUFFER_BINDING */, &read_fbo);
        blend = g_glFuncs.glIsEnabled != nullptr ? g_glFuncs.glIsEnabled(GL_BLEND) : GL_FALSE;
        g_glFuncs.glGetIntegerv(GL_BLEND_SRC_RGB, &src_rgb);
        g_glFuncs.glGetIntegerv(GL_BLEND_DST_RGB, &dst_rgb);
        g_glFuncs.glGetIntegerv(GL_BLEND_SRC_ALPHA, &src_a);
        g_glFuncs.glGetIntegerv(GL_BLEND_DST_ALPHA, &dst_a);
    }
    ~accum_backend_guard_t() {
        g_glFuncs.glBindFramebuffer(0x8CA9 /* GL_DRAW_FRAMEBUFFER */, draw_fbo);
        g_glFuncs.glBindFramebuffer(0x8CA8 /* GL_READ_FRAMEBUFFER */, read_fbo);
        if (blend)
            g_glFuncs.glEnable(GL_BLEND);
        else
            g_glFuncs.glDisable(GL_BLEND);
        g_glFuncs.glBlendFuncSeparate(src_rgb, dst_rgb, src_a, dst_a);
    }
};

} // namespace

void glClearAccum(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    accumState().clear_value = {red, green, blue, alpha};
}

namespace {

void drainFailedMapError();

// Where a bitmap's bits sit, per GL 2.1 3.6.4: rows are a*ceil(l/(8a)) bytes
// apart - a = GL_UNPACK_ALIGNMENT (whose default is 4, so a tight ceil(w/8)
// packing is the exception, not the rule) and l = GL_UNPACK_ROW_LENGTH or
// width - and GL_UNPACK_SKIP_ROWS/SKIP_PIXELS select a sub-rectangle, the
// latter counting BITS, so it need not land on a byte boundary.
struct bitmap_unpack_layout_t {
    size_t row_stride = 0;  // bytes between rows
    size_t start = 0;       // bytes from the base of the image to row 0
    size_t bit_offset = 0;  // bits into the first byte of every row
    size_t extent = 0;      // bytes from the base of the image the whole rectangle spans
};
// Both defined further down, next to the pixel-unpack helpers they share.
bool bitmapUnpackLayout(GLsizei width, GLsizei height, bitmap_unpack_layout_t* out);
void drawBitmapRectangle(GLsizei width, GLsizei height, GLfloat xorig, GLfloat yorig,
                         const GLubyte* bitmap, const bitmap_unpack_layout_t& layout);
bool captureBitmapListPayload(GLsizei width, GLsizei height, const GLubyte* bitmap,
                              std::vector<uint8_t>* out);

// The compiled form of glBitmap: the payload is tight and MSB-first by then,
// so nothing about the unpack state at glCallList may reach it - including a
// bound unpack buffer, which would read the captured pointer as an offset.
void replayBitmap(GLsizei width, GLsizei height, GLfloat xorig, GLfloat yorig, GLfloat xmove,
                  GLfloat ymove, const GLubyte* bitmap) {
    sfpew_list_unpack_replay_t unpack(false, false);
    SELF_CALL(glBitmap, width, height, xorig, yorig, xmove, ymove, bitmap)
}

bool pixelMapIndex(GLenum map, size_t* index = nullptr) {
    if (map < GL_PIXEL_MAP_I_TO_I || map > GL_PIXEL_MAP_A_TO_A) return false;
    if (index != nullptr) *index = static_cast<size_t>(map - GL_PIXEL_MAP_I_TO_I);
    return true;
}

bool pixelMapIsIndex(GLenum map) {
    return map == GL_PIXEL_MAP_I_TO_I || map == GL_PIXEL_MAP_S_TO_S;
}

bool pixelMapSizeIsValid(GLenum map, GLsizei mapsize) {
    if (mapsize < 1 || mapsize > SFPEW_MAX_PIXEL_MAP_TABLE) return false;
    // The six maps indexed by a color/stencil index use masking to select an
    // entry and therefore require a power-of-two size. Component-to-component
    // maps do not have that restriction.
    return map >= GL_PIXEL_MAP_R_TO_R || (mapsize & (mapsize - 1)) == 0;
}

template <typename T>
bool copyPixelMapSource(GLsizei mapsize, const T* values, std::vector<T>* copied) {
    try {
        copied->resize(static_cast<size_t>(mapsize));
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return false;
    }

    GLint unpack_buffer = 0;
    if (!DisplayListManager::isCalling() && sfpewEnsureBackend() &&
        g_glFuncs.glGetIntegerv != nullptr) {
        g_glFuncs.glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &unpack_buffer);
    }
    if (unpack_buffer == 0) {
        if (values == nullptr) return false;
        std::copy_n(values, mapsize, copied->data());
        return true;
    }

    if (g_glFuncs.glGetBufferParameteriv == nullptr || g_glFuncs.glMapBufferRange == nullptr ||
        g_glFuncs.glUnmapBuffer == nullptr) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }
    const size_t offset = reinterpret_cast<uintptr_t>(values);
    const size_t bytes = static_cast<size_t>(mapsize) * sizeof(T);
    GLint buffer_size = 0, buffer_mapped = GL_FALSE;
    g_glFuncs.glGetBufferParameteriv(GL_PIXEL_UNPACK_BUFFER, GL_BUFFER_SIZE, &buffer_size);
    g_glFuncs.glGetBufferParameteriv(GL_PIXEL_UNPACK_BUFFER, GL_BUFFER_MAPPED, &buffer_mapped);
    if (offset % sizeof(T) != 0 || buffer_mapped == GL_TRUE || buffer_size < 0 ||
        offset > static_cast<size_t>(buffer_size) || bytes > static_cast<size_t>(buffer_size) - offset ||
        offset > static_cast<size_t>(std::numeric_limits<GLintptr>::max()) ||
        bytes > static_cast<size_t>(std::numeric_limits<GLsizeiptr>::max())) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }

    const void* mapped = g_glFuncs.glMapBufferRange(
        GL_PIXEL_UNPACK_BUFFER, static_cast<GLintptr>(offset), static_cast<GLsizeiptr>(bytes),
        GL_MAP_READ_BIT);
    if (mapped == nullptr) {
        drainFailedMapError();
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }
    std::memcpy(copied->data(), mapped, bytes);
    if (g_glFuncs.glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER) != GL_TRUE) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }
    return true;
}

template <typename T>
void storePixelMap(GLenum map, const std::vector<T>& values) {
    size_t index = 0;
    pixelMapIndex(map, &index);
    const bool index_map = pixelMapIsIndex(map);
    auto& destination = g_glstate.pixel_maps[index];
    try {
        destination.resize(values.size());
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return;
    }
    for (size_t i = 0; i < values.size(); ++i) {
        if (index_map) {
            destination[i] = static_cast<GLfloat>(values[i]);
        } else if constexpr (std::is_floating_point_v<T>) {
            const GLfloat value = static_cast<GLfloat>(values[i]);
            destination[i] = std::isnan(value) ? 0.0f : std::clamp(value, 0.0f, 1.0f);
        } else {
            destination[i] = static_cast<GLfloat>(values[i]) /
                             static_cast<GLfloat>(std::numeric_limits<T>::max());
        }
    }
}

template <typename T>
T pixelMapResult(GLenum map, GLfloat value) {
    if constexpr (std::is_floating_point_v<T>) {
        return value;
    } else {
        if (std::isnan(value) || value <= 0.0f) return 0;
        const long double maximum = static_cast<long double>(std::numeric_limits<T>::max());
        const long double converted = pixelMapIsIndex(map)
                                          ? static_cast<long double>(value)
                                          : static_cast<long double>(std::min(value, 1.0f)) * maximum;
        if (converted >= maximum) return std::numeric_limits<T>::max();
        return static_cast<T>(std::llround(converted));
    }
}

template <typename T>
bool writePixelMapDestination(const std::vector<T>& converted, T* values) {
    GLint pack_buffer = 0;
    if (sfpewEnsureBackend() && g_glFuncs.glGetIntegerv != nullptr)
        g_glFuncs.glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &pack_buffer);
    if (pack_buffer == 0) {
        if (values == nullptr) return false;
        std::copy(converted.begin(), converted.end(), values);
        return true;
    }

    if (g_glFuncs.glGetBufferParameteriv == nullptr || g_glFuncs.glMapBufferRange == nullptr ||
        g_glFuncs.glUnmapBuffer == nullptr) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }
    const size_t offset = reinterpret_cast<uintptr_t>(values);
    const size_t bytes = converted.size() * sizeof(T);
    GLint buffer_size = 0, buffer_mapped = GL_FALSE;
    g_glFuncs.glGetBufferParameteriv(GL_PIXEL_PACK_BUFFER, GL_BUFFER_SIZE, &buffer_size);
    g_glFuncs.glGetBufferParameteriv(GL_PIXEL_PACK_BUFFER, GL_BUFFER_MAPPED, &buffer_mapped);
    if (offset % sizeof(T) != 0 || buffer_mapped == GL_TRUE || buffer_size < 0 ||
        offset > static_cast<size_t>(buffer_size) || bytes > static_cast<size_t>(buffer_size) - offset ||
        offset > static_cast<size_t>(std::numeric_limits<GLintptr>::max()) ||
        bytes > static_cast<size_t>(std::numeric_limits<GLsizeiptr>::max())) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }

    void* mapped = g_glFuncs.glMapBufferRange(
        GL_PIXEL_PACK_BUFFER, static_cast<GLintptr>(offset), static_cast<GLsizeiptr>(bytes),
        GL_MAP_WRITE_BIT);
    if (mapped == nullptr) {
        drainFailedMapError();
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }
    std::memcpy(mapped, converted.data(), bytes);
    if (g_glFuncs.glUnmapBuffer(GL_PIXEL_PACK_BUFFER) != GL_TRUE) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }
    return true;
}

template <typename T>
void getPixelMap(GLenum map, T* values) {
    sfpewEntryBarrier();
    size_t index = 0;
    if (!pixelMapIndex(map, &index)) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    const auto& source = g_glstate.pixel_maps[index];
    std::vector<T> converted;
    try {
        converted.resize(source.size());
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return;
    }
    for (size_t i = 0; i < source.size(); ++i)
        converted[i] = pixelMapResult<T>(map, source[i]);
    writePixelMapDestination(converted, values);
}

} // namespace

void glPixelMapfv(GLenum map, GLsizei mapsize, const GLfloat* values) {
    sfpewEntryBarrier();
    if (!pixelMapIndex(map)) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    if (!pixelMapSizeIsValid(map, mapsize)) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    std::vector<GLfloat> copied;
    if (!copyPixelMapSource(mapsize, values, &copied)) return;
    LIST_RECORD(glPixelMapfv, {{2, copied.size() * sizeof(GLfloat)}}, map, mapsize,
                static_cast<const GLfloat*>(copied.data()))
    storePixelMap(map, copied);
}

void glPixelMapuiv(GLenum map, GLsizei mapsize, const GLuint* values) {
    sfpewEntryBarrier();
    if (!pixelMapIndex(map)) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    if (!pixelMapSizeIsValid(map, mapsize)) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    std::vector<GLuint> copied;
    if (!copyPixelMapSource(mapsize, values, &copied)) return;
    LIST_RECORD(glPixelMapuiv, {{2, copied.size() * sizeof(GLuint)}}, map, mapsize,
                static_cast<const GLuint*>(copied.data()))
    storePixelMap(map, copied);
}

void glPixelMapusv(GLenum map, GLsizei mapsize, const GLushort* values) {
    sfpewEntryBarrier();
    if (!pixelMapIndex(map)) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    if (!pixelMapSizeIsValid(map, mapsize)) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    std::vector<GLushort> copied;
    if (!copyPixelMapSource(mapsize, values, &copied)) return;
    LIST_RECORD(glPixelMapusv, {{2, copied.size() * sizeof(GLushort)}}, map, mapsize,
                static_cast<const GLushort*>(copied.data()))
    storePixelMap(map, copied);
}

void glGetPixelMapfv(GLenum map, GLfloat* values) {
    getPixelMap(map, values);
}

void glGetPixelMapuiv(GLenum map, GLuint* values) {
    getPixelMap(map, values);
}

void glGetPixelMapusv(GLenum map, GLushort* values) {
    getPixelMap(map, values);
}

// GL_ACCUM_CLEAR_VALUE, for the glGet family: the accumulation state is
// private to this file, but its clear color is queryable state.
void sfpewAccumClearValue(GLfloat* rgba) {
    const glm::vec4& value = accumState().clear_value;
    rgba[0] = value.r;
    rgba[1] = value.g;
    rgba[2] = value.b;
    rgba[3] = value.a;
}

void glAccum(GLenum op, GLfloat value) {
    sfpewEntryBarrier();
    if (op != GL_ACCUM && op != GL_LOAD && op != GL_ADD && op != GL_MULT && op != GL_RETURN) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    if (!sfpewEnsureBackend() || g_glFuncs.glBlendFuncSeparate == nullptr ||
        g_glFuncs.glCopyTexImage2D == nullptr) {
        return;
    }
    GLint viewport[4] = {0, 0, 0, 0};
    g_glFuncs.glGetIntegerv(GL_VIEWPORT, viewport);
    if (viewport[2] <= 0 || viewport[3] <= 0) return;

    auto& a = accumState();
    // Constructed before ensureAccum, not after: the lazy setup binds the
    // accumulation framebuffer, and a guard that only starts saving afterwards
    // records THAT as the caller's binding and restores it - so the first
    // glAccum of a process leaves the app drawing into (and reading out of)
    // the accumulation buffer, and its own GL_ACCUM/GL_LOAD snapshot copies
    // from the RGBA16F accumulation storage instead of the caller's buffer.
    accum_backend_guard_t backend;
    if (!ensureAccum(a, viewport[2], viewport[3])) return;

    const glm::vec4 scale(value, value, value, value);

    if (op == GL_ACCUM || op == GL_LOAD) {
        // Snapshot the caller's framebuffer region into the scratch texture.
        g_glFuncs.glBindFramebuffer(0x8CA8 /* GL_READ_FRAMEBUFFER */, backend.read_fbo);
        g_glFuncs.glBindTexture(GL_TEXTURE_2D, a.scratch_tex);
        g_glFuncs.glCopyTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, viewport[0], viewport[1], viewport[2],
                                   viewport[3], 0);
        g_glFuncs.glBindFramebuffer(0x8CA9 /* GL_DRAW_FRAMEBUFFER */, a.fbo);
        if (op == GL_ACCUM) {
            g_glFuncs.glEnable(GL_BLEND);
            g_glFuncs.glBlendFuncSeparate(GL_ONE, GL_ONE, GL_ONE, GL_ONE);
        } else {
            g_glFuncs.glDisable(GL_BLEND);
        }
        sfpewDrawTextureQuad(a.scratch_tex, scale);
    } else if (op == GL_ADD || op == GL_MULT) {
        g_glFuncs.glBindFramebuffer(0x8CA9, a.fbo);
        g_glFuncs.glEnable(GL_BLEND);
        if (op == GL_ADD)
            g_glFuncs.glBlendFuncSeparate(GL_ONE, GL_ONE, GL_ONE, GL_ONE);
        else
            g_glFuncs.glBlendFuncSeparate(GL_DST_COLOR, GL_ZERO, GL_DST_ALPHA, GL_ZERO);
        // ADD paints the constant; MULT multiplies the destination by it.
        sfpewDrawTextureQuad(0 /* white */, op == GL_ADD ? scale : scale);
    } else { // GL_RETURN
        g_glFuncs.glBindFramebuffer(0x8CA9, backend.draw_fbo);
        g_glFuncs.glDisable(GL_BLEND);
        sfpewDrawTextureQuad(a.texture, scale);
    }
}

void glBitmap(GLsizei width, GLsizei height, GLfloat xorig, GLfloat yorig, GLfloat xmove,
              GLfloat ymove, const GLubyte* bitmap) {
    sfpewEntryBarrier();
    if (width < 0 || height < 0) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    // With a pixel unpack buffer bound `bitmap` is a byte offset into it
    // (glBitmap's reference page), which makes offset 0 - a null pointer - a
    // real bitmap to draw rather than "no bitmap".
    const bool has_ink = width > 0 && height > 0 && (bitmap != nullptr || sfpewUnpackPboBound());

    // plans/17 P13. GL 2.1 compiles every glBitmap, and the payload-free form
    // is not a curiosity: glBitmap's own Notes give NULL-bitmap-with-xmove as
    // the way to move the raster position outside the viewport, and
    // glXUseXFont/wglUseFontBitmaps emit exactly that for a blank glyph. So
    // this sits outside the drawing guard AND ahead of the raster-validity
    // test - recording is not conditional on there being ink to draw, nor on
    // a state the replay will evaluate for itself.
    if (!disableRecording && DisplayListManager::shouldRecord()) {
        std::vector<uint8_t> payload;
        if (!has_ink || captureBitmapListPayload(width, height, bitmap, &payload)) {
            displayListManager.record<replayBitmap>(
                {{6, payload.size()}}, width, height, xorig, yorig, xmove, ymove,
                payload.empty() ? nullptr : static_cast<const GLubyte*>(payload.data()));
        }
        if (DisplayListManager::shouldFinish()) return;
    }

    if (!g_glstate.fpe_uniform.raster_position_valid) return;
    auto& raster = g_glstate.fpe_uniform.raster_position;

    bitmap_unpack_layout_t layout;
    if (has_ink && sfpewEnsureBackend() && g_glFuncs.glTexImage2D != nullptr &&
        bitmapUnpackLayout(width, height, &layout)) {
        drawBitmapRectangle(width, height, xorig, yorig, bitmap, layout);
    }

    // The raster position always advances, even for w/h 0 or null bitmaps.
    raster.x += xmove;
    raster.y += ymove;
}

namespace {

struct pixel_format_info_t {
    int components = 0;
    bool depth = false;
    bool stencil = false;
};

bool describePixelFormat(GLenum format, pixel_format_info_t* out) {
    switch (format) {
    case GL_RED:
    case GL_GREEN:
    case GL_BLUE:
    case GL_ALPHA:
    case GL_LUMINANCE:
        out->components = 1;
        return true;
    case GL_LUMINANCE_ALPHA:
        out->components = 2;
        return true;
    case GL_RGB:
    case GL_BGR:
        out->components = 3;
        return true;
    case GL_RGBA:
    case GL_BGRA:
        out->components = 4;
        return true;
    case GL_DEPTH_COMPONENT:
        out->components = 1;
        out->depth = true;
        return true;
    case GL_STENCIL_INDEX:
        out->components = 1;
        out->stencil = true;
        return true;
    default:
        return false;
    }
}

bool scalarPixelType(GLenum type, size_t* bytes) {
    switch (type) {
    case GL_BYTE:
    case GL_UNSIGNED_BYTE:
        *bytes = 1;
        return true;
    case GL_SHORT:
    case GL_UNSIGNED_SHORT:
    case GL_HALF_FLOAT:
        *bytes = 2;
        return true;
    case GL_INT:
    case GL_UNSIGNED_INT:
    case GL_FLOAT:
        *bytes = 4;
        return true;
    default:
        return false;
    }
}

bool packedPixelType(GLenum type, int widths[4], int* components, size_t* bytes,
                     bool* reversed) {
    *reversed = false;
    switch (type) {
    case GL_UNSIGNED_BYTE_3_3_2:
        widths[0] = 3; widths[1] = 3; widths[2] = 2;
        *components = 3; *bytes = 1;
        return true;
    case GL_UNSIGNED_BYTE_2_3_3_REV:
        widths[0] = 3; widths[1] = 3; widths[2] = 2;
        *components = 3; *bytes = 1; *reversed = true;
        return true;
    case GL_UNSIGNED_SHORT_5_6_5:
        widths[0] = 5; widths[1] = 6; widths[2] = 5;
        *components = 3; *bytes = 2;
        return true;
    case GL_UNSIGNED_SHORT_5_6_5_REV:
        widths[0] = 5; widths[1] = 6; widths[2] = 5;
        *components = 3; *bytes = 2; *reversed = true;
        return true;
    case GL_UNSIGNED_SHORT_4_4_4_4:
        widths[0] = 4; widths[1] = 4; widths[2] = 4; widths[3] = 4;
        *components = 4; *bytes = 2;
        return true;
    case GL_UNSIGNED_SHORT_4_4_4_4_REV:
        widths[0] = 4; widths[1] = 4; widths[2] = 4; widths[3] = 4;
        *components = 4; *bytes = 2; *reversed = true;
        return true;
    case GL_UNSIGNED_SHORT_5_5_5_1:
        widths[0] = 5; widths[1] = 5; widths[2] = 5; widths[3] = 1;
        *components = 4; *bytes = 2;
        return true;
    case GL_UNSIGNED_SHORT_1_5_5_5_REV:
        widths[0] = 5; widths[1] = 5; widths[2] = 5; widths[3] = 1;
        *components = 4; *bytes = 2; *reversed = true;
        return true;
    case GL_UNSIGNED_INT_8_8_8_8:
        widths[0] = 8; widths[1] = 8; widths[2] = 8; widths[3] = 8;
        *components = 4; *bytes = 4;
        return true;
    case GL_UNSIGNED_INT_8_8_8_8_REV:
        widths[0] = 8; widths[1] = 8; widths[2] = 8; widths[3] = 8;
        *components = 4; *bytes = 4; *reversed = true;
        return true;
    case GL_UNSIGNED_INT_10_10_10_2:
        widths[0] = 10; widths[1] = 10; widths[2] = 10; widths[3] = 2;
        *components = 4; *bytes = 4;
        return true;
    case GL_UNSIGNED_INT_2_10_10_10_REV:
        widths[0] = 10; widths[1] = 10; widths[2] = 10; widths[3] = 2;
        *components = 4; *bytes = 4; *reversed = true;
        return true;
    default:
        return false;
    }
}

bool describePixelType(GLenum format, const pixel_format_info_t& format_info, GLenum type,
                       size_t* pixel_bytes) {
    size_t scalar_bytes = 0;
    if (scalarPixelType(type, &scalar_bytes)) {
        *pixel_bytes = scalar_bytes * static_cast<size_t>(format_info.components);
        return true;
    }

    int widths[4] = {};
    int packed_components = 0;
    bool reversed = false;
    if (!packedPixelType(type, widths, &packed_components, pixel_bytes, &reversed)) return false;
    (void)widths;
    (void)reversed;
    // The three-field packings (_3_3_2/_2_3_3_REV/_5_6_5/_5_6_5_REV) are
    // GL_RGB and nothing else - GL_BGR is not exempt, unlike the four-field
    // packings, which do take GL_BGRA (GL 2.1 3.6.4, and glDrawPixels' own
    // error list).
    if ((packed_components == 3 && format != GL_RGB) ||
        (packed_components == 4 && format != GL_RGBA && format != GL_BGRA)) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }
    return true;
}

template <typename T>
T loadPixelScalar(const uint8_t* source, bool swap_bytes) {
    T value{};
    if (swap_bytes && sizeof(T) > 1) {
        uint8_t bytes[sizeof(T)];
        std::memcpy(bytes, source, sizeof(T));
        std::reverse(bytes, bytes + sizeof(T));
        std::memcpy(&value, bytes, sizeof(T));
    } else {
        std::memcpy(&value, source, sizeof(T));
    }
    return value;
}

float halfToFloat(uint16_t bits) {
    const bool negative = (bits & 0x8000u) != 0;
    const uint16_t exponent = (bits >> 10u) & 0x1Fu;
    const uint16_t mantissa = bits & 0x03FFu;
    float value = 0.0f;
    if (exponent == 0) {
        value = std::ldexp(static_cast<float>(mantissa), -24);
    } else if (exponent == 0x1Fu) {
        value = mantissa == 0 ? std::numeric_limits<float>::infinity()
                              : std::numeric_limits<float>::quiet_NaN();
    } else {
        value = std::ldexp(1.0f + static_cast<float>(mantissa) / 1024.0f,
                           static_cast<int>(exponent) - 15);
    }
    return negative ? -value : value;
}

float readPixelComponent(const uint8_t* source, GLenum type, bool swap_bytes) {
    switch (type) {
    case GL_BYTE: return sfpewNormalizeColorComponent(loadPixelScalar<GLbyte>(source, false));
    case GL_UNSIGNED_BYTE:
        return sfpewNormalizeColorComponent(loadPixelScalar<GLubyte>(source, false));
    case GL_SHORT: return sfpewNormalizeColorComponent(loadPixelScalar<GLshort>(source, swap_bytes));
    case GL_UNSIGNED_SHORT:
        return sfpewNormalizeColorComponent(loadPixelScalar<GLushort>(source, swap_bytes));
    case GL_INT: return sfpewNormalizeColorComponent(loadPixelScalar<GLint>(source, swap_bytes));
    case GL_UNSIGNED_INT:
        return sfpewNormalizeColorComponent(loadPixelScalar<GLuint>(source, swap_bytes));
    case GL_FLOAT: return loadPixelScalar<GLfloat>(source, swap_bytes);
    case GL_HALF_FLOAT:
        return halfToFloat(loadPixelScalar<uint16_t>(source, swap_bytes));
    default: return 0.0f;
    }
}

// defects-plan-2.md 2.5: a GL_STENCIL_INDEX value is the index itself, not
// a [0,1]-normalized quantity - unlike readPixelComponent above, which
// exists for color/depth. Signed types reinterpret their bit pattern as
// unsigned (a source byte 0xFF/-1 becomes index 255), the same convention
// GL_UNSIGNED_BYTE already uses implicitly. GL_FLOAT/GL_HALF_FLOAT are not
// legal glDrawPixels(GL_STENCIL_INDEX) types (GL 2.1 table 3.6) and
// GL_BITMAP is a further, documented scope cut - both return false.
bool readPixelStencilIndex(const uint8_t* source, GLenum type, bool swap_bytes, uint32_t* out) {
    switch (type) {
    case GL_BYTE:
        *out = static_cast<uint8_t>(loadPixelScalar<GLbyte>(source, false));
        return true;
    case GL_UNSIGNED_BYTE:
        *out = loadPixelScalar<GLubyte>(source, false);
        return true;
    case GL_SHORT:
        *out = static_cast<uint16_t>(loadPixelScalar<GLshort>(source, swap_bytes));
        return true;
    case GL_UNSIGNED_SHORT:
        *out = loadPixelScalar<GLushort>(source, swap_bytes);
        return true;
    case GL_INT:
        *out = static_cast<uint32_t>(loadPixelScalar<GLint>(source, swap_bytes));
        return true;
    case GL_UNSIGNED_INT:
        *out = loadPixelScalar<GLuint>(source, swap_bytes);
        return true;
    default:
        return false;
    }
}

void decodePackedPixel(const uint8_t* source, GLenum type, bool swap_bytes, float values[4],
                       int* components) {
    int widths[4] = {};
    size_t bytes = 0;
    bool reversed = false;
    packedPixelType(type, widths, components, &bytes, &reversed);
    uint32_t word = 0;
    if (bytes == 1)
        word = loadPixelScalar<uint8_t>(source, false);
    else if (bytes == 2)
        word = loadPixelScalar<uint16_t>(source, swap_bytes);
    else
        word = loadPixelScalar<uint32_t>(source, swap_bytes);

    int shift = reversed ? 0 : static_cast<int>(bytes * 8u);
    for (int component = 0; component < *components; ++component) {
        if (reversed)
            shift += component == 0 ? 0 : widths[component - 1];
        else
            shift -= widths[component];
        const uint32_t mask = (1u << widths[component]) - 1u;
        values[component] = static_cast<float>((word >> shift) & mask) /
                            static_cast<float>(mask);
    }
}

glm::vec4 expandPixel(GLenum format, const float values[4]) {
    switch (format) {
    case GL_RED: return {values[0], 0.0f, 0.0f, 1.0f};
    case GL_GREEN: return {0.0f, values[0], 0.0f, 1.0f};
    case GL_BLUE: return {0.0f, 0.0f, values[0], 1.0f};
    case GL_ALPHA: return {0.0f, 0.0f, 0.0f, values[0]};
    case GL_RGB: return {values[0], values[1], values[2], 1.0f};
    case GL_BGR: return {values[2], values[1], values[0], 1.0f};
    case GL_RGBA: return {values[0], values[1], values[2], values[3]};
    case GL_BGRA: return {values[2], values[1], values[0], values[3]};
    case GL_LUMINANCE: return {values[0], values[0], values[0], 1.0f};
    case GL_LUMINANCE_ALPHA: return {values[0], values[0], values[0], values[1]};
    case GL_DEPTH_COMPONENT:
    case GL_STENCIL_INDEX:
        return {values[0], 0.0f, 0.0f, 1.0f};
    default: return {0.0f, 0.0f, 0.0f, 0.0f};
    }
}

glm::vec4 decodePixel(const uint8_t* source, GLenum format, GLenum type,
                      const pixel_format_info_t& format_info, bool swap_bytes) {
    float values[4] = {};
    size_t scalar_bytes = 0;
    if (scalarPixelType(type, &scalar_bytes)) {
        for (int component = 0; component < format_info.components; ++component) {
            values[component] =
                readPixelComponent(source + static_cast<size_t>(component) * scalar_bytes, type,
                                   swap_bytes);
        }
    } else {
        int ignored_components = 0;
        decodePackedPixel(source, type, swap_bytes, values, &ignored_components);
    }
    return expandPixel(format, values);
}

bool checkedPixelAdd(size_t left, size_t right, size_t* out) {
    if (right > std::numeric_limits<size_t>::max() - left) return false;
    *out = left + right;
    return true;
}

bool checkedPixelMultiply(size_t left, size_t right, size_t* out) {
    if (left != 0 && right > std::numeric_limits<size_t>::max() / left) return false;
    *out = left * right;
    return true;
}

struct pixel_unpack_view_t {
    const uint8_t* pixels = nullptr;
    size_t row_stride = 0;
    GLenum mapped_target = GL_NONE;
    GLuint scratch = 0;
    GLint previous_copy_write = 0;

    ~pixel_unpack_view_t() {
        if (mapped_target != GL_NONE && g_glFuncs.glUnmapBuffer != nullptr)
            g_glFuncs.glUnmapBuffer(mapped_target);
        if (scratch != 0) {
            g_glFuncs.glBindBuffer(GL_COPY_WRITE_BUFFER, static_cast<GLuint>(previous_copy_write));
            g_glFuncs.glDeleteBuffers(1, &scratch);
        }
    }
};

void drainFailedMapError() {
    if (g_glFuncs.glGetError == nullptr) return;
    while (g_glFuncs.glGetError() != GL_NO_ERROR) {}
}

// Points `out->pixels` at the first byte of an unpack whose layout is already
// resolved: client memory plus `start`, or - when a pixel unpack buffer is
// bound, which makes `pixels` a byte offset into it - that buffer mapped for
// reading. `needed` is the whole extent read, measured from that offset.
bool mapPixelUnpackSource(const GLvoid* pixels, size_t start, size_t needed,
                          pixel_unpack_view_t* out) {
    GLint pbo = 0;
    g_glFuncs.glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pbo);
    if (pbo == 0) {
        if (pixels == nullptr) return false;
        out->pixels = static_cast<const uint8_t*>(pixels) + start;
        return true;
    }
    if (g_glFuncs.glGetBufferParameteriv == nullptr || g_glFuncs.glMapBufferRange == nullptr ||
        g_glFuncs.glUnmapBuffer == nullptr) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }

    GLint buffer_size = 0, buffer_mapped = GL_FALSE;
    g_glFuncs.glGetBufferParameteriv(GL_PIXEL_UNPACK_BUFFER, GL_BUFFER_SIZE, &buffer_size);
    g_glFuncs.glGetBufferParameteriv(GL_PIXEL_UNPACK_BUFFER, GL_BUFFER_MAPPED, &buffer_mapped);
    const size_t offset = reinterpret_cast<uintptr_t>(pixels);
    if (buffer_mapped == GL_TRUE || buffer_size < 0 || offset > static_cast<size_t>(buffer_size) ||
        needed > static_cast<size_t>(buffer_size) - offset ||
        needed > static_cast<size_t>(std::numeric_limits<GLsizeiptr>::max()) ||
        offset > static_cast<size_t>(std::numeric_limits<GLintptr>::max())) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }

    const auto* mapped = static_cast<const uint8_t*>(g_glFuncs.glMapBufferRange(
        GL_PIXEL_UNPACK_BUFFER, static_cast<GLintptr>(offset), static_cast<GLsizeiptr>(needed),
        GL_MAP_READ_BIT));
    if (mapped != nullptr) {
        out->mapped_target = GL_PIXEL_UNPACK_BUFFER;
        out->pixels = mapped + start;
        return true;
    }

    // Upload-oriented mobile buffers are often not directly READ-mappable.
    // Copy the exact source range into a STREAM_READ buffer before giving up.
    drainFailedMapError();
    if (g_glFuncs.glCopyBufferSubData == nullptr || g_glFuncs.glGenBuffers == nullptr ||
        g_glFuncs.glDeleteBuffers == nullptr || g_glFuncs.glBindBuffer == nullptr ||
        g_glFuncs.glBufferData == nullptr) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }
    g_glFuncs.glGetIntegerv(GL_COPY_WRITE_BUFFER_BINDING, &out->previous_copy_write);
    g_glFuncs.glGenBuffers(1, &out->scratch);
    g_glFuncs.glBindBuffer(GL_COPY_WRITE_BUFFER, out->scratch);
    g_glFuncs.glBufferData(GL_COPY_WRITE_BUFFER, static_cast<GLsizeiptr>(needed), nullptr,
                           GL_STREAM_READ);
    g_glFuncs.glCopyBufferSubData(GL_PIXEL_UNPACK_BUFFER, GL_COPY_WRITE_BUFFER,
                                  static_cast<GLintptr>(offset), 0,
                                  static_cast<GLsizeiptr>(needed));
    mapped = static_cast<const uint8_t*>(g_glFuncs.glMapBufferRange(
        GL_COPY_WRITE_BUFFER, 0, static_cast<GLsizeiptr>(needed), GL_MAP_READ_BIT));
    if (mapped == nullptr) {
        drainFailedMapError();
        g_glFuncs.glBindBuffer(GL_COPY_WRITE_BUFFER,
                               static_cast<GLuint>(out->previous_copy_write));
        g_glFuncs.glDeleteBuffers(1, &out->scratch);
        out->scratch = 0;
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }
    out->mapped_target = GL_COPY_WRITE_BUFFER;
    out->pixels = mapped + start;
    return true;
}

bool bitmapUnpackLayout(GLsizei width, GLsizei height, bitmap_unpack_layout_t* out) {
    if (g_glFuncs.glGetIntegerv == nullptr) return false;
    GLint alignment = 4, row_length = 0, skip_rows = 0, skip_pixels = 0;
    g_glFuncs.glGetIntegerv(GL_UNPACK_ALIGNMENT, &alignment);
    g_glFuncs.glGetIntegerv(GL_UNPACK_ROW_LENGTH, &row_length);
    g_glFuncs.glGetIntegerv(GL_UNPACK_SKIP_ROWS, &skip_rows);
    g_glFuncs.glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &skip_pixels);
    if ((alignment != 1 && alignment != 2 && alignment != 4 && alignment != 8) || row_length < 0 ||
        skip_rows < 0 || skip_pixels < 0) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }

    const size_t a = static_cast<size_t>(alignment);
    const size_t row_pixels = row_length > 0 ? static_cast<size_t>(row_length)
                                             : static_cast<size_t>(width);
    size_t rows_of_a = 0, start = 0, last_row = 0, extent = 0;
    if (!checkedPixelAdd(row_pixels, 8u * a - 1u, &rows_of_a)) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return false;
    }
    out->bit_offset = static_cast<size_t>(skip_pixels) % 8u;
    if (!checkedPixelMultiply(a, rows_of_a / (8u * a), &out->row_stride) ||
        !checkedPixelMultiply(static_cast<size_t>(skip_rows), out->row_stride, &start) ||
        !checkedPixelAdd(start, static_cast<size_t>(skip_pixels) / 8u, &start) ||
        !checkedPixelMultiply(static_cast<size_t>(height - 1), out->row_stride, &last_row) ||
        !checkedPixelAdd(start, last_row, &extent) ||
        !checkedPixelAdd(extent, (out->bit_offset + static_cast<size_t>(width) + 7u) / 8u,
                         &extent)) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return false;
    }
    out->start = start;
    out->extent = extent;
    return true;
}

void drawBitmapRectangle(GLsizei width, GLsizei height, GLfloat xorig, GLfloat yorig,
                         const GLubyte* bitmap, const bitmap_unpack_layout_t& layout) {
    std::vector<uint8_t> texels;
    try {
        texels.resize(static_cast<size_t>(width) * static_cast<size_t>(height));
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return;
    }
    {
        pixel_unpack_view_t source;
        if (!mapPixelUnpackSource(bitmap, layout.start, layout.extent, &source)) return;
        // MSB-first within each byte unless GL_UNPACK_LSB_FIRST.
        const bool lsb_first = g_glstate.pixel_store_unpack_lsb_first;
        for (GLsizei row = 0; row < height; ++row) {
            const uint8_t* line = source.pixels + static_cast<size_t>(row) * layout.row_stride;
            for (GLsizei column = 0; column < width; ++column) {
                const size_t bit_index = layout.bit_offset + static_cast<size_t>(column);
                const uint8_t byte = line[bit_index / 8u];
                const int bit = lsb_first ? static_cast<int>(bit_index % 8u)
                                          : static_cast<int>(7u - bit_index % 8u);
                texels[static_cast<size_t>(row) * static_cast<size_t>(width) +
                       static_cast<size_t>(column)] = ((byte >> bit) & 1u) ? 0xFF : 0x00;
            }
        }
    }

    const auto& raster = g_glstate.fpe_uniform.raster_position;
    // No glPixelZoom here: a bitmap's fragments are one per bit (GL 2.1 3.7).
    drawQuad(texels.data(), width, height, GL_RED, GL_UNSIGNED_BYTE, raster.x - xorig,
             raster.y - yorig, static_cast<GLfloat>(width), static_cast<GLfloat>(height), raster.z,
             quad_mode_t::bitmap, g_glstate.fpe_uniform.raster_color);
}

bool preparePixelUnpackView(GLsizei width, GLsizei height, size_t pixel_bytes,
                            const GLvoid* pixels, pixel_unpack_view_t* out) {
    if (g_glFuncs.glGetIntegerv == nullptr) return false;

    GLint alignment = 4, row_length = 0, skip_rows = 0, skip_pixels = 0;
    g_glFuncs.glGetIntegerv(GL_UNPACK_ALIGNMENT, &alignment);
    g_glFuncs.glGetIntegerv(GL_UNPACK_ROW_LENGTH, &row_length);
    g_glFuncs.glGetIntegerv(GL_UNPACK_SKIP_ROWS, &skip_rows);
    g_glFuncs.glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &skip_pixels);
    if ((alignment != 1 && alignment != 2 && alignment != 4 && alignment != 8) ||
        row_length < 0 || skip_rows < 0 || skip_pixels < 0) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }

    const size_t row_pixels = row_length > 0 ? static_cast<size_t>(row_length)
                                             : static_cast<size_t>(width);
    size_t row_bytes = 0, padded_row_bytes = 0;
    if (!checkedPixelMultiply(row_pixels, pixel_bytes, &row_bytes) ||
        !checkedPixelAdd(row_bytes, static_cast<size_t>(alignment - 1), &padded_row_bytes)) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return false;
    }
    out->row_stride = padded_row_bytes & ~static_cast<size_t>(alignment - 1);

    size_t start = 0, last_row = 0, final_row_bytes = 0, needed = 0;
    if (!checkedPixelMultiply(static_cast<size_t>(skip_rows), out->row_stride, &start) ||
        !checkedPixelMultiply(static_cast<size_t>(skip_pixels), pixel_bytes, &final_row_bytes) ||
        !checkedPixelAdd(start, final_row_bytes, &start) ||
        !checkedPixelMultiply(static_cast<size_t>(height - 1), out->row_stride, &last_row) ||
        !checkedPixelMultiply(static_cast<size_t>(width), pixel_bytes, &final_row_bytes) ||
        !checkedPixelAdd(start, last_row, &needed) ||
        !checkedPixelAdd(needed, final_row_bytes, &needed)) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return false;
    }
    return mapPixelUnpackSource(pixels, start, needed, out);
}

// plans/17 P13: the compile-time bitmap, repacked into tight MSB-first rows
// of ceil(width/8) bytes. GL_UNPACK_SKIP_PIXELS counts BITS, so its sub-byte
// remainder has nowhere to live in a byte-granular tight copy and is shifted
// out here; GL_UNPACK_LSB_FIRST goes with it, being the same loop.
bool captureBitmapListPayload(GLsizei width, GLsizei height, const GLubyte* bitmap,
                              std::vector<uint8_t>* out) {
    bitmap_unpack_layout_t layout;
    if (!bitmapUnpackLayout(width, height, &layout)) return false;
    const size_t tight_stride = (static_cast<size_t>(width) + 7u) / 8u;
    try {
        out->assign(tight_stride * static_cast<size_t>(height), 0u);
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return false;
    }
    pixel_unpack_view_t source;
    if (!mapPixelUnpackSource(bitmap, layout.start, layout.extent, &source)) return false;
    const bool lsb_first = g_glstate.pixel_store_unpack_lsb_first;
    for (GLsizei row = 0; row < height; ++row) {
        const uint8_t* line = source.pixels + static_cast<size_t>(row) * layout.row_stride;
        uint8_t* destination = out->data() + static_cast<size_t>(row) * tight_stride;
        for (GLsizei column = 0; column < width; ++column) {
            const size_t bit_index = layout.bit_offset + static_cast<size_t>(column);
            const int bit = lsb_first ? static_cast<int>(bit_index % 8u)
                                      : static_cast<int>(7u - bit_index % 8u);
            if (((line[bit_index / 8u] >> bit) & 1u) != 0u) {
                destination[static_cast<size_t>(column) / 8u] |=
                    static_cast<uint8_t>(0x80u >> (static_cast<size_t>(column) % 8u));
            }
        }
    }
    return true;
}

float clampPixel(float value) {
    if (std::isnan(value)) return 0.0f;
    return std::clamp(value, 0.0f, 1.0f);
}

// defects-plan-2.md 2.5. GL_INDEX_SHIFT/GL_INDEX_OFFSET are deliberately
// not applied here - they belong to color-index mode, which state.cpp's
// glPixelTransfer already treats as a no-op project-wide (plans/10, 10.5;
// see defects-plan.md's §2 boundary note), and this inherits that same
// decision rather than special-casing stencil out of it. GL_PIXEL_MAP_S_TO_S
// (a real, separate feature from color-index mode) IS applied, since
// pixel_map_stencil/pixel_maps already exist and are otherwise unused.
void drawStencilPixels(GLsizei width, GLsizei height, GLenum type, const GLvoid* pixels) {
    // The six integer scalar types readPixelStencilIndex handles.
    // scalarPixelType() alone isn't a tight enough filter: it also accepts
    // GL_FLOAT/GL_HALF_FLOAT, which are not legal glDrawPixels(GL_STENCIL_
    // INDEX) types (GL 2.1 table 3.6). GL_BITMAP is a further, documented
    // scope cut - packedPixelType's formats are all color-component
    // packings with no stencil equivalent.
    size_t pixel_bytes = 0;
    if ((type != GL_BYTE && type != GL_UNSIGNED_BYTE && type != GL_SHORT &&
        type != GL_UNSIGNED_SHORT && type != GL_INT && type != GL_UNSIGNED_INT) ||
        !scalarPixelType(type, &pixel_bytes)) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    if (!g_glstate.fpe_uniform.raster_position_valid || width == 0 || height == 0) return;
    if (!sfpewEnsureBackend() || g_glFuncs.glTexImage2D == nullptr) return;

    size_t pixel_count = 0;
    if (!checkedPixelMultiply(static_cast<size_t>(width), static_cast<size_t>(height),
                              &pixel_count)) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return;
    }
    std::vector<GLubyte> stencil_bytes;
    try {
        stencil_bytes.resize(pixel_count);
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return;
    }

    const auto& un = g_glstate.fpe_uniform;
    const auto& map =
        g_glstate.pixel_maps[static_cast<size_t>(GL_PIXEL_MAP_S_TO_S - GL_PIXEL_MAP_I_TO_I)];
    {
        pixel_unpack_view_t source;
        if (!preparePixelUnpackView(width, height, pixel_bytes, pixels, &source)) return;
        const bool swap_bytes = g_glstate.pixel_store_unpack_swap_bytes;
        for (GLsizei row = 0; row < height; ++row) {
            const uint8_t* line = source.pixels + static_cast<size_t>(row) * source.row_stride;
            for (GLsizei column = 0; column < width; ++column) {
                const size_t pixel = static_cast<size_t>(row) * static_cast<size_t>(width) +
                                     static_cast<size_t>(column);
                uint32_t index = 0;
                readPixelStencilIndex(line + static_cast<size_t>(column) * pixel_bytes, type,
                                      swap_bytes, &index);
                if (un.pixel_map_stencil && !map.empty()) {
                    index = static_cast<uint32_t>(map[index & (map.size() - 1)]);
                }
                stencil_bytes[pixel] = static_cast<GLubyte>(index & 0xFFu);
            }
        }
    }

    const auto& raster = un.raster_position;
    drawStencilBitplanes(stencil_bytes.data(), width, height, raster.x, raster.y,
                         static_cast<GLfloat>(width) * un.pixel_zoom_x,
                         static_cast<GLfloat>(height) * un.pixel_zoom_y, raster.z);
}

} // namespace

// --- Display-list capture of pixel rectangles (init.h documents the rule) --

namespace {

// Bytes one pixel of this format/type pair occupies in client memory. Wider
// than describePixelFormat/describePixelType above, which answer for
// glDrawPixels alone: a texture upload also takes GL_RG, the integer formats
// and the combined depth/stencil types.
bool pixelPayloadStride(GLenum format, GLenum type, size_t* bytes) {
    // A packed type describes a whole pixel, so the format contributes
    // nothing to its size; whether the two agree on the field count is each
    // entry point's own validation.
    switch (type) {
    case GL_UNSIGNED_BYTE_3_3_2:
    case GL_UNSIGNED_BYTE_2_3_3_REV:
        *bytes = 1;
        return true;
    case GL_UNSIGNED_SHORT_5_6_5:
    case GL_UNSIGNED_SHORT_5_6_5_REV:
    case GL_UNSIGNED_SHORT_4_4_4_4:
    case GL_UNSIGNED_SHORT_4_4_4_4_REV:
    case GL_UNSIGNED_SHORT_5_5_5_1:
    case GL_UNSIGNED_SHORT_1_5_5_5_REV:
        *bytes = 2;
        return true;
    case GL_UNSIGNED_INT_8_8_8_8:
    case GL_UNSIGNED_INT_8_8_8_8_REV:
    case GL_UNSIGNED_INT_10_10_10_2:
    case GL_UNSIGNED_INT_2_10_10_10_REV:
    case GL_UNSIGNED_INT_24_8:
    case GL_UNSIGNED_INT_10F_11F_11F_REV:
    case GL_UNSIGNED_INT_5_9_9_9_REV:
        *bytes = 4;
        return true;
    case GL_FLOAT_32_UNSIGNED_INT_24_8_REV:
        *bytes = 8;
        return true;
    default:
        break;
    }
    size_t scalar = 0;
    switch (type) {
    case GL_BYTE:
    case GL_UNSIGNED_BYTE:
        scalar = 1;
        break;
    case GL_SHORT:
    case GL_UNSIGNED_SHORT:
    case GL_HALF_FLOAT:
        scalar = 2;
        break;
    case GL_INT:
    case GL_UNSIGNED_INT:
    case GL_FLOAT:
        scalar = 4;
        break;
    default:
        return false;
    }
    size_t components = 0;
    switch (format) {
    case GL_RED:
    case GL_GREEN:
    case GL_BLUE:
    case GL_ALPHA:
    case GL_LUMINANCE:
    case GL_INTENSITY:
    case GL_DEPTH_COMPONENT:
    case GL_STENCIL_INDEX:
    case GL_RED_INTEGER:
    case GL_ALPHA_INTEGER:
        components = 1;
        break;
    case GL_RG:
    case GL_RG_INTEGER:
    case GL_LUMINANCE_ALPHA:
        components = 2;
        break;
    case GL_RGB:
    case GL_BGR:
    case GL_RGB_INTEGER:
    case GL_BGR_INTEGER:
        components = 3;
        break;
    case GL_RGBA:
    case GL_BGRA:
    case GL_RGBA_INTEGER:
    case GL_BGRA_INTEGER:
        components = 4;
        break;
    default:
        return false;
    }
    *bytes = scalar * components;
    return true;
}

} // namespace

bool sfpewCaptureListPixelPayload(GLsizei width, GLsizei height, size_t pixel_bytes,
                                  const GLvoid* pixels, std::vector<uint8_t>* out) {
    out->clear();
    if (width <= 0 || height <= 0 || pixel_bytes == 0) return true;
    // A null pointer with no unpack buffer bound is an allocation with no
    // image, not a rectangle that failed to read.
    if (pixels == nullptr && !sfpewUnpackPboBound()) return true;
    size_t row_bytes = 0, total = 0;
    if (!checkedPixelMultiply(static_cast<size_t>(width), pixel_bytes, &row_bytes) ||
        !checkedPixelMultiply(row_bytes, static_cast<size_t>(height), &total)) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return false;
    }
    pixel_unpack_view_t source;
    if (!preparePixelUnpackView(width, height, pixel_bytes, pixels, &source)) return false;
    try {
        out->resize(total);
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return false;
    }
    for (GLsizei row = 0; row < height; ++row) {
        std::memcpy(out->data() + static_cast<size_t>(row) * row_bytes,
                    source.pixels + static_cast<size_t>(row) * source.row_stride, row_bytes);
    }
    return true;
}

bool sfpewCaptureListPixelUpload(const char* entry, GLsizei width, GLsizei height, GLenum format,
                                 GLenum type, const GLvoid* pixels, std::vector<uint8_t>* out) {
    out->clear();
    size_t pixel_bytes = 0;
    if (!pixelPayloadStride(format, type, &pixel_bytes)) {
        SFPEW_LOGW("%s: format 0x%x with type 0x%x has no known client-memory size; the call is "
                   "not compiled into the display list", entry, format, type);
        return false;
    }
    return sfpewCaptureListPixelPayload(width, height, pixel_bytes, pixels, out);
}

sfpew_list_unpack_replay_t::sfpew_list_unpack_replay_t(bool swap_bytes, bool lsb_first) {
    if (!sfpewEnsureBackend() || g_glFuncs.glGetIntegerv == nullptr ||
        g_glFuncs.glPixelStorei == nullptr || g_glFuncs.glBindBuffer == nullptr) {
        return;
    }
    g_glFuncs.glGetIntegerv(GL_UNPACK_ALIGNMENT, &alignment_);
    g_glFuncs.glGetIntegerv(GL_UNPACK_ROW_LENGTH, &row_length_);
    g_glFuncs.glGetIntegerv(GL_UNPACK_SKIP_ROWS, &skip_rows_);
    g_glFuncs.glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &skip_pixels_);
    g_glFuncs.glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pbo_);
    swap_bytes_ = g_glstate.pixel_store_unpack_swap_bytes;
    lsb_first_ = g_glstate.pixel_store_unpack_lsb_first;
    if (pbo_ != 0) g_glFuncs.glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    g_glFuncs.glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    g_glFuncs.glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    g_glFuncs.glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
    g_glFuncs.glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
    g_glstate.pixel_store_unpack_swap_bytes = swap_bytes;
    g_glstate.pixel_store_unpack_lsb_first = lsb_first;
    active_ = true;
}

sfpew_list_unpack_replay_t::~sfpew_list_unpack_replay_t() {
    if (!active_) return;
    g_glFuncs.glPixelStorei(GL_UNPACK_ALIGNMENT, alignment_);
    g_glFuncs.glPixelStorei(GL_UNPACK_ROW_LENGTH, row_length_);
    g_glFuncs.glPixelStorei(GL_UNPACK_SKIP_ROWS, skip_rows_);
    g_glFuncs.glPixelStorei(GL_UNPACK_SKIP_PIXELS, skip_pixels_);
    g_glstate.pixel_store_unpack_swap_bytes = swap_bytes_;
    g_glstate.pixel_store_unpack_lsb_first = lsb_first_;
    if (pbo_ != 0) g_glFuncs.glBindBuffer(GL_PIXEL_UNPACK_BUFFER, static_cast<GLuint>(pbo_));
}

namespace {

// The compiled form of glDrawPixels: its payload is already tight, so the
// unpack state the app happens to have at glCallList must not reach it.
void replayDrawPixels(GLsizei width, GLsizei height, GLenum format, GLenum type,
                      GLboolean swap_bytes, const GLvoid* pixels) {
    sfpew_list_unpack_replay_t unpack(swap_bytes != GL_FALSE, false);
    SELF_CALL(glDrawPixels, width, height, format, type, pixels)
}

} // namespace

void glDrawPixels(GLsizei width, GLsizei height, GLenum format, GLenum type, const GLvoid* pixels) {
    sfpewEntryBarrier();
    if (width < 0 || height < 0) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    pixel_format_info_t format_info;
    if (!describePixelFormat(format, &format_info)) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    size_t pixel_bytes = 0;
    if (!describePixelType(format, format_info, type, &pixel_bytes)) {
        if (g_glstate.first_error == GL_NO_ERROR)
            g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    // plans/17 P15. Ahead of the raster-position and zero-area tests below:
    // both are execution-time conditions, and a rectangle whose raster
    // position is invalid while the list compiles must still be compiled.
    if (!disableRecording && DisplayListManager::shouldRecord()) {
        std::vector<uint8_t> payload;
        if (sfpewCaptureListPixelPayload(width, height, pixel_bytes, pixels, &payload)) {
            displayListManager.record<replayDrawPixels>(
                {{5, payload.size()}}, width, height, format, type,
                static_cast<GLboolean>(g_glstate.pixel_store_unpack_swap_bytes ? GL_TRUE
                                                                              : GL_FALSE),
                payload.empty() ? nullptr : static_cast<const GLvoid*>(payload.data()));
        }
        if (DisplayListManager::shouldFinish()) return;
    }
    if (format_info.stencil) {
        // defects-plan-2.md 2.5: a 16-pass (2 per bit) bit-plane stencil
        // write - see drawStencilBitplanes for why one pass per bit isn't
        // enough (no per-fragment stencil-export on either backend floor).
        drawStencilPixels(width, height, type, pixels);
        return;
    }
    if (!g_glstate.fpe_uniform.raster_position_valid || width == 0 || height == 0) return;
    if (!sfpewEnsureBackend() || g_glFuncs.glTexImage2D == nullptr) return;

    size_t pixel_count = 0, rgba_count = 0;
    if (!checkedPixelMultiply(static_cast<size_t>(width), static_cast<size_t>(height),
                              &pixel_count) ||
        (!format_info.depth && !checkedPixelMultiply(pixel_count, 4u, &rgba_count))) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return;
    }

    const auto& un = g_glstate.fpe_uniform;
    const bool imaging = !format_info.depth && sfpewImagingActive();
    const bool float_output = format_info.depth || type == GL_FLOAT || type == GL_HALF_FLOAT || imaging;
    std::vector<GLfloat> float_pixels;
    std::vector<GLubyte> byte_pixels;
    try {
        if (float_output)
            float_pixels.resize(format_info.depth ? pixel_count : rgba_count);
        else
            byte_pixels.resize(rgba_count);
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return;
    }

    {
        pixel_unpack_view_t source;
        if (!preparePixelUnpackView(width, height, pixel_bytes, pixels, &source)) return;
        const bool swap_bytes = g_glstate.pixel_store_unpack_swap_bytes;
        for (GLsizei row = 0; row < height; ++row) {
            const uint8_t* line = source.pixels + static_cast<size_t>(row) * source.row_stride;
            for (GLsizei column = 0; column < width; ++column) {
                const size_t pixel = static_cast<size_t>(row) * static_cast<size_t>(width) +
                                     static_cast<size_t>(column);
                glm::vec4 value = decodePixel(line + static_cast<size_t>(column) * pixel_bytes,
                                              format, type, format_info, swap_bytes);
                if (format_info.depth) {
                    float_pixels[pixel] =
                        clampPixel(value.r * un.pixel_scale[4] + un.pixel_bias[4]);
                    continue;
                }
                for (int channel = 0; channel < 4; ++channel) {
                    float transferred =
                        clampPixel(value[channel] * un.pixel_scale[channel] + un.pixel_bias[channel]);
                    if (un.pixel_map_color) {
                        const auto& map = g_glstate.pixel_maps[
                            static_cast<size_t>(GL_PIXEL_MAP_R_TO_R - GL_PIXEL_MAP_I_TO_I) +
                            static_cast<size_t>(channel)];
                        const size_t map_index = std::min(
                            static_cast<size_t>(std::floor(transferred * map.size())),
                            map.size() - 1u);
                        transferred = map[map_index];
                    }
                    if (float_output)
                        float_pixels[pixel * 4u + static_cast<size_t>(channel)] = transferred;
                    else
                        byte_pixels[pixel * 4u + static_cast<size_t>(channel)] =
                            static_cast<GLubyte>(transferred * 255.0f + 0.5f);
                }
            }
        }
    }

    GLsizei output_width = width, output_height = height;
    if (imaging) {
        sfpewImagingTransfer(float_pixels.data(), &output_width, &output_height);
        if (sfpewImagingSink()) return;
    }
    const auto& raster = un.raster_position;
    const void* upload = float_output ? static_cast<const void*>(float_pixels.data())
                                      : static_cast<const void*>(byte_pixels.data());
    const GLenum upload_format = format_info.depth ? GL_RED : GL_RGBA;
    const GLenum upload_type = float_output ? GL_FLOAT : GL_UNSIGNED_BYTE;
    drawQuad(upload, output_width, output_height, upload_format, upload_type, raster.x, raster.y,
             output_width * un.pixel_zoom_x, output_height * un.pixel_zoom_y, raster.z,
             format_info.depth ? quad_mode_t::depth : quad_mode_t::color, glm::vec4(1.0f));
}

namespace {

struct framebuffer_plane_t {
    bool present = false;
    GLint object_type = GL_NONE;
    GLint object_name = 0;
    GLint bits = 0;
    GLint component_type = 0;
};

GLenum framebufferPlaneAttachment(GLint framebuffer, GLenum type) {
    if (framebuffer == 0) return type == GL_DEPTH ? GL_DEPTH : GL_STENCIL;
    return type == GL_DEPTH ? GL_DEPTH_ATTACHMENT : GL_STENCIL_ATTACHMENT;
}

bool queryFramebufferPlane(GLenum target, GLint framebuffer, GLenum type,
                           framebuffer_plane_t* out) {
    if (g_glFuncs.glGetFramebufferAttachmentParameteriv == nullptr) return false;
    const GLenum attachment = framebufferPlaneAttachment(framebuffer, type);
    g_glFuncs.glGetFramebufferAttachmentParameteriv(
        target, attachment, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &out->object_type);
    if (out->object_type == GL_NONE) return true;
    if (framebuffer != 0) {
        g_glFuncs.glGetFramebufferAttachmentParameteriv(
            target, attachment, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &out->object_name);
    }
    g_glFuncs.glGetFramebufferAttachmentParameteriv(
        target, attachment,
        type == GL_DEPTH ? GL_FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE
                         : GL_FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE,
        &out->bits);
    g_glFuncs.glGetFramebufferAttachmentParameteriv(
        target, attachment, GL_FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE, &out->component_type);
    out->present = out->bits > 0;
    return true;
}

bool planesShareStorage(GLint framebuffer, const framebuffer_plane_t& depth,
                        const framebuffer_plane_t& stencil) {
    if (!depth.present || !stencil.present || depth.object_type != stencil.object_type) return false;
    if (framebuffer == 0) return true;
    return depth.object_name != 0 && depth.object_name == stencil.object_name;
}

GLenum scratchPlaneFormat(GLenum type, GLint framebuffer, const framebuffer_plane_t& requested,
                          const framebuffer_plane_t& other) {
    const framebuffer_plane_t& depth = type == GL_DEPTH ? requested : other;
    const framebuffer_plane_t& stencil = type == GL_STENCIL ? requested : other;
    if (planesShareStorage(framebuffer, depth, stencil)) {
        return depth.component_type == GL_FLOAT ? GL_DEPTH32F_STENCIL8
                                                : GL_DEPTH24_STENCIL8;
    }
    if (type == GL_STENCIL) return requested.bits <= 8 ? GL_STENCIL_INDEX8 : GL_NONE;
    if (requested.bits <= 16) return GL_DEPTH_COMPONENT16;
    if (requested.bits <= 24) return GL_DEPTH_COMPONENT24;
    // >24 bits and not float would otherwise fall to the legacy, non-float
    // GL_DEPTH_COMPONENT32 (0x81A7) - never a valid GLES3 sized internal
    // format (its renderbuffer/texture tables only have 16/24/32F) and not
    // in desktop GL4's core-required table either. This return value feeds
    // straight into ensureCopyPixelsScratch's raw g_glFuncs.glRenderbufferStorage
    // call below, bypassing fbo.cpp's own glRenderbufferStorage wrapper -
    // which already remaps this exact enum to GL_DEPTH_COMPONENT32F for the
    // same reason. 32F is a safe, universally valid choice for this ">24
    // bits" bucket regardless of the source plane's own component type.
    return GL_DEPTH_COMPONENT32F;
}

struct copy_pixels_scratch_t {
    GLuint fbo = 0;
    GLuint renderbuffer = 0;
    GLsizei width = 0;
    GLsizei height = 0;
    GLint samples = 0;
    GLenum internal_format = GL_NONE;
};

struct copy_pixels_scratch_cache_t {
    EGLContext context = EGL_NO_CONTEXT;
    copy_pixels_scratch_t scratch{};
};

copy_pixels_scratch_t& copyPixelsScratch() {
    // A raw pointer behind a lazy heap allocation, not the cache struct
    // directly: this library is always reached via dlopen (the test harness
    // here, and the MobileGlues plugin path on Android), where a dlopen'd
    // module's static TLS block is a small, fixed-size reservation that this
    // struct's bytes would otherwise sit in for no benefit.
    static thread_local copy_pixels_scratch_cache_t* instance = nullptr;
    if (instance == nullptr) instance = new copy_pixels_scratch_cache_t();
    auto& cache = *instance;
    const EGLContext current = sfpewCurrentContext();
    if (cache.context != current) {
        cache.context = current;
        cache.scratch = {};
    }
    return cache.scratch;
}

bool ensureCopyPixelsScratch(copy_pixels_scratch_t& scratch, GLsizei width, GLsizei height,
                             GLint samples, GLenum internal_format) {
    if (g_glFuncs.glGenFramebuffers == nullptr || g_glFuncs.glGenRenderbuffers == nullptr ||
        g_glFuncs.glBindRenderbuffer == nullptr || g_glFuncs.glRenderbufferStorage == nullptr ||
        g_glFuncs.glFramebufferRenderbuffer == nullptr ||
        g_glFuncs.glCheckFramebufferStatus == nullptr || g_glFuncs.glDrawBuffers == nullptr ||
        g_glFuncs.glReadBuffer == nullptr) {
        return false;
    }
    if (scratch.fbo == 0) g_glFuncs.glGenFramebuffers(1, &scratch.fbo);
    if (scratch.renderbuffer == 0) g_glFuncs.glGenRenderbuffers(1, &scratch.renderbuffer);
    if (scratch.fbo == 0 || scratch.renderbuffer == 0) return false;

    const bool resized = scratch.width != width || scratch.height != height ||
                         scratch.samples != samples || scratch.internal_format != internal_format;
    g_glFuncs.glBindRenderbuffer(GL_RENDERBUFFER, scratch.renderbuffer);
    if (resized) {
        if (samples > 0) {
            if (g_glFuncs.glRenderbufferStorageMultisample == nullptr) return false;
            g_glFuncs.glRenderbufferStorageMultisample(GL_RENDERBUFFER, samples, internal_format,
                                                       width, height);
        } else {
            g_glFuncs.glRenderbufferStorage(GL_RENDERBUFFER, internal_format, width, height);
        }
    }

    g_glFuncs.glBindFramebuffer(GL_FRAMEBUFFER, scratch.fbo);
    g_glFuncs.glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, 0);
    g_glFuncs.glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, 0);
    g_glFuncs.glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER,
                                        0);
    if (internal_format == GL_STENCIL_INDEX8) {
        g_glFuncs.glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER,
                                            scratch.renderbuffer);
    } else if (internal_format == GL_DEPTH24_STENCIL8 ||
               internal_format == GL_DEPTH32F_STENCIL8) {
        g_glFuncs.glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT,
                                            GL_RENDERBUFFER, scratch.renderbuffer);
    } else {
        g_glFuncs.glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER,
                                            scratch.renderbuffer);
    }
    const GLenum none = GL_NONE;
    g_glFuncs.glDrawBuffers(1, &none);
    g_glFuncs.glReadBuffer(GL_NONE);
    if (g_glFuncs.glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return false;
    if (resized) {
        scratch.width = width;
        scratch.height = height;
        scratch.samples = samples;
        scratch.internal_format = internal_format;
    }
    return true;
}

struct copy_pixels_backend_guard_t {
    GLint read_fbo = 0;
    GLint draw_fbo = 0;
    GLint renderbuffer = 0;
    bool scissor = false;

    copy_pixels_backend_guard_t() {
        g_glFuncs.glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read_fbo);
        g_glFuncs.glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw_fbo);
        g_glFuncs.glGetIntegerv(GL_RENDERBUFFER_BINDING, &renderbuffer);
        scissor = g_glFuncs.glIsEnabled != nullptr &&
                  g_glFuncs.glIsEnabled(GL_SCISSOR_TEST) == GL_TRUE;
    }

    ~copy_pixels_backend_guard_t() {
        g_glFuncs.glBindFramebuffer(GL_READ_FRAMEBUFFER, static_cast<GLuint>(read_fbo));
        g_glFuncs.glBindFramebuffer(GL_DRAW_FRAMEBUFFER, static_cast<GLuint>(draw_fbo));
        g_glFuncs.glBindRenderbuffer(GL_RENDERBUFFER, static_cast<GLuint>(renderbuffer));
        if (scissor)
            g_glFuncs.glEnable(GL_SCISSOR_TEST);
        else
            g_glFuncs.glDisable(GL_SCISSOR_TEST);
    }
};

// defects-plan-3.md: glCopyPixels(GL_STENCIL) + GL_MAP_STENCIL. Raw index
// bytes read straight off the framebuffer - like drawStencilPixels above,
// the S_TO_S map stores and looks up raw index values directly, no
// normalization. GL_INDEX_SHIFT/GL_INDEX_OFFSET stay unapplied, same
// project-wide color-index-mode boundary drawStencilPixels documents.
bool readStencilIndices(GLint x, GLint y, GLsizei width, GLsizei height,
                        std::vector<GLubyte>* out) {
    if (!sfpewEnsureBackend() || g_glFuncs.glReadPixels == nullptr ||
        g_glFuncs.glGetIntegerv == nullptr || g_glFuncs.glPixelStorei == nullptr ||
        g_glFuncs.glBindBuffer == nullptr || width <= 0 || height <= 0) {
        return false;
    }
    try {
        out->resize(static_cast<size_t>(width) * static_cast<size_t>(height));
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return false;
    }
    // `out` is our own tightly packed buffer, not the caller's: neutralize
    // GL_PACK_* state and any bound pack PBO around the backend call (see
    // imaging.cpp's readFramebuffer/sfpewReadTransformedDepth for the same
    // pattern), then restore both.
    GLint alignment = 4, row_length = 0, skip_rows = 0, skip_pixels = 0, pbo = 0;
    g_glFuncs.glGetIntegerv(GL_PACK_ALIGNMENT, &alignment);
    g_glFuncs.glGetIntegerv(GL_PACK_ROW_LENGTH, &row_length);
    g_glFuncs.glGetIntegerv(GL_PACK_SKIP_ROWS, &skip_rows);
    g_glFuncs.glGetIntegerv(GL_PACK_SKIP_PIXELS, &skip_pixels);
    g_glFuncs.glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &pbo);
    if (pbo != 0) g_glFuncs.glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    g_glFuncs.glPixelStorei(GL_PACK_ALIGNMENT, 1);
    g_glFuncs.glPixelStorei(GL_PACK_ROW_LENGTH, 0);
    g_glFuncs.glPixelStorei(GL_PACK_SKIP_ROWS, 0);
    g_glFuncs.glPixelStorei(GL_PACK_SKIP_PIXELS, 0);
    g_glFuncs.glReadPixels(x, y, width, height, GL_STENCIL_INDEX, GL_UNSIGNED_BYTE, out->data());
    // A backend that rejects this raw read (some do, for GL_DEPTH_COMPONENT
    // at least - see imaging.cpp's sfpewReadTransformedDepth) must not leak
    // its own error into the caller's next glGetError().
    drainFailedMapError();
    g_glFuncs.glPixelStorei(GL_PACK_ALIGNMENT, alignment);
    g_glFuncs.glPixelStorei(GL_PACK_ROW_LENGTH, row_length);
    g_glFuncs.glPixelStorei(GL_PACK_SKIP_ROWS, skip_rows);
    g_glFuncs.glPixelStorei(GL_PACK_SKIP_PIXELS, skip_pixels);
    if (pbo != 0) g_glFuncs.glBindBuffer(GL_PIXEL_PACK_BUFFER, static_cast<GLuint>(pbo));
    return true;
}

bool sfpewStencilPixelTransferActive() {
    if (!g_glstate.fpe_uniform.pixel_map_stencil) return false;
    const auto& map =
        g_glstate.pixel_maps[static_cast<size_t>(GL_PIXEL_MAP_S_TO_S - GL_PIXEL_MAP_I_TO_I)];
    return !map.empty();
}

} // namespace

void glCopyPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum type) {
    sfpewEntryBarrier();
    if (width < 0 || height < 0) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    if (type != GL_COLOR && type != GL_DEPTH && type != GL_STENCIL) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    // plans/17 P15. No payload to snapshot - the source is the framebuffer as
    // it stands at execution time - so this is a plain argument recording,
    // taken before the execution-time conditions below the way its
    // glCopyTexImage2D sibling is.
    LIST_RECORD(glCopyPixels, {}, x, y, width, height, type)
    if (!g_glstate.fpe_uniform.raster_position_valid || width == 0 || height == 0 ||
        !sfpewEnsureBackend() || g_glFuncs.glBlitFramebuffer == nullptr) {
        return;
    }
    const auto& un = g_glstate.fpe_uniform;
    const GLint dx0 = (GLint)un.raster_position.x;
    const GLint dy0 = (GLint)un.raster_position.y;
    const GLint dx1 = dx0 + (GLint)(width * un.pixel_zoom_x);
    const GLint dy1 = dy0 + (GLint)(height * un.pixel_zoom_y);
    const GLbitfield mask = type == GL_COLOR     ? GL_COLOR_BUFFER_BIT
                            : type == GL_DEPTH   ? GL_DEPTH_BUFFER_BIT
                                                : GL_STENCIL_BUFFER_BIT;

    // defects-plan-3.md: full GL 2.1 3.6.3 pixel transfer for GL_COLOR
    // (scale/bias/map, then whatever ARB_imaging stages are active -
    // sfpewFullColorReadRgba returns false, unchanged fast path below,
    // whenever neither is active); GL_DEPTH_SCALE/BIAS for GL_DEPTH;
    // GL_MAP_STENCIL for GL_STENCIL. Each new branch reads fully into a CPU
    // buffer before writing anything to the destination, so - unlike the
    // blit path below - it is inherently safe when source and destination
    // overlap in the same framebuffer, with no separate scratch-FBO copy
    // needed.
    //
    // Same-framebuffer color copies force this path even with no transfer
    // active: GLES's glBlitFramebuffer refuses "if the source and
    // destination buffers are identical" (no desktop-GL equivalent, and -
    // unlike the depth/stencil overlap check below - no rectangle-overlap
    // exemption either), so the fast blit at the bottom of this function
    // is simply never legal on GLES when read_fbo == draw_fbo, whatever
    // the two rectangles are.
    if (type == GL_COLOR) {
        GLint read_fbo = 0, draw_fbo = 0;
        g_glFuncs.glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read_fbo);
        g_glFuncs.glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw_fbo);
        const bool same_buffer = read_fbo == draw_fbo;
        std::vector<GLfloat> rgba;
        GLsizei output_width = width, output_height = height;
        if (sfpewFullColorReadRgba(x, y, width, height, &rgba, &output_width, &output_height,
                                   same_buffer)) {
            if (sfpewImagingSink() || rgba.empty()) return;
            drawQuad(rgba.data(), output_width, output_height, GL_RGBA, GL_FLOAT,
                     un.raster_position.x, un.raster_position.y,
                     output_width * un.pixel_zoom_x, output_height * un.pixel_zoom_y,
                     un.raster_position.z, quad_mode_t::color, glm::vec4(1.0f));
            return;
        }
    }
    if ((type == GL_DEPTH && sfpewDepthPixelTransferActive()) ||
        (type == GL_STENCIL && sfpewStencilPixelTransferActive())) {
        // Same presence contract as the blit path below: a plane missing on
        // either end is GL_INVALID_OPERATION, not a silent no-op reading
        // garbage off a nonexistent attachment.
        GLint read_fbo = 0, draw_fbo = 0;
        g_glFuncs.glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read_fbo);
        g_glFuncs.glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw_fbo);
        framebuffer_plane_t source_plane, destination_plane;
        if (!queryFramebufferPlane(GL_READ_FRAMEBUFFER, read_fbo, type, &source_plane) ||
            !queryFramebufferPlane(GL_DRAW_FRAMEBUFFER, draw_fbo, type, &destination_plane) ||
            !source_plane.present || !destination_plane.present) {
            g_glstate.set_error(GL_INVALID_OPERATION);
            return;
        }
        if (type == GL_DEPTH) {
            std::vector<GLfloat> depth;
            if (!sfpewReadTransformedDepth(x, y, width, height, &depth)) return;
            drawQuad(depth.data(), width, height, GL_RED, GL_FLOAT, un.raster_position.x,
                     un.raster_position.y, width * un.pixel_zoom_x, height * un.pixel_zoom_y,
                     un.raster_position.z, quad_mode_t::depth, glm::vec4(1.0f));
        } else {
            std::vector<GLubyte> indices;
            if (!readStencilIndices(x, y, width, height, &indices)) return;
            const auto& map =
                g_glstate.pixel_maps[static_cast<size_t>(GL_PIXEL_MAP_S_TO_S - GL_PIXEL_MAP_I_TO_I)];
            for (auto& index : indices)
                index = static_cast<GLubyte>(static_cast<uint32_t>(map[index & (map.size() - 1)]) &
                                             0xFFu);
            drawStencilBitplanes(indices.data(), width, height, un.raster_position.x,
                                 un.raster_position.y, width * un.pixel_zoom_x,
                                 height * un.pixel_zoom_y, un.raster_position.z);
        }
        return;
    }

    copy_pixels_backend_guard_t backend;
    if (type != GL_COLOR) {
        framebuffer_plane_t source_plane, source_other, destination_plane;
        const GLenum other_type = type == GL_DEPTH ? GL_STENCIL : GL_DEPTH;
        if (!queryFramebufferPlane(GL_READ_FRAMEBUFFER, backend.read_fbo, type, &source_plane) ||
            !queryFramebufferPlane(GL_READ_FRAMEBUFFER, backend.read_fbo, other_type,
                                   &source_other) ||
            !queryFramebufferPlane(GL_DRAW_FRAMEBUFFER, backend.draw_fbo, type,
                                   &destination_plane) ||
            !source_plane.present || !destination_plane.present) {
            g_glstate.set_error(GL_INVALID_OPERATION);
            return;
        }

        // GLES's glBlitFramebuffer: "GL_INVALID_OPERATION is generated if
        // the source and destination buffers are identical" - no desktop-GL
        // equivalent, and (checked directly against the spec text) no
        // rectangle-overlap exemption either, so this triggers the scratch-
        // FBO intermediate whenever the two framebuffers match, regardless
        // of whether x/y/width/height and dx0/dy0/dx1/dy1 overlap.
        const bool same_buffer = backend.read_fbo == backend.draw_fbo;
        if (same_buffer) {
            GLint samples = 0;
            g_glFuncs.glGetIntegerv(GL_SAMPLES, &samples);
            const GLenum internal_format =
                scratchPlaneFormat(type, backend.read_fbo, source_plane, source_other);
            auto& scratch = copyPixelsScratch();
            if (internal_format == GL_NONE ||
                !ensureCopyPixelsScratch(scratch, width, height, samples, internal_format)) {
                g_glstate.set_error(GL_INVALID_OPERATION);
                return;
            }

            // The caller's scissor belongs to the destination pixel
            // operation. It must not clip the intermediate source snapshot.
            if (backend.scissor) g_glFuncs.glDisable(GL_SCISSOR_TEST);
            g_glFuncs.glBindFramebuffer(GL_READ_FRAMEBUFFER,
                                        static_cast<GLuint>(backend.read_fbo));
            g_glFuncs.glBindFramebuffer(GL_DRAW_FRAMEBUFFER, scratch.fbo);
            g_glFuncs.glBlitFramebuffer(x, y, x + width, y + height, 0, 0, width, height, mask,
                                        GL_NEAREST);

            g_glFuncs.glBindFramebuffer(GL_READ_FRAMEBUFFER, scratch.fbo);
            g_glFuncs.glBindFramebuffer(GL_DRAW_FRAMEBUFFER,
                                        static_cast<GLuint>(backend.draw_fbo));
            if (backend.scissor) g_glFuncs.glEnable(GL_SCISSOR_TEST);
            g_glFuncs.glBlitFramebuffer(0, 0, width, height, dx0, dy0, dx1, dy1, mask,
                                        GL_NEAREST);
            return;
        }
    }

    g_glFuncs.glBlitFramebuffer(x, y, x + width, y + height, dx0, dy0, dx1, dy1, mask,
                                GL_NEAREST);
}
