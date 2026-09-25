// SimpleFPEWrapper - SimpleFPEWrapper/ordered_passthrough.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "init.h"
#include "fpe/drawing1x.h"
#include "fpe/list.h"
#include "fpe/imaging.h"
#include <vector>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include "fpe/fpe.hpp"

namespace {

struct logical_program_state_t {
    EGLContext context = EGL_NO_CONTEXT;
    GLint program = 0;
    bool known = false;
};

thread_local logical_program_state_t logicalProgramState;

logical_program_state_t& getLogicalProgramState() {
    // Reconciles against the calling entry's strict-resolve snapshot
    // (docs/context-model.md); no eglGetCurrentContext of its own.
    const EGLContext context = (EGLContext)glstate_t::cached_context();
    if (logicalProgramState.context != context) {
        logicalProgramState = {};
        logicalProgramState.context = context;
    }
    return logicalProgramState;
}

} // namespace

GLint sfpewLogicalProgram() {
    auto& state = getLogicalProgramState();
    // Callers that bypass the glUseProgram wrapper (JNI direct dispatch,
    // layered wrappers) would otherwise desynchronize this shadow forever.
    // Re-read the truth every 256 queries - one cheap glGetIntegerv per ~256
    // draws keeps the FPE interception decision self-healing (plans/07).
    thread_local unsigned reconcile_counter = 0;
    const bool reconcile = (++reconcile_counter & 0xFFu) == 0u;
    // While a fixed-function draw is holding the app's state (plans/12), the
    // backend has the WRAPPER's program bound, so asking it would poison the
    // shadow with an internal program id - and every later draw would then
    // take the user-program path and pass GL_QUADS straight to GLES. The save
    // on the context is the app's truth here; the reconcile just waits for the
    // next unheld query.
    const bool held = g_glstate_c.deferred_draw.held;
    if (!state.known || (reconcile && !held)) {
        if (!sfpewEnsureBackend() || g_glFuncs.glGetIntegerv == nullptr) return 0;
        if (held) {
            state.program = g_glstate_c.deferred_draw.program;
        } else {
            g_glFuncs.glGetIntegerv(GL_CURRENT_PROGRAM, &state.program);
            // A backend readback can catch one of the WRAPPER's own programs:
            // with the deferred restore the FPE program stays bound between
            // fixed-function draws, and any window where this shadow seeds or
            // heals against that binding (context-poll jitter resetting the
            // thread-local state, a heal landing between a flush and its
            // restore) records the wrapper's program as if the app had bound
            // it. Every fixed-function draw then takes the user-program path:
            // no FPE program bind, no uniforms, attributes fed to a shader
            // whose inputs they do not match - on-device this is the
            // menu/world flicker with stacked glyphs and stale frames. The
            // app can never legitimately have one of our internal names
            // bound (they are created and used only inside wrapper draw
            // scopes), so a readback that returns one is always leftover
            // wrapper state, i.e. logically program 0.
            if (state.program != 0 &&
                g_glstate_c.internal_programs.count(state.program) != 0) {
                state.program = 0;
            }
        }
        state.known = true;
    }
    return state.program;
}

#define ORDERED_PASSTHROUGH(name, declaration, arguments)                                                             \
    void name declaration {                                                                                           \
        if (!sfpewEnsureBackend()) return;                                                                            \
        sfpewEntryBarrier();                                                                                 \
        if (g_glFuncs.name != nullptr) g_glFuncs.name arguments;                                                      \
    }

#define OP_ARGS(...) __VA_ARGS__
// Server-state commands are compiled into display lists per GL 2.1 5.4;
// their default tryMerge()==false also makes each one a batching barrier,
// so the display-list draw merger cannot fuse across them.
#define RECORDED_PASSTHROUGH(name, declaration, arguments)                                                            \
    void name declaration {                                                                                           \
        if (!sfpewEnsureBackend()) return;                                                                            \
        sfpewEntryBarrier();                                                                                 \
        LIST_RECORD(name, {}, OP_ARGS arguments)                                                                      \
        if (g_glFuncs.name != nullptr) g_glFuncs.name arguments;                                                      \
    }

// glClear is the one call every frame starts with, so it is also where the
// SFPEW_LISTLOG summary is flushed: a launcher that drives eglSwapBuffers
// around the wrapper would otherwise never reach a frame boundary the
// wrapper can see. The summary itself skips a boundary with nothing to say.
void glClear(GLbitfield mask) {
    if (!sfpewEnsureBackend()) return;
    sfpewEntryBarrier();
    LIST_RECORD(glClear, {}, mask)
    sfpewListLogFrame();
    if (g_glFuncs.glClear != nullptr) g_glFuncs.glClear(mask);
}

namespace {

bool rejectDuringBeginEnd(glstate_t& gs) {
    if (gs.fpe_state.fpe_draw.primitive == kNoPrimitive) return false;
    gs.set_error(GL_INVALID_OPERATION);
    return true;
}

bool isLegacyDrawBuffer(GLenum buf) {
    switch (buf) {
    case GL_FRONT_LEFT:
    case GL_FRONT_RIGHT:
    case GL_BACK_LEFT:
    case GL_BACK_RIGHT:
    case GL_FRONT:
    case GL_BACK:
    case GL_LEFT:
    case GL_RIGHT:
    case GL_FRONT_AND_BACK: return true;
    default: return false;
    }
}

bool isAuxDrawBuffer(GLenum buf) {
    return buf >= GL_AUX0 && buf <= GL_AUX3;
}

bool isColorAttachment(GLenum buf) {
    return buf >= GL_COLOR_ATTACHMENT0 && buf <= GL_COLOR_ATTACHMENT31;
}

bool validateQueryObject(glstate_t& gs, GLuint id, GLenum pname) {
    if (pname != GL_QUERY_RESULT && pname != GL_QUERY_RESULT_AVAILABLE) {
        gs.set_error(GL_INVALID_ENUM);
        return false;
    }
    if (g_glFuncs.glIsQuery != nullptr && g_glFuncs.glIsQuery(id) == GL_FALSE) {
        gs.set_error(GL_INVALID_OPERATION);
        return false;
    }
    return true;
}

} // namespace

// Desktop GL's double spelling is represented by the float entry point on
// the two backend floors. Clamp before narrowing, as GL 2.1 requires.
void glClearDepth(GLdouble depth) {
    auto& gs = g_glstate;
    LIST_RECORD(glClearDepth, {}, depth)
    if (rejectDuringBeginEnd(gs)) return;
    sfpewEntryBarrier();
    if (!sfpewEnsureBackend() || g_glFuncs.glClearDepthf == nullptr) return;
    g_glFuncs.glClearDepthf(static_cast<GLfloat>(std::clamp(depth, 0.0, 1.0)));
}

