// SimpleFPEWrapper - SimpleFPEWrapper/fpe/fpe.hpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#pragma once

#include <GL/gl.h>
#include <cstdint>
#include <vector>
#include "transformation.h"
#include "state.h"
#include "vertexpointer.h"
#include "../init.h"

void sfpewFlushDeferredDrawState();

#define GET_PREV_PROGRAM                                                                                               \
    GLint m_prev_program;                                                                                              \
    g_glFuncs.glGetIntegerv(GL_CURRENT_PROGRAM, &m_prev_program);
#define SET_PREV_PROGRAM                                                                                               \
    sfpewInvalidateImmediateDrawState();                                                                                \
    g_glFuncs.glUseProgram(m_prev_program);

// Strict resolve (one eglGetCurrentContext) - use for the FIRST context
// access of an exported entry point. Downstream code uses g_glstate_c.
// The strict resolve, with its fast path inlined here (types.h).
#define g_glstate sfpewResolveState()
// Relaxed: thread-local snapshot refreshed by the entry's strict resolve.
#define g_glstate_c glstate_t::current()

int init_fpe();

// User-program compatibility uniforms (shader/userprogram.cpp, plans/09 9.3).
void sfpewFeedUserProgramUniforms(GLuint program);


// Replays a GL_COLOR_BUFFER_BIT / GL_ENABLE_BIT blend-state snapshot onto
// the backend (glPopAttrib). Only the differing calls are issued.
void restore_color_buffer(const color_buffer_state_t& current, const color_buffer_state_t& wanted);

// Replays a GL_DEPTH_BUFFER_BIT / GL_STENCIL_BUFFER_BIT / GL_SCISSOR_BIT /
// GL_ENABLE_BIT depth-stencil-scissor snapshot onto the backend
// (glPopAttrib). `mask` gates which of the four groups actually restores -
// the caller passes the ORIGINAL push mask, not a merged one, since a pop
// must only touch what its own push captured. Only the differing calls are
// issued; the caller is responsible for writing `wanted` back into its own
// `backend_state` shadow afterward (these calls go straight to the backend
// and do not update it themselves).
void restore_depth_stencil_scissor(const fixed_function_state_t::backend_state_shadow_t& current,
                                   const fixed_function_state_t::backend_state_shadow_t& wanted,
                                   GLbitfield mask);

// plans/09 S9 mixed pipeline: a bound USER program still consumes the
// fixed-function vertex arrays / immediate-mode vertices in GL 2.1. These
// resolve the program's fpe_* attribute locations (slot-indexed like
// vertex_pointer_array_t; false when the program has no fpe_Vertex) and
// submit the current arrays onto those locations inside fpe_user_vao.
bool sfpewUserProgramAttribLocations(GLuint program, GLint out_locations[VERTEX_POINTER_COUNT]);
bool gather_client_arrays(const vertex_pointer_array_t& raw, GLint first, GLsizei count,
                          vertex_pointer_array_t* out);

// Ground-truth classification of a draw's enabled vertex attributes: whether
// their `gl*Pointer` data source is real client memory, one shared VBO, or a
// mix of the two/several VBOs - read from client_array_buffer_bindings[]
// (types.h, populated by rememberClientArrayBufferBinding at every gl*Pointer
// call) rather than guessed from the `pointer` value's magnitude, which
// cannot tell a real address from a small buffer offset (plans/13).
enum class client_array_kind_t { all_client_memory, single_buffer, mixed };
client_array_kind_t classifyClientArrays(const vertex_pointer_array_t& raw, GLuint* out_buffer_id);

// `mixed` counterpart to gather_client_arrays (plans/13 13.4): some enabled
// attributes are real client memory, others are byte offsets into a bound
// VBO (the same buffer for more than one, or several different ones) - no
// single glVertexAttribPointer/glBindBuffer pair can express that, so every
// attribute's bytes are read to the CPU individually (buffer-backed ones via
// a synchronous glMapBufferRange readback) and interleaved into the same
// gathered-buffer shape gather_client_arrays produces, so it flows through
// the identical downstream ring-upload path. False on failure (draw should
// be dropped, not fallen back on - the old pointer-magnitude heuristic this
// replaces is gone).
bool gather_mixed_client_arrays(const vertex_pointer_array_t& raw, GLint first, GLsizei count,
                                vertex_pointer_array_t* out);

