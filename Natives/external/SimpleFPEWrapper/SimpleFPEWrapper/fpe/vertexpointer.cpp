// SimpleFPEWrapper - SimpleFPEWrapper/fpe/vertexpointer.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "vertexpointer.h"
#include "../log.h"
#include "fpe.hpp"
#include "drawing1x.h"
#include <algorithm>
#include <cstring>

#define DEBUG 0

namespace {

struct logical_array_buffer_state_t {
    EGLContext context = EGL_NO_CONTEXT;
    GLuint binding = 0;
    bool known = false;
};

thread_local logical_array_buffer_state_t logicalArrayBufferState;

logical_array_buffer_state_t& getLogicalArrayBufferState() {
    // Reconciles against the calling entry's strict-resolve snapshot
    // (docs/context-model.md); no eglGetCurrentContext of its own.
    const EGLContext context = (EGLContext)glstate_t::cached_context();
    if (logicalArrayBufferState.context != context) {
        logicalArrayBufferState = {};
        logicalArrayBufferState.context = context;
    }
    return logicalArrayBufferState;
}

GLuint getLogicalArrayBufferBinding() {
    auto& state = getLogicalArrayBufferState();

    // Callers that bypass the glBindBuffer wrapper (JNI direct dispatch, a
    // layered wrapper) would otherwise desynchronize this shadow for the rest
    // of the process: unlike the program and VAO shadows it had no heal at all,
    // and once seeded it answered from itself forever. Re-read the truth every
    // 256 queries, the same self-healing reconciliation those two use
    // (sfpewLogicalProgram, plans/07) - one glGetIntegerv per ~256 queries.
    thread_local unsigned reconcile_counter = 0;
    const bool reconcile = (++reconcile_counter & 0xFFu) == 0u;

    // While a fixed-function draw holds the app's state the backend has the
    // WRAPPER's buffer bound, so asking it would poison the shadow with the
    // ring buffer as if the app had bound it (plans/12). The save on the
    // context is the app's truth here; the reconcile waits for the next
    // unheld query.
    const bool held = g_glstate_c.deferred_draw.held;
    if (state.known && !(reconcile && !held)) return state.binding;

    if (held) {
        state.binding = static_cast<GLuint>(g_glstate_c.deferred_draw.array_buffer);
        state.known = true;
        return state.binding;
    }

    if (!sfpewEnsureBackend() || g_glFuncs.glGetIntegerv == nullptr) {
        return state.known ? state.binding : 0;
    }
    GLint binding = 0;
    g_glFuncs.glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &binding);
    // Backend readbacks can catch one of the wrapper's own buffers (rings,
    // quad-index storage, the display-list arena): with the deferred restore
    // those legitimately stay bound between fixed-function draws. Adopting
    // one would make the guard restore the wrapper's buffer as if the app had
    // bound it, and later draws would source attributes from it (mirror of
    // the internal_programs rule in sfpewLogicalProgram; on-device forensics
    // caught "arraybuffer shadow heal 0 -> 4" with 4 being our arena).
    if (binding != 0 &&
        g_glstate_c.internal_buffers.count(static_cast<unsigned>(binding)) != 0) {
        binding = 0;
    }
    state.binding = static_cast<GLuint>(binding);
    state.known = true;
    return state.binding;
}

GLuint getLogicalVertexArrayBinding() {
    // The shadow itself lives on glstate_t next to the element-buffer one
    // (docs/context-model.md); the draw guard heals both every 256 draws, so
    // this only has to answer from it, or seed it once.
    auto& gs = g_glstate_c;
    // Held: backend_vao_binding is the wrapper's fpe_vao, not the app's.
    if (gs.deferred_draw.held) return static_cast<GLuint>(gs.deferred_draw.vertex_array);
    if (gs.backend_vao_known) return static_cast<GLuint>(gs.backend_vao_binding);

    if (!sfpewEnsureBackend() || g_glFuncs.glGetIntegerv == nullptr) return 0;
    GLint binding = 0;
    g_glFuncs.glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &binding);
    gs.backend_vao_binding = binding;
    gs.backend_vao_known = true;
    return static_cast<GLuint>(binding);
}

void rememberClientArrayBufferBinding(int index) {
    if (index < 0 || index >= VERTEX_POINTER_COUNT) return;
    g_glstate_c.fpe_state.client_array_buffer_bindings[index] = getLogicalArrayBufferBinding();
}

// Deleting a buffer clears the backend's VAO/binding references to it and
// returns the NAME to the pool. send_vertex_attributes skips its rebind
// whenever its cache already names the same buffer, so an object later handed
// the recycled name would be matched by an entry describing the dead one and
// never get the bind it needs. list_capture.cpp runs the identical scrub for
// the buffers the wrapper deletes itself (two sites); worth folding into one
// shared helper once both files are free to edit.
void forgetVertexAttributeCache(GLuint buffer) {
    if (buffer == 0) return;
    auto& gs = g_glstate_c;
    if (gs.fpe_vertex_binding_valid && gs.fpe_vertex_binding_buffer == buffer) {
        gs.fpe_vertex_binding_valid = false;
    }
    for (auto& attribute : gs.fpe_vertex_attributes) {
        if (!attribute.separate_binding && attribute.array_buffer == buffer) {
            attribute.pointer_valid = false;
        }
    }
}

// The app's generic attribute array declarations, shadowed per VAO so a
// user-program draw through fpe_user_vao can replay them (plans/16 H6).
// Every writer below runs downstream of sfpewEntryBarrier(), so the app's own
// VAO and array buffer are the live ones and the two logical resolves answer
// about the app's state rather than the wrapper's.
app_vertex_attrib_arrays_t* appAttribArrays(bool create) {
    auto& gs = g_glstate_c;
    const GLuint vao = getLogicalVertexArrayBinding();
    if (!create) {
        auto found = gs.app_attrib_arrays.find(vao);
        return found == gs.app_attrib_arrays.end() ? nullptr : &found->second;
    }
    return &gs.app_attrib_arrays[vao];
}