// Keep the backend spelling wrapped as well: callers resolving glClearDepthf
// must still get ordering and display-list semantics.
void glClearDepthf(GLfloat depth) {
    auto& gs = g_glstate;
    LIST_RECORD(glClearDepthf, {}, depth)
    if (rejectDuringBeginEnd(gs)) return;
    sfpewEntryBarrier();
    if (!sfpewEnsureBackend() || g_glFuncs.glClearDepthf == nullptr) return;
    g_glFuncs.glClearDepthf(std::clamp(depth, 0.0f, 1.0f));
}

// GL 2.1's singular draw-buffer selector maps to the one-element plural
// command available on both backend floors. EGL surfaces have no separately
// addressable front buffer, so every legacy surface selector lands on BACK.
void glDrawBuffer(GLenum buf) {
    auto& gs = g_glstate;
    LIST_RECORD(glDrawBuffer, {}, buf)
    if (rejectDuringBeginEnd(gs)) return;

    const bool legacy = isLegacyDrawBuffer(buf);
    const bool auxiliary = isAuxDrawBuffer(buf);
    const bool attachment = isColorAttachment(buf);
    if (buf != GL_NONE && !legacy && !auxiliary && !attachment) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }

    sfpewEntryBarrier();
    if (!sfpewEnsureBackend() || g_glFuncs.glDrawBuffers == nullptr ||
        g_glFuncs.glGetIntegerv == nullptr) {
        return;
    }

    GLint framebuffer = 0;
    g_glFuncs.glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &framebuffer);
    GLenum mapped = buf;
    if (framebuffer == 0) {
        if (attachment || auxiliary) {
            gs.set_error(GL_INVALID_OPERATION);
            return;
        }
        if (legacy) mapped = GL_BACK;
    } else {
        if (legacy || auxiliary) {
            gs.set_error(GL_INVALID_OPERATION);
            return;
        }
        if (attachment) {
            GLint maximum = 0;
            g_glFuncs.glGetIntegerv(GL_MAX_COLOR_ATTACHMENTS, &maximum);
            const GLint index = static_cast<GLint>(buf - GL_COLOR_ATTACHMENT0);
            if (maximum <= 0 || index >= maximum) {
                gs.set_error(GL_INVALID_OPERATION);
                return;
            }
            // GLES3 requires bufs[i] to be GL_NONE or GL_COLOR_ATTACHMENTi -
            // positional, unlike desktop GL, which accepts any valid
            // attachment token at any array position. A one-element {buf}
            // array (the fallback below) is only legal here when buf is
            // already GL_COLOR_ATTACHMENT0; anything past that needs every
            // earlier slot explicitly disabled with GL_NONE.
            std::vector<GLenum> buffers(static_cast<size_t>(index) + 1, GL_NONE);
            buffers[static_cast<size_t>(index)] = buf;
            g_glFuncs.glDrawBuffers(static_cast<GLsizei>(buffers.size()), buffers.data());
            return;
        }
    }
    g_glFuncs.glDrawBuffers(1, &mapped);
}

// defects-plan-2.md 2.1: glReadBuffer was entirely unwrapped - not in
// lookup.cpp's GETPROC table and absent from this file, so
// eglGetProcAddress("glReadBuffer") fell through to the backend's own
// address (both floors have it natively as ES 3.0/GL 3.2 core), bypassing
// LIST_RECORD and every other wrapper-side barrier. Mirrors glDrawBuffer
// above almost exactly, checking the read-framebuffer binding instead of
// the draw one. One real difference from glDrawBuffer: GL_FRONT_AND_BACK
// is legal to draw into but illegal to read from ("not a single buffer",
// GL 2.1 spec 4.3.1) - isLegacyDrawBuffer alone isn't enough, so that one
// value gets an explicit carve-out.
void glReadBuffer(GLenum src) {
    auto& gs = g_glstate;
    LIST_RECORD(glReadBuffer, {}, src)
    if (rejectDuringBeginEnd(gs)) return;

    // GL_FRONT_AND_BACK is a recognized legacy selector - just not a legal
    // one to read from - so it must set GL_INVALID_OPERATION, not fall into
    // the "not a selector GL knows at all" GL_INVALID_ENUM bucket below.
    if (src == GL_FRONT_AND_BACK) {
        gs.set_error(GL_INVALID_OPERATION);
        return;
    }
    const bool legacy = isLegacyDrawBuffer(src);
    const bool auxiliary = isAuxDrawBuffer(src);
    const bool attachment = isColorAttachment(src);
    if (src != GL_NONE && !legacy && !auxiliary && !attachment) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }

    sfpewEntryBarrier();
    if (!sfpewEnsureBackend() || g_glFuncs.glReadBuffer == nullptr ||
        g_glFuncs.glGetIntegerv == nullptr) {
        return;
    }

    GLint framebuffer = 0;
    g_glFuncs.glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &framebuffer);
    GLenum mapped = src;
    if (framebuffer == 0) {
        if (attachment || auxiliary) {
            gs.set_error(GL_INVALID_OPERATION);
            return;
        }
        if (legacy) mapped = GL_BACK;
    } else {
        if (legacy || auxiliary) {
            gs.set_error(GL_INVALID_OPERATION);
            return;
        }
        if (attachment) {
            GLint maximum = 0;
            g_glFuncs.glGetIntegerv(GL_MAX_COLOR_ATTACHMENTS, &maximum);
            if (maximum <= 0 || static_cast<GLint>(src - GL_COLOR_ATTACHMENT0) >= maximum) {
                gs.set_error(GL_INVALID_OPERATION);
                return;
            }
        }
    }
    g_glFuncs.glReadBuffer(mapped);
}

// Neither backend's *EXT signed/64-bit accessor pointer can be trusted by
// non-nullness alone: no GLES extension defines glGetQueryObject{i,i64,ui64}
// vEXT at all (a GLES driver handing back a non-null pointer for one anyway
// is a documented-legal driver quirk, not a capability signal - EGL/GLES
// allow eglGetProcAddress to return non-null for unsupported names), and
// desktop's own GL_EXT_occlusion_query glGetQueryObjectivEXT - which does
// legitimately exist as a real entry point - measured on this machine's own
// desktop driver to silently never mark GL_QUERY_RESULT_AVAILABLE either.
// The core unsigned glGetQueryObjectuiv (ES 3.0 core, and desktop GL 1.5+
// core) is the only accessor confirmed reliable on both backends, so always
// read through it and convert/saturate for the signed/64-bit callers.
void glGetQueryObjectiv(GLuint id, GLenum pname, GLint* params) {
    if (params == nullptr) return;
    auto& gs = g_glstate;
    if (rejectDuringBeginEnd(gs)) return;
    sfpewEntryBarrier();
    if (!sfpewEnsureBackend() || !validateQueryObject(gs, id, pname)) return;
    if (g_glFuncs.glGetQueryObjectuiv == nullptr) return;
    GLuint value = 0;
    g_glFuncs.glGetQueryObjectuiv(id, pname, &value);
    *params = value > static_cast<GLuint>(std::numeric_limits<GLint>::max())
                  ? std::numeric_limits<GLint>::max()
                  : static_cast<GLint>(value);
}

