// SimpleFPEWrapper - SimpleFPEWrapper/fpe/draw_now.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "../init.h"
#include "../log.h"

#include "fpe.hpp"
#include "list.h"
#include "list_diagnostics.h"
#include "drawing1x.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

namespace {

// CPU-side scratch for the selection and mixed-polygon-mode paths below.
// Each field belongs to exactly one call site (the prefix names which); they
// are grouped into one struct behind a single thread_local pointer instead
// of one thread_local std::vector per site so the library's static TLS
// block - fixed-size and shared by every dlopen of this .so - stays small.
// A separate thread_local std::vector per site costs a 24-byte control
// block each; a dozen of them is enough to exceed glibc's default static-TLS
// surplus for a library loaded via dlopen (the normal way this wrapper is
// loaded, both here and as a MobileGlues plugin), which fails the whole
// dlopen rather than just this feature.
struct drawing_scratch_t {
    std::vector<glm::vec4> da_selection_positions;      // drawArraysNow: selection/feedback
    std::vector<glm::vec4> da_mixed_positions;          // drawArraysNow: mixed polygon mode
    std::vector<uint8_t> da_mixed_edge_flags;
    std::vector<glm::vec4> upde_mixed_positions;        // userProgramDrawElements: mixed mode
    std::vector<uint8_t> upde_mixed_edge_flags;
    std::vector<uint32_t> upde_mixed_indices;
    std::vector<uint8_t> de_selection_index_bytes;      // drawElementsNow: selection/feedback
    std::vector<uint32_t> de_selection_indices;
    std::vector<glm::vec4> de_selection_source_positions;
    std::vector<glm::vec4> de_selection_positions;
    std::vector<glm::vec4> de_mixed_positions;          // drawElementsNow: mixed polygon mode
    std::vector<uint8_t> de_mixed_edge_flags;
    std::vector<uint32_t> de_mixed_indices;
};

drawing_scratch_t& drawingScratch() {
    thread_local drawing_scratch_t* instance = nullptr;
    if (instance == nullptr) instance = new drawing_scratch_t();
    return *instance;
}

// GL_QUADS/GL_QUAD_STRIP/GL_POLYGON for a draw that keeps the APP's vertex
// state. Sodium binds its own program and its own VAO with generic attributes,
// then issues glDrawArrays(GL_QUADS, ...) - legal in GL 2.1, but mode 7 does not
// exist in GLES, so passing it through raw is GL_INVALID_ENUM and the draw is
// dropped (RenderDoc, 1.16 sodium, EID 130..2311: 503 such draws).
//
// The app's attributes are already correct and must not be touched, so unlike
// the fixed-function paths this cannot move to fpe_vao. Only the element
// binding is needed, and that IS VAO state, so it is saved and restored around
// the draw. Returns true when the draw was issued here.
bool passthroughLegacyDrawArrays(GLenum mode, GLint first, GLsizei count) {
    if (mode == GL_QUAD_STRIP || mode == GL_POLYGON) {
        // Vertex order is identical; no index rewrite needed, but an
        // incomplete trailing group still has to be dropped.
        GLenum converted = mode;
        sfpewConvertLegacyDrawMode(&converted, &count);
        if (count > 0) g_glFuncs.glDrawArrays(converted, first, count);
        return true;
    }
    if (mode != GL_QUADS) return false;
    if (count < 4 || first < 0) {
        // Nothing a quad can be made of; swallow it rather than handing the
        // backend an enum it will reject.
        return true;
    }
    if (g_glFuncs.glDrawElements == nullptr || g_glFuncs.glBindBuffer == nullptr ||
        g_glFuncs.glGetIntegerv == nullptr) {
        return false;
    }
    auto& st = g_glstate_c.fpe_state;
    if (st.fpe_ibo == 0) {
        if (g_glFuncs.glGenBuffers == nullptr) return false;
        g_glFuncs.glGenBuffers(1, &st.fpe_ibo);
        sfpewNoteInternalBuffer(st.fpe_ibo);
        if (st.fpe_ibo == 0) return false;
    }

    const bool base_vertex = first != 0 && g_glFuncs.glDrawElementsBaseVertex != nullptr;
    const GLuint index_first = base_vertex ? 0u : static_cast<GLuint>(first);
    const bool upload = prepare_quad_indices(count, index_first);
    const GLsizei index_count = (count / 4) * 6;

    // The app owns this VAO's element binding; put it back afterwards.
    GLint saved_element_buffer = 0;
    g_glFuncs.glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &saved_element_buffer);

    g_glFuncs.glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, st.fpe_ibo);
    st.fpe_ibo_bound = false; // this bind landed in the app's VAO, not fpe_vao
    if (upload) {
        g_glFuncs.glBufferData(GL_ELEMENT_ARRAY_BUFFER, (GLsizeiptr)quad_index_size_bytes(),
                               quad_index_data(), GL_DYNAMIC_DRAW);
    }

    if (base_vertex) {
        g_glFuncs.glDrawElementsBaseVertex(GL_TRIANGLES, index_count, quad_index_type(), (void*)0,
                                           first);
    } else {
        g_glFuncs.glDrawElements(GL_TRIANGLES, index_count, quad_index_type(), (void*)0);
    }

    g_glFuncs.glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, (GLuint)saved_element_buffer);
    return true;
}

} // namespace