void recordAppAttribPointer(GLuint index, GLint size, GLenum type, bool normalized, bool integer,
                            GLsizei stride, const void* pointer) {
    if (index >= (GLuint)SFPEW_TRACKED_VERTEX_ATTRIBS) return;
    auto* record = appAttribArrays(true);
    if (record == nullptr) return;
    auto& attribute = record->attribs[index];
    attribute.pointer = pointer;
    attribute.buffer = getLogicalArrayBufferBinding();
    attribute.stride = stride;
    attribute.size = size;
    attribute.type = type;
    attribute.normalized = normalized;
    attribute.integer = integer;
    attribute.declared = true;
}

// A deleted buffer's name goes back to the pool, so a shadowed attribute
// still naming it would replay a live but unrelated object into fpe_user_vao
// - the H2 disease one level up. GL only resets the CURRENT VAO's references,
// but a dangling one in any other VAO is undefined to source from anyway, so
// forgetting the declaration everywhere is both safe and stricter.
void forgetAppAttribArrayBuffer(GLuint buffer) {
    if (buffer == 0) return;
    for (auto& entry : g_glstate_c.app_attrib_arrays) {
        for (auto& attribute : entry.second.attribs) {
            if (attribute.declared && attribute.buffer == buffer) {
                attribute.declared = false;
                attribute.buffer = 0;
                attribute.pointer = nullptr;
            }
        }
    }
}

void recordAppAttribEnable(GLuint index, bool enabled) {
    if (index >= (GLuint)SFPEW_TRACKED_VERTEX_ATTRIBS) return;
    // Only an enable creates the record: a disable of something never declared
    // has nothing to say, and the latch below must not fire for it.
    auto* record = appAttribArrays(enabled);
    if (record == nullptr) return;
    if (enabled) {
        record->enabled_mask |= 1u << index;
        g_glstate_c.app_attrib_arrays_used = true;
    } else {
        record->enabled_mask &= ~(1u << index);
    }
}

} // namespace

void glBindBuffer(GLenum target, GLuint buffer) {
    if (!sfpewEnsureBackend() || g_glFuncs.glBindBuffer == nullptr) return;
    (void)g_glstate; // entry strict resolve; the array-buffer shadow reads the snapshot
    if (target == GL_ARRAY_BUFFER) {
        // GL_ARRAY_BUFFER is global (not VAO) state, so the bind can land
        // while a fixed-function draw still holds the app's draw state: the
        // held snapshot is updated so the eventual restore reproduces THIS
        // binding, and the immediate arm forgets its buffer so the next FPE
        // draw re-binds its own source. Handing the whole trio back here made
        // every bind-pointers-draw sequence (the MC chunk VBO shape) pay a
        // glUseProgram(0) -> glUseProgram(fpe) round trip per draw.
        flushPendingImmediateDraws();
        g_glFuncs.glBindBuffer(GL_ARRAY_BUFFER, buffer);
        auto& gs = g_glstate_c;
        // The arm tracks the backend ARRAY binding the wrapper knows about;
        // this bind just went straight through, so record the exact value.
        // The next FPE draw whose attribute source IS this buffer (the MC
        // chunk shape: bind, respecify pointers, draw) then skips its
        // re-bind entirely instead of re-issuing it for the driver to dedup.
        gs.immediate_live_buffer = buffer;
        if (gs.deferred_draw.held) {
            gs.deferred_draw.array_buffer = static_cast<GLint>(buffer);
        }
        auto& state = getLogicalArrayBufferState();
        state.binding = buffer;
        state.known = true;
        return;
    }
    sfpewEntryBarrier();
    g_glFuncs.glBindBuffer(target, buffer);
    if (target == GL_ELEMENT_ARRAY_BUFFER) {
        // Element bindings are VAO state; app calls run with the app's VAO
        // bound (the draw guard restored it). Track VAO 0's binding for the
        // guard; with an unknown or non-zero backend VAO, force a re-query.
        auto& gs = g_glstate_c;
        if (gs.backend_vao_known && gs.backend_vao_binding == 0) {
            gs.backend_vao0_element_binding = static_cast<GLint>(buffer);
            gs.backend_vao0_element_known = true;
        } else {
            gs.backend_vao0_element_known = false;
        }
    }
}

void glDeleteBuffers(GLsizei n, const GLuint* buffers) {
    if (!sfpewEnsureBackend() || g_glFuncs.glDeleteBuffers == nullptr) return;
    (void)g_glstate; // entry strict resolve; the array-buffer shadow reads the snapshot
    sfpewEntryBarrier();
    g_glFuncs.glDeleteBuffers(n, buffers);
    if (n <= 0 || buffers == nullptr) return;

    // A deleted name's "wrapper-internal" identity dies with it, whoever
    // deleted it - the pool will recycle the name (see
    // sfpewForgetInternalBuffer). Wrapper-side deletions call the helper at
    // their own sites; this covers names the app deletes.
    for (GLsizei i = 0; i < n; ++i) sfpewForgetInternalBuffer(buffers[i]);

    // Deleting the buffer the arm remembers un-binds it driver-side, and the
    // recycled NAME can come back as a different object: a later arm match
    // against the reused name would skip a bind the backend actually needs.
    for (GLsizei i = 0; i < n; ++i) {
        if (g_glstate_c.immediate_live_buffer == buffers[i]) {
            g_glstate_c.immediate_live_buffer = 0;
            break;
        }
    }

    auto& state = getLogicalArrayBufferState();
    auto& gs = g_glstate_c;
    for (GLsizei i = 0; i < n; ++i) {
        forgetVertexAttributeCache(buffers[i]);
        forgetAppAttribArrayBuffer(buffers[i]);
        if (state.known && buffers[i] == state.binding) state.binding = 0;
        // Deleting the shadowed element binding: let the next draw guard
        // re-query instead of guessing what the driver unbound.
        if (gs.backend_vao0_element_known &&
            static_cast<GLint>(buffers[i]) == gs.backend_vao0_element_binding) {
            gs.backend_vao0_element_known = false;
        }
    }
}

GLuint sfpewLogicalArrayBufferBinding() { return getLogicalArrayBufferBinding(); }