void glGetQueryObjecti64v(GLuint id, GLenum pname, GLint64* params) {
    if (params == nullptr) return;
    auto& gs = g_glstate;
    if (rejectDuringBeginEnd(gs)) return;
    sfpewEntryBarrier();
    if (!sfpewEnsureBackend() || !validateQueryObject(gs, id, pname)) return;
    if (g_glFuncs.glGetQueryObjectuiv == nullptr) return;
    GLuint value = 0;
    g_glFuncs.glGetQueryObjectuiv(id, pname, &value);
    *params = static_cast<GLint64>(value);
}

void glGetQueryObjectui64v(GLuint id, GLenum pname, GLuint64* params) {
    if (params == nullptr) return;
    auto& gs = g_glstate;
    if (rejectDuringBeginEnd(gs)) return;
    sfpewEntryBarrier();
    if (!sfpewEnsureBackend() || !validateQueryObject(gs, id, pname)) return;
    if (g_glFuncs.glGetQueryObjectuiv == nullptr) return;
    GLuint value = 0;
    g_glFuncs.glGetQueryObjectuiv(id, pname, &value);
    *params = static_cast<GLuint64>(value);
}

namespace {

// plans/17 P1: whether the backend will accept this color format/type pair
// for a read at all. A GLES backend takes exactly two (ES 3.0 4.3.1,
// /docsgl/es3/glReadPixels.xhtml): GL_RGBA+GL_UNSIGNED_BYTE for a normalized
// fixed-point read buffer, plus the single pair the implementation names
// through GL_IMPLEMENTATION_COLOR_READ_FORMAT/_TYPE. Everything else - all
// twelve packed types, GL_BGRA, GL_RGB, GL_LUMINANCE, GL_FLOAT - is
// GL_INVALID_OPERATION, and "if an error is generated, no change is made to
// the contents of data": the caller gets its own uninitialized buffer back.
// Desktop GL takes the whole GL 2.1 table instead.
//
// This is the capability test imaging.h:40-46 asks for rather than a
// blanket CPU round trip: the no-transfer GL_RGBA+GL_UNSIGNED_BYTE read -
// the overwhelmingly common one, and the only pair every backend floor is
// required to have - answers true before anything is queried, so it keeps
// the raw backend path it always had.
bool backendTakesColorReadPair(GLenum format, GLenum type) {
    if (format == GL_RGBA && type == GL_UNSIGNED_BYTE) return true;
    // Not color reads: they have their own transfer path, and the color
    // encoder refuses them anyway. Answering here also keeps the two
    // queries below off the depth-read path.
    if (format == GL_DEPTH_COMPONENT || format == GL_STENCIL_INDEX ||
        format == GL_DEPTH_STENCIL) {
        return true;
    }
    // sfpewBackendTakesBgra() and not sfpewBackendIsES(): the question is
    // "is this really desktop GL", and MobileGlues answers GL_VERSION like
    // desktop while forwarding every read to GLES underneath
    // (backend/capabilities.cpp) - it needs the CPU encoder exactly as much
    // as a plain ES backend does.
    if (sfpewBackendTakesBgra()) return true;
    if (g_glFuncs.glGetIntegerv == nullptr) return false;
    // Asked per read, never cached: the implementation-chosen pair is a
    // property of the bound read framebuffer's attachment, not of the
    // backend, so an app that reads from an FBO with a different format
    // gets a different answer.
    GLint implementation_format = 0, implementation_type = 0;
    g_glFuncs.glGetIntegerv(GL_IMPLEMENTATION_COLOR_READ_FORMAT, &implementation_format);
    g_glFuncs.glGetIntegerv(GL_IMPLEMENTATION_COLOR_READ_TYPE, &implementation_type);
    return static_cast<GLenum>(implementation_format) == format &&
           static_cast<GLenum>(implementation_type) == type;
}

} // namespace

// glDrawElements lives in fpe/draw_now.cpp: it is FPE-converted, not passthrough.
void glReadPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type,
                  GLvoid* pixels) {
    if (!sfpewEnsureBackend() || g_glFuncs.glReadPixels == nullptr) return;
    sfpewEntryBarrier();
    // defects-plan-3.md: full GL 2.1 3.6.3 pixel transfer for color reads
    // (scale/bias/map, then whatever ARB_imaging stages are active -
    // supersedes sfpewImagingReadPixels, which only ever ran the second
    // half); GL_DEPTH_SCALE/BIAS for depth reads. Both return false
    // (nothing to do) whenever the corresponding transfer sits at its
    // default no-op values - the overwhelmingly common case - so the raw
    // passthrough below stays exactly as it always was for that case.
    //
    // plans/17 P1/P4: that same CPU path is also the only correct encoder
    // for a pair the backend would refuse, so a refused pair forces it even
    // with the transfer at its defaults. It supersedes the old in-place
    // BGRA->RGBA swap outright: that read with the caller's full GL_PACK_*
    // layout and then swapped a TIGHT width*height*4 run from the caller's
    // base pointer, so a non-zero GL_PACK_ROW_LENGTH left every row past
    // the first unswapped and GL_PACK_SKIP_ROWS rewrote caller bytes
    // outside the requested rectangle. imaging.cpp's encodePixels writes
    // the addresses the pack state actually names, pixel buffer included.
    const bool raw = backendTakesColorReadPair(format, type);
    if (sfpewFullColorReadPixels(x, y, width, height, format, type, pixels, !raw)) return;
    if (sfpewDepthPixelTransferReadPixels(x, y, width, height, format, type, pixels)) return;
    g_glFuncs.glReadPixels(x, y, width, height, format, type, pixels);
}
ORDERED_PASSTHROUGH(glFlush, (), ())
ORDERED_PASSTHROUGH(glFinish, (), ())