// Bytes a `count`-vertex draw may read out of a client-memory layout: the
// last row stops at its last attribute, not at the end of the stride (GL 2.1
// 2.8). Every site that uploads client vertex data calls this - see its
// definition in fpe.cpp for why that is not optional.
int64_t sfpewClientArrayUploadSize(const vertex_pointer_array_t& va, GLsizei count);
// How the app's OWN generic attribute arrays are to be replayed into
// fpe_user_vao alongside the fixed-function ones (plans/16 H6).
//
// `active` is false for immediate mode: GL 2.1 2.8 has the array commands as
// the only consumers of vertex arrays, so inside glBegin/glEnd every generic
// attribute takes its current value and replaying the arrays would be wrong.
//
// `base_vertex` is what the fixed-function gather rebased away. When a
// client-memory gather folds glDrawArrays' `first` into the upload the draw
// then issues first = 0, but the app's generic arrays were never rebased and
// still have to be read from element `first` on.
struct user_program_array_mirror_t {
    bool active = false;
    GLint base_vertex = 0;
    // Restored after the replay, so the call leaves the ARRAY_BUFFER binding
    // exactly as the caller set it up.
    GLuint source_buffer = 0;
};

void sfpewSendUserProgramAttributes(const GLint locations[VERTEX_POINTER_COUNT],
                                    const vertex_pointer_array_t& va, GLintptr binding_offset,
                                    const user_program_array_mirror_t& mirror = {});
// Full fixed-function-arrays draw through a user program. Returns true
// when the draw was submitted (or dropped on error); false = caller must
// fall back to the plain passthrough.
bool sfpewUserProgramFixedFunctionDrawArrays(GLuint program, GLenum mode, GLint first,
                                             GLsizei count);
void sfpewForgetUserProgram(GLuint program);

// Evaluator enables (fpe/evaluators.cpp, plans/10 10.2).
bool sfpewEvaluatorEnable(GLenum cap, bool enable);

// Evaluator enables (fpe/evaluators.cpp, plans/10 10.2).
bool sfpewEvaluatorEnable(GLenum cap, bool enable);

// Selection/feedback CPU pipeline (fpe/selection.cpp, plans/10 10.3).
void sfpewFlushSelectionHit();
void sfpewSelectionProcessVertices(GLenum mode, const GLfloat* positions, size_t stride_floats,
                                   GLint position_size, size_t vertex_count,
                                   const GLfloat* colors = nullptr,
                                   size_t color_stride_floats = 0, GLint color_size = 0,
                                   const GLfloat* texcoords = nullptr,
                                   size_t texcoord_stride_floats = 0, GLint texcoord_size = 0);
bool prepare_quad_indices(GLsizei count, GLuint first = 0);
const void* quad_index_data();
size_t quad_index_size_bytes();
GLenum quad_index_type();

// Route every wrapper-side backend VAO / element-array bind through these so
// the binding shadows on glstate_t stay exact (docs/context-model.md). All
// call sites run downstream of an entry's strict resolve.
inline void sfpewBackendBindVertexArray(GLuint vao) {
    g_glFuncs.glBindVertexArray(vao);
    auto& gs = g_glstate_c;
    gs.backend_vao_binding = static_cast<GLint>(vao);
    gs.backend_vao_known = true;
    // Any VAO change invalidates the immediate-draw fast path; the immediate
    // path re-arms it after its own binds. Putting the clear here means the
    // other FPE draw paths and the app's own glBindVertexArray get it for free.
    gs.immediate_live_program = -1;
    gs.immediate_live_buffer = 0;
}

// Anything that binds a program, VAO or array buffer other than the
// immediate-draw trio must call this, or the next immediate draw skips a bind
// it actually needed (plans/12).
// True for the primitive modes glPolygonMode applies to. Points and lines
// are rasterized as themselves whatever the polygon mode says.
inline bool sfpewIsFilledPrimitive(GLenum mode) {
    return mode == GL_TRIANGLES || mode == GL_TRIANGLE_STRIP || mode == GL_TRIANGLE_FAN ||
           mode == GL_QUADS || mode == GL_QUAD_STRIP || mode == GL_POLYGON;
}

// The polygon mode in force when both faces agree. GL_NONE means the modes
// differ and the draw must go through sfpewDrawMixedPolygonMode(). Keeping
// mixed mode distinct from GL_FILL also prevents immediate-mode batching from
// rewriting the application's polygon boundaries before facing is classified.
inline GLenum sfpewUniformPolygonMode() {
    const auto& un = g_glstate_c.fpe_uniform;
    return un.polygon_mode_front == un.polygon_mode_back ? un.polygon_mode_front : GL_NONE;
}