// Test-only handles on the internal-buffer registry. Driver name-recycling
// policy is not controllable from a test, so smoke_buffer_name_reuse marks a
// buffer internal directly to prove the poisoning is real, then deletes it
// and asserts the identity is shed (the fix for the MC 1.12 "Use VBOs"
// random vertex corruption).
SFPEW_APIENTRY void sfpewMarkBufferInternalForTest(GLuint buffer) {
    g_glstate_c.internal_buffers.insert(buffer);
}
SFPEW_APIENTRY bool sfpewBufferIsInternalForTest(GLuint buffer) {
    return g_glstate_c.internal_buffers.count(buffer) != 0;
}
SFPEW_APIENTRY GLuint sfpewLogicalArrayBufferBindingForTest(void) {
    return getLogicalArrayBufferBinding();
}
// Whether send_vertex_attributes' skip-the-rebind cache still names this
// buffer. Name recycling is the driver's business and cannot be forced from a
// test, so gtest_delete_buffer_attrib_cache asserts the scrub itself.
SFPEW_APIENTRY bool sfpewVertexAttributeCacheHoldsBufferForTest(GLuint buffer) {
    const auto& gs = g_glstate_c;
    if (gs.fpe_vertex_binding_valid && gs.fpe_vertex_binding_buffer == buffer) return true;
    for (const auto& attribute : gs.fpe_vertex_attributes) {
        if (attribute.pointer_valid && !attribute.separate_binding &&
            attribute.array_buffer == buffer) {
            return true;
        }
    }
    return false;
}

// --- Buffer and vertex-attribute surface (plans/12) ---------------------
//
// These are plain pass-throughs today. They exist because the wrapper must
// SEE them: each one reads or writes through the bound GL_ARRAY_BUFFER or the
// bound VAO, and unwrapped they fall through to the backend's own pointer
// where the wrapper cannot observe them at all. That leaves the wrapper
// shadowing the array-buffer binding while blind to writes through it, and it
// is the prerequisite for deferring the fixed-function draw-state restore
// (which would otherwise let an app's glBufferData land in the wrapper's
// immediate ring buffer).
//
// Each also orders against the pending glyph batch, like every other entry
// point that can change what a queued draw would observe.

void glBufferData(GLenum target, GLsizeiptr size, const void* data, GLenum usage) {
    if (!sfpewEnsureBackend() || g_glFuncs.glBufferData == nullptr) return;
    (void)g_glstate; // entry strict resolve
    sfpewEntryBarrier();
    g_glFuncs.glBufferData(target, size, data, usage);
}

void glBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void* data) {
    if (!sfpewEnsureBackend() || g_glFuncs.glBufferSubData == nullptr) return;
    (void)g_glstate;
    sfpewEntryBarrier();
    g_glFuncs.glBufferSubData(target, offset, size, data);
}

void* glMapBufferRange(GLenum target, GLintptr offset, GLsizeiptr length, GLbitfield access) {
    if (!sfpewEnsureBackend() || g_glFuncs.glMapBufferRange == nullptr) return nullptr;
    (void)g_glstate;
    sfpewEntryBarrier();
    return g_glFuncs.glMapBufferRange(target, offset, length, access);
}

GLboolean glUnmapBuffer(GLenum target) {
    if (!sfpewEnsureBackend() || g_glFuncs.glUnmapBuffer == nullptr) return GL_FALSE;
    (void)g_glstate;
    sfpewEntryBarrier();
    return g_glFuncs.glUnmapBuffer(target);
}

void glGetBufferParameteriv(GLenum target, GLenum pname, GLint* params) {
    if (!sfpewEnsureBackend() || g_glFuncs.glGetBufferParameteriv == nullptr) return;
    (void)g_glstate;
    sfpewEntryBarrier();
    g_glFuncs.glGetBufferParameteriv(target, pname, params);
}

namespace {
// GL 3.2 / ARB_vertex_array_bgra: size may be GL_BGRA, which means four
// components in B, G, R, A order. The spec allows it only with an unsigned
// byte or packed 10/10/10/2 type, and the values are always normalized.
bool isBgraArraySize(GLint size, GLenum type) {
    if (size != (GLint)GL_BGRA) return false;
    return type == GL_UNSIGNED_BYTE || type == GL_UNSIGNED_INT_2_10_10_10_REV ||
           type == GL_INT_2_10_10_10_REV;
}
} // namespace

void glVertexAttribPointer(GLuint index, GLint size, GLenum type, GLboolean normalized,
                           GLsizei stride, const void* pointer) {
    if (!sfpewEnsureBackend() || g_glFuncs.glVertexAttribPointer == nullptr) return;
    (void)g_glstate;
    sfpewEntryBarrier();
    // GL_BGRA reaches a USER program's attribute, whose shader the wrapper
    // does not get to rewrite - so unlike the fixed-function color array
    // (glColorPointer) there is nowhere to put the component reordering.
    // Desktop GL performs it in the driver; on GLES the array is declared as
    // four plain components so the draw still happens, with the application's
    // own shader seeing them in its own order. Said once, because a renderer
    // that does this does it every frame.
    if (isBgraArraySize(size, type) && !sfpewBackendTakesBgra()) {
        static bool warned = false;
        if (!warned) {
            warned = true;
            SFPEW_LOGW("glVertexAttribPointer(index %u): GL_BGRA has no GLES equivalent and the "
                       "component order cannot be applied to an application's own shader; "
                       "declaring four components instead", index);
        }
        size = 4;
        normalized = GL_TRUE;
    }
    g_glFuncs.glVertexAttribPointer(index, size, type, normalized, stride, pointer);
    recordAppAttribPointer(index, size, type, normalized != GL_FALSE, false, stride, pointer);
}

void glVertexAttribIPointer(GLuint index, GLint size, GLenum type, GLsizei stride,
                            const void* pointer) {
    if (!sfpewEnsureBackend() || g_glFuncs.glVertexAttribIPointer == nullptr) return;
    (void)g_glstate;
    sfpewEntryBarrier();
    g_glFuncs.glVertexAttribIPointer(index, size, type, stride, pointer);
    recordAppAttribPointer(index, size, type, false, true, stride, pointer);
}

void glEnableVertexAttribArray(GLuint index) {
    if (!sfpewEnsureBackend() || g_glFuncs.glEnableVertexAttribArray == nullptr) return;
    (void)g_glstate;
    sfpewEntryBarrier();
    g_glFuncs.glEnableVertexAttribArray(index);
    recordAppAttribEnable(index, true);
}

void glDisableVertexAttribArray(GLuint index) {
    if (!sfpewEnsureBackend() || g_glFuncs.glDisableVertexAttribArray == nullptr) return;
    (void)g_glstate;
    sfpewEntryBarrier();
    g_glFuncs.glDisableVertexAttribArray(index);
    recordAppAttribEnable(index, false);
}