ORDERED_PASSTHROUGH(glBindFramebuffer, (GLenum target, GLuint framebuffer), (target, framebuffer))
void glUseProgram(GLuint program) {
    if (!sfpewEnsureBackend()) return;
    (void)g_glstate; // entry strict resolve; the program shadow reads the snapshot
    sfpewEntryBarrier();
    if (g_glFuncs.glUseProgram == nullptr) return;
    sfpewInvalidateImmediateDrawState();
    g_glFuncs.glUseProgram(program);

    // Use the backend's post-call value so an invalid/unlinked program cannot
    // poison the logical shadow. This query happens only on glUseProgram,
    // replacing the per-draw GL_CURRENT_PROGRAM query on the hot path.
    auto& state = getLogicalProgramState();
    g_glFuncs.glGetIntegerv(GL_CURRENT_PROGRAM, &state.program);
    // Keep the invariant that the logical shadow never holds one of the
    // wrapper's internal programs (see sfpewLogicalProgram).
    if (state.program != 0 && g_glstate_c.internal_programs.count(state.program) != 0)
        state.program = 0;
    state.known = true;
}

// The blend/mask family keeps a shadow as well as passing through: only a
// shadow lets glPushAttrib(GL_COLOR_BUFFER_BIT) restore it (legacy
// Minecraft brackets GUI and item rendering that way, and a leaked blend
// function corrupts every later translucent draw).
// Blend, color mask, depth range, hint, pixel store and texture parameters
// take the flush-only barrier: all of them are server or CPU state that
// neither reads nor writes the program, VAO or buffer bindings, and a
// renderer changes blending and texture filtering between draws constantly.
void glBlendColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    if (!sfpewEnsureBackend()) return;
    sfpewClientStateBarrier();
    LIST_RECORD(glBlendColor, {}, red, green, blue, alpha)
    auto& cb = g_glstate.fpe_state.color_buffer;
    cb.blend_color[0] = red;
    cb.blend_color[1] = green;
    cb.blend_color[2] = blue;
    cb.blend_color[3] = alpha;
    if (g_glFuncs.glBlendColor != nullptr) g_glFuncs.glBlendColor(red, green, blue, alpha);
}

void glBlendEquation(GLenum mode) {
    if (!sfpewEnsureBackend()) return;
    sfpewClientStateBarrier();
    LIST_RECORD(glBlendEquation, {}, mode)
    auto& cb = g_glstate.fpe_state.color_buffer;
    cb.equation_rgb = mode;
    cb.equation_alpha = mode;
    if (g_glFuncs.glBlendEquation != nullptr) g_glFuncs.glBlendEquation(mode);
}

void glBlendEquationSeparate(GLenum modeRGB, GLenum modeAlpha) {
    if (!sfpewEnsureBackend()) return;
    sfpewClientStateBarrier();
    LIST_RECORD(glBlendEquationSeparate, {}, modeRGB, modeAlpha)
    auto& cb = g_glstate.fpe_state.color_buffer;
    cb.equation_rgb = modeRGB;
    cb.equation_alpha = modeAlpha;
    if (g_glFuncs.glBlendEquationSeparate != nullptr)
        g_glFuncs.glBlendEquationSeparate(modeRGB, modeAlpha);
}

void glBlendFunc(GLenum sfactor, GLenum dfactor) {
    if (!sfpewEnsureBackend()) return;
    sfpewClientStateBarrier();
    LIST_RECORD(glBlendFunc, {}, sfactor, dfactor)
    auto& cb = g_glstate.fpe_state.color_buffer;
    cb.src_rgb = cb.src_alpha = sfactor;
    cb.dst_rgb = cb.dst_alpha = dfactor;
    if (g_glFuncs.glBlendFunc != nullptr) g_glFuncs.glBlendFunc(sfactor, dfactor);
}

void glBlendFuncSeparate(GLenum sfactorRGB, GLenum dfactorRGB, GLenum sfactorAlpha,
                         GLenum dfactorAlpha) {
    if (!sfpewEnsureBackend()) return;
    sfpewClientStateBarrier();
    LIST_RECORD(glBlendFuncSeparate, {}, sfactorRGB, dfactorRGB, sfactorAlpha, dfactorAlpha)
    auto& cb = g_glstate.fpe_state.color_buffer;
    cb.src_rgb = sfactorRGB;
    cb.dst_rgb = dfactorRGB;
    cb.src_alpha = sfactorAlpha;
    cb.dst_alpha = dfactorAlpha;
    if (g_glFuncs.glBlendFuncSeparate != nullptr)
        g_glFuncs.glBlendFuncSeparate(sfactorRGB, dfactorRGB, sfactorAlpha, dfactorAlpha);
}

void glColorMask(GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha) {
    if (!sfpewEnsureBackend()) return;
    sfpewClientStateBarrier();
    LIST_RECORD(glColorMask, {}, red, green, blue, alpha)
    auto& cb = g_glstate.fpe_state.color_buffer;
    cb.color_mask[0] = red;
    cb.color_mask[1] = green;
    cb.color_mask[2] = blue;
    cb.color_mask[3] = alpha;
    if (g_glFuncs.glColorMask != nullptr) g_glFuncs.glColorMask(red, green, blue, alpha);
}

// Plain per-fragment state. These entries neither read nor write the
// program, VAO or buffer bindings, so they take the flush-only barrier
// (drawing1x.h explains the bar): handing the app back bindings it cannot
// observe only makes the next fixed-function draw re-establish ours, and a
// legacy renderer puts a dozen of these between two draws.
//
// They are also filtered against a shadow of what the backend was last
// told. Nothing else in the wrapper writes this state, so a repeated value
// is unobservable - and re-asserting a whole pass's worth of state around
// every draw is exactly what legacy renderers do.
// `shadow_test` is a ternary whose false branch has the side effect of
// writing the new value(s) into `shadow` - it must always be evaluated, not
// only once the shadow is already known, or the very first call to a given
// SHADOWED_STATE entry point forwards to the backend correctly but leaves
// the shadow's value fields at their compile-time defaults. That desync is
// invisible until something else reads the shadow expecting it to match
// reality - glPushAttrib/glPopAttrib's depth/stencil/scissor restore does
// exactly that. `shadow.known` only gates whether the redundant-call skip
// is trusted, not whether the shadow gets updated.
#define SHADOWED_STATE(name, declaration, arguments, shadow_test)                                  \
    void name declaration {                                                                        \
        if (!sfpewEnsureBackend()) return;                                                         \
        sfpewClientStateBarrier();                                                                 \
        LIST_RECORD(name, {}, OP_ARGS arguments)                                                   \
        auto& shadow = g_glstate.fpe_state.backend_state;                                                    \
        const bool redundant = (shadow_test);                                                      \
        const bool was_known = shadow.known;                                                       \
        shadow.known = true;                                                                       \
        if (was_known && redundant) return;                                                        \
        if (g_glFuncs.name != nullptr) g_glFuncs.name arguments;                                   \
    }