// Declared in fpe/drawing1x.h: fpe/list_capture.cpp's
// captured_draw_arrays_cmd_t::execute() calls this to replay a captured
// display-list draw, so it needs external linkage rather than staying
// confined to this file's anonymous namespace.
void drawArraysNow(GLenum mode, GLint first, GLsizei count, bool forceFixedFunction,
                   GLint arrayBufferOverride) {
    SFPEW_LISTLOG_TALLY(++g_listLog.drawsTotal);
    // A zero-vertex draw is legal and simply draws nothing - only a NEGATIVE
    // count is an error. Returning here keeps it away from the client-array
    // upload sizing in commit_fpe_state_on_draw, which assumes at least one
    // vertex and rejected count == 0 with a spurious GL_INVALID_VALUE.
    // Nothing below this point is observable for a zero-vertex draw.
    if (count == 0) return;

    // A display-list API call owns one backend guard around the whole replay.
    // Captured draws always provide an explicit static VBO (or zero for the
    // allocation-failure fallback), so they can keep the FPE backend state
    // live between commands and avoid four synchronous state queries per
    // draw. The outer glCallList(s) guard restores all caller state once.
    const bool mixed_polygon_mode = sfpewMixedPolygonMode(mode);
    if (g_glstate_c.render_mode == GL_RENDER && forceFixedFunction &&
        DisplayListManager::isCalling() && arrayBufferOverride >= 0 && !mixed_polygon_mode) {
        // No explicit bind here: commit_fpe_state_on_draw binds the
        // attribute source itself (arm-checked), so binding first just
        // doubled the call on every captured display-list draw.
        const int doDrawElement =
            commit_fpe_state_on_draw(&mode, &first, &count, arrayBufferOverride);
        if (doDrawElement < 0) return;
        if (doDrawElement == 2) {
            g_glFuncs.glDrawElements(mode, count, GL_UNSIGNED_INT, (void*)0);
        } else if (doDrawElement > 0) {
            if (first != 0 && g_glFuncs.glDrawElementsBaseVertex != nullptr)
                g_glFuncs.glDrawElementsBaseVertex(mode, count, quad_index_type(), (void*)0, first);
            else
                g_glFuncs.glDrawElements(mode, count, quad_index_type(), (void*)0);
        } else {
            g_glFuncs.glDrawArrays(mode, first, count);
        }
        return;
    }

    const GLint current_program = sfpewLogicalProgram();

    const auto& vertex_array = g_glstate_c.fpe_state.vertexpointer_array;
    const uint32_t vertex_array_mask = 1u << vp2idx(GL_VERTEX_ARRAY);
    if (g_glstate_c.render_mode != GL_RENDER &&
        ((!forceFixedFunction && current_program != 0) ||
         !(vertex_array.enabled_pointers & vertex_array_mask))) {
        sfpewFlushDeferredDrawState();
        SFPEW_LOGW(
            "selection: draw arrays skipped because no fixed-function vertex transform is available");
        return;
    }
    if (g_glstate_c.render_mode != GL_RENDER && (first < 0 || count < 0)) {
        g_glstate_c.set_error(GL_INVALID_VALUE);
        return;
    }
    if ((!forceFixedFunction && current_program != 0) || first < 0 || count < 0 ||
        !(vertex_array.enabled_pointers & vertex_array_mask)) {
        // These paths draw with the app's own program/VAO/element state; the
        // glDrawArrays entry no longer restores it for fixed-function draws,
        // so it must come back here before anything reaches the backend.
        sfpewFlushDeferredDrawState();
        if (current_program != 0) {
            // GL 2.1: a bound user program still consumes the fixed-function
            // vertex arrays (shader packs draw terrain via glVertexPointer).
            if ((vertex_array.enabled_pointers & vertex_array_mask) && first >= 0 && count > 0 &&
                sfpewUserProgramFixedFunctionDrawArrays((GLuint)current_program, mode, first,
                                                        count)) {
                return;
            }
            sfpewFeedUserProgramUniforms((GLuint)current_program);
        }
        if (passthroughLegacyDrawArrays(mode, first, count)) return;
        g_glFuncs.glDrawArrays(mode, first, count);
        return;
    }

    if (g_glstate_c.render_mode != GL_RENDER) {
        // Selection/feedback is CPU-only. Read client memory and VBO-backed
        // arrays through the same type conversion used by mixed polygon mode.
        sfpewFlushDeferredDrawState();
        array_buffer_binding_guard_t array_buffer_guard;
        const int position_slot = vp2idx(GL_VERTEX_ARRAY);
        const GLuint position_buffer = arrayBufferOverride >= 0
                                           ? static_cast<GLuint>(arrayBufferOverride)
                                           : getClientArrayBufferBinding(position_slot);
        auto& selection_positions = drawingScratch().da_selection_positions;
        if (!sfpewReadVertexPositions(vertex_array.attributes[position_slot], position_buffer,
                                      first, count, selection_positions)) {
            g_glstate_c.set_error(GL_INVALID_OPERATION);
            SFPEW_LOGW("selection: failed to read the vertex array");
            return;
        }

        // Preserve the feedback payload support for ordinary float client
        // arrays. Position conversion above is independent of these optional
        // streams, so selection also works when they use other sources.
        const auto feedbackAttribute = [&](int slot, const GLfloat** pointer,
                                           size_t* stride_floats, GLint* size) {
            if (((vertex_array.enabled_pointers >> slot) & 1u) == 0 ||
                getClientArrayBufferBinding(slot) != 0) {
                return;
            }
            const auto& feedback_attr = vertex_array.attributes[slot];
            // The stride is cast to size_t below, so a negative one becomes a
            // ~2^64 step off the end of the array (plans/16 M1). The
            // gl*Pointer entry points reject it now; this path reads a raw
            // client pointer directly, so it checks for itself.
            if (feedback_attr.pointer == nullptr || feedback_attr.type != GL_FLOAT ||
                feedback_attr.stride < 0) {
                return;
            }
            const GLsizei feedback_stride =
                feedback_attr.stride != 0
                    ? feedback_attr.stride
                    : feedback_attr.size * static_cast<GLsizei>(sizeof(GLfloat));
            *pointer = reinterpret_cast<const GLfloat*>(
                static_cast<const uint8_t*>(feedback_attr.pointer) +
                static_cast<size_t>(first) * static_cast<size_t>(feedback_stride));
            *stride_floats = static_cast<size_t>(feedback_stride) / sizeof(GLfloat);
            *size = feedback_attr.size;
        };
        const GLfloat* colors = nullptr;
        const GLfloat* texcoords = nullptr;
        size_t color_stride = 0, texcoord_stride = 0;
        GLint color_size = 0, texcoord_size = 0;
        feedbackAttribute(vp2idx(GL_COLOR_ARRAY), &colors, &color_stride, &color_size);
        feedbackAttribute(7, &texcoords, &texcoord_stride, &texcoord_size);
        sfpewSelectionProcessVertices(
            mode, &selection_positions.front().x, sizeof(glm::vec4) / sizeof(GLfloat), 4,
            static_cast<size_t>(count), colors, color_stride, color_size, texcoords,
            texcoord_stride, texcoord_size);
        return;
    }

    const GLint logicalArrayBuffer = static_cast<GLint>(sfpewLogicalArrayBufferBinding());
    fpe_backend_draw_state_guard_t backend_state(current_program, logicalArrayBuffer);
    GLint attributeArrayBuffer = logicalArrayBuffer;
    if (arrayBufferOverride >= 0) {
        attributeArrayBuffer = arrayBufferOverride; // commit binds it (arm-checked)
    }
    const GLenum polygon_primitive = mode;
    const GLsizei polygon_count = count;
    auto& mixed_positions = drawingScratch().da_mixed_positions;
    auto& mixed_edge_flags = drawingScratch().da_mixed_edge_flags;
    if (mixed_polygon_mode) {
        const int position_slot = vp2idx(GL_VERTEX_ARRAY);
        const GLuint position_buffer = arrayBufferOverride >= 0
                                           ? static_cast<GLuint>(arrayBufferOverride)
                                           : getClientArrayBufferBinding(position_slot);
        if (!sfpewReadVertexPositions(vertex_array.attributes[position_slot], position_buffer,
                                      first, count, mixed_positions)) {
            g_glstate_c.set_error(GL_INVALID_OPERATION);
            return;
        }
        mixed_edge_flags.clear();
        const int edge_slot = vp2idx(GL_EDGE_FLAG_ARRAY);
        if (((vertex_array.enabled_pointers >> edge_slot) & 1u) != 0) {
            const GLuint edge_buffer = arrayBufferOverride >= 0
                                           ? static_cast<GLuint>(arrayBufferOverride)
                                           : getClientArrayBufferBinding(edge_slot);
            (void)sfpewReadEdgeFlags(vertex_array.attributes[edge_slot], edge_buffer, first,
                                     count, mixed_edge_flags);
        }
    }
    int do_draw_element = commit_fpe_state_on_draw(&mode, &first, &count, attributeArrayBuffer);
    if (do_draw_element < 0) {
        return;
    } else if (mixed_polygon_mode &&
               sfpewDrawMixedPolygonMode(
                   polygon_primitive, mixed_positions.data(), mixed_positions.size(), nullptr,
                   static_cast<size_t>(polygon_count), static_cast<uint32_t>(first),
                   mixed_edge_flags.empty() ? nullptr : mixed_edge_flags.data(),
                   mixed_edge_flags.size())) {
        return;
    } else if (do_draw_element == 2) {
        g_glFuncs.glDrawElements(mode, count, GL_UNSIGNED_INT, (void*)0);
    } else if (do_draw_element > 0) {
        if (first != 0 && g_glFuncs.glDrawElementsBaseVertex != nullptr)
            g_glFuncs.glDrawElementsBaseVertex(mode, count, quad_index_type(), (void*)0, first);
        else
            g_glFuncs.glDrawElements(mode, count, quad_index_type(), (void*)0);
    } else {
        g_glFuncs.glDrawArrays(mode, first, count);
    }
}

