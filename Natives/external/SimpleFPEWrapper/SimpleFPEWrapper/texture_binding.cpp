// SimpleFPEWrapper - SimpleFPEWrapper/texture_binding.cpp
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
#include <algorithm>
#include <unordered_map>
#include "fpe/fpe.hpp"
#include "fpe/drawing1x.h"
#include "fpe/list.h"

namespace {
struct LogicalTextureBindings {
    EGLContext context = EGL_NO_CONTEXT;
    GLenum activeTexture = GL_TEXTURE0;
    bool activeTextureKnown = false;
    std::unordered_map<uint64_t, GLuint> bindings;
    // Bumped by every real change to the active unit or to a binding. The
    // immediate-mode merge key rides on this instead of re-reading the
    // active unit and its 2D binding for every Begin/End batch: those two
    // reads (a map lookup each) cost more than everything else the merge
    // decision does. Both mutators below already return early when nothing
    // changes, so an unchanged state never bumps and never forces a flush.
    uint64_t generation = 1;
};

thread_local LogicalTextureBindings logicalTextureBindings;

LogicalTextureBindings& getLogicalTextureBindings() {
    // Reconciles against the snapshot of the calling entry's strict resolve
    // (docs/context-model.md); no eglGetCurrentContext of its own.
    const EGLContext context = (EGLContext)glstate_t::cached_context();
    if (logicalTextureBindings.context != context) {
        logicalTextureBindings = {};
        logicalTextureBindings.context = context;
    }
    return logicalTextureBindings;
}

GLenum getLogicalActiveTexture(LogicalTextureBindings& state) {
    if (!state.activeTextureKnown) {
        if (!sfpewEnsureBackend() || g_glFuncs.glGetIntegerv == nullptr) return GL_TEXTURE0;
        GLint active = GL_TEXTURE0;
        g_glFuncs.glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
        state.activeTexture = static_cast<GLenum>(active);
        state.activeTextureKnown = true;
    }
    return state.activeTexture;
}

GLenum textureBindingQuery(GLenum target) {
    switch (target) {
    case GL_TEXTURE_2D:
        return GL_TEXTURE_BINDING_2D;
    case GL_TEXTURE_CUBE_MAP:
        return GL_TEXTURE_BINDING_CUBE_MAP;
#ifdef GL_TEXTURE_3D
    case GL_TEXTURE_3D:
        return GL_TEXTURE_BINDING_3D;
#endif
#ifdef GL_TEXTURE_2D_ARRAY
    case GL_TEXTURE_2D_ARRAY:
        return GL_TEXTURE_BINDING_2D_ARRAY;
#endif
    default:
        return GL_NONE;
    }
}

uint64_t textureBindingKey(GLenum activeTexture, GLenum target) {
    return (static_cast<uint64_t>(activeTexture) << 32u) | static_cast<uint64_t>(target);
}
} // namespace

GLenum sfpewLogicalActiveTexture() {
    auto& state = getLogicalTextureBindings();
    return getLogicalActiveTexture(state);
}

uint64_t sfpewTextureStateGeneration() { return getLogicalTextureBindings().generation; }

GLuint sfpewLogicalTextureBinding(GLenum target) {
    auto& state = getLogicalTextureBindings();
    const GLenum query = textureBindingQuery(target);
    if (query == GL_NONE) return 0;

    const uint64_t key = textureBindingKey(getLogicalActiveTexture(state), target);
    auto binding = state.bindings.find(key);
    if (binding == state.bindings.end()) {
        GLint current = 0;
        g_glFuncs.glGetIntegerv(query, &current);
        binding = state.bindings.emplace(key, static_cast<GLuint>(current)).first;
    }
    return binding->second;
}

GLuint sfpewLogicalTextureBindingForUnit(GLenum unit, GLenum target) {
    auto& state = getLogicalTextureBindings();
    const GLenum query = textureBindingQuery(target);
    if (query == GL_NONE) return 0;

    const auto binding = state.bindings.find(textureBindingKey(unit, target));
    return binding == state.bindings.end() ? 0 : binding->second;
}

