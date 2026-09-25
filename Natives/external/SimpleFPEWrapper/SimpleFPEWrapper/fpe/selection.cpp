// SimpleFPEWrapper - SimpleFPEWrapper/fpe/selection.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

// GL selection & feedback (plans/10, 10.3): a CPU transform pipeline over
// the FPE's CPU-visible vertex data. While render_mode != GL_RENDER, FPE
// draws transform on the CPU and never reach the GPU. Draws issued with a
// user program current are outside fixed-function transform semantics and
// are skipped with a log (documented deviation).

#include "fpe.hpp"
#include "drawing1x.h"
#include "transformation.h"
#include "../log.h"

#include <algorithm>

namespace {

constexpr GLuint kMaxNameStackDepth = 64;

struct feedback_vertex_t {
    glm::vec3 ndc{};
    GLfloat clip_w = 1.0f;
    glm::vec4 color{1.0f};
    glm::vec4 texcoord{0.0f, 0.0f, 0.0f, 1.0f};
};

// Writes one word into the selection buffer with overflow latching.
void selectWrite(glstate_t& gs, GLuint value) {
    if (gs.select_written < (GLuint)gs.select_buffer_size) {
        gs.select_buffer[gs.select_written++] = value;
    } else {
        gs.select_overflow = true;
    }
}

void feedbackWrite(glstate_t& gs, GLfloat value) {
    if (gs.feedback_written < gs.feedback_buffer_size) {
        gs.feedback_buffer[gs.feedback_written++] = value;
    } else {
        gs.feedback_overflow = true;
    }
}

} // namespace

// Flushes the accumulated hit record (called on name-stack changes and on
// leaving GL_SELECT). Hit record: name count, min z, max z, names...
void sfpewFlushSelectionHit() {
    auto& gs = g_glstate;
    if (!gs.hit_pending) return;
    gs.hit_pending = false;
    ++gs.select_hit_count;
    if (gs.select_buffer == nullptr) {
        gs.select_overflow = true;
        return;
    }
    selectWrite(gs, (GLuint)gs.name_stack.size());
    // z in [0,1] scaled to the full unsigned range per spec.
    selectWrite(gs, (GLuint)(std::clamp(gs.hit_min_z, 0.0f, 1.0f) * 4294967295.0));
    selectWrite(gs, (GLuint)(std::clamp(gs.hit_max_z, 0.0f, 1.0f) * 4294967295.0));
    for (GLuint name : gs.name_stack) selectWrite(gs, name);
}