namespace {

size_t indexTypeSize(GLenum type) {
    switch (type) {
    case GL_UNSIGNED_BYTE:
        return 1;
    case GL_UNSIGNED_SHORT:
        return 2;
    case GL_UNSIGNED_INT:
        return 4;
    default:
        return 0;
    }
}

template <typename T>
uint32_t maxIndexOf(const T* indices, size_t count) {
    uint32_t result = 0;
    for (size_t i = 0; i < count; ++i)
        result = std::max(result, static_cast<uint32_t>(indices[i]));
    return result;
}

void copyIndicesToUint32(const uint8_t* source, size_t count, GLenum type,
                         std::vector<uint32_t>& out) {
    out.resize(count);
    switch (type) {
    case GL_UNSIGNED_BYTE:
        for (size_t i = 0; i < count; ++i) out[i] = source[i];
        break;
    case GL_UNSIGNED_SHORT:
        for (size_t i = 0; i < count; ++i) {
            uint16_t value = 0;
            std::memcpy(&value, source + i * sizeof(value), sizeof(value));
            out[i] = value;
        }
        break;
    default:
        for (size_t i = 0; i < count; ++i) {
            uint32_t value = 0;
            std::memcpy(&value, source + i * sizeof(value), sizeof(value));
            out[i] = value;
        }
        break;
    }
}

// FPE conversion for glDrawElements (plans/02 section B): mirrors the
// glDrawArrays interception - only program 0 with an enabled legacy vertex
// array is converted, everything else passes through untouched.
// User program + fixed-function arrays + glDrawElements (plans/09 S9).
// Everything goes through the CPU-simplest correct path: indices land in
// fpe_element_ibo (expanded for GL_QUADS), client vertices upload sized by
// the largest referenced index. Returns false to fall back to passthrough.
bool userProgramDrawElements(GLuint program, GLenum mode, GLsizei count, GLenum type,
                             const GLvoid* indices) {
    GLint locations[VERTEX_POINTER_COUNT];
    if (count <= 0 || !sfpewUserProgramAttribLocations(program, locations)) return false;
    const size_t index_size = indexTypeSize(type);
    if (index_size == 0) return false;
    if (!g_glstate.fpe_ready && init_fpe() != 0) return false;

    auto& st = g_glstate.fpe_state;
    if (st.fpe_user_vao == 0) {
        if (g_glFuncs.glGenVertexArrays == nullptr) return false;
        g_glFuncs.glGenVertexArrays(1, &st.fpe_user_vao);
        st.fpe_user_vao_enabled = 0;
        if (st.fpe_user_vao == 0) return false;
    }

    // Pull the indices to the CPU (client memory or mapped buffer).
    GLint element_buffer = 0;
    g_glFuncs.glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &element_buffer);
    thread_local std::vector<uint8_t> scratch;
    const uint8_t* cpu_indices = nullptr;
    if (element_buffer == 0) {
        if (indices == nullptr) return false;
        cpu_indices = static_cast<const uint8_t*>(indices);
    } else {
        if (g_glFuncs.glMapBufferRange == nullptr || g_glFuncs.glUnmapBuffer == nullptr)
            return false;
        const size_t bytes = (size_t)count * index_size;
        void* mapped = g_glFuncs.glMapBufferRange(
            GL_ELEMENT_ARRAY_BUFFER, (GLintptr)(uintptr_t)indices, (GLsizeiptr)bytes,
            GL_MAP_READ_BIT);
        if (mapped == nullptr) return false;
        scratch.assign((const uint8_t*)mapped, (const uint8_t*)mapped + bytes);
        g_glFuncs.glUnmapBuffer(GL_ELEMENT_ARRAY_BUFFER);
        cpu_indices = scratch.data();
    }
    const GLint logical_array_buffer = (GLint)sfpewLogicalArrayBufferBinding();
    fpe_backend_draw_state_guard_t backend_state((GLint)program, logical_array_buffer);

    const auto& raw_vpa = g_glstate.fpe_state.vertexpointer_array;