GLuint sfpewLogicalVertexArrayBinding() { return getLogicalVertexArrayBinding(); }

// Wrapped only to keep the shadow above current; the call itself is a
// straight pass-through. Without this the shadow would only converge on the
// draw guard's every-256-draws heal, so an app that binds its own VAO would
// have that many draws restore the wrong one.
void glBindVertexArray(GLuint array) {
    if (!sfpewEnsureBackend() || g_glFuncs.glBindVertexArray == nullptr) return;
    (void)g_glstate; // entry strict resolve; the shadows read the snapshot
    sfpewEntryBarrier();
    sfpewBackendBindVertexArray(array); // keeps the shadow and clears the fast path
    auto& gs = g_glstate_c;
    // VAO 0's element binding is only tracked while VAO 0 is the bound one;
    // any other VAO carries its own, so the cached value stops applying.
    if (array != 0) gs.backend_vao0_element_known = false;
}

void glDeleteVertexArrays(GLsizei n, const GLuint* arrays) {
    if (!sfpewEnsureBackend() || g_glFuncs.glDeleteVertexArrays == nullptr) return;
    (void)g_glstate; // entry strict resolve; the shadows read the snapshot
    sfpewEntryBarrier();
    g_glFuncs.glDeleteVertexArrays(n, arrays);
    if (n <= 0 || arrays == nullptr) return;

    // The generic-attribute shadow is per VAO; a recycled name must not
    // inherit the dead object's declarations.
    auto& gs = g_glstate_c;
    for (GLsizei i = 0; i < n; ++i) gs.app_attrib_arrays.erase(arrays[i]);

    // Deleting the bound VAO reverts the binding to zero, which brings VAO
    // 0's element binding back into scope - unknown until something re-reads.
    if (!gs.backend_vao_known) return;
    for (GLsizei i = 0; i < n; ++i) {
        if (static_cast<GLint>(arrays[i]) == gs.backend_vao_binding) {
            gs.backend_vao_binding = 0;
            gs.backend_vao0_element_known = false;
            break;
        }
    }
}

GLuint getClientArrayBufferBinding(int index) {
    if (index < 0 || index >= VERTEX_POINTER_COUNT) return 0;
    return g_glstate_c.fpe_state.client_array_buffer_bindings[index];
}


namespace {
// True when the attribute already holds exactly these values. MC's chunk
// loop respecifies identical pointers for every chunk with only the bound
// buffer changing; an identical respec must NOT mark the layout dirty, or
// every chunk pays a full normalize + program-key relayout for a
// declaration that did not change. The buffer binding is remembered
// separately (rememberClientArrayBufferBinding) either way.
bool samePointerSpec(const vertexattribute_t& a, GLint size, GLenum usage, GLenum type,
                     GLenum normalized, GLsizei stride, const void* pointer, bool bgra = false) {
    return a.size == size && a.usage == usage && a.type == type && a.normalized == normalized &&
           a.stride == stride && a.pointer == pointer && a.bgra == bgra;
}

// GL 2.1 section 2.8 gives each array its own legal type set, and they are not
// nested: GL_UNSIGNED_BYTE is a color type but not a vertex one, GL_BYTE is a
// secondary-color type but not a color-index one. Spelled out per array rather
// than shared so a widened set cannot leak from one entry point to another.
bool isVertexArrayType(GLenum type) {
    return type == GL_SHORT || type == GL_INT || type == GL_FLOAT || type == GL_DOUBLE;
}
bool isColorArrayType(GLenum type) {
    return type == GL_BYTE || type == GL_UNSIGNED_BYTE || type == GL_SHORT ||
           type == GL_UNSIGNED_SHORT || type == GL_INT || type == GL_UNSIGNED_INT ||
           type == GL_FLOAT || type == GL_DOUBLE;
}
bool isNormalArrayType(GLenum type) {
    return type == GL_BYTE || type == GL_SHORT || type == GL_INT || type == GL_FLOAT ||
           type == GL_DOUBLE;
}
bool isIndexArrayType(GLenum type) {
    return type == GL_UNSIGNED_BYTE || type == GL_SHORT || type == GL_INT || type == GL_FLOAT ||
           type == GL_DOUBLE;
}

// All eight pointer commands reject a negative stride the same way. Rejecting
// it HERE, before any array state is written, is what keeps it out of every
// consumer at once: gather_client_arrays (fpe.cpp) casts the stored stride to
// size_t, so a stored -8 became a ~2^64 step walking out of the allocation.
// (The glEdgeFlagPointer reference page says GL_INVALID_ENUM for this; the
// spec body and the other seven pages say GL_INVALID_VALUE.)
bool rejectNegativeStride(glstate_t& gs, GLsizei stride) {
    if (stride >= 0) return false;
    gs.set_error(GL_INVALID_VALUE);
    return true;
}
} // namespace

void glVertexPointer(GLint size, GLenum type, GLsizei stride, const void* pointer) {
    auto& gs = g_glstate;
    // Validation runs before the barrier and before any store: a rejected
    // pointer command must leave the array exactly as it was (GL 2.1 2.8).
    if (size < 2 || size > 4) {
        gs.set_error(GL_INVALID_VALUE);
        return;
    }
    if (!isVertexArrayType(type)) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (rejectNegativeStride(gs, stride)) return;
    sfpewClientStateBarrier();
    // LOG_D("glVertexPointer, size = %d, type = %s, stride = %d, pointer = 0x%x", size, glEnumToString(type), stride,
    // pointer)
    auto& attr = gs.fpe_state.vertexpointer_array.attributes[vp2idx(GL_VERTEX_ARRAY)];
    if (samePointerSpec(attr, size, GL_VERTEX_ARRAY, type, GL_FALSE, stride, pointer)) {
        rememberClientArrayBufferBinding(vp2idx(GL_VERTEX_ARRAY));
        gs.fpe_state.vertexpointer_array.buffer_based = true;
        return;
    }
    attr.size = size;
    attr.usage = GL_VERTEX_ARRAY;
    attr.type = type;
    attr.normalized = GL_FALSE;
    attr.stride = stride;
    attr.pointer = pointer;
    rememberClientArrayBufferBinding(vp2idx(GL_VERTEX_ARRAY));
    //    attr.varying = true;
    gs.fpe_state.vertexpointer_array.dirty = true;
    gs.fpe_state.vertexpointer_array.buffer_based = true;
}

