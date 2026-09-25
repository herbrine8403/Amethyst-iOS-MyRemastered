// SimpleFPEWrapper - SimpleFPEWrapper/fpe/linestipple.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

// defects-plan.md 1.5: glLineStipple had exact state and queries but no
// rasterization consumer at all. Neither backend floor has a
// fixed-function stipple test (removed from core GL 3.1+, never in ES), so
// this emulates it with a screen-space "distance along the line since the
// last reset" value computed per vertex on the CPU and tested per fragment
// in a small, dedicated shader (outside the FPE program cache, the same
// pattern pixelops.cpp's quad drawer uses) rather than folding it into the
// generated fixed-function uber-shader.
//
// Scope, deliberately: the immediate-mode path only (glBegin(GL_LINES /
// GL_LINE_STRIP / GL_LINE_LOOP) ... glEnd()) - the historically dominant
// use of this legacy feature (debug grids, wireframe helpers) and the one
// place the wrapper already has the fully assembled per-vertex float
// stream on the CPU before upload. Vertex-array-sourced stippled lines
// (glDrawArrays/glDrawElements with GL_LINE_STIPPLE enabled) are a known,
// undone gap - they still draw solid. Lighting, texturing and fog are not
// applied to stippled lines either: real GL_LINE_STIPPLE usage is
// overwhelmingly simple flat-colored debug/UI lines, and folding this into
// the uber-shader generator to cover the rare lit/textured stippled line
// would cost much more risk than the case is worth.
//
// The GL 2.1 stipple counter (spec 3.4.2) is reset at the start of each
// line SEGMENT for GL_LINES (independent pairs) but is continuous across
// an entire GL_LINE_STRIP/GL_LINE_LOOP. This emulation matches that:
// GL_LINES gets a fresh distance=0 at every even vertex; GL_LINE_STRIP
// accumulates distance from vertex 0 to the end; GL_LINE_LOOP accumulates
// the same way and additionally appends one extra vertex (a copy of vertex
// 0, carrying the total loop length) so the closing segment's pattern
// continues forward instead of interpolating backward to distance 0 - the
// draw call itself becomes GL_LINE_STRIP with vertexCount+1 vertices, which
// is the same rasterized shape a GL_LINE_LOOP of vertexCount vertices
// produces.

#include "fpe.hpp"
#include "drawing1x.h"
#include "../log.h"

#include <cmath>
#include <cstddef>
#include <vector>

namespace {

constexpr char kStippleVS[] = "#version 300 es\n"
                              "precision highp float;\n"
                              "layout(location = 0) in vec4 aClipPos;\n"
                              "layout(location = 1) in vec4 aColor;\n"
                              "layout(location = 2) in float aDistance;\n"
                              "out vec4 vColor;\n"
                              "out float vDistance;\n"
                              "void main() {\n"
                              "    gl_Position = aClipPos;\n"
                              "    vColor = aColor;\n"
                              "    vDistance = aDistance;\n"
                              "}\n";

constexpr char kStippleFS[] = "#version 300 es\n"
                              "precision highp float;\n"
                              "in vec4 vColor;\n"
                              "in float vDistance;\n"
                              "uniform float uFactor;\n"
                              "uniform uint uPattern;\n"
                              "out vec4 FragColor;\n"
                              "void main() {\n"
                              "    uint bitIndex = uint(vDistance / uFactor) & 15u;\n"
                              "    if (((uPattern >> bitIndex) & 1u) == 0u) discard;\n"
                              "    FragColor = vColor;\n"
                              "}\n";

struct stipple_drawer_t {
    GLuint program = 0;
    GLuint vao = 0;
    GLuint vbo = 0;
    GLint loc_factor = -1, loc_pattern = -1;
    bool init_failed = false;
};

// Per-context: GL object names are context-scoped, same reasoning as
// pixelops.cpp's quad drawer cache.
stipple_drawer_t& drawer() {
    static thread_local struct {
        EGLContext context = EGL_NO_CONTEXT;
        stipple_drawer_t d{};
    } cache;
    const EGLContext current = sfpewCurrentContext();
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
        SFPEW_LOGE("line-stipple shader failed: %s", info);
        g_glFuncs.glDeleteShader(shader);
        return 0;
    }
    return shader;
}