    // Ground-truth classification (plans/13): mirrors
    // sfpewUserProgramFixedFunctionDrawArrays / commit_fpe_state_on_draw -
    // see either's comment for the rationale. Doubles as the old manual
    // "any enabled array VBO-backed" scan this function used only to skip
    // gather_client_arrays/the index scan below when nothing needs them
    // (all_client_memory is exactly !any_vbo_backed): a single VBO-backed
    // array made the gather bail on its own anyway (gather_client_arrays,
    // fpe/fpe.cpp), so the two checks were already redundant, just phrased
    // two different ways. The largest referenced index below still has
    // exactly two consumers - the vertex count that sizes
    // gather_client_arrays' copy, and the client-memory upload size - so
    // the scan over every index of every draw stays dead work whenever the
    // classification turns out not to need it: 1.16-Optifine/1-frame19661
    // .rdc walks 108630 indices a frame for a value nothing reads.
    GLuint single_buffer_id = 0;
    const client_array_kind_t array_kind = classifyClientArrays(raw_vpa, &single_buffer_id);
    uint32_t max_index = 0;
    bool max_index_known = false;
    const auto vertexCount = [&]() -> GLsizei {
        if (!max_index_known) {
            switch (index_size) {
            case 1: max_index = maxIndexOf((const uint8_t*)cpu_indices, (size_t)count); break;
            case 2: max_index = maxIndexOf((const uint16_t*)cpu_indices, (size_t)count); break;
            default: max_index = maxIndexOf((const uint32_t*)cpu_indices, (size_t)count); break;
            }
            max_index_known = true;
        }
        return (GLsizei)max_index + 1;
    };

    const bool mixed_polygon_mode = sfpewMixedPolygonMode(mode);
    auto& mixed_positions = drawingScratch().upde_mixed_positions;
    auto& mixed_edge_flags = drawingScratch().upde_mixed_edge_flags;
    auto& mixed_indices = drawingScratch().upde_mixed_indices;
    if (mixed_polygon_mode) {
        const GLsizei mixed_vertex_count = vertexCount();
        if (max_index >= static_cast<uint32_t>(std::numeric_limits<GLsizei>::max())) {
            g_glstate.set_error(GL_INVALID_VALUE);
            return true;
        }
        const int position_slot = vp2idx(GL_VERTEX_ARRAY);
        if (!sfpewReadVertexPositions(raw_vpa.attributes[position_slot],
                                      getClientArrayBufferBinding(position_slot), 0,
                                      mixed_vertex_count, mixed_positions)) {
            g_glstate.set_error(GL_INVALID_OPERATION);
            return true;
        }
        mixed_edge_flags.clear();
        const int edge_slot = vp2idx(GL_EDGE_FLAG_ARRAY);
        if (((raw_vpa.enabled_pointers >> edge_slot) & 1u) != 0) {
            (void)sfpewReadEdgeFlags(raw_vpa.attributes[edge_slot],
                                     getClientArrayBufferBinding(edge_slot), 0,
                                     mixed_vertex_count, mixed_edge_flags);
        }
        copyIndicesToUint32(cpu_indices, static_cast<size_t>(count), type, mixed_indices);
    }

    sfpewBackendBindVertexArray(st.fpe_user_vao);

    if (array_kind == client_array_kind_t::single_buffer) {
        // Same fix shape as sfpewUserProgramFixedFunctionDrawArrays: bind
        // exactly the buffer the classifier found and hand raw_vpa's
        // offsets to sfpewSendUserProgramAttributes untouched (plans/13
        // crash 1, crash 4).
        sfpewBackendBindAttributeBuffer(single_buffer_id, backend_state.holds_save);
        // No base_vertex: an indexed draw's gathers all start at vertex 0 and
        // the indices reach this function unmodified, so the app's generic
        // arrays are addressed by exactly the same numbers either way.
        sfpewSendUserProgramAttributes(locations, raw_vpa, 0, {true, 0, single_buffer_id});
    } else {
        vertex_pointer_array_t vpa;
        if (array_kind == client_array_kind_t::mixed) {
            // plans/13 13.4: same rationale as commit_fpe_state_on_draw's
            // mixed branch - at least one enabled attribute is buffer-backed
            // and at least one is not (or two disagree on which buffer), so
            // every attribute is read to the CPU individually and
            // interleaved. vertexCount(), not `count`: an index can
            // reference any vertex up to the largest one actually used, not
            // just the first `count` of them.
            if (!gather_mixed_client_arrays(raw_vpa, 0, vertexCount(), &vpa)) {
                g_glstate.set_error(GL_INVALID_OPERATION);
                return true;
            }
            // gathered layout starts at vertex 0
        } else if (array_kind == client_array_kind_t::all_client_memory &&
                   gather_client_arrays(raw_vpa, 0, vertexCount(), &vpa)) {
            // gathered layout starts at vertex 0
        } else {
            vertex_pointer_array_t raw_copy = raw_vpa;
            vpa = raw_copy.normalize();
        }

        // all_client_memory and mixed are both certainties from the
        // classifier now, not a pointer-magnitude guess - mixed only reaches
        // here after gather_mixed_client_arrays above already succeeded (or
        // the draw already returned).
        const bool client_memory_draw =
            array_kind == client_array_kind_t::all_client_memory ||
            array_kind == client_array_kind_t::mixed;
        const GLuint attribute_buffer = (logical_array_buffer == 0 || client_memory_draw)
                                            ? st.fpe_vbo
                                            : (GLuint)logical_array_buffer;
        sfpewBackendBindAttributeBuffer(attribute_buffer, backend_state.holds_save);
        if (client_memory_draw) {
            const int64_t upload_size = sfpewClientArrayUploadSize(vpa, vertexCount());
            if (upload_size <= 0 || upload_size > (int64_t)std::numeric_limits<GLsizei>::max()) {
                g_glstate.set_error(GL_INVALID_VALUE);
                return true;
            }
            g_glFuncs.glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)upload_size, vpa.starting_pointer,
                                   GL_DYNAMIC_DRAW);
        }

        sfpewSendUserProgramAttributes(locations, vpa, 0, {true, 0, attribute_buffer});
    }
    sfpewFeedUserProgramUniforms(program);

    if (mixed_polygon_mode &&
        sfpewDrawMixedPolygonMode(mode, mixed_positions.data(), mixed_positions.size(),
                                  mixed_indices.data(), mixed_indices.size(), 0u,
                                  mixed_edge_flags.empty() ? nullptr : mixed_edge_flags.data(),
                                  mixed_edge_flags.size())) {
        return true;
    }

    GLenum draw_mode = mode;
    GLsizei draw_count = count;
    GLenum draw_type = type;
    const void* draw_offset = nullptr;
    thread_local std::vector<uint32_t> expanded;
    if (mode == GL_QUADS) {
        const size_t quads = (size_t)count / 4u;
        switch (index_size) {
        case 1: expandQuadIndices((const uint8_t*)cpu_indices, quads, expanded); break;
        case 2: expandQuadIndices((const uint16_t*)cpu_indices, quads, expanded); break;
        default: expandQuadIndices((const uint32_t*)cpu_indices, quads, expanded); break;
        }
        if (st.fpe_element_ring == 0) g_glFuncs.glGenBuffers(1, &st.fpe_element_ring); sfpewNoteInternalBuffer(st.fpe_element_ring);
        g_glFuncs.glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, st.fpe_element_ring);
        st.fpe_ibo_bound = false;
        draw_offset = (const void*)(uintptr_t)sfpewUploadElementData(
            expanded.data(), expanded.size() * sizeof(uint32_t));
        draw_mode = GL_TRIANGLES;
        draw_count = (GLsizei)expanded.size();
        draw_type = GL_UNSIGNED_INT;
    } else {
        if (mode == GL_QUAD_STRIP) draw_mode = GL_TRIANGLE_STRIP;
        else if (mode == GL_POLYGON) draw_mode = GL_TRIANGLE_FAN;
        if (st.fpe_element_ring == 0) g_glFuncs.glGenBuffers(1, &st.fpe_element_ring); sfpewNoteInternalBuffer(st.fpe_element_ring);
        g_glFuncs.glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, st.fpe_element_ring);
        st.fpe_ibo_bound = false;
        draw_offset = (const void*)(uintptr_t)sfpewUploadElementData(
            cpu_indices, (size_t)count * index_size);
    }
    g_glFuncs.glDrawElements(draw_mode, draw_count, draw_type, draw_offset);
    return true;
}