void glNormalPointer(GLenum type, GLsizei stride, const GLvoid* pointer) {
    auto& gs = g_glstate;
    if (!isNormalArrayType(type)) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (rejectNegativeStride(gs, stride)) return;
    sfpewClientStateBarrier();
    // LOG_D("glNormalPointer, type = %s, stride = %d, pointer = 0x%x", glEnumToString(type), stride, pointer)
    const auto& cur = gs.fpe_state.vertexpointer_array.attributes[vp2idx(GL_NORMAL_ARRAY)];
    if (samePointerSpec(cur, 3, GL_NORMAL_ARRAY, type, static_cast<GLenum>((type == GL_FLOAT || type == GL_DOUBLE) ? GL_FALSE : GL_TRUE), stride, pointer)) {
        rememberClientArrayBufferBinding(vp2idx(GL_NORMAL_ARRAY));
        return;
    }
    gs.fpe_state.vertexpointer_array.attributes[vp2idx(GL_NORMAL_ARRAY)] = {
        .size = 3,
        .usage = GL_NORMAL_ARRAY,
        .type = type,
        .normalized = static_cast<GLenum>((type == GL_FLOAT || type == GL_DOUBLE) ? GL_FALSE : GL_TRUE),
        .stride = stride,
        .pointer = pointer,
        //            .varying = true
    };
    rememberClientArrayBufferBinding(vp2idx(GL_NORMAL_ARRAY));
    gs.fpe_state.vertexpointer_array.dirty = true;
}

// Remaining GL 1.4/1.5 pointer trio. State is stored in the reserved
// vp slots (vp2idx already maps them); shader-side consumption arrives
// with plans/04 (secondary color), plans/05 (fog coord) and plans/08
// (edge flags for PolygonMode).
void glEdgeFlagPointer(GLsizei stride, const GLvoid* pointer) {
    auto& gs = g_glstate;
    if (rejectNegativeStride(gs, stride)) return;
    sfpewClientStateBarrier();
    gs.fpe_state.vertexpointer_array.attributes[vp2idx(GL_EDGE_FLAG_ARRAY)] = {
        .size = 1,
        .usage = GL_EDGE_FLAG_ARRAY,
        .type = GL_UNSIGNED_BYTE, // GLboolean elements
        .normalized = GL_FALSE,
        .stride = stride,
        .pointer = pointer,
    };
    rememberClientArrayBufferBinding(vp2idx(GL_EDGE_FLAG_ARRAY));
    gs.fpe_state.vertexpointer_array.dirty = true;
}