bool ensureDrawer(stipple_drawer_t& d) {
    if (d.program != 0) return true;
    if (d.init_failed) return false;
    if (g_glFuncs.glCreateShader == nullptr || g_glFuncs.glCreateProgram == nullptr ||
        g_glFuncs.glGenVertexArrays == nullptr || g_glFuncs.glGenBuffers == nullptr) {
        d.init_failed = true;
        return false;
    }

    const GLuint vs = compileStage(GL_VERTEX_SHADER, kStippleVS);
    const GLuint fs = compileStage(GL_FRAGMENT_SHADER, kStippleFS);
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
        SFPEW_LOGE("line-stipple program failed to link");
        g_glFuncs.glDeleteProgram(program);
        d.init_failed = true;
        return false;
    }
    d.program = program;
    d.loc_factor = g_glFuncs.glGetUniformLocation(program, "uFactor");
    d.loc_pattern = g_glFuncs.glGetUniformLocation(program, "uPattern");
    g_glFuncs.glGenVertexArrays(1, &d.vao);
    g_glFuncs.glGenBuffers(1, &d.vbo);
    if (d.vbo != 0) g_glstate_c.internal_buffers.insert(d.vbo);
    return d.vao != 0 && d.vbo != 0;
}

// One CPU-side vertex for the dedicated stipple program: already-projected
// clip-space position (so the shader needs no matrix uniforms), the
// vertex's color, and its cumulative stipple distance.
struct stipple_vertex_t {
    glm::vec4 clip_pos;
    glm::vec4 color;
    GLfloat distance;
};

} // namespace