inline bool sfpewMixedPolygonMode(GLenum primitive) {
    const auto& un = g_glstate_c.fpe_uniform;
    return sfpewIsFilledPrimitive(primitive) &&
           un.polygon_mode_front != un.polygon_mode_back;
}

// Copies a legacy position array into CPU-visible homogeneous coordinates.
// VBO-backed arrays are mapped through the backend; client arrays are read in
// place. This is shared by mixed polygon-mode facing and selection/feedback.
bool sfpewReadVertexPositions(const vertexattribute_t& attribute, GLuint array_buffer,
                              GLint first, GLsizei count, std::vector<glm::vec4>& out);

// Same source handling for the one-component GL_EDGE_FLAG_ARRAY.
bool sfpewReadEdgeFlags(const vertexattribute_t& attribute, GLuint array_buffer,
                        GLint first, GLsizei count, std::vector<uint8_t>& out);

// Handles a draw whose front/back polygon modes differ. `positions` contains
// object-space vertices; optional `indices` addresses that array. Generated
// backend indices add output_base, allowing a draw-array range uploaded at
// vertex zero or left in a VBO at `first` to use the same classifier. Returns
// true when the draw was handled, including an empty result after culling.
bool sfpewDrawMixedPolygonMode(GLenum primitive, const glm::vec4* positions,
                               size_t position_count, const uint32_t* indices,
                               size_t index_count, uint32_t output_base,
                               const uint8_t* edge_flags = nullptr,
                               size_t edge_flag_count = 0);

// glLineStipple rasterization (defects-plan.md 1.5), immediate-mode path
// only - see linestipple.cpp's header comment for the full scope and the
// spec's per-primitive counter-reset rule this follows. `vertices`,
// `floatCount`, `vertexCount` and `sizes` are exactly
// drawImmediateVertices' own parameters; `primitive` must be one of
// GL_LINES/GL_LINE_STRIP/GL_LINE_LOOP.
void sfpewDrawStippledLines(GLenum primitive, const GLfloat* vertices, size_t floatCount,
                            size_t vertexCount, const fixed_function_draw_size_t& sizes);

// Expands a filled primitive into the GL_LINES index pairs that outline it,
// for GL_LINE polygon mode. Indices are emitted relative to `base`. Shared
// edges are emitted twice, which is visually identical to a wireframe.
// Shared by the client-array commit and the immediate-mode draw so the two
// cannot disagree about what an outline is.
//
// `edge_flags`, when non-null, holds `flag_count` per-vertex edge flags
// indexed the same way as the primitive's vertices (NOT offset by `base`).
// An edge is emitted only when the flag of the vertex it LEAVES is set,
// which is how GL defines glEdgeFlag: the flag current when a vertex is
// specified controls the edge beginning at it. Null means every edge is a
// boundary edge, the GL default.
void sfpewBuildWireframeIndices(GLenum mode, uint32_t base, uint32_t count,
                                std::vector<uint32_t>& out,
                                const uint8_t* edge_flags = nullptr,
                                size_t flag_count = 0);

// Uploads wireframe indices into the dedicated element buffer and binds it.
// Returns false when no backend buffer could be created.
bool sfpewUploadWireframeIndices(const std::vector<uint32_t>& wire);

// GL_QUAD_STRIP and GL_POLYGON have no GLES equivalent but ARE vertex-order
// compatible with a core mode, so converting them is a mode swap plus a
// count truncation. Both halves matter:
//
//   - Without the swap the raw legacy enum reaches the backend and the draw
//     dies with GL_INVALID_ENUM, rendering nothing.
//   - Without the truncation an INCOMPLETE trailing group starts drawing.
//     GL_QUAD_STRIP needs vertices in pairs and at least four of them; a
//     3-vertex strip must draw nothing, but GL_TRIANGLE_STRIP happily draws
//     a triangle from those same three vertices. (GL_POLYGON needs no
//     truncation: a fan of fewer than three vertices already draws nothing.)
//
// Leaves every other mode, GL_QUADS included, untouched - quads convert to
// indexed triangles separately, and that path does its own (count / 4) * 6
// truncation.
inline void sfpewConvertLegacyDrawMode(GLenum* mode, GLsizei* count) {
    if (*mode == GL_QUAD_STRIP) {
        *mode = GL_TRIANGLE_STRIP;
        *count = *count >= 4 ? (*count & ~GLsizei{1}) : 0;
    } else if (*mode == GL_POLYGON) {
        *mode = GL_TRIANGLE_FAN;
    }
}