SHADOWED_STATE(glDepthFunc, (GLenum func), (func),
               shadow.depth_func == func ? true : (shadow.depth_func = func, false))
SHADOWED_STATE(glDepthMask, (GLboolean flag), (flag),
               shadow.depth_mask == flag ? true : (shadow.depth_mask = flag, false))
SHADOWED_STATE(glCullFace, (GLenum mode), (mode),
               shadow.cull_face == mode ? true : (shadow.cull_face = mode, false))
SHADOWED_STATE(glFrontFace, (GLenum mode), (mode),
               shadow.front_face == mode ? true : (shadow.front_face = mode, false))
SHADOWED_STATE(glScissor, (GLint x, GLint y, GLsizei width, GLsizei height),
               (x, y, width, height),
               (shadow.scissor[0] == x && shadow.scissor[1] == y && shadow.scissor[2] == width &&
                shadow.scissor[3] == height)
                   ? true
                   : (shadow.scissor[0] = x, shadow.scissor[1] = y, shadow.scissor[2] = width,
                      shadow.scissor[3] = height, false))
SHADOWED_STATE(glPolygonOffset, (GLfloat factor, GLfloat units), (factor, units),
               (shadow.polygon_offset[0] == factor && shadow.polygon_offset[1] == units)
                   ? true
                   : (shadow.polygon_offset[0] = factor, shadow.polygon_offset[1] = units, false))
SHADOWED_STATE(glLineWidth, (GLfloat width), (width),
               shadow.line_width == width ? true : (shadow.line_width = width, false))
SHADOWED_STATE(glStencilFunc, (GLenum func, GLint ref, GLuint mask), (func, ref, mask),
               (shadow.stencil_func == func && shadow.stencil_ref == ref &&
                shadow.stencil_value_mask == mask)
                   ? true
                   : (shadow.stencil_func = func, shadow.stencil_ref = ref,
                      shadow.stencil_value_mask = mask, false))
SHADOWED_STATE(glStencilMask, (GLuint mask), (mask),
               shadow.stencil_mask == mask ? true : (shadow.stencil_mask = mask, false))
SHADOWED_STATE(glStencilOp, (GLenum fail, GLenum zfail, GLenum zpass), (fail, zfail, zpass),
               (shadow.stencil_fail == fail && shadow.stencil_zfail == zfail &&
                shadow.stencil_zpass == zpass)
                   ? true
                   : (shadow.stencil_fail = fail, shadow.stencil_zfail = zfail,
                      shadow.stencil_zpass = zpass, false))
#undef SHADOWED_STATE

// Viewport keeps the full barrier and no filtering: it is the one entry in
// this group the wrapper itself re-issues (the render-to-texture and blit
// paths), so a shadow here would have to be invalidated from those.
RECORDED_PASSTHROUGH(glViewport, (GLint x, GLint y, GLsizei width, GLsizei height),
                    (x, y, width, height))

namespace {

bool isTextureWrapParameter(GLenum pname) {
    return pname == GL_TEXTURE_WRAP_S || pname == GL_TEXTURE_WRAP_T || pname == GL_TEXTURE_WRAP_R;
}

bool validTextureParameterTarget(GLenum target) {
    switch (target) {
    case GL_TEXTURE_1D:
    case GL_TEXTURE_2D:
    case GL_TEXTURE_3D:
    case GL_TEXTURE_CUBE_MAP:
        return true;
    default:
        return false;
    }
}

GLint compatibleTextureParameter(GLenum pname, GLint param) {
    // GL_CLAMP was removed from the programmable/core and GLES profiles used
    // by SFPEW's backends.  Legacy games still use it for projected textures
    // such as Minecraft's entity shadows.  Passing 0x2900 through produces
    // GL_INVALID_ENUM and leaves the sampler at REPEAT, so out-of-range shadow
    // UVs tile across the ground.  An edge clamp is the compatible behavior
    // for these transparent-border textures.
    return isTextureWrapParameter(pname) && param == GL_CLAMP ? GL_CLAMP_TO_EDGE : param;
}

// True when this call needs border-clamp support the real backend may not
// have: GL_TEXTURE_BORDER_COLOR unconditionally (the pname itself does not
// exist without the extension), or a wrap parameter being set to
// GL_CLAMP_TO_BORDER. wrapValue is ignored for the GL_TEXTURE_BORDER_COLOR
// case, so callers that only reach this for that pname may pass 0.
// sfpewTextureBorderClampSupported() (init.h) is the actual backend probe -
// shared with getter_version_strings.cpp, which uses the same answer to decide whether
// GL_ARB_texture_border_clamp belongs in the advertised extension string.
bool rejectsAsUnsupportedBorderClamp(GLenum pname, GLint wrapValue) {
    const bool usesBorderClamp =
        pname == GL_TEXTURE_BORDER_COLOR ||
        (isTextureWrapParameter(pname) && wrapValue == GL_CLAMP_TO_BORDER);
    return usesBorderClamp && !sfpewTextureBorderClampSupported();
}

// GL_GENERATE_MIPMAP (GL 1.4): tracked per bound texture object; TexImage
// uploads regenerate the chain via the ES3 glGenerateMipmap.
bool sfpewHandleGenerateMipmapParam(GLenum target, GLenum pname, GLint param) {
    if (pname != 0x8191 /* GL_GENERATE_MIPMAP */) return false;
    if (target == GL_TEXTURE_1D) target = GL_TEXTURE_2D;
    sfpewSetGenerateMipmap(target, sfpewLogicalTextureBinding(target), param != 0);
    return true;
}

// GL_ARB_shadow's GL_TEXTURE_COMPARE_MODE is, unlike GL_TEXTURE_PRIORITY and
// GL_DEPTH_TEXTURE_MODE above, a real GLES3/GL-core enum the backend already
// accepts and stores itself (a shadow sampler's hardware comparison depends
// on the driver having it) - so this only ever mirrors it into
// texture_compare_mode for glstate.cpp's program_hash() resync, and never
// swallows the call: every caller below still falls through to the ordinary
// passthrough beneath it. GL_TEXTURE_COMPARE_FUNC needs no such mirror -
// nothing but the driver ever consults it - so it takes no special path at
// all.
void sfpewRecordTextureCompareMode(GLenum target, GLenum pname, GLint param) {
    if (pname != GL_TEXTURE_COMPARE_MODE) return;
    if (target == GL_TEXTURE_1D) target = GL_TEXTURE_2D;
    if (!validTextureParameterTarget(target)) return;
    g_glstate.texture_compare_mode[sfpewLogicalTextureBinding(target)] = static_cast<GLenum>(param);
}

} // namespace