void glSecondaryColorPointer(GLint size, GLenum type, GLsizei stride, const GLvoid* pointer) {
    auto& gs = g_glstate;
    if (size != 3) { // GL 2.1: secondary color arrays are strictly 3-component
        gs.set_error(GL_INVALID_VALUE);
        return;
    }
    if (!isColorArrayType(type)) { // same type set as the primary color array
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (rejectNegativeStride(gs, stride)) return;
    sfpewClientStateBarrier();
    gs.fpe_state.vertexpointer_array.attributes[vp2idx(GL_SECONDARY_COLOR_ARRAY)] = {
        .size = size,
        .usage = GL_SECONDARY_COLOR_ARRAY,
        .type = type,
        .normalized = static_cast<GLenum>((type == GL_FLOAT || type == GL_DOUBLE) ? GL_FALSE : GL_TRUE),
        .stride = stride,
        .pointer = pointer,
    };
    rememberClientArrayBufferBinding(vp2idx(GL_SECONDARY_COLOR_ARRAY));
    gs.fpe_state.vertexpointer_array.dirty = true;
}

void glFogCoordPointer(GLenum type, GLsizei stride, const GLvoid* pointer) {
    auto& gs = g_glstate;
    if (type != GL_FLOAT && type != GL_DOUBLE) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (rejectNegativeStride(gs, stride)) return;
    sfpewClientStateBarrier();
    gs.fpe_state.vertexpointer_array.attributes[vp2idx(GL_FOG_COORD_ARRAY)] = {
        .size = 1,
        .usage = GL_FOG_COORD_ARRAY,
        .type = type,
        .normalized = GL_FALSE,
        .stride = stride,
        .pointer = pointer,
    };
    rememberClientArrayBufferBinding(vp2idx(GL_FOG_COORD_ARRAY));
    gs.fpe_state.vertexpointer_array.dirty = true;
}

void glColorPointer(GLint size, GLenum type, GLsizei stride, const GLvoid* pointer) {
    auto& gs = g_glstate;
    // A GL_BGRA array is four components with a component ORDER, not a
    // component count: everything downstream works with size 4 and the order
    // is applied at the two places that can express it (see vertexattribute_t).
    // It carries its own type set (GL_ARB_vertex_array_bgra), so it is decided
    // before the ordinary size/type checks rather than inside them.
    const bool bgra = isBgraArraySize(size, type);
    if (bgra) {
        size = 4;
    } else if (size != 3 && size != 4) {
        gs.set_error(GL_INVALID_VALUE);
        return;
    } else if (!isColorArrayType(type)) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (rejectNegativeStride(gs, stride)) return;
    sfpewClientStateBarrier();
    // LOG_D("glColorPointer, size = %d, type = %s, stride = %d, pointer = 0x%x", size, glEnumToString(type), stride,
    // pointer)
    const auto& cur = gs.fpe_state.vertexpointer_array.attributes[vp2idx(GL_COLOR_ARRAY)];
    if (samePointerSpec(cur, size, GL_COLOR_ARRAY, type, GL_TRUE, stride, pointer, bgra)) {
        rememberClientArrayBufferBinding(vp2idx(GL_COLOR_ARRAY));
        return;
    }
    gs.fpe_state.vertexpointer_array.attributes[vp2idx(GL_COLOR_ARRAY)] = {
        .size = size,
        .usage = GL_COLOR_ARRAY,
        .type = type,
        .normalized = GL_TRUE,
        .stride = stride,
        .pointer = pointer,
        .bgra = bgra,
        //            .varying = true
    };
    rememberClientArrayBufferBinding(vp2idx(GL_COLOR_ARRAY));
    gs.fpe_state.vertexpointer_array.dirty = true;
}

void glTexCoordPointer(GLint size, GLenum type, GLsizei stride, const GLvoid* pointer) {
    auto& gs = g_glstate;
    if (size < 1 || size > 4) {
        gs.set_error(GL_INVALID_VALUE);
        return;
    }
    if (!isVertexArrayType(type)) { // same type set as the vertex array
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (rejectNegativeStride(gs, stride)) return;
    sfpewClientStateBarrier();
    // LOG_D("glTexCoordPointer, size = %d, type = %s, stride = %d, pointer = 0x%x", size, glEnumToString(type), stride,
    // pointer) LOG_D("Active texture: %s", glEnumToString(g_glstate.fpe_state.client_active_texture))
    const int index = vp2idx(GL_TEXTURE_COORD_ARRAY);
    const auto& cur = gs.fpe_state.vertexpointer_array.attributes[index];
    if (samePointerSpec(cur, size, GL_TEXTURE_COORD_ARRAY + (gs.fpe_state.client_active_texture - GL_TEXTURE0), type, GL_FALSE, stride, pointer)) {
        rememberClientArrayBufferBinding(index);
        return;
    }
    gs.fpe_state.vertexpointer_array.attributes[index] = {
        .size = size,
        .usage = GL_TEXTURE_COORD_ARRAY + (gs.fpe_state.client_active_texture - GL_TEXTURE0),
        .type = type,
        .normalized = GL_FALSE,
        .stride = stride,
        .pointer = pointer,
        //            .varying = true
    };
    rememberClientArrayBufferBinding(index);
    gs.fpe_state.vertexpointer_array.dirty = true;
}

void glIndexPointer(GLenum type, GLsizei stride, const GLvoid* pointer) {
    auto& gs = g_glstate;
    if (!isIndexArrayType(type)) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (rejectNegativeStride(gs, stride)) return;
    sfpewClientStateBarrier();
    // LOG_D("glIndexPointer, size = %d, type = %s, stride = %d, pointer = 0x%x", glEnumToString(type), stride, pointer)
    gs.fpe_state.vertexpointer_array.attributes[vp2idx(GL_INDEX_ARRAY)] = {
        .size = 1,
        .usage = GL_INDEX_ARRAY,
        .type = type,
        .normalized = GL_FALSE,
        .stride = stride,
        .pointer = pointer,
        //            .varying = true
    };
    rememberClientArrayBufferBinding(vp2idx(GL_INDEX_ARRAY));
    gs.fpe_state.vertexpointer_array.dirty = true;
}

void glEnableClientState(GLenum cap) {
    auto& gs = g_glstate;
    sfpewClientStateBarrier();
    // LOG_D("glEnableClientState, cap = %s", glEnumToString(cap))

    auto mask = vp_mask(cap);
    if (mask == 0) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    gs.fpe_state.vertexpointer_array.enabled_pointers |= mask;
    // LOG_D("Enabled Ptr: 0x%x", g_glstate.fpe_state.vertexpointer_array.enabled_pointers)
    gs.fpe_state.vertexpointer_array.dirty = true;
}

void glDisableClientState(GLenum cap) {
    auto& gs = g_glstate;
    sfpewClientStateBarrier();
    // LOG_D("glDisableClientState, cap = %s", glEnumToString(cap))
    auto mask = vp_mask(cap);
    if (mask == 0) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }

    gs.fpe_state.vertexpointer_array.enabled_pointers &= (~mask);
    // LOG_D("Enabled Ptr: 0x%x", g_glstate.fpe_state.vertexpointer_array.enabled_pointers)
    gs.fpe_state.vertexpointer_array.dirty = true;
}

// glInterleavedArrays: a GL 1.1 shortcut that declares up to four client
// arrays inside one interleaved block (spec table 2.5). Implemented on top
// of the public pointer/enable entry points so flushing, shadowing and
// future recording behave exactly as if the caller made those calls.
void glInterleavedArrays(GLenum format, GLsizei stride, const void* pointer) {
    auto& gs = g_glstate;
    struct layout_t {
        GLint tex, color, normal, vertex;    // component counts, 0 = absent
        GLenum color_type;
        size_t tex_off, color_off, normal_off, vertex_off, tight;
    };
    constexpr size_t F = sizeof(GLfloat);
    layout_t l{};
    switch (format) {
    case GL_V2F:              l = {0, 0, 0, 2, 0, 0, 0, 0, 0, 2 * F}; break;
    case GL_V3F:              l = {0, 0, 0, 3, 0, 0, 0, 0, 0, 3 * F}; break;
    case GL_C4UB_V2F:         l = {0, 4, 0, 2, GL_UNSIGNED_BYTE, 0, 0, 0, 4, 4 + 2 * F}; break;
    case GL_C4UB_V3F:         l = {0, 4, 0, 3, GL_UNSIGNED_BYTE, 0, 0, 0, 4, 4 + 3 * F}; break;
    case GL_C3F_V3F:          l = {0, 3, 0, 3, GL_FLOAT, 0, 0, 0, 3 * F, 6 * F}; break;
    case GL_N3F_V3F:          l = {0, 0, 3, 3, 0, 0, 0, 0, 3 * F, 6 * F}; l.normal_off = 0; break;
    case GL_C4F_N3F_V3F:      l = {0, 4, 3, 3, GL_FLOAT, 0, 0, 4 * F, 7 * F, 10 * F}; break;
    case GL_T2F_V3F:          l = {2, 0, 0, 3, 0, 0, 0, 0, 2 * F, 5 * F}; break;
    case GL_T4F_V4F:          l = {4, 0, 0, 4, 0, 0, 0, 0, 4 * F, 8 * F}; break;
    case GL_T2F_C4UB_V3F:     l = {2, 4, 0, 3, GL_UNSIGNED_BYTE, 0, 2 * F, 0, 2 * F + 4, 2 * F + 4 + 3 * F}; break;
    case GL_T2F_C3F_V3F:      l = {2, 3, 0, 3, GL_FLOAT, 0, 2 * F, 0, 5 * F, 8 * F}; break;
    case GL_T2F_N3F_V3F:      l = {2, 0, 3, 3, 0, 0, 0, 2 * F, 5 * F, 8 * F}; break;
    case GL_T2F_C4F_N3F_V3F:  l = {2, 4, 3, 3, GL_FLOAT, 0, 2 * F, 6 * F, 9 * F, 12 * F}; break;
    // 15f, not 14f: the vertex block starts at 11f and is four wide.
    case GL_T4F_C4F_N3F_V4F:  l = {4, 4, 3, 4, GL_FLOAT, 0, 4 * F, 8 * F, 11 * F, 15 * F}; break;
    default:
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (stride < 0) {
        gs.set_error(GL_INVALID_VALUE);
        return;
    }
    const GLsizei effective_stride = stride != 0 ? stride : static_cast<GLsizei>(l.tight);
    const auto* base = static_cast<const uint8_t*>(pointer);

    // Per spec, these four client arrays are unconditionally disabled.
    glDisableClientState(GL_EDGE_FLAG_ARRAY);
    glDisableClientState(GL_INDEX_ARRAY);
    glDisableClientState(GL_SECONDARY_COLOR_ARRAY);
    glDisableClientState(GL_FOG_COORD_ARRAY);

    if (l.tex > 0) {
        glEnableClientState(GL_TEXTURE_COORD_ARRAY);
        glTexCoordPointer(l.tex, GL_FLOAT, effective_stride, base + l.tex_off);
    } else {
        glDisableClientState(GL_TEXTURE_COORD_ARRAY);
    }
    if (l.color > 0) {
        glEnableClientState(GL_COLOR_ARRAY);
        glColorPointer(l.color, l.color_type, effective_stride, base + l.color_off);
    } else {
        glDisableClientState(GL_COLOR_ARRAY);
    }
    if (l.normal > 0) {
        glEnableClientState(GL_NORMAL_ARRAY);
        glNormalPointer(GL_FLOAT, effective_stride, base + l.normal_off);
    } else {
        glDisableClientState(GL_NORMAL_ARRAY);
    }
    glEnableClientState(GL_VERTEX_ARRAY);
    glVertexPointer(l.vertex, GL_FLOAT, effective_stride, base + l.vertex_off);
}

namespace {

// Byte distance between consecutive elements: the declared stride, or the
// tightly packed element size a stride of zero stands for.
size_t arrayElementStride(const vertexattribute_t& a) {
    return a.stride != 0 ? (size_t)a.stride : (size_t)a.size * (size_t)type_size(a.type);
}

// Reads one component out of an array element that has already been located.
GLfloat decodeArrayComponent(const uint8_t* p, GLenum type, bool normalized) {
    switch (type) {
    case GL_BYTE: {
        auto v = *reinterpret_cast<const GLbyte*>(p);
        return normalized ? std::max((GLfloat)v / 127.0f, -1.0f) : (GLfloat)v;
    }
    case GL_UNSIGNED_BYTE: {
        auto v = *reinterpret_cast<const GLubyte*>(p);
        return normalized ? (GLfloat)v / 255.0f : (GLfloat)v;
    }
    case GL_SHORT: {
        auto v = *reinterpret_cast<const GLshort*>(p);
        return normalized ? std::max((GLfloat)v / 32767.0f, -1.0f) : (GLfloat)v;
    }
    case GL_UNSIGNED_SHORT: {
        auto v = *reinterpret_cast<const GLushort*>(p);
        return normalized ? (GLfloat)v / 65535.0f : (GLfloat)v;
    }
    case GL_INT: {
        auto v = *reinterpret_cast<const GLint*>(p);
        return normalized ? std::max((GLfloat)((GLdouble)v / 2147483647.0), -1.0f) : (GLfloat)v;
    }
    case GL_UNSIGNED_INT: {
        auto v = *reinterpret_cast<const GLuint*>(p);
        return normalized ? (GLfloat)((GLdouble)v / 4294967295.0) : (GLfloat)v;
    }
    case GL_DOUBLE:
        return (GLfloat)*reinterpret_cast<const GLdouble*>(p);
    case GL_FLOAT:
    default:
        return *reinterpret_cast<const GLfloat*>(p);
    }
}

// GL_ARRAY_BUFFER borrowed for a readback and handed straight back. Unlike
// copyAttributeElements (fpe.cpp), which runs inside a wrapper draw scope that
// re-binds its source anyway, this runs at an application entry point: the
// binding it finds - the app's, or the wrapper's own while a fixed-function
// draw is still held - has to be exactly the binding it leaves. Same
// save-and-restore shape as the cold path in linestipple.cpp, and it reads the
// backend directly so no wrapper shadow is involved either way.
class array_buffer_borrow_t {
public:
    array_buffer_borrow_t() = default;
    array_buffer_borrow_t(const array_buffer_borrow_t&) = delete;
    array_buffer_borrow_t& operator=(const array_buffer_borrow_t&) = delete;
    ~array_buffer_borrow_t() {
        if (borrowed) g_glFuncs.glBindBuffer(GL_ARRAY_BUFFER, (GLuint)prior);
    }
    bool bind(GLuint buffer) {
        if (g_glFuncs.glBindBuffer == nullptr || g_glFuncs.glGetIntegerv == nullptr) return false;
        if (!borrowed) {
            g_glFuncs.glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &prior);
            borrowed = true;
        }
        g_glFuncs.glBindBuffer(GL_ARRAY_BUFFER, buffer);
        return true;
    }

private:
    GLint prior = 0;
    bool borrowed = false;
};

struct array_element_t {
    bool present = false;
    GLint components = 0;
    GLfloat v[4] = {0.0f, 0.0f, 0.0f, 1.0f};
};

// Element `i` of one array slot, wherever that array lives. GL 2.1 section 2.8
// draws no distinction between an array in client memory and one in a buffer
// object; the wrapper used to skip the buffer case outright, so an indexed
// immediate-mode primitive over VBO arrays emitted no geometry at all.
bool readArrayElement(const vertex_pointer_array_t& va, int idx, GLint i, bool normalized,
                      array_buffer_borrow_t& borrow, array_element_t* out) {
    if (idx < 0 || idx >= VERTEX_POINTER_COUNT) return false;
    if (((va.enabled_pointers >> idx) & 1u) == 0) return false;
    const auto& a = va.attributes[idx];
    const GLsizei component_size = type_size(a.type);
    if (a.size <= 0 || component_size <= 0) return false;
    const GLint components = std::min(a.size, 4);

    // plans/13: which of the two an array is comes from what was bound when
    // gl*Pointer ran, never from how large the pointer value looks.
    const GLuint buffer = getClientArrayBufferBinding(idx);
    uint8_t staging[4 * sizeof(GLdouble)];
    const uint8_t* element = nullptr;
    if (buffer == 0) {
        if (a.pointer == nullptr) return false;
        element = static_cast<const uint8_t*>(a.pointer) + (size_t)i * arrayElementStride(a);
    } else {
        if (g_glFuncs.glMapBufferRange == nullptr || g_glFuncs.glUnmapBuffer == nullptr) {
            return false;
        }
        // A buffer-relative offset of zero is a legal declaration, so the null
        // check above deliberately does not apply here.
        const size_t offset = (size_t)reinterpret_cast<uintptr_t>(a.pointer) +
                              (size_t)i * arrayElementStride(a);
        const size_t bytes = (size_t)components * (size_t)component_size;
        if (!borrow.bind(buffer)) return false;
        void* mapped = g_glFuncs.glMapBufferRange(GL_ARRAY_BUFFER, (GLintptr)offset,
                                                  (GLsizeiptr)bytes, GL_MAP_READ_BIT);
        if (mapped == nullptr) return false;
        std::memcpy(staging, mapped, bytes);
        // The bytes are already out; an unmap reporting data loss is a
        // write-map concern and costs this read nothing.
        g_glFuncs.glUnmapBuffer(GL_ARRAY_BUFFER);
        element = staging;
    }

    for (GLint c = 0; c < components; ++c)
        out->v[c] = decodeArrayComponent(element + (size_t)c * component_size, a.type, normalized);
    // GL_BGRA is a component ORDER stored as size 4 (vertexattribute_t). The
    // two array-draw paths apply it in the driver or in the generated shader;
    // the current-value path has to apply it here, or the same array comes out
    // with red and blue exchanged depending on how it was drawn.
    if (a.bgra) {
        const GLfloat blue = out->v[0];
        out->v[0] = out->v[2];
        out->v[2] = blue;
    }
    out->components = components;
    out->present = true;
    return true;
}

} // namespace

// glArrayElement: feed element i of every enabled client array through the
// immediate-mode current-value path, in the order GL 2.1 section 2.8 lays out
// for it (vertex last: it commits the vertex).
//
// Dispatch goes through the public per-attribute entry points, not the mglX
// templates they wrap, purely so that recording comes for free: each of those
// carries its own LIST_RECORD, so a glArrayElement between glNewList and
// glEndList compiles to exactly the commands an application spelling the
// attributes out by hand would have produced, and glCallList replays them.
// Calling the templates instead skipped recording entirely - under GL_COMPILE
// the values went to a batch no glBegin had opened and the list came back
// empty (plans/15 15.2). This costs one full entry point per attribute per
// element; glArrayElement is legacy indexed immediate mode, never a per-frame
// hot path, and glDrawArrays/glDrawElements do not go through here.
void glArrayElement(GLint i) {
    auto& gs = g_glstate;
    if (i < 0) {
        gs.set_error(GL_INVALID_VALUE);
        return;
    }
    const auto& va = gs.fpe_state.vertexpointer_array;

    // Every enabled array is resolved BEFORE anything is dispatched. A
    // buffer-backed one is read through GL_ARRAY_BUFFER and the dispatch below
    // can re-bind it, so the two must not interleave; resolving in one pass
    // also pays the borrow's save/restore once per element rather than once
    // per array.
    array_element_t edge{}, fog{}, secondary{}, color{}, normal{}, vertex{};
    array_element_t texcoord[MAX_TEX];
    {
        array_buffer_borrow_t borrow;
        readArrayElement(va, vp2idx(GL_EDGE_FLAG_ARRAY), i, false, borrow, &edge);
        for (int unit = 0; unit < MAX_TEX; ++unit)
            readArrayElement(va, 7 + unit, i, false, borrow, &texcoord[unit]);
        readArrayElement(va, vp2idx(GL_FOG_COORD_ARRAY), i, false, borrow, &fog);
        readArrayElement(va, vp2idx(GL_SECONDARY_COLOR_ARRAY), i, true, borrow, &secondary);
        readArrayElement(va, vp2idx(GL_COLOR_ARRAY), i, true, borrow, &color);
        readArrayElement(va, vp2idx(GL_NORMAL_ARRAY), i, true, borrow, &normal);
        readArrayElement(va, vp2idx(GL_VERTEX_ARRAY), i, false, borrow, &vertex);
    }

    if (edge.present) glEdgeFlag(edge.v[0] != 0.0f ? GL_TRUE : GL_FALSE);
    for (int unit = 0; unit < MAX_TEX; ++unit) {
        const auto& t = texcoord[unit];
        if (t.present) glMultiTexCoord4f(GL_TEXTURE0 + unit, t.v[0], t.v[1], t.v[2], t.v[3]);
    }
    if (fog.present) glFogCoordf(fog.v[0]);
    if (secondary.present) glSecondaryColor3f(secondary.v[0], secondary.v[1], secondary.v[2]);
    if (color.present) {
        // Three components keeps the three-component current-color size the
        // old mglColor<GLfloat, 3> recorded, not a widened four.
        if (color.components == 3)
            glColor3f(color.v[0], color.v[1], color.v[2]);
        else
            glColor4f(color.v[0], color.v[1], color.v[2], color.v[3]);
    }
    if (normal.present) glNormal3f(normal.v[0], normal.v[1], normal.v[2]);
    if (vertex.present) glVertex4f(vertex.v[0], vertex.v[1], vertex.v[2], vertex.v[3]);
}

bool sfpewUnpackPboBound() {
    if (!sfpewEnsureBackend() || g_glFuncs.glGetIntegerv == nullptr) return false;
    GLint binding = 0;
    g_glFuncs.glGetIntegerv(0x88EF /* GL_PIXEL_UNPACK_BUFFER_BINDING */, &binding);
    return binding != 0;
}

bool sfpewPackPboBound() {
    if (!sfpewEnsureBackend() || g_glFuncs.glGetIntegerv == nullptr) return false;
    GLint binding = 0;
    g_glFuncs.glGetIntegerv(0x88ED /* GL_PIXEL_PACK_BUFFER_BINDING */, &binding);
    return binding != 0;
}