inline void sfpewInvalidateImmediateDrawState() {
    g_glstate_c.immediate_live_program = -1;
    g_glstate_c.immediate_live_buffer = 0;
}

// Registers a buffer object the WRAPPER created for its own draw plumbing.
// The logical array-buffer shadow treats a backend readback that returns one
// of these as logical zero - it is leftover wrapper state, not the app's
// binding (mirror of internal_programs; see sfpewLogicalProgram).
inline void sfpewNoteInternalBuffer(GLuint buffer) {
    if (buffer != 0) g_glstate_c.internal_buffers.insert(buffer);
}

// MUST be called wherever the wrapper deletes one of its own buffers. A
// deleted name goes back to the GL name pool and the app's next glGenBuffers
// can hand it out again; a stale entry here would then make the array-buffer
// shadow treat the APP'S OWN VBO as wrapper-internal and report it as zero -
// fixed-function draws silently switch their attribute source to the ring
// and read garbage vertices. Seen in the wild within hours of b3dd356: MC
// 1.12 with "Use VBOs" recycles chunk VBO names constantly, so random chunks
// rendered with corrupted vertices.
inline void sfpewForgetInternalBuffer(GLuint buffer) {
    if (buffer != 0) g_glstate_c.internal_buffers.erase(buffer);
}

// Binds the array buffer a fixed-function draw will source attributes from,
// skipping the call when the backend provably has it already.
//
// The guard below hands the app's ARRAY_BUFFER binding to the context and then
// deliberately leaves the backend alone until sfpewEntryBarrier() restores it,
// so while a save is held and nothing has rebound since, deferred_draw
// .array_buffer IS the live backend binding. A fixed-function draw that sources
// straight from the app's own VBO therefore asks for the buffer that is already
// bound. Measured on RDC/Minecraft/1.16-Optifine/1-frame19661.rdc: one
// redundant bind per draw, 107 of the frame's 549 glBindBuffer calls.
//
// guard_holds_save must be the guard's holds_save: false means an earlier
// fixed-function draw is holding the save and the backend carries THAT draw's
// attribute buffer, which this function cannot know - so it always binds.
inline void sfpewBackendBindAttributeBuffer(GLuint buffer, bool guard_holds_save) {
    const auto& held = g_glstate_c.deferred_draw;
    if (guard_holds_save && held.held && held.array_buffer == static_cast<GLint>(buffer)) return;
    g_glFuncs.glBindBuffer(GL_ARRAY_BUFFER, buffer);
}

inline void sfpewBackendBindElementBuffer(GLuint buffer) {
    g_glFuncs.glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, buffer);
    auto& gs = g_glstate_c;
    if (gs.backend_vao_known && gs.backend_vao_binding == 0) {
        gs.backend_vao0_element_binding = static_cast<GLint>(buffer);
        gs.backend_vao0_element_known = true;
    }
}

// Which buffer an indexed draw's `indices` argument is an offset into - the
// caller's element-array binding, which is VAO state. Resolved from the
// wrapper's shadows instead of a synchronous glGetIntegerv per draw: while a
// fixed-function draw holds the app's state the held snapshot has it, and
// outside that VAO 0's binding is shadowed (healed every 256 draws by the
// guard). The leftover cases - app VAO unknown or non-zero - restore and take
// the real query, which also leaves the app's own binding live for a caller
// that means to read the buffer.
//
// Single source of truth on purpose: this is the index-side counterpart of
// classifyClientArrays' ground truth for vertex attributes (plans/13), and the
// immediate draw path and the display-list capture path must never disagree
// about whether a given `indices` value is a client pointer or a byte offset.
inline GLint sfpewResolveElementArrayBinding() {
    auto& gs = g_glstate_c;
    if (gs.deferred_draw.held && gs.deferred_draw.vertex_array == 0 &&
        gs.deferred_draw.element_array_buffer >= 0) {
        return gs.deferred_draw.element_array_buffer;
    }
    if (!gs.deferred_draw.held && gs.backend_vao_known && gs.backend_vao_binding == 0 &&
        gs.backend_vao0_element_known) {
        return gs.backend_vao0_element_binding;
    }
    sfpewFlushDeferredDrawState();
    GLint element_buffer = 0;
    g_glFuncs.glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &element_buffer);
    return element_buffer;
}