// CPU processing of one FPE draw while selecting / in feedback mode.
// vertices: interleaved float data; stride/offset in floats.
void sfpewSelectionProcessVertices(GLenum mode, const GLfloat* positions, size_t stride_floats,
                                   GLint position_size, size_t vertex_count,
                                   const GLfloat* colors, size_t color_stride_floats,
                                   GLint color_size, const GLfloat* texcoords,
                                   size_t texcoord_stride_floats, GLint texcoord_size) {
    auto& gs = g_glstate;
    const auto& un = gs.fpe_uniform;
    const glm::mat4 mvp = un.transformation.matrices[matrix_idx(GL_PROJECTION)] *
                          un.transformation.matrices[matrix_idx(GL_MODELVIEW)];

    bool any_inside = false;
    float min_z = 1.0f, max_z = 0.0f;
    std::vector<feedback_vertex_t> feedback_vertices;
    if (gs.render_mode == GL_FEEDBACK) feedback_vertices.reserve(vertex_count);

    const auto readAttribute = [](const GLfloat* source, size_t stride, GLint size, size_t vertex,
                                  const glm::vec4& fallback) {
        if (source == nullptr || size <= 0) return fallback;
        glm::vec4 value(0.0f, 0.0f, 0.0f, 1.0f);
        if (stride == 0) stride = static_cast<size_t>(size);
        for (GLint component = 0; component < size && component < 4; ++component)
            glm::value_ptr(value)[component] = source[vertex * stride + component];
        return value;
    };

    for (size_t v = 0; v < vertex_count; ++v) {
        glm::vec4 pos(0.0f, 0.0f, 0.0f, 1.0f);
        for (GLint c = 0; c < position_size && c < 4; ++c)
            glm::value_ptr(pos)[c] = positions[v * stride_floats + c];
        const glm::vec4 clip = mvp * pos;
        if (clip.w <= 0.0f) continue;
        const glm::vec3 ndc = glm::vec3(clip) / clip.w;
        const float window_z = ndc.z * 0.5f + 0.5f;
        if (ndc.x >= -1.0f && ndc.x <= 1.0f && ndc.y >= -1.0f && ndc.y <= 1.0f && ndc.z >= -1.0f &&
            ndc.z <= 1.0f) {
            any_inside = true;
            min_z = std::min(min_z, window_z);
            max_z = std::max(max_z, window_z);
        }
        if (gs.render_mode == GL_FEEDBACK) {
            feedback_vertex_t feedback_vertex;
            feedback_vertex.ndc = ndc;
            feedback_vertex.clip_w = clip.w;
            feedback_vertex.color =
                readAttribute(colors, color_stride_floats, color_size, v,
                              gs.fpe_state.fpe_draw.current_data.color);
            const glm::vec4 raw_texcoord =
                readAttribute(texcoords, texcoord_stride_floats, texcoord_size, v,
                              gs.fpe_state.fpe_draw.current_data.texcoord[0]);
            feedback_vertex.texcoord = un.transformation.texture_matrices[0] * raw_texcoord;
            feedback_vertices.push_back(feedback_vertex);
        }
    }

    if (gs.render_mode == GL_SELECT) {
        if (!any_inside) return;
        if (!gs.hit_pending) {
            gs.hit_pending = true;
            gs.hit_min_z = min_z;
            gs.hit_max_z = max_z;
        } else {
            gs.hit_min_z = std::min(gs.hit_min_z, min_z);
            gs.hit_max_z = std::max(gs.hit_max_z, max_z);
        }
        return;
    }

    // GL_FEEDBACK: emit the vertex shape selected by glFeedbackBuffer. This
    // wrapper has no color-index mode (GL_INDEX_MODE is always false), so the
    // color-bearing forms always contain four RGBA values.
    if (gs.feedback_buffer == nullptr || feedback_vertices.empty()) return;
    GLint viewport[4] = {0, 0, 1, 1};
    if (g_glFuncs.glGetIntegerv != nullptr) g_glFuncs.glGetIntegerv(GL_VIEWPORT, viewport);
    const auto emitVertex = [&](const feedback_vertex_t& vertex) {
        feedbackWrite(gs, viewport[0] + (vertex.ndc.x * 0.5f + 0.5f) * viewport[2]);
        feedbackWrite(gs, viewport[1] + (vertex.ndc.y * 0.5f + 0.5f) * viewport[3]);
        if (gs.feedback_type == GL_2D) return;
        feedbackWrite(gs, vertex.ndc.z * 0.5f + 0.5f);
        if (gs.feedback_type == GL_4D_COLOR_TEXTURE) feedbackWrite(gs, vertex.clip_w);
        if (gs.feedback_type == GL_3D_COLOR || gs.feedback_type == GL_3D_COLOR_TEXTURE ||
            gs.feedback_type == GL_4D_COLOR_TEXTURE) {
            for (GLint component = 0; component < 4; ++component)
                feedbackWrite(gs, glm::value_ptr(vertex.color)[component]);
        }
        if (gs.feedback_type == GL_3D_COLOR_TEXTURE ||
            gs.feedback_type == GL_4D_COLOR_TEXTURE) {
            for (GLint component = 0; component < 4; ++component)
                feedbackWrite(gs, glm::value_ptr(vertex.texcoord)[component]);
        }
    };
    if (mode == GL_POINTS) {
        for (const auto& vertex : feedback_vertices) {
            feedbackWrite(gs, (GLfloat)GL_POINT_TOKEN);
            emitVertex(vertex);
        }
    } else if (mode == GL_LINES || mode == GL_LINE_STRIP || mode == GL_LINE_LOOP) {
        for (size_t i = 0; i + 1 < feedback_vertices.size(); i += (mode == GL_LINES ? 2 : 1)) {
            feedbackWrite(gs, (GLfloat)GL_LINE_TOKEN);
            emitVertex(feedback_vertices[i]);
            emitVertex(feedback_vertices[i + 1]);
        }
    } else {
        feedbackWrite(gs, (GLfloat)GL_POLYGON_TOKEN);
        feedbackWrite(gs, (GLfloat)feedback_vertices.size());
        for (const auto& vertex : feedback_vertices) emitVertex(vertex);
    }
}