// Indexed counterpart of passthroughLegacyDrawArrays: the app owns the vertex
// state, only the legacy primitive mode has to go. QUAD_STRIP and POLYGON are
// vertex-order compatible so they are pure mode swaps. GL_QUADS needs its index
// data rewritten, which means reading the app's indices back - from client
// memory when no element buffer is bound, otherwise by mapping the app's buffer.
bool passthroughLegacyDrawElements(GLenum mode, GLsizei count, GLenum type,
                                   const GLvoid* indices) {
    if (g_glFuncs.glDrawElements == nullptr) return false;
    if (mode == GL_QUAD_STRIP) {
        g_glFuncs.glDrawElements(GL_TRIANGLE_STRIP, count, type, indices);
        return true;
    }
    if (mode == GL_POLYGON) {
        g_glFuncs.glDrawElements(GL_TRIANGLE_FAN, count, type, indices);
        return true;
    }
    if (mode != GL_QUADS) return false;
    if (count < 4) return true; // nothing a quad can be made of
    const size_t index_size = indexTypeSize(type);
    if (index_size == 0) {
        g_glstate_c.set_error(GL_INVALID_ENUM);
        return true;
    }
    if (g_glFuncs.glGetIntegerv == nullptr || g_glFuncs.glBindBuffer == nullptr) return false;

    GLint app_element_buffer = 0;
    g_glFuncs.glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &app_element_buffer);

    // Pull the app's indices to the CPU so the quads can be expanded.
    thread_local std::vector<uint8_t> scratch;
    const uint8_t* cpu_indices = nullptr;
    const size_t byte_count = (size_t)count * index_size;
    if (app_element_buffer == 0) {
        if (indices == nullptr) {
            g_glstate_c.set_error(GL_INVALID_VALUE);
            return true;
        }
        cpu_indices = static_cast<const uint8_t*>(indices);
    } else {
        if (g_glFuncs.glMapBufferRange == nullptr || g_glFuncs.glUnmapBuffer == nullptr) return false;
        void* mapped = g_glFuncs.glMapBufferRange(
            GL_ELEMENT_ARRAY_BUFFER, (GLintptr)reinterpret_cast<uintptr_t>(indices),
            (GLsizeiptr)byte_count, GL_MAP_READ_BIT);
        if (mapped == nullptr) return false;
        scratch.assign(static_cast<const uint8_t*>(mapped),
                       static_cast<const uint8_t*>(mapped) + byte_count);
        g_glFuncs.glUnmapBuffer(GL_ELEMENT_ARRAY_BUFFER);
        cpu_indices = scratch.data();
    }

    thread_local std::vector<uint32_t> expanded;
    const size_t quads = (size_t)count / 4u;
    switch (index_size) {
    case 1: expandQuadIndices(cpu_indices, quads, expanded); break;
    case 2: expandQuadIndices(reinterpret_cast<const uint16_t*>(cpu_indices), quads, expanded); break;
    default: expandQuadIndices(reinterpret_cast<const uint32_t*>(cpu_indices), quads, expanded); break;
    }
    if (expanded.empty()) return true;

    auto& st = g_glstate_c.fpe_state;
    if (st.fpe_element_ring == 0) {
        if (g_glFuncs.glGenBuffers == nullptr) return false;
        g_glFuncs.glGenBuffers(1, &st.fpe_element_ring); sfpewNoteInternalBuffer(st.fpe_element_ring);
        if (st.fpe_element_ring == 0) return false;
    }
    g_glFuncs.glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, st.fpe_element_ring);
    st.fpe_ibo_bound = false; // this bind landed in the app's VAO
    const GLintptr offset =
        sfpewUploadElementData(expanded.data(), expanded.size() * sizeof(uint32_t));
    g_glFuncs.glDrawElements(GL_TRIANGLES, (GLsizei)expanded.size(), GL_UNSIGNED_INT,
                             (const void*)(uintptr_t)offset);

    // The element binding is the app's VAO state; hand it back.
    g_glFuncs.glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, (GLuint)app_element_buffer);
    return true;
}

} // namespace