namespace {

// Duplicated from texture_binding.cpp (which owns the logical texture-binding
// shadow that sfpewLogicalTextureBinding et al. maintain, using this same
// switch to map a target onto its GL_TEXTURE_BINDING_* query enum) rather
// than exposed cross-TU: validTextureGetParameterTarget below only needs the
// "is this target bindable" question, and this switch is small enough that a
// second copy is simpler than a new export for it.
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

// Renamed from its original "validTextureParameterTarget" when the texture
// getters moved here: this file already has its own (differently-scoped, setter-side)
// validTextureParameterTarget above accepting only TEXTURE_1D/2D/3D/CUBE_MAP,
// and both would otherwise collide in this translation unit's single
// anonymous namespace. Kept verbatim otherwise - this getter-side check also
// accepts GL_TEXTURE_2D_ARRAY, unlike the setter-side one; that pre-existing
// discrepancy was not introduced by this move.
bool validTextureGetParameterTarget(GLenum target) {
    if (target == GL_TEXTURE_1D) return true;
    return textureBindingQuery(target) != GL_NONE;
}

GLenum textureParameterTarget(GLenum target) {
    return target == GL_TEXTURE_1D ? GL_TEXTURE_2D : target;
}

GLclampf texturePriority(GLuint texture) {
    const auto& priorities = g_glstate_c.texture_priorities;
    const auto it = priorities.find(texture);
    return it == priorities.end() ? 1.0f : it->second;
}

GLenum depthTextureMode(GLuint texture) {
    const auto& modes = g_glstate_c.texture_depth_mode;
    const auto it = modes.find(texture);
    return it == modes.end() ? GL_LUMINANCE : it->second;
}

} // namespace

void glGetTexParameterfv(GLenum target, GLenum pname, GLfloat* params) {
    auto& gs = g_glstate;
    if (params == nullptr) return;
    if (pname == GL_TEXTURE_PRIORITY || pname == GL_TEXTURE_RESIDENT || pname == GL_DEPTH_TEXTURE_MODE) {
        if (!validTextureGetParameterTarget(target)) {
            gs.set_error(GL_INVALID_ENUM);
            return;
        }
        sfpewEntryBarrier();
        if (pname == GL_TEXTURE_PRIORITY)
            params[0] = texturePriority(sfpewLogicalTextureBinding(textureParameterTarget(target)));
        else if (pname == GL_DEPTH_TEXTURE_MODE)
            params[0] = static_cast<GLfloat>(depthTextureMode(sfpewLogicalTextureBinding(textureParameterTarget(target))));
        else
            params[0] = 1.0f; // all live and default textures are reported resident
        return;
    }
    if (!sfpewEnsureBackend() || g_glFuncs.glGetTexParameterfv == nullptr) return;
    sfpewEntryBarrier();
    g_glFuncs.glGetTexParameterfv(textureParameterTarget(target), pname, params);
}

void glGetTexParameteriv(GLenum target, GLenum pname, GLint* params) {
    auto& gs = g_glstate;
    if (params == nullptr) return;
    if (pname == GL_TEXTURE_PRIORITY || pname == GL_TEXTURE_RESIDENT || pname == GL_DEPTH_TEXTURE_MODE) {
        if (!validTextureGetParameterTarget(target)) {
            gs.set_error(GL_INVALID_ENUM);
            return;
        }
        sfpewEntryBarrier();
        if (pname == GL_TEXTURE_PRIORITY) {
            const GLfloat value = texturePriority(sfpewLogicalTextureBinding(textureParameterTarget(target)));
            *params = static_cast<GLint>(std::lround(value));
        } else if (pname == GL_DEPTH_TEXTURE_MODE) {
            *params = static_cast<GLint>(depthTextureMode(sfpewLogicalTextureBinding(textureParameterTarget(target))));
        } else {
            *params = GL_TRUE;
        }
        return;
    }
    if (!sfpewEnsureBackend() || g_glFuncs.glGetTexParameteriv == nullptr) return;
    sfpewEntryBarrier();
    g_glFuncs.glGetTexParameteriv(textureParameterTarget(target), pname, params);
}

void glTexParameterf(GLenum target, GLenum pname, GLfloat param) {
    auto& gs = g_glstate;
    sfpewClientStateBarrier();
    LIST_RECORD(glTexParameterf, {}, target, pname, param)
    if (sfpewHandleGenerateMipmapParam(target, pname, (GLint)param)) return;
    sfpewRecordTextureCompareMode(target, pname, static_cast<GLint>(param));
    if (pname == GL_TEXTURE_PRIORITY) {
        if (target == GL_TEXTURE_1D) target = GL_TEXTURE_2D;
        if (!validTextureParameterTarget(target)) {
            gs.set_error(GL_INVALID_ENUM);
            return;
        }
        gs.texture_priorities[sfpewLogicalTextureBinding(target)] = std::clamp(param, 0.0f, 1.0f);
        return;
    }
    if (pname == GL_DEPTH_TEXTURE_MODE) {
        if (target == GL_TEXTURE_1D) target = GL_TEXTURE_2D;
        if (!validTextureParameterTarget(target)) {
            gs.set_error(GL_INVALID_ENUM);
            return;
        }
        const GLuint texture = sfpewLogicalTextureBinding(target);
        gs.texture_depth_mode[texture] = static_cast<GLenum>(param);
        sfpewApplyDepthTextureModeSwizzle(target, texture);
        return;
    }
    if (target == GL_TEXTURE_1D) target = GL_TEXTURE_2D;
    if (g_glFuncs.glTexParameterf == nullptr) return;
    if (rejectsAsUnsupportedBorderClamp(pname, static_cast<GLint>(param))) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (isTextureWrapParameter(pname) && static_cast<GLint>(param) == GL_CLAMP)
        param = static_cast<GLfloat>(GL_CLAMP_TO_EDGE);
    g_glFuncs.glTexParameterf(target, pname, param);
}