GLint glRenderMode(GLenum mode) {
    sfpewEntryBarrier();
    auto& gs = g_glstate;
    if (mode != GL_RENDER && mode != GL_SELECT && mode != GL_FEEDBACK) {
        gs.set_error(GL_INVALID_ENUM);
        return 0;
    }
    if (mode == GL_SELECT && gs.select_buffer == nullptr) {
        gs.set_error(GL_INVALID_OPERATION);
        return 0;
    }
    if (mode == GL_FEEDBACK && gs.feedback_buffer == nullptr) {
        gs.set_error(GL_INVALID_OPERATION);
        return 0;
    }

    GLint result = 0;
    if (gs.render_mode == GL_SELECT) {
        sfpewFlushSelectionHit();
        result = gs.select_overflow ? -1 : (GLint)gs.select_hit_count;
    } else if (gs.render_mode == GL_FEEDBACK) {
        result = gs.feedback_overflow ? -1 : (GLint)gs.feedback_written;
    }

    gs.render_mode = mode;
    gs.select_written = 0;
    gs.select_hit_count = 0;
    gs.select_overflow = false;
    gs.hit_pending = false;
    gs.feedback_written = 0;
    gs.feedback_overflow = false;
    return result;
}

void glSelectBuffer(GLsizei size, GLuint* buffer) {
    auto& gs = g_glstate;
    if (size < 0) {
        gs.set_error(GL_INVALID_VALUE);
        return;
    }
    if (gs.render_mode == GL_SELECT) {
        gs.set_error(GL_INVALID_OPERATION);
        return;
    }
    gs.select_buffer = buffer;
    gs.select_buffer_size = size;
}

void glFeedbackBuffer(GLsizei size, GLenum type, GLfloat* buffer) {
    auto& gs = g_glstate;
    if (size < 0) {
        gs.set_error(GL_INVALID_VALUE);
        return;
    }
    if (type != GL_2D && type != GL_3D && type != GL_3D_COLOR && type != GL_3D_COLOR_TEXTURE &&
        type != GL_4D_COLOR_TEXTURE) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (gs.render_mode == GL_FEEDBACK) {
        gs.set_error(GL_INVALID_OPERATION);
        return;
    }
    gs.feedback_buffer = buffer;
    gs.feedback_buffer_size = size;
    gs.feedback_type = type;
}

void glInitNames(void) {
    sfpewFlushSelectionHit();
    g_glstate.name_stack.clear();
}

void glPushName(GLuint name) {
    auto& gs = g_glstate;
    sfpewFlushSelectionHit();
    if (gs.name_stack.size() >= kMaxNameStackDepth) {
        gs.set_error(GL_STACK_OVERFLOW);
        return;
    }
    gs.name_stack.push_back(name);
}

void glPopName(void) {
    auto& gs = g_glstate;
    sfpewFlushSelectionHit();
    if (gs.name_stack.empty()) {
        gs.set_error(GL_STACK_UNDERFLOW);
        return;
    }
    gs.name_stack.pop_back();
}

void glLoadName(GLuint name) {
    auto& gs = g_glstate;
    sfpewFlushSelectionHit();
    if (gs.name_stack.empty()) {
        gs.set_error(GL_INVALID_OPERATION);
        return;
    }
    gs.name_stack.back() = name;
}

void glPassThrough(GLfloat token) {
    auto& gs = g_glstate;
    if (gs.render_mode != GL_FEEDBACK) return;
    feedbackWrite(gs, (GLfloat)GL_PASS_THROUGH_TOKEN);
    feedbackWrite(gs, token);
}
