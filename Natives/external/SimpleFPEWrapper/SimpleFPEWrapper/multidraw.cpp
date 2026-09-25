// SimpleFPEWrapper - SimpleFPEWrapper/multidraw.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "init.h"
#include "log.h"

#include "fpe/fpe.hpp"
#include "fpe/drawing1x.h"
#include "fpe/list.h"

#include <cstring>

namespace {

// Multi-draw exists under two spellings and the backend may have either, both,
// or neither: desktop GL has the unsuffixed pair in 1.4 core, GLES has only the
// EXT pair from EXT_multi_draw_arrays. Prefer unsuffixed, fall back to EXT, and
// report null when the backend has no multi-draw at all (the caller then loops).
// True once the backend extension string has been checked.
// Result: nullptr = use loop; otherwise = pointer to call.
// Resolves once per context by caching on the first call after a backend is
// present. The result covers both the backend-type test (ES vs desktop) and the
// extension-string test, so callers never need to re-probe.
static auto pickMultiDrawArrays() {
    using Fn = decltype(g_glFuncs.glMultiDrawArrays);
    static Fn cached = nullptr;
    static bool probed = false;
    if (probed) return cached;
    if (g_glFuncs.glGetString == nullptr) return cached; // too early; re-probe next call
    probed = true;

    const char* ver = reinterpret_cast<const char*>(g_glFuncs.glGetString(0x1F02 /*GL_VERSION*/));
    if (ver == nullptr) return cached;
    const bool is_es = std::strstr(ver, "OpenGL ES") != nullptr;

    if (!is_es) {
        // Desktop GL: glMultiDrawArrays is 1.4 core, pointer is valid.
        cached = g_glFuncs.glMultiDrawArrays;
        return cached;
    }
    // GLES: only usable if the backend advertises GL_EXT_multi_draw_arrays.
    const char* ext = reinterpret_cast<const char*>(g_glFuncs.glGetString(0x1F03 /*GL_EXTENSIONS*/));
    if (ext != nullptr && std::strstr(ext, "GL_EXT_multi_draw_arrays") != nullptr) {
        cached = g_glFuncs.glMultiDrawArraysEXT;
    }
    return cached;
}

static auto pickMultiDrawElements() {
    using Fn = decltype(g_glFuncs.glMultiDrawElements);
    static Fn cached = nullptr;
    static bool probed = false;
    if (probed) return cached;
    if (g_glFuncs.glGetString == nullptr) return cached;
    probed = true;

    const char* ver = reinterpret_cast<const char*>(g_glFuncs.glGetString(0x1F02));
    if (ver == nullptr) return cached;
    const bool is_es = std::strstr(ver, "OpenGL ES") != nullptr;

    if (!is_es) {
        cached = g_glFuncs.glMultiDrawElements;
        return cached;
    }
    const char* ext = reinterpret_cast<const char*>(g_glFuncs.glGetString(0x1F03));
    if (ext != nullptr && std::strstr(ext, "GL_EXT_multi_draw_arrays") != nullptr) {
        cached = g_glFuncs.glMultiDrawElementsEXT;
    }
    return cached;
}

decltype(g_glFuncs.glMultiDrawArrays) nativeMultiDrawArrays() {
    return pickMultiDrawArrays();
}

decltype(g_glFuncs.glMultiDrawElements) nativeMultiDrawElements() {
    return pickMultiDrawElements();
}

// One native multi-draw replaces the loop only when no sub-draw needs individual
// work. Two conditions, both invariant across the sub-draws of a single call:
//
//  - the app owns the vertex state, so there is nothing to commit or upload
//    per sub-draw. This is the same predicate drawArraysNow uses to reach its
//    passthrough branch, minus the per-draw first/count tests.
//  - the primitive mode survives to the backend unchanged.
//
// The fixed-function path deliberately keeps looping: commit_fpe_state_on_draw
// rewrites first/count per draw (GL_QUADS expands to a different index count)
// and uploads only the range that draw covers, so the sub-draws are not
// interchangeable.
bool appOwnsVertexStateForPassthrough() {
    if (g_glstate_c.render_mode != GL_RENDER) return false;
    const GLint current_program = sfpewLogicalProgram();
    if (current_program == 0) return false;
    const auto& vertex_array = g_glstate_c.fpe_state.vertexpointer_array;
    const uint32_t vertex_array_mask = 1u << vp2idx(GL_VERTEX_ARRAY);
    // With fixed-function arrays live the user-program path wires them per draw.
    return (vertex_array.enabled_pointers & vertex_array_mask) == 0;
}

// The mode the backend can be handed directly, or GL_NONE when it needs a
// per-draw rewrite. QUAD_STRIP/POLYGON are vertex-order compatible so the swap
// applies uniformly to every sub-draw; GL_QUADS is not, since it becomes an
// indexed draw whose index count differs per sub-draw.
GLenum nativeMultiDrawMode(GLenum mode) {
    switch (mode) {
    case GL_QUADS:
        return GL_NONE;
    case GL_QUAD_STRIP:
        return GL_TRIANGLE_STRIP;
    case GL_POLYGON:
        return GL_TRIANGLE_FAN;
    default:
        return mode;
    }
}

} // namespace