void glTexParameterfv(GLenum target, GLenum pname, const GLfloat* params) {
    auto& gs = g_glstate;
    sfpewClientStateBarrier();
    if (params == nullptr) return;
    LIST_RECORD(glTexParameterfv,
                {{2, (pname == GL_TEXTURE_BORDER_COLOR ? 4u : 1u) * sizeof(GLfloat)}}, target, pname,
                params)
    sfpewRecordTextureCompareMode(target, pname, static_cast<GLint>(params[0]));
    if (pname == GL_TEXTURE_PRIORITY) {
        if (target == GL_TEXTURE_1D) target = GL_TEXTURE_2D;
        if (!validTextureParameterTarget(target)) {
            gs.set_error(GL_INVALID_ENUM);
            return;
        }
        gs.texture_priorities[sfpewLogicalTextureBinding(target)] = std::clamp(params[0], 0.0f, 1.0f);
        return;
    }
    if (pname == GL_DEPTH_TEXTURE_MODE) {
        if (target == GL_TEXTURE_1D) target = GL_TEXTURE_2D;
        if (!validTextureParameterTarget(target)) {
            gs.set_error(GL_INVALID_ENUM);
            return;
        }
        const GLuint texture = sfpewLogicalTextureBinding(target);
        gs.texture_depth_mode[texture] = static_cast<GLenum>(params[0]);
        sfpewApplyDepthTextureModeSwizzle(target, texture);
        return;
    }
    if (target == GL_TEXTURE_1D) target = GL_TEXTURE_2D;
    if (g_glFuncs.glTexParameterfv == nullptr) return;
    if (rejectsAsUnsupportedBorderClamp(pname, static_cast<GLint>(params[0]))) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (isTextureWrapParameter(pname) && static_cast<GLint>(params[0]) == GL_CLAMP) {
        const GLfloat compatible = static_cast<GLfloat>(GL_CLAMP_TO_EDGE);
        g_glFuncs.glTexParameterfv(target, pname, &compatible);
    } else {
        g_glFuncs.glTexParameterfv(target, pname, params);
    }
}

void glTexParameteri(GLenum target, GLenum pname, GLint param) {
    auto& gs = g_glstate;
    sfpewClientStateBarrier();
    LIST_RECORD(glTexParameteri, {}, target, pname, param)
    if (sfpewHandleGenerateMipmapParam(target, pname, param)) return;
    sfpewRecordTextureCompareMode(target, pname, param);
    if (pname == GL_TEXTURE_PRIORITY) {
        if (target == GL_TEXTURE_1D) target = GL_TEXTURE_2D;
        if (!validTextureParameterTarget(target)) {
            gs.set_error(GL_INVALID_ENUM);
            return;
        }
        gs.texture_priorities[sfpewLogicalTextureBinding(target)] =
            std::clamp(static_cast<GLfloat>(param), 0.0f, 1.0f);
        return;
    }
    if (pname == GL_DEPTH_TEXTURE_MODE) {
        if (target == GL_TEXTURE_1D) target = GL_TEXTURE_2D;
        if (!validTextureParameterTarget(target)) {
            gs.set_error(GL_INVALID_ENUM);
            return;
        }
        const GLuint texture = sfpewLogicalTextureBinding(target);
        gs.texture_depth_mode[texture] = static_cast<GLenum>(param);
        sfpewApplyDepthTextureModeSwizzle(target, texture);
        return;
    }
    if (target == GL_TEXTURE_1D) target = GL_TEXTURE_2D;
    if (g_glFuncs.glTexParameteri == nullptr) return;
    if (rejectsAsUnsupportedBorderClamp(pname, param)) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    g_glFuncs.glTexParameteri(target, pname, compatibleTextureParameter(pname, param));
}

void glTexParameteriv(GLenum target, GLenum pname, const GLint* params) {
    auto& gs = g_glstate;
    sfpewClientStateBarrier();
    if (params == nullptr) return;
    LIST_RECORD(glTexParameteriv,
                {{2, (pname == GL_TEXTURE_BORDER_COLOR ? 4u : 1u) * sizeof(GLint)}}, target, pname,
                params)
    sfpewRecordTextureCompareMode(target, pname, params[0]);
    if (pname == GL_TEXTURE_PRIORITY) {
        if (target == GL_TEXTURE_1D) target = GL_TEXTURE_2D;
        if (!validTextureParameterTarget(target)) {
            gs.set_error(GL_INVALID_ENUM);
            return;
        }
        gs.texture_priorities[sfpewLogicalTextureBinding(target)] =
            std::clamp(static_cast<GLfloat>(params[0]), 0.0f, 1.0f);
        return;
    }
    if (pname == GL_DEPTH_TEXTURE_MODE) {
        if (target == GL_TEXTURE_1D) target = GL_TEXTURE_2D;
        if (!validTextureParameterTarget(target)) {
            gs.set_error(GL_INVALID_ENUM);
            return;
        }
        const GLuint texture = sfpewLogicalTextureBinding(target);
        gs.texture_depth_mode[texture] = static_cast<GLenum>(params[0]);
        sfpewApplyDepthTextureModeSwizzle(target, texture);
        return;
    }
    if (target == GL_TEXTURE_1D) target = GL_TEXTURE_2D;
    if (g_glFuncs.glTexParameteriv == nullptr) return;
    if (rejectsAsUnsupportedBorderClamp(pname, params[0])) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (isTextureWrapParameter(pname) && params[0] == GL_CLAMP) {
        const GLint compatible = GL_CLAMP_TO_EDGE;
        g_glFuncs.glTexParameteriv(target, pname, &compatible);
    } else {
        g_glFuncs.glTexParameteriv(target, pname, params);
    }
}
namespace {

// The compiled form of glTexSubImage2D; see replayTexImage2D in
// texture_image.cpp - the payload is tight, so no unpack state (least of all
// a bound unpack buffer) from glCallList time may reach it.
void replayTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width,
                         GLsizei height, GLenum format, GLenum type, GLboolean swap_bytes,
                         const GLvoid* pixels) {
    sfpew_list_unpack_replay_t unpack(swap_bytes != GL_FALSE, false);
    SELF_CALL(glTexSubImage2D, target, level, xoffset, yoffset, width, height, format, type,
              pixels)
}

} // namespace

void glTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width,
                     GLsizei height, GLenum format, GLenum type, const GLvoid* pixels) {
    if (!sfpewEnsureBackend() || g_glFuncs.glTexSubImage2D == nullptr) return;
    struct bgra_upload_guard_t {
        sfpew_bgra_upload_t state{};
        bool active = false;
        ~bgra_upload_guard_t() {
            if (active) sfpewFinishBgraUpload(state);
        }
    } bgraUpload;
    struct imaging_upload_guard_t {
        sfpew_imaging_upload_t state{};
        bool active = false;
        ~imaging_upload_guard_t() {
            if (active) sfpewFinishImagingUpload(state);
        }
    } imagingUpload;
    (void)g_glstate; // entry strict resolve; mipmap tracking reads the binding shadow
    sfpewEntryBarrier();
    // plans/17 P15.
    if (!disableRecording && DisplayListManager::shouldRecord()) {
        std::vector<uint8_t> payload;
        if (sfpewCaptureListPixelUpload("glTexSubImage2D", width, height, format, type, pixels,
                                        &payload)) {
            displayListManager.record<replayTexSubImage2D>(
                {{9, payload.size()}}, target, level, xoffset, yoffset, width, height, format,
                type,
                static_cast<GLboolean>(g_glstate.pixel_store_unpack_swap_bytes ? GL_TRUE
                                                                              : GL_FALSE),
                payload.empty() ? nullptr : static_cast<const GLvoid*>(payload.data()));
        }
        if (DisplayListManager::shouldFinish()) return;
    }
    if (sfpewImagingActive() && (pixels != nullptr || sfpewUnpackPboBound())) {
        imagingUpload.active =
            sfpewPrepareImagingUpload(width, height, format, type, pixels, &imagingUpload.state);
        if (imagingUpload.active) {
            if (!imagingUpload.state.valid || imagingUpload.state.sink) return;
            width = imagingUpload.state.width;
            height = imagingUpload.state.height;
            format = GL_RGBA;
            type = GL_FLOAT;
            pixels = imagingUpload.state.rgba.data();
        }
    }
    // Legacy formats must match the RED/RG storage glTexImage2D allocated
    // for them; BGRA is swapped on the CPU (tight rows assumed, mirroring
    // the allocation path in texture_image.cpp).
    if (format == GL_ALPHA || format == GL_LUMINANCE) {
        format = GL_RED;
    } else if (format == GL_LUMINANCE_ALPHA) {
        format = GL_RG;
    } else if (format == GL_BGRA && !sfpewBackendTakesBgra()) {
        // Same conversion as glTexImage2D: reorders from client memory or a
        // mapped pixel unpack buffer, honouring row length and skips, into a
        // tight RGBA rectangle - which is what atlas stitching uploads and
        // the old tight-row-only swap silently corrupted.
        if (sfpewPrepareBgraUpload(width, height, type, pixels, &bgraUpload.state)) {
            bgraUpload.active = true;
            pixels = bgraUpload.state.pixels;
            format = GL_RGBA;
            type = GL_UNSIGNED_BYTE;
        } else {
            SFPEW_LOGW("glTexSubImage2D: unsupported GL_BGRA type 0x%x passed through", type);
        }
    }
    g_glFuncs.glTexSubImage2D(target, level, xoffset, yoffset, width, height, format, type, pixels);
    sfpewMaybeGenerateMipmap(target);
}

// --- Desktop-only entry points GLES lacks (plans/03, 3.4) ---------------

void glDepthRange(GLdouble nearVal, GLdouble farVal) {
    if (!sfpewEnsureBackend() || g_glFuncs.glDepthRangef == nullptr) return;
    sfpewClientStateBarrier();
    g_glFuncs.glDepthRangef(static_cast<GLfloat>(nearVal), static_cast<GLfloat>(farVal));
}

// Keeps the setter below and the glGet family on one numbering.
int sfpewLegacyHintSlot(GLenum target) {
    switch (target) {
    case GL_FOG_HINT: return 0;
    case GL_LINE_SMOOTH_HINT: return 1;
    case GL_PERSPECTIVE_CORRECTION_HINT: return 2;
    case GL_POINT_SMOOTH_HINT: return 3;
    case GL_POLYGON_SMOOTH_HINT: return 4;
    case GL_TEXTURE_COMPRESSION_HINT: return 5;
    case GL_GENERATE_MIPMAP_HINT: return 6;
    default: return -1;
    }
}

void glHint(GLenum target, GLenum mode) {
    if (mode != GL_FASTEST && mode != GL_NICEST && mode != GL_DONT_CARE) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    switch (target) {
    // Backed by both floors.
    case GL_FRAGMENT_SHADER_DERIVATIVE_HINT:
        if (!sfpewEnsureBackend() || g_glFuncs.glHint == nullptr) return;
        sfpewClientStateBarrier();
        g_glFuncs.glHint(target, mode);
        return;
    // ES 3 has this one and a GL 3.2 core context does not - it went out
    // with the fixed-function mipmap generation the wrapper now does itself.
    // Remember it either way, and only pass it on where it means something.
    case GL_GENERATE_MIPMAP_HINT: {
        const int slot = sfpewLegacyHintSlot(target);
        if (slot >= 0) g_glstate.legacy_hints[slot] = mode;
        int major = 0, minor = 0;
        if (sfpewDesktopGLVersion(&major, &minor) && sfpewEnsureBackend() &&
            g_glFuncs.glHint != nullptr) {
            sfpewClientStateBarrier();
            g_glFuncs.glHint(target, mode);
        }
        return;
    }
    // Legal GL 2.1 hints with no GLES equivalent: accepting them as a no-op
    // is a conforming implementation of a hint, but the value has to be
    // remembered - a hint that cannot be read back is not state.
    case GL_FOG_HINT:
    case GL_LINE_SMOOTH_HINT:
    case GL_PERSPECTIVE_CORRECTION_HINT:
    case GL_POINT_SMOOTH_HINT:
    case GL_POLYGON_SMOOTH_HINT:
    case GL_TEXTURE_COMPRESSION_HINT: {
        const int slot = sfpewLegacyHintSlot(target);
        if (slot >= 0) g_glstate.legacy_hints[slot] = mode;
        return;
    }
    default:
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
}

void glPixelStorei(GLenum pname, GLint param) {
    switch (pname) {
    // Desktop-only modes: shadowed for the CPU repack pipeline (plans/05/08).
    case GL_UNPACK_SWAP_BYTES:
        g_glstate.pixel_store_unpack_swap_bytes = param != 0;
        return;
    case GL_UNPACK_LSB_FIRST:
        g_glstate.pixel_store_unpack_lsb_first = param != 0;
        return;
    case GL_PACK_SWAP_BYTES:
        g_glstate.pixel_store_pack_swap_bytes = param != 0;
        return;
    case GL_PACK_LSB_FIRST:
        g_glstate.pixel_store_pack_lsb_first = param != 0;
        return;
    default:
        // Everything else (ALIGNMENT, ROW_LENGTH, SKIP_*, IMAGE_HEIGHT...)
        // is native ES 3.0 state; let the backend validate the value.
        if (!sfpewEnsureBackend() || g_glFuncs.glPixelStorei == nullptr) return;
        sfpewClientStateBarrier();
        g_glFuncs.glPixelStorei(pname, param);
        return;
    }
}

void glPixelStoref(GLenum pname, GLfloat param) { glPixelStorei(pname, static_cast<GLint>(param)); }

#undef ORDERED_PASSTHROUGH