struct fpe_backend_draw_state_guard_t {
    GLint program = 0;
    GLint vertex_array = 0;
    GLint array_buffer = 0;
    // -1: not captured; the restored VAO carries its own element binding.
    GLint element_array_buffer = -1;
    // Without a backend (no context yet / loader failure) the guard must be
    // inert: display-list replay reaches this even backend-less.
    bool active = false;
    // True when THIS guard captured the save (rather than finding one already
    // held by an earlier fixed-function draw).
    bool holds_save = false;

    explicit fpe_backend_draw_state_guard_t(GLint known_program = -1,
                                            GLint known_array_buffer = -1) {
        if (g_glFuncs.glGetIntegerv == nullptr || g_glFuncs.glUseProgram == nullptr ||
            g_glFuncs.glBindVertexArray == nullptr || g_glFuncs.glBindBuffer == nullptr) {
            return;
        }
        active = true;

        // A previous fixed-function draw may still be holding the app's state.
        // The save is already made and the backend is already in OUR state, so
        // capturing again here would record the wrapper's own bindings as if
        // they were the app's - the classic way a deferred scheme corrupts
        // state. Leave the existing save alone.
        if (g_glstate_c.deferred_draw.held) {
            holds_save = false;
            return;
        }
        holds_save = true;

        if (known_program >= 0)
            program = known_program;
        else
            g_glFuncs.glGetIntegerv(GL_CURRENT_PROGRAM, &program);
        if (known_array_buffer >= 0)
            array_buffer = known_array_buffer;
        else
            g_glFuncs.glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &array_buffer);

        // The two remaining bindings come from the backend shadows instead of
        // synchronous glGetIntegerv round-trips; a real query self-heals them
        // every 256 draws (JNI-direct callers cannot desync them for long).
        auto& gs = g_glstate_c;
        const bool heal = (++gs.backend_shadow_heal_counter & 0xFFu) == 0u;
        if (gs.backend_vao_known && !heal) {
            vertex_array = gs.backend_vao_binding;
        } else {
            g_glFuncs.glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vertex_array);
            gs.backend_vao_binding = vertex_array;
            gs.backend_vao_known = true;
        }
        if (vertex_array == 0) {
            if (gs.backend_vao0_element_known && !heal) {
                element_array_buffer = gs.backend_vao0_element_binding;
            } else {
                g_glFuncs.glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &element_array_buffer);
                gs.backend_vao0_element_binding = element_array_buffer;
                gs.backend_vao0_element_known = true;
            }
        }

        // Hand the save to the context so it outlives this guard. From here
        // the backend stays in the wrapper's draw state until
        // sfpewEntryBarrier(), so consecutive fixed-function draws neither
        // restore nor re-bind it.
        gs.deferred_draw = {true, program, vertex_array, array_buffer, element_array_buffer};
    }

    // Deliberately does not restore: the save lives on the context and is
    // replayed by sfpewEntryBarrier() at the next entry point that is not an
    // immediate-mode vertex call, so a run of fixed-function draws pays the
    // restore once instead of once per draw (plans/12).
    ~fpe_backend_draw_state_guard_t() = default;

    fpe_backend_draw_state_guard_t(const fpe_backend_draw_state_guard_t&) = delete;
    fpe_backend_draw_state_guard_t& operator=(const fpe_backend_draw_state_guard_t&) = delete;
};

struct array_buffer_binding_guard_t {
    GLint binding = 0;

    array_buffer_binding_guard_t() { g_glFuncs.glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &binding); }

    ~array_buffer_binding_guard_t() {
        g_glFuncs.glBindBuffer(GL_ARRAY_BUFFER, binding);
        // The restore changed the backend binding underneath the immediate
        // arm; cold path, so a plain invalidate keeps the invariant simple.
        sfpewInvalidateImmediateDrawState();
    }

    array_buffer_binding_guard_t(const array_buffer_binding_guard_t&) = delete;
    array_buffer_binding_guard_t& operator=(const array_buffer_binding_guard_t&) = delete;
};

// -1 - FPE unavailable, 0 - keep DrawArrays, 1 - switch to DrawElements
int commit_fpe_state_on_draw(GLenum* mode, GLint* first, GLsizei* count, GLint previous_array_buffer);