// Declared in fpe/drawing1x.h: multidraw.cpp's glMultiDrawElements calls this
// per sub-draw as its loop fallback, so it needs external linkage rather than
// staying confined to this file's anonymous namespace (mirrors drawArraysNow
// above).
void drawElementsNow(GLenum mode, GLsizei count, GLenum type, const GLvoid* indices,
                     bool forceFixedFunction, GLint elementBufferOverride) {
    const GLint current_program = sfpewLogicalProgram();
    const auto& vertex_array = g_glstate_c.fpe_state.vertexpointer_array;
    const uint32_t vertex_array_mask = 1u << vp2idx(GL_VERTEX_ARRAY);
    // A captured display-list replay owns the arrays it just installed and
    // draws them through the fixed-function pipeline whatever program the app
    // has bound now, exactly as drawArraysNow's forceFixedFunction does - the
    // user-program branches below would hand the app's state back and lose the
    // replay's own element binding with it.
    const bool app_program_draw = !forceFixedFunction && current_program != 0;

    if (g_glstate_c.render_mode != GL_RENDER &&
        (app_program_draw || !(vertex_array.enabled_pointers & vertex_array_mask))) {
        sfpewFlushDeferredDrawState();
        SFPEW_LOGW(
            "selection: draw elements skipped because no fixed-function vertex transform is available");
        return;
    }

    if (app_program_draw || !(vertex_array.enabled_pointers & vertex_array_mask)) {
        // These paths draw with the app's own program/VAO/element state; the
        // glDrawElements entry no longer restores it for fixed-function
        // draws, so it must come back before anything reaches the backend.
        sfpewFlushDeferredDrawState();
        if (current_program != 0) {
            if ((vertex_array.enabled_pointers & vertex_array_mask) &&
                userProgramDrawElements((GLuint)current_program, mode, count, type, indices)) {
                return;
            }
            sfpewFeedUserProgramUniforms((GLuint)current_program);
        }
        if (passthroughLegacyDrawElements(mode, count, type, indices)) return;
        if (g_glFuncs.glDrawElements != nullptr) g_glFuncs.glDrawElements(mode, count, type, indices);
        return;
    }

    const size_t index_size = indexTypeSize(type);
    if (index_size == 0) {
        g_glstate_c.set_error(GL_INVALID_ENUM);
        return;
    }
    if (count < 0) {
        g_glstate_c.set_error(GL_INVALID_VALUE);
        return;
    }
    if (count == 0) return;

    if (g_glstate_c.render_mode != GL_RENDER) {
        // CPU-only selection/feedback. The index list itself may live in an
        // element buffer and the legacy position array may independently live
        // in an array buffer, so read each source while the app's bindings are
        // restored and never submit the draw to the backend.
        sfpewFlushDeferredDrawState();
        GLint element_buffer = elementBufferOverride;
        if (element_buffer < 0)
            g_glFuncs.glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &element_buffer);

        const uint64_t index_bytes = static_cast<uint64_t>(count) * index_size;
        const uint64_t index_offset = reinterpret_cast<uintptr_t>(indices);
        if (index_bytes > static_cast<uint64_t>(std::numeric_limits<GLsizeiptr>::max()) ||
            index_offset > static_cast<uint64_t>(std::numeric_limits<GLintptr>::max())) {
            g_glstate_c.set_error(GL_INVALID_VALUE);
            return;
        }

        auto& selection_index_bytes = drawingScratch().de_selection_index_bytes;
        const uint8_t* cpu_indices = nullptr;
        void* mapped_indices = nullptr;
        if (element_buffer == 0) {
            if (indices == nullptr) {
                g_glstate_c.set_error(GL_INVALID_VALUE);
                return;
            }
            cpu_indices = static_cast<const uint8_t*>(indices);
        } else {
            if (g_glFuncs.glMapBufferRange == nullptr || g_glFuncs.glUnmapBuffer == nullptr) {
                g_glstate_c.set_error(GL_INVALID_OPERATION);
                return;
            }
            mapped_indices = g_glFuncs.glMapBufferRange(
                GL_ELEMENT_ARRAY_BUFFER, static_cast<GLintptr>(index_offset),
                static_cast<GLsizeiptr>(index_bytes), GL_MAP_READ_BIT);
            if (mapped_indices == nullptr) {
                g_glstate_c.set_error(GL_INVALID_OPERATION);
                return;
            }
            selection_index_bytes.assign(
                static_cast<const uint8_t*>(mapped_indices),
                static_cast<const uint8_t*>(mapped_indices) + static_cast<size_t>(index_bytes));
            if (g_glFuncs.glUnmapBuffer(GL_ELEMENT_ARRAY_BUFFER) == GL_FALSE) {
                g_glstate_c.set_error(GL_INVALID_OPERATION);
                return;
            }
            cpu_indices = selection_index_bytes.data();
        }

        auto& selection_indices = drawingScratch().de_selection_indices;
        copyIndicesToUint32(cpu_indices, static_cast<size_t>(count), type, selection_indices);
        const uint32_t max_index =
            *std::max_element(selection_indices.begin(), selection_indices.end());
        if (max_index >= static_cast<uint32_t>(std::numeric_limits<GLsizei>::max())) {
            g_glstate_c.set_error(GL_INVALID_VALUE);
            return;
        }

        array_buffer_binding_guard_t array_buffer_guard;
        const int position_slot = vp2idx(GL_VERTEX_ARRAY);
        auto& selection_source_positions = drawingScratch().de_selection_source_positions;
        if (!sfpewReadVertexPositions(
                vertex_array.attributes[position_slot],
                getClientArrayBufferBinding(position_slot), 0,
                static_cast<GLsizei>(max_index + 1u), selection_source_positions)) {
            g_glstate_c.set_error(GL_INVALID_OPERATION);
            SFPEW_LOGW("selection: failed to read the indexed vertex array");
            return;
        }

        auto& selection_positions = drawingScratch().de_selection_positions;
        selection_positions.resize(static_cast<size_t>(count));
        for (size_t i = 0; i < selection_indices.size(); ++i)
            selection_positions[i] = selection_source_positions[selection_indices[i]];
        sfpewSelectionProcessVertices(
            mode, &selection_positions.front().x, sizeof(glm::vec4) / sizeof(GLfloat), 4,
            selection_positions.size());
        return;
    }

    if (!g_glstate_c.fpe_ready && init_fpe() != 0) {
        if (g_glFuncs.glDrawElements != nullptr) g_glFuncs.glDrawElements(mode, count, type, indices);
        return;
    }

    // Where this draw's indices live. A display-list replay names its own
    // index buffer; everyone else asks for the caller's element-array binding
    // (fpe.hpp, shared with the capture path so the two cannot disagree).
    const GLint element_buffer =
        elementBufferOverride >= 0 ? elementBufferOverride : sfpewResolveElementArrayBinding();

    // Legacy modes: GL_QUADS needs index rewriting; the strip/fan quads
    // modes are vertex-order compatible with core modes.
    GLenum draw_mode = mode;
    const bool rewrite_quads = mode == GL_QUADS;
    const bool mixed_polygon_mode = sfpewMixedPolygonMode(mode);
    if (mode == GL_QUAD_STRIP)
        draw_mode = GL_TRIANGLE_STRIP;
    else if (mode == GL_POLYGON)
        draw_mode = GL_TRIANGLE_FAN;

    // Client-memory vertex arrays force an upload sized by the largest
    // referenced index. Ground-truth classification (plans/13 13.5)
    // replaces the old independent `pointer > 1MB` heuristic, which could -
    // and, per the audit, did - disagree with commit_fpe_state_on_draw's own
    // classifyClientArrays() call below on the very same vertex_array: a
    // large VBO byte offset read as "client memory" here forced an
    // unnecessary glMapBufferRange sync on the index buffer even though the
    // vertex data was never going to be read as client memory downstream.
    // mixed counts as client-memory too: at least one enabled attribute
    // genuinely is, so the max-index scan/upload sizing below stays the
    // conservative superset regardless of how commit_fpe_state_on_draw's own
    // gather_mixed_client_arrays() (plans/13 13.4) resolves it - single_buffer
    // is the only kind that provably needs neither.
    const client_array_kind_t array_kind = classifyClientArrays(vertex_array, nullptr);
    const bool client_vertices = array_kind != client_array_kind_t::single_buffer;

    // Pull the index data to the CPU when we must scan or rewrite it.
    thread_local std::vector<uint8_t> index_scratch;
    const uint8_t* cpu_indices = nullptr;
    if (element_buffer == 0) {
        if (indices == nullptr) {
            g_glstate_c.set_error(GL_INVALID_VALUE);
            return;
        }
        cpu_indices = static_cast<const uint8_t*>(indices);
    } else if (client_vertices || rewrite_quads || mixed_polygon_mode) {
        if (g_glFuncs.glMapBufferRange == nullptr || g_glFuncs.glUnmapBuffer == nullptr) {
            if (g_glFuncs.glDrawElements != nullptr) g_glFuncs.glDrawElements(mode, count, type, indices);
            return;
        }
        const size_t byte_count = static_cast<size_t>(count) * index_size;
        // Bind the caller's index VBO explicitly before mapping: with the
        // draw state held, the current VAO is the wrapper's and its element
        // binding is the wrapper's ring - mapping GL_ELEMENT_ARRAY_BUFFER
        // without this would read the wrong buffer.
        sfpewBackendBindElementBuffer(static_cast<GLuint>(element_buffer));
        g_glstate_c.fpe_state.fpe_ibo_bound = false;
        void* mapped = g_glFuncs.glMapBufferRange(GL_ELEMENT_ARRAY_BUFFER,
                                                  (GLintptr)reinterpret_cast<uintptr_t>(indices),
                                                  (GLsizeiptr)byte_count, GL_MAP_READ_BIT);
        if (mapped == nullptr) {
            if (g_glFuncs.glDrawElements != nullptr) g_glFuncs.glDrawElements(mode, count, type, indices);
            return;
        }
        index_scratch.assign(static_cast<const uint8_t*>(mapped),
                             static_cast<const uint8_t*>(mapped) + byte_count);
        g_glFuncs.glUnmapBuffer(GL_ELEMENT_ARRAY_BUFFER);
        cpu_indices = index_scratch.data();
    }

    uint32_t max_index = 0;
    if ((client_vertices || mixed_polygon_mode) && cpu_indices != nullptr) {
        switch (type) {
        case GL_UNSIGNED_BYTE:
            max_index = maxIndexOf(cpu_indices, static_cast<size_t>(count));
            break;
        case GL_UNSIGNED_SHORT:
            max_index = maxIndexOf(reinterpret_cast<const uint16_t*>(cpu_indices), static_cast<size_t>(count));
            break;
        default:
            max_index = maxIndexOf(reinterpret_cast<const uint32_t*>(cpu_indices), static_cast<size_t>(count));
            break;
        }
        if (max_index >= static_cast<uint32_t>(std::numeric_limits<GLsizei>::max())) {
            g_glstate_c.set_error(GL_INVALID_VALUE);
            return;
        }
    }

    const GLint logical_array_buffer = static_cast<GLint>(sfpewLogicalArrayBufferBinding());
    fpe_backend_draw_state_guard_t backend_state(current_program, logical_array_buffer);

    auto& mixed_positions = drawingScratch().de_mixed_positions;
    auto& mixed_edge_flags = drawingScratch().de_mixed_edge_flags;
    auto& mixed_indices = drawingScratch().de_mixed_indices;
    if (mixed_polygon_mode) {
        if (max_index >= static_cast<uint32_t>(std::numeric_limits<GLsizei>::max())) {
            g_glstate_c.set_error(GL_INVALID_VALUE);
            return;
        }
        copyIndicesToUint32(cpu_indices, static_cast<size_t>(count), type, mixed_indices);
        const GLsizei mixed_vertex_count = static_cast<GLsizei>(max_index + 1u);
        const int position_slot = vp2idx(GL_VERTEX_ARRAY);
        if (!sfpewReadVertexPositions(vertex_array.attributes[position_slot],
                                      getClientArrayBufferBinding(position_slot), 0,
                                      mixed_vertex_count, mixed_positions)) {
            g_glstate_c.set_error(GL_INVALID_OPERATION);
            return;
        }
        mixed_edge_flags.clear();
        const int edge_slot = vp2idx(GL_EDGE_FLAG_ARRAY);
        if (((vertex_array.enabled_pointers >> edge_slot) & 1u) != 0) {
            (void)sfpewReadEdgeFlags(vertex_array.attributes[edge_slot],
                                     getClientArrayBufferBinding(edge_slot), 0,
                                     mixed_vertex_count, mixed_edge_flags);
        }
    }

    // Reuse the arrays-path commit for program/uniform/attribute setup and
    // the client-memory vertex upload. GL_TRIANGLES bypasses its
    // QUADS-from-arrays conversion; first/count only size that upload.
    GLenum commit_mode = GL_TRIANGLES;
    GLint commit_first = 0;
    GLsizei commit_count = client_vertices ? static_cast<GLsizei>(max_index + 1u) : count;
    if (commit_fpe_state_on_draw(&commit_mode, &commit_first, &commit_count, logical_array_buffer) < 0) return;

    if (mixed_polygon_mode &&
        sfpewDrawMixedPolygonMode(mode, mixed_positions.data(), mixed_positions.size(),
                                  mixed_indices.data(), mixed_indices.size(), 0u,
                                  mixed_edge_flags.empty() ? nullptr : mixed_edge_flags.data(),
                                  mixed_edge_flags.size())) {
        return;
    }

    thread_local std::vector<uint32_t> expanded_indices;
    const void* draw_indices = indices;
    GLenum draw_type = type;
    GLsizei draw_count = count;

    if (rewrite_quads) {
        const size_t quad_count = static_cast<size_t>(count) / 4u; // partial quads are dropped per spec
        switch (type) {
        case GL_UNSIGNED_BYTE:
            expandQuadIndices(cpu_indices, quad_count, expanded_indices);
            break;
        case GL_UNSIGNED_SHORT:
            expandQuadIndices(reinterpret_cast<const uint16_t*>(cpu_indices), quad_count, expanded_indices);
            break;
        default:
            expandQuadIndices(reinterpret_cast<const uint32_t*>(cpu_indices), quad_count, expanded_indices);
            break;
        }
        draw_mode = GL_TRIANGLES;
        draw_type = GL_UNSIGNED_INT;
        draw_count = static_cast<GLsizei>(quad_count * 6u);
        if (draw_count == 0) return;
    }

    auto& state = g_glstate_c.fpe_state;
    if (rewrite_quads || element_buffer == 0) {
        const void* upload_data = rewrite_quads ? (const void*)expanded_indices.data()
                                                : (const void*)cpu_indices;
        const size_t upload_bytes = rewrite_quads
                                        ? expanded_indices.size() * sizeof(uint32_t)
                                        : static_cast<size_t>(count) * index_size;

        // Apps redraw the same client-memory index pattern every frame (GUI
        // widgets, glyph quads, chunk passes). The second consecutive draw
        // with byte-identical indices promotes them into a device-local
        // buffer; every later repeat pays a memcmp instead of a ring upload,
        // and the GPU reads its indices from device memory instead of the
        // coherent ring. Capped so a pathological app cannot pin memory.
        constexpr size_t kElementReuseLimit = 1u << 20;
        bool reused = false;
        if (upload_bytes <= kElementReuseLimit && upload_data != nullptr) {
            auto& hot = state.fpe_element_reuse_bytes;
            auto& pending = state.fpe_element_reuse_pending;
            if (state.fpe_element_reuse_buffer != 0 && hot.size() == upload_bytes &&
                std::memcmp(hot.data(), upload_data, upload_bytes) == 0) {
                sfpewBackendBindElementBuffer(state.fpe_element_reuse_buffer);
                state.fpe_ibo_bound = false; // fpe_vao's element binding changed
                draw_indices = (const void*)0;
                reused = true;
            } else if (pending.size() == upload_bytes &&
                       std::memcmp(pending.data(), upload_data, upload_bytes) == 0) {
                // Second sighting: promote. A miss keeps streaming through
                // the ring, so one-shot index sets never pay glBufferData.
                if (state.fpe_element_reuse_buffer == 0) {
                    g_glFuncs.glGenBuffers(1, &state.fpe_element_reuse_buffer);
                    sfpewNoteInternalBuffer(state.fpe_element_reuse_buffer);
                }
                if (state.fpe_element_reuse_buffer != 0) {
                    sfpewBackendBindElementBuffer(state.fpe_element_reuse_buffer);
                    state.fpe_ibo_bound = false;
                    g_glFuncs.glBufferData(GL_ELEMENT_ARRAY_BUFFER,
                                           (GLsizeiptr)upload_bytes, upload_data,
                                           GL_STATIC_DRAW);
                    hot.assign(static_cast<const uint8_t*>(upload_data),
                               static_cast<const uint8_t*>(upload_data) + upload_bytes);
                    pending.clear();
                    draw_indices = (const void*)0;
                    reused = true;
                }
            } else {
                pending.assign(static_cast<const uint8_t*>(upload_data),
                               static_cast<const uint8_t*>(upload_data) + upload_bytes);
            }
        }

        if (!reused) {
            // CPU-side index data streams through the persistent-mapped
            // element ring. glBufferData here orphaned and reallocated a
            // buffer on every indexed client-array draw, which measured as
            // about half that draw's cost (plans/12).
            if (state.fpe_element_ring == 0) g_glFuncs.glGenBuffers(1, &state.fpe_element_ring); sfpewNoteInternalBuffer(state.fpe_element_ring);
            sfpewBackendBindElementBuffer(state.fpe_element_ring);
            state.fpe_ibo_bound = false; // fpe_vao's element binding changed
            draw_indices = (const void*)(uintptr_t)sfpewUploadElementData(upload_data, upload_bytes);
        }
    } else {
        // Indices stay in the caller's VBO; bind it inside fpe_vao.
        sfpewBackendBindElementBuffer(static_cast<GLuint>(element_buffer));
        state.fpe_ibo_bound = false;
    }

    g_glFuncs.glDrawElements(draw_mode, draw_count, draw_type, draw_indices);
}