// GL 1.4 core. Forwards to the backend's multi-draw when nothing needs doing per
// sub-draw, otherwise loops over the single-draw path so legacy modes and the
// fixed-function/user-program plumbing still apply to each one.
void glMultiDrawArrays(GLenum mode, const GLint* first, const GLsizei* count, GLsizei drawcount) {
    if (!sfpewEnsureBackend()) return;
    if (drawcount < 0) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    if (first == nullptr || count == nullptr) return;
    sfpewEntryBarrier();

    // GL 2.1 5.4: under GL_COMPILE this belongs in the list, not on the
    // screen. A multi-draw is n independent glDrawArrays as far as the list
    // is concerned, so each sub-draw is captured exactly the way glDrawArrays
    // captures itself - the alternative was executing it immediately and
    // replaying nothing at all (plans/15 15.1).
    if (!disableRecording && DisplayListManager::shouldRecord()) {
        (void)g_glstate; // strict resolve: capture reads the snapshot, and
                         // nothing above this point refreshed it
        for (GLsizei i = 0; i < drawcount; ++i) {
            if (count[i] <= 0) continue;
            sfpewRecordCapturedDrawArrays(mode, first[i], count[i]);
        }
        if (DisplayListManager::shouldFinish()) return;
    }

    const auto native = nativeMultiDrawArrays();
    const GLenum native_mode = nativeMultiDrawMode(mode);
    if (native != nullptr && native_mode != GL_NONE && appOwnsVertexStateForPassthrough()) {
        sfpewFeedUserProgramUniforms((GLuint)sfpewLogicalProgram());
        native(native_mode, first, count, drawcount);
        return;
    }

    for (GLsizei i = 0; i < drawcount; ++i) {
        if (count[i] <= 0) continue;
        drawArraysNow(mode, first[i], count[i], false);
    }
}

void glMultiDrawElements(GLenum mode, const GLsizei* count, GLenum type,
                         const GLvoid* const* indices, GLsizei drawcount) {
    if (!sfpewEnsureBackend()) return;
    if (drawcount < 0) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    if (count == nullptr || indices == nullptr) return;
    sfpewEntryBarrier();

    // Same reasoning as glMultiDrawArrays above, one step further out: n
    // independent glDrawElements as far as the list is concerned, each
    // captured the way glDrawElements captures itself (plans/15 15.4).
    if (!disableRecording && DisplayListManager::shouldRecord()) {
        (void)g_glstate; // strict resolve: capture reads the snapshot, and
                         // nothing above this point refreshed it
        for (GLsizei i = 0; i < drawcount; ++i) {
            if (count[i] <= 0) continue;
            sfpewRecordCapturedDrawElements(mode, count[i], type, indices[i]);
        }
        if (DisplayListManager::shouldFinish()) return;
    }

    const auto native = nativeMultiDrawElements();
    const GLenum native_mode = nativeMultiDrawMode(mode);
    if (native != nullptr && native_mode != GL_NONE && appOwnsVertexStateForPassthrough()) {
        sfpewFeedUserProgramUniforms((GLuint)sfpewLogicalProgram());
        native(native_mode, count, type, indices, drawcount);
        return;
    }

    for (GLsizei i = 0; i < drawcount; ++i) {
        if (count[i] <= 0) continue;
        drawElementsNow(mode, count[i], type, indices[i]);
    }
}