// `vertices`/`floatCount`/`vertexCount`/`sizes` are exactly
// drawImmediateVertices' own parameters - the assembled interleaved
// per-vertex float stream for this glBegin/glEnd run. `primitive` is one
// of GL_LINES/GL_LINE_STRIP/GL_LINE_LOOP (the caller checks this).
void sfpewDrawStippledLines(GLenum primitive, const GLfloat* vertices, size_t floatCount,
                            size_t vertexCount, const fixed_function_draw_size_t& sizes) {
    if (vertexCount < 2) return;
    auto& gs = g_glstate_c;
    if (!sfpewEnsureBackend() || g_glFuncs.glDrawArrays == nullptr) return;
    auto& d = drawer();
    if (!ensureDrawer(d)) return;

    // Interleaved layout, matching drawImmediateVertices' own selection-mode
    // parsing above: vertex, normal, color, [index - not packed],
    // [edge - not packed], fog(1 float), secondary_color, texcoord*.
    size_t stride_floats = 0;
    for (int slot = 0; slot < VERTEX_POINTER_COUNT; ++slot) {
        if (slot == 3 || slot == 4 || sizes.data[slot] <= 0) continue;
        stride_floats += static_cast<size_t>(sizes.data[slot]);
    }
    if (stride_floats == 0 || floatCount < stride_floats * vertexCount) return;

    const GLint vertex_size = sizes.vertex_size;
    if (vertex_size < 2 || vertex_size > 4) return;
    const bool has_color = sizes.color_size > 0;
    const size_t color_offset = static_cast<size_t>(vertex_size) +
                                (sizes.normal_size > 0 ? static_cast<size_t>(sizes.normal_size) : 0u);
    const glm::vec4 constant_color = gs.fpe_state.fpe_draw.current_data.color;

    const auto& uniform = gs.fpe_uniform;
    const glm::mat4 mvp = uniform.transformation.matrices[matrix_idx(GL_PROJECTION)] *
                          uniform.transformation.matrices[matrix_idx(GL_MODELVIEW)];

    GLint viewport[4] = {0, 0, 1, 1};
    g_glFuncs.glGetIntegerv(GL_VIEWPORT, viewport);
    if (viewport[2] <= 0 || viewport[3] <= 0) return;

    // window_pos is only needed transiently to accumulate distance; the
    // shader receives clip-space position, not window-space.
    thread_local std::vector<glm::vec2>* window_pos_ptr = nullptr;
    if (window_pos_ptr == nullptr) window_pos_ptr = new std::vector<glm::vec2>();
    thread_local std::vector<stipple_vertex_t>* out_ptr = nullptr;
    if (out_ptr == nullptr) out_ptr = new std::vector<stipple_vertex_t>();
    auto& window_pos = *window_pos_ptr;
    auto& out = *out_ptr;
    window_pos.resize(vertexCount);
    out.resize(vertexCount);

    for (size_t i = 0; i < vertexCount; ++i) {
        glm::vec4 object_pos(0.0f, 0.0f, 0.0f, 1.0f);
        const GLfloat* src = vertices + i * stride_floats;
        for (GLint c = 0; c < vertex_size; ++c) glm::value_ptr(object_pos)[c] = src[c];

        const glm::vec4 clip = mvp * object_pos;
        window_pos[i] = clip.w != 0.0f
                            ? glm::vec2(viewport[0] + (clip.x / clip.w * 0.5f + 0.5f) * viewport[2],
                                       viewport[1] + (clip.y / clip.w * 0.5f + 0.5f) * viewport[3])
                            : glm::vec2(0.0f, 0.0f);

        out[i].clip_pos = clip;
        out[i].color = has_color ? glm::vec4(src[color_offset], src[color_offset + 1],
                                             src[color_offset + 2],
                                             sizes.color_size > 3 ? src[color_offset + 3] : 1.0f)
                                 : constant_color;
    }

    // Distance accumulation: reset per pair for GL_LINES, continuous
    // otherwise (spec 3.4.2 - see the file header).
    GLenum draw_primitive = primitive;
    size_t draw_count = vertexCount;
    if (primitive == GL_LINES) {
        for (size_t i = 0; i + 1 < vertexCount; i += 2) {
            out[i].distance = 0.0f;
            out[i + 1].distance = glm::length(window_pos[i + 1] - window_pos[i]);
        }
        draw_count = vertexCount - (vertexCount % 2);
    } else {
        out[0].distance = 0.0f;
        for (size_t i = 1; i < vertexCount; ++i) {
            out[i].distance = out[i - 1].distance + glm::length(window_pos[i] - window_pos[i - 1]);
        }
        if (primitive == GL_LINE_LOOP) {
            stipple_vertex_t closing = out[0];
            closing.distance =
                out[vertexCount - 1].distance + glm::length(window_pos[0] - window_pos[vertexCount - 1]);
            out.push_back(closing);
            draw_count = vertexCount + 1;
            draw_primitive = GL_LINE_STRIP; // see file header: same shape, correct distance
        }
    }
    if (draw_count < 2) return;

    // Save what this draw touches so it restores exactly, matching the
    // established drawQuad pattern rather than participating in the FPE
    // deferred-restore scheme - this is a cold path where a few extra
    // restore calls cost nothing.
    GLint prior_program = 0, prior_vao = 0, prior_array_buffer = 0;
    g_glFuncs.glGetIntegerv(GL_CURRENT_PROGRAM, &prior_program);
    g_glFuncs.glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &prior_vao);
    g_glFuncs.glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &prior_array_buffer);

    sfpewInvalidateImmediateDrawState();
    g_glFuncs.glUseProgram(d.program);
    sfpewBackendBindVertexArray(d.vao);
    g_glFuncs.glBindBuffer(GL_ARRAY_BUFFER, d.vbo);
    g_glFuncs.glBufferData(GL_ARRAY_BUFFER,
                           static_cast<GLsizeiptr>(draw_count * sizeof(stipple_vertex_t)), out.data(),
                           GL_STREAM_DRAW);
    g_glFuncs.glEnableVertexAttribArray(0);
    g_glFuncs.glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, sizeof(stipple_vertex_t),
                                    (const void*)offsetof(stipple_vertex_t, clip_pos));
    g_glFuncs.glEnableVertexAttribArray(1);
    g_glFuncs.glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, sizeof(stipple_vertex_t),
                                    (const void*)offsetof(stipple_vertex_t, color));
    g_glFuncs.glEnableVertexAttribArray(2);
    g_glFuncs.glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, sizeof(stipple_vertex_t),
                                    (const void*)offsetof(stipple_vertex_t, distance));

    if (d.loc_factor >= 0) g_glFuncs.glUniform1f(d.loc_factor, (GLfloat)uniform.line_stipple_factor);
    if (d.loc_pattern >= 0 && g_glFuncs.glUniform1ui != nullptr)
        g_glFuncs.glUniform1ui(d.loc_pattern, (GLuint)uniform.line_stipple_pattern);

    g_glFuncs.glDrawArrays(draw_primitive, 0, static_cast<GLsizei>(draw_count));

    g_glFuncs.glUseProgram((GLuint)prior_program);
    sfpewBackendBindVertexArray((GLuint)prior_vao);
    g_glFuncs.glBindBuffer(GL_ARRAY_BUFFER, (GLuint)prior_array_buffer);
}