void glActiveTexture(GLenum texture) {
    if (!sfpewEnsureBackend() || g_glFuncs.glActiveTexture == nullptr) return;
    (void)g_glstate; // entry strict resolve; the binding shadow reads the snapshot
    // Validate before anything else: an invalid enum must leave the active
    // unit (and the shadow that mirrors it) untouched, matching
    // DEFINE_MULTITEXCOORD's own bounds check on the same MAX_TEX range -
    // without this, the shadow below would adopt an out-of-range unit that
    // every per-unit reader (active_texture_index() et al.) then clamps
    // differently than the rejected backend call did.
    if (texture < GL_TEXTURE0 || texture - GL_TEXTURE0 >= MAX_TEX) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    // Record BEFORE the redundancy shortcut: a list must contain the command
    // even when it matches the current state (GL spec; audit finding).
    LIST_RECORD(glActiveTexture, {}, texture)
    auto& state = getLogicalTextureBindings();
    if (getLogicalActiveTexture(state) == texture) return;

    sfpewTextureStateBarrier();
    g_glFuncs.glActiveTexture(texture);
    state.activeTexture = texture;
    state.activeTextureKnown = true;
    ++state.generation;
}

void glBindTexture(GLenum target, GLuint texture) {
    if (!sfpewEnsureBackend() || g_glFuncs.glBindTexture == nullptr) return;
    (void)g_glstate; // entry strict resolve; the binding shadow reads the snapshot
    if (target == GL_TEXTURE_1D) target = GL_TEXTURE_2D; // Nx1 emulation
    LIST_RECORD(glBindTexture, {}, target, texture)
    auto& state = getLogicalTextureBindings();
    const GLenum activeTexture = getLogicalActiveTexture(state);
    const GLenum query = textureBindingQuery(target);
    const uint64_t key = textureBindingKey(activeTexture, target);

    if (query != GL_NONE) {
        if (sfpewLogicalTextureBinding(target) == texture) return;
    }

    sfpewTextureStateBarrier();
    g_glFuncs.glBindTexture(target, texture);
    if (query != GL_NONE) {
        state.bindings[key] = texture;
        ++state.generation;
    }
}

void glDeleteTextures(GLsizei n, const GLuint* textures) {
    if (!sfpewEnsureBackend() || g_glFuncs.glDeleteTextures == nullptr) return;
    (void)g_glstate; // entry strict resolve; the binding shadow reads the snapshot
    sfpewEntryBarrier();
    g_glFuncs.glDeleteTextures(n, textures);
    if (n <= 0 || textures == nullptr) return;

    auto& state = getLogicalTextureBindings();
    auto& gs = g_glstate_c;
    for (auto& [key, binding] : state.bindings) {
        for (GLsizei i = 0; i < n; ++i) {
            if (binding == textures[i]) {
                binding = 0;
                ++state.generation;
                break;
            }
        }
    }
    for (GLsizei i = 0; i < n; ++i) {
        gs.texture_priorities.erase(textures[i]);
        gs.texture_depth_mode.erase(textures[i]);
        gs.texture_compare_mode.erase(textures[i]);
        sfpewForgetTextureMetadata(textures[i]);
    }
}

GLboolean glAreTexturesResident(GLsizei n, const GLuint* textures, GLboolean* residences) {
    auto& gs = g_glstate;
    if (n < 0) {
        gs.set_error(GL_INVALID_VALUE);
        return GL_FALSE;
    }
    if (n == 0) return GL_TRUE;
    if (textures == nullptr || residences == nullptr) return GL_FALSE;
    sfpewEntryBarrier();
    // Validate the complete input before touching the caller's output buffer.
    for (GLsizei i = 0; i < n; ++i) {
        if (textures[i] == 0 || g_glFuncs.glIsTexture == nullptr ||
            g_glFuncs.glIsTexture(textures[i]) == GL_FALSE) {
            gs.set_error(GL_INVALID_VALUE);
            return GL_FALSE;
        }
    }
    for (GLsizei i = 0; i < n; ++i) residences[i] = GL_TRUE;
    return GL_TRUE;
}

void glPrioritizeTextures(GLsizei n, const GLuint* textures, const GLclampf* priorities) {
    auto& gs = g_glstate;
    if (n < 0) {
        gs.set_error(GL_INVALID_VALUE);
        return;
    }
    LIST_RECORD(glPrioritizeTextures,
                {{1, (size_t)n * sizeof(GLuint)}, {2, (size_t)n * sizeof(GLclampf)}},
                n, textures, priorities)
    if (n == 0 || textures == nullptr || priorities == nullptr) return;
    sfpewEntryBarrier();
    for (GLsizei i = 0; i < n; ++i) {
        if (textures[i] == 0) continue;
        if (g_glFuncs.glIsTexture != nullptr && g_glFuncs.glIsTexture(textures[i]) == GL_FALSE)
            continue;
        gs.texture_priorities[textures[i]] = std::clamp(priorities[i], 0.0f, 1.0f);
    }
}