namespace {

// glDrawElements and glDrawRangeElements are one entry point under two names
// as far as the wrapper is concerned, so they share one body rather than two
// copies of a display-list gate that would have to stay identical.
void drawElementsEntry(GLenum mode, GLsizei count, GLenum type, const GLvoid* indices) {
    if (!sfpewEnsureBackend()) return;
    (void)g_glstate; // entry strict resolve; commit/capture path reads the snapshot
    // Same contract as glDrawArrays: a fixed-function draw re-establishes
    // the wrapper's state itself; only user-program draws consume the app's -
    // and recording, whose capture reads the caller's arrays and index buffer
    // through the app's own bindings and so needs them live.
    flushPendingImmediateDraws();
    if (sfpewLogicalProgram() != 0 || DisplayListManager::shouldRecord())
        sfpewFlushDeferredDrawState();

    // GL 2.1 5.4: under GL_COMPILE the draw belongs in the list, with both its
    // arrays and its indices dereferenced now (plans/15 15.4). Until this was
    // here the draw went straight to the screen and the list came out empty.
    // A capture that cannot be taken records nothing and the GL_COMPILE case
    // still returns: omitting the geometry beats replaying whatever the
    // caller's pointers point at by then, which is what glDrawArrays does too.
    if (!disableRecording && DisplayListManager::shouldRecord()) {
        sfpewRecordCapturedDrawElements(mode, count, type, indices);
        if (DisplayListManager::shouldFinish()) return;
    }

    drawElementsNow(mode, count, type, indices);
}

} // namespace

void glDrawElements(GLenum mode, GLsizei count, GLenum type, const GLvoid* indices) {
    drawElementsEntry(mode, count, type, indices);
}

// GL 1.2 core. start/end are a promise about the index range, not state, so
// the wrapper can honor it by simply forwarding to the glDrawElements
// logic: legacy modes get converted, fixed-function arrays get wired and
// the emulated alpha test uniforms get fed. Passing this through raw (the
// previous behavior) meant GL_QUADS died on GLES and cutout foliage drawn
// this way kept a stale alpha-test state.
void glDrawRangeElements(GLenum mode, GLuint start, GLuint end, GLsizei count, GLenum type,
                         const GLvoid* indices) {
    // The recording path has no use for them either: it derives the captured
    // vertex range by scanning the indices, which is exact where start/end are
    // only a promise an app is free to break (plans/15 15.3).
    (void)start;
    (void)end;
    drawElementsEntry(mode, count, type, indices);
}
