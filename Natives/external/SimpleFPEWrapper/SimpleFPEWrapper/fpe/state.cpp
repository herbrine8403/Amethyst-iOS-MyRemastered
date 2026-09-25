// SimpleFPEWrapper - SimpleFPEWrapper/fpe/state.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "state.h"
#include "fpe.hpp"
#include "drawing1x.h"
#include <glm/gtc/type_ptr.hpp>
#include "list.h"
#include "pointer_utils.h"
#include "../init.h"

#include <algorithm>
#include <cstring>

#define DEBUG 0

#if GLOBAL_DEBUG || DEBUG
#pragma clang optimize off
#endif

namespace {

int active_texture_index() {
    // The glActiveTexture wrapper maintains a thread-local shadow; a
    // synchronous backend round-trip per call is unnecessary.
    const GLint active = (GLint)sfpewLogicalActiveTexture();
    return std::clamp(active - (GLint)GL_TEXTURE0, 0, MAX_TEX - 1);
}

int light_index(GLenum light) {
    if (light < GL_LIGHT0 || light >= GL_LIGHT0 + MAX_LIGHTS) return -1;
    return static_cast<int>(light - GL_LIGHT0);
}

int material_param_count(GLenum pname) {
    switch (pname) {
    case GL_SHININESS:
        return 1;
    case GL_COLOR_INDEXES:
        return 3;
    case GL_AMBIENT:
    case GL_DIFFUSE:
    case GL_SPECULAR:
    case GL_EMISSION:
    case GL_AMBIENT_AND_DIFFUSE:
        return 4;
    default:
        return 1;
    }
}

int tex_env_param_count(GLenum pname) {
    return pname == GL_TEXTURE_ENV_COLOR ? 4 : 1;
}

template <typename Func>
void for_each_material(GLenum face, Func&& func) {
    auto& materials = g_glstate.fpe_uniform.materials;
    if (face == GL_FRONT || face == GL_FRONT_AND_BACK) func(materials[0]);
    if (face == GL_BACK || face == GL_FRONT_AND_BACK) func(materials[1]);
}

texture_env_t& current_texture_env(glstate_t& gs) {
    return gs.fpe_uniform.texture_env[active_texture_index()];
}

// Shared body of glTexEnvi minus recording: called by the glTexEnv* family
// after the entry's single strict resolve, replacing SELF_CALL re-entry
// (which would re-resolve the context per hop).
void tex_env_set_int(glstate_t& gs, GLenum target, GLenum pname, GLint param) {
    if (target == GL_TEXTURE_FILTER_CONTROL && pname == GL_TEXTURE_LOD_BIAS) {
        current_texture_env(gs).lod_bias = (GLfloat)param;
        return;
    }
    // defects-plan-2.md 2.2: glTexEnv(GL_POINT_SPRITE, GL_COORD_REPLACE, ...)
    // targets the currently active unit, same indexing as every other
    // per-unit texture-env parameter.
    if (target == GL_POINT_SPRITE && pname == GL_COORD_REPLACE) {
        gs.fpe_state.fpe_bools.point_sprite_coord_replace[active_texture_index()] = param != 0;
        return;
    }
    if (target != GL_TEXTURE_ENV) return;

    auto& env = current_texture_env(gs);
    switch (pname) {
    case GL_TEXTURE_ENV_MODE:
        env.mode = param;
        gs.fpe_state.texture_env_mode[active_texture_index()] = param;
        break;
    case GL_COMBINE_RGB:
        env.combine_rgb = param;
        break;
    case GL_COMBINE_ALPHA:
        env.combine_alpha = param;
        break;
    case GL_SOURCE0_RGB:
    case GL_SOURCE1_RGB:
    case GL_SOURCE2_RGB:
        env.source_rgb[pname - GL_SOURCE0_RGB] = param;
        break;
    case GL_SOURCE0_ALPHA:
    case GL_SOURCE1_ALPHA:
    case GL_SOURCE2_ALPHA:
        env.source_alpha[pname - GL_SOURCE0_ALPHA] = param;
        break;
    case GL_OPERAND0_RGB:
    case GL_OPERAND1_RGB:
    case GL_OPERAND2_RGB:
        env.operand_rgb[pname - GL_OPERAND0_RGB] = param;
        break;
    case GL_OPERAND0_ALPHA:
    case GL_OPERAND1_ALPHA:
    case GL_OPERAND2_ALPHA:
        env.operand_alpha[pname - GL_OPERAND0_ALPHA] = param;
        break;
    case GL_RGB_SCALE:
        env.rgb_scale = (GLfloat)param;
        break;
    case GL_ALPHA_SCALE:
        env.alpha_scale = (GLfloat)param;
        break;
    default:
        break;
    }
}

} // namespace

void sfpewInitializePointSizeMax(glstate_t& state) {
    auto& uniform = state.fpe_uniform;
    if (uniform.point_size_max_initialized) return;
    if (sfpewCurrentContext() == EGL_NO_CONTEXT || !sfpewEnsureBackend() ||
        g_glFuncs.glGetFloatv == nullptr) {
        return;
    }

    // GL 2.1 initializes POINT_SIZE_MAX to the implementation's supported
    // maximum, even though Table 6.10 prints 1.0. GLES exposes that limit as
    // ALIASED_POINT_SIZE_RANGE; desktop compatibility uses POINT_SIZE_RANGE.
    GLenum range_name = GL_POINT_SIZE_RANGE;
    int major = 0, minor = 0;
    if (sfpewDesktopGLVersion(&major, &minor)) range_name = GL_ALIASED_POINT_SIZE_RANGE;
    GLfloat range[2] = {1.0f, 1.0f};
    g_glFuncs.glGetFloatv(range_name, range);
    uniform.point_size_max = std::max(1.0f, range[1]);
    uniform.point_size_max_initialized = true;
}

// Replays a color-buffer snapshot onto the backend, skipping the calls
// whose state already matches (glPopAttrib is frequent in legacy GUI code).
void restore_color_buffer(const color_buffer_state_t& current,
                          const color_buffer_state_t& wanted) {
    if (wanted.blend_enable != current.blend_enable) {
        if (wanted.blend_enable) g_glFuncs.glEnable(GL_BLEND);
        else g_glFuncs.glDisable(GL_BLEND);
    }
    if (wanted.dither_enable != current.dither_enable) {
        if (wanted.dither_enable) g_glFuncs.glEnable(GL_DITHER);
        else g_glFuncs.glDisable(GL_DITHER);
    }
    if ((wanted.src_rgb != current.src_rgb || wanted.dst_rgb != current.dst_rgb ||
         wanted.src_alpha != current.src_alpha || wanted.dst_alpha != current.dst_alpha)) {
        if (g_glFuncs.glBlendFuncSeparate != nullptr) {
            g_glFuncs.glBlendFuncSeparate(wanted.src_rgb, wanted.dst_rgb, wanted.src_alpha,
                                          wanted.dst_alpha);
        } else if (g_glFuncs.glBlendFunc != nullptr) {
            g_glFuncs.glBlendFunc(wanted.src_rgb, wanted.dst_rgb);
        }
    }
    if (wanted.equation_rgb != current.equation_rgb ||
        wanted.equation_alpha != current.equation_alpha) {
        if (g_glFuncs.glBlendEquationSeparate != nullptr) {
            g_glFuncs.glBlendEquationSeparate(wanted.equation_rgb, wanted.equation_alpha);
        } else if (g_glFuncs.glBlendEquation != nullptr) {
            g_glFuncs.glBlendEquation(wanted.equation_rgb);
        }
    }
    if (std::memcmp(wanted.blend_color, current.blend_color, sizeof(wanted.blend_color)) != 0 &&
        g_glFuncs.glBlendColor != nullptr) {
        g_glFuncs.glBlendColor(wanted.blend_color[0], wanted.blend_color[1], wanted.blend_color[2],
                               wanted.blend_color[3]);
    }
    if (std::memcmp(wanted.color_mask, current.color_mask, sizeof(wanted.color_mask)) != 0 &&
        g_glFuncs.glColorMask != nullptr) {
        g_glFuncs.glColorMask(wanted.color_mask[0], wanted.color_mask[1], wanted.color_mask[2],
                              wanted.color_mask[3]);
    }
}

void restore_depth_stencil_scissor(const fixed_function_state_t::backend_state_shadow_t& current,
                                   const fixed_function_state_t::backend_state_shadow_t& wanted,
                                   GLbitfield mask) {
    using shadow_t = fixed_function_state_t::backend_state_shadow_t;
    if (mask & GL_DEPTH_BUFFER_BIT) {
        if (wanted.depth_func != current.depth_func && g_glFuncs.glDepthFunc != nullptr)
            g_glFuncs.glDepthFunc(wanted.depth_func);
        if (wanted.depth_mask != current.depth_mask && g_glFuncs.glDepthMask != nullptr)
            g_glFuncs.glDepthMask(wanted.depth_mask);
    }
    if (mask & GL_STENCIL_BUFFER_BIT) {
        if ((wanted.stencil_func != current.stencil_func || wanted.stencil_ref != current.stencil_ref ||
             wanted.stencil_value_mask != current.stencil_value_mask) &&
            g_glFuncs.glStencilFunc != nullptr) {
            g_glFuncs.glStencilFunc(wanted.stencil_func, wanted.stencil_ref, wanted.stencil_value_mask);
        }
        if (wanted.stencil_mask != current.stencil_mask && g_glFuncs.glStencilMask != nullptr)
            g_glFuncs.glStencilMask(wanted.stencil_mask);
        if ((wanted.stencil_fail != current.stencil_fail ||
             wanted.stencil_zfail != current.stencil_zfail ||
             wanted.stencil_zpass != current.stencil_zpass) &&
            g_glFuncs.glStencilOp != nullptr) {
            g_glFuncs.glStencilOp(wanted.stencil_fail, wanted.stencil_zfail, wanted.stencil_zpass);
        }
    }
    if (mask & GL_SCISSOR_BIT) {
        if (std::memcmp(wanted.scissor, current.scissor, sizeof(wanted.scissor)) != 0 &&
            g_glFuncs.glScissor != nullptr) {
            g_glFuncs.glScissor(wanted.scissor[0], wanted.scissor[1], wanted.scissor[2],
                                wanted.scissor[3]);
        }
    }
    // GL_ENABLE_BIT covers every enable flag, including these three; a push
    // that named GL_DEPTH_BUFFER_BIT etc. without GL_ENABLE_BIT restores the
    // function/mask/op values above but leaves the enable itself alone, per
    // spec - GL_DEPTH_TEST's enable bit belongs to GL_ENABLE_BIT, not
    // GL_DEPTH_BUFFER_BIT (GL 2.1 table 6.23).
    if (mask & GL_ENABLE_BIT) {
        const int slots[3] = {shadow_t::kEnableDepthTest, shadow_t::kEnableStencilTest,
                              shadow_t::kEnableScissorTest};
        const GLenum caps[3] = {GL_DEPTH_TEST, GL_STENCIL_TEST, GL_SCISSOR_TEST};
        for (int i = 0; i < 3; ++i) {
            const int slot = slots[i];
            if (!wanted.enable_known[slot]) continue;
            if (current.enable_known[slot] && current.enable_value[slot] == wanted.enable_value[slot])
                continue;
            if (wanted.enable_value[slot]) {
                if (g_glFuncs.glEnable != nullptr) g_glFuncs.glEnable(caps[i]);
            } else {
                if (g_glFuncs.glDisable != nullptr) g_glFuncs.glDisable(caps[i]);
            }
        }
    }
}

// Caps the backend owns but the attrib stack must be able to restore.
// Unlike hijack_fpe_states this only records: the call still goes through.
void shadow_backend_enable(GLenum cap, bool enable) {
    auto& cb = g_glstate.fpe_state.color_buffer;
    switch (cap) {
    case GL_BLEND:
        cb.blend_enable = enable;
        break;
    case GL_DITHER:
        cb.dither_enable = enable;
        break;
    default:
        break;
    }
}

bool hijack_fpe_states(GLenum cap, bool enable, fixed_function_bool_t* bools) {
    switch (cap) {
    case GL_FOG:
        bools->fog_enable = enable;
        return true;
    case GL_LIGHTING:
        bools->lighting_enable = enable;
        return true;
    case GL_ALPHA_TEST:
        bools->alpha_test_enable = enable;
        return true;
    case GL_COLOR_MATERIAL:
        bools->color_material_enable = enable;
        return true;
    case GL_LIGHT0:
    case GL_LIGHT1:
    case GL_LIGHT2:
    case GL_LIGHT3:
    case GL_LIGHT4:
    case GL_LIGHT5:
    case GL_LIGHT6:
    case GL_LIGHT7:
        bools->light_enable[cap - GL_LIGHT0] = enable;
        return true;
    case GL_TEXTURE_1D: // Nx1 2D emulation shares the unit enable
    case GL_TEXTURE_2D:
        bools->texture_2d_enable[active_texture_index()] = enable;
        return true;
    case GL_TEXTURE_3D:
        bools->texture_3d_enable[active_texture_index()] = enable;
        return true;
    case GL_TEXTURE_CUBE_MAP:
        bools->texture_cube_enable[active_texture_index()] = enable;
        return true;
    case GL_NORMALIZE:
        bools->normalize_enable = enable;
        return true;
    case GL_TEXTURE_GEN_S:
    case GL_TEXTURE_GEN_T:
    case GL_TEXTURE_GEN_R:
    case GL_TEXTURE_GEN_Q:
        bools->texture_gen_enable[active_texture_index()][cap - GL_TEXTURE_GEN_S] = enable;
        return true;
    case GL_POLYGON_STIPPLE:
        bools->polygon_stipple_enable = enable;
        return true;
    case GL_LINE_STIPPLE:
        bools->line_stipple_enable = enable;
        return true;
    case GL_CLIP_PLANE0:
    case GL_CLIP_PLANE0 + 1:
    case GL_CLIP_PLANE0 + 2:
    case GL_CLIP_PLANE0 + 3:
    case GL_CLIP_PLANE0 + 4:
    case GL_CLIP_PLANE0 + 5:
        bools->clip_plane_enable[cap - GL_CLIP_PLANE0] = enable;
        return true;
    case GL_RESCALE_NORMAL:
        bools->rescale_normal_enable = enable;
        return true;
    case GL_COLOR_SUM:
        bools->color_sum_enable = enable;
        return true;
    // defects-plan-2.md 2.2/2.4.
    case GL_POINT_SPRITE:
        bools->point_sprite_enable = enable;
        return true;
    case GL_POINT_SMOOTH:
        bools->point_smooth_enable = enable;
        return true;
    default:
        break;
    }
    return sfpewEvaluatorEnable(cap, enable);
}

// Slot for the caps whose last issued value the wrapper can trust; -1 for
// everything else, which is always forwarded. Deliberately conservative: a
// cap belongs here only if nothing inside the wrapper ever enables or
// disables it behind the app's back.
static int backendEnableSlot(GLenum cap) {
    using shadow_t = fixed_function_state_t::backend_state_shadow_t;
    switch (cap) {
    case GL_DEPTH_TEST: return shadow_t::kEnableDepthTest;
    case GL_STENCIL_TEST: return shadow_t::kEnableStencilTest;
    case GL_SCISSOR_TEST: return shadow_t::kEnableScissorTest;
    case GL_CULL_FACE: return shadow_t::kEnableCullFace;
    case GL_POLYGON_OFFSET_FILL: return shadow_t::kEnablePolygonOffsetFill;
    case GL_SAMPLE_ALPHA_TO_COVERAGE: return shadow_t::kEnableSampleAlphaToCoverage;
    case GL_SAMPLE_COVERAGE: return shadow_t::kEnableSampleCoverage;
    default: return -1;
    }
}

// True when this enable/disable is already the backend's state, so the call
// can be dropped. Legacy renderers re-assert a pass's enables around every
// draw, and those repeats are pure driver cost.
static bool backendEnableRedundant(glstate_t& gs, GLenum cap, bool enable) {
    const int slot = backendEnableSlot(cap);
    if (slot < 0) return false;
    auto& shadow = gs.fpe_state.backend_state;
    if (shadow.enable_known[slot] && shadow.enable_value[slot] == enable) return true;
    shadow.enable_known[slot] = true;
    shadow.enable_value[slot] = enable;
    return false;
}

void glEnable(GLenum cap) {
    // Flush-only: FPE-hijacked caps mutate wrapper CPU state, and the
    // passthrough caps (GL_BLEND, GL_DEPTH_TEST, ...) are server enables that
    // neither read nor write the program, VAO or buffer bindings - the same
    // bar sfpewTextureStateBarrier documents. MC's GUI toggles GL_ALPHA_TEST
    // around every widget, so a full restore here cost a glUseProgram round
    // trip per widget.
    sfpewClientStateBarrier();
    // LOG()
    // LOG_D("glEnable, cap = %s", glEnumToString(cap));

    LIST_RECORD(glEnable, {}, cap)

    auto& gs = g_glstate;
    switch (cap) {
    case GL_COLOR_TABLE: gs.color_tables[0].enabled = true; return;
    case GL_POST_CONVOLUTION_COLOR_TABLE: gs.color_tables[1].enabled = true; return;
    case GL_POST_COLOR_MATRIX_COLOR_TABLE: gs.color_tables[2].enabled = true; return;
    case GL_CONVOLUTION_1D: gs.convolutions[0].enabled = true; return;
    case GL_CONVOLUTION_2D: gs.convolutions[1].enabled = true; return;
    case GL_SEPARABLE_2D: gs.convolutions[2].enabled = true; return;
    case GL_HISTOGRAM: gs.histogram.enabled = true; return;
    case GL_MINMAX: gs.minmax.enabled = true; return;
    default: break;
    }
    if (hijack_fpe_states(cap, true, &gs.fpe_state.fpe_bools)) return;

    shadow_backend_enable(cap, true);
    if (backendEnableRedundant(gs, cap, true)) return;
    // A cap hijack_fpe_states/backendEnableRedundant doesn't recognize (e.g.
    // GL_COLOR_LOGIC_OP) can be the very first backend-touching call this
    // context ever makes, so the backend must be lazily loaded here too -
    // every other raw passthrough in the wrapper already guards this way.
    if (!sfpewEnsureBackend() || g_glFuncs.glEnable == nullptr) return;
    g_glFuncs.glEnable(cap);
}

void glDisable(GLenum cap) {
    // Flush-only; see glEnable.
    sfpewClientStateBarrier();
    // LOG()
    // LOG_D("glDisable, cap = %s", glEnumToString(cap))

    LIST_RECORD(glDisable, {}, cap)

    auto& gs = g_glstate;
    switch (cap) {
    case GL_COLOR_TABLE: gs.color_tables[0].enabled = false; return;
    case GL_POST_CONVOLUTION_COLOR_TABLE: gs.color_tables[1].enabled = false; return;
    case GL_POST_COLOR_MATRIX_COLOR_TABLE: gs.color_tables[2].enabled = false; return;
    case GL_CONVOLUTION_1D: gs.convolutions[0].enabled = false; return;
    case GL_CONVOLUTION_2D: gs.convolutions[1].enabled = false; return;
    case GL_SEPARABLE_2D: gs.convolutions[2].enabled = false; return;
    case GL_HISTOGRAM: gs.histogram.enabled = false; return;
    case GL_MINMAX: gs.minmax.enabled = false; return;
    default: break;
    }
    if (hijack_fpe_states(cap, false, &gs.fpe_state.fpe_bools)) return;

    shadow_backend_enable(cap, false);
    if (backendEnableRedundant(gs, cap, false)) return;
    // See the matching guard in glEnable.
    if (!sfpewEnsureBackend() || g_glFuncs.glDisable == nullptr) return;
    g_glFuncs.glDisable(cap);
}

void glClientActiveTexture(GLenum texture) {
    sfpewClientStateBarrier();
    // LOG()
    // LOG_D("glClientActiveTexture(GL_TEXTURE%d)", texture - GL_TEXTURE0)

    // Todo: this function can be added to displayList when GL 1.3+ is disabled

    // Unvalidated, client_active_texture would reach vp2idx() unclamped and
    // index straight past attributes[VERTEX_POINTER_COUNT] on an out-of-range
    // enum - matching the bounds check DEFINE_MULTITEXCOORD below already
    // applies to its own unit argument.
    if (texture < GL_TEXTURE0 || texture - GL_TEXTURE0 >= MAX_TEX) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }

    auto& gs = g_glstate;
    gs.fpe_state.client_active_texture = texture;
}

// glFogCoord* (GL 1.4 core / EXT_fog_coord). Only meaningful once
// glFogi(GL_FOG_COORD_SRC, GL_FOG_COORD) selects it as the fog distance;
// these were missing entirely, so callers resolved the backend's desktop
// symbol and got GL_INVALID_OPERATION on a GLES context.
void glFogCoordf(GLfloat coord) {
    LIST_RECORD(glFogCoordf, {}, coord)
    mglFogCoord(coord);
}

void glFogCoordd(GLdouble coord) {
    LIST_RECORD(glFogCoordd, {}, coord)
    mglFogCoord(coord);
}

void glFogCoordfv(const GLfloat* coord) {
    if (coord == nullptr) return;
    glFogCoordf(coord[0]);
}

void glFogCoorddv(const GLdouble* coord) {
    if (coord == nullptr) return;
    glFogCoordd(coord[0]);
}

template <typename T>
void set_secondary_color(T red, T green, T blue) {
    mglSecondaryColor<T, 3>({red, green, blue});
}

#define DEFINE_SECONDARY_COLOR(SUFFIX, TYPE)                                                        \
    void glSecondaryColor3##SUFFIX(TYPE red, TYPE green, TYPE blue) {                               \
        LIST_RECORD(glSecondaryColor3##SUFFIX, {}, red, green, blue)                                \
        set_secondary_color(red, green, blue);                                                       \
    }                                                                                                \
    void glSecondaryColor3##SUFFIX##v(const TYPE* value) {                                          \
        if (value == nullptr) return;                                                                \
        LIST_RECORD(glSecondaryColor3##SUFFIX##v, {{0, 3 * sizeof(TYPE)}}, value)                    \
        set_secondary_color(value[0], value[1], value[2]);                                           \
    }

DEFINE_SECONDARY_COLOR(b, GLbyte)
DEFINE_SECONDARY_COLOR(s, GLshort)
DEFINE_SECONDARY_COLOR(i, GLint)
DEFINE_SECONDARY_COLOR(f, GLfloat)
DEFINE_SECONDARY_COLOR(d, GLdouble)
DEFINE_SECONDARY_COLOR(ub, GLubyte)
DEFINE_SECONDARY_COLOR(us, GLushort)
DEFINE_SECONDARY_COLOR(ui, GLuint)

#undef DEFINE_SECONDARY_COLOR

// The fixed-function state family below (alpha test, fog, lighting,
// materials, texture environment, texgen, clip planes, point/line/polygon
// state) takes the flush-only barrier. Every one of them writes wrapper
// CPU state that the next draw turns into a uniform or a shader key, and
// not one reads or writes the program, VAO or buffer bindings - the bar
// drawing1x.h sets. The pending batch still drains, because it was
// collected under the state being changed.
//
// Under the full barrier a lit renderer paid a
// glUseProgram/glBindVertexArray/glBindBuffer round trip for every
// material and light change: five of those per model in the lighting
// benchmark, none of which the application could observe.
void glAlphaFunc(GLenum func, GLclampf ref) {
    sfpewClientStateBarrier();
    // LOG()
    // LOG_D("glAlphaFunc(%s, %f)", glEnumToString(func), ref)

    // alpha_func feeds shader generation; an unvalidated enum used to end
    // up as error text inside the GLSL source. Erroring commands are not
    // recorded into display lists.
    auto& gs = g_glstate;
    if (func < GL_NEVER || func > GL_ALWAYS) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }

    LIST_RECORD(glAlphaFunc, {}, func, ref)

    gs.fpe_state.alpha_func = func;
    gs.fpe_uniform.alpha_ref = ref;
}

// glLogicOp (GL 1.0, spec 4.1.10): stored so GL_LOGIC_OP_MODE reads back
// exactly what was set, but neither backend floor gets a real logic-op
// effect from it - ES 3.0 core removed fixed-function logic ops entirely,
// and there is no extension-free way to read the framebuffer's current
// color inside a fragment shader on that floor to emulate one. Per this
// project's two-backend, no-branching invariant, a feature only one floor
// can execute does not get a real implementation (see how texture
// residency/priorities are handled - real, honest state tracking with no
// forwarded rendering effect). GL_COLOR_LOGIC_OP/GL_INDEX_LOGIC_OP
// deliberately keep reporting disabled in ffp_state_query.cpp for the same reason:
// enabling them would advertise a render effect that is not present.
void glLogicOp(GLenum opcode) {
    sfpewClientStateBarrier();
    auto& gs = g_glstate;
    if (opcode < GL_CLEAR || opcode > GL_SET) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    LIST_RECORD(glLogicOp, {}, opcode)
    gs.fpe_state.logic_op_mode = opcode;
}

void glFogf(GLenum pname, GLfloat param) {
    sfpewClientStateBarrier();
    // LOG()
    // LOG_D("glFogf(%s, %f)", glEnumToString(pname), param)

    LIST_RECORD(glFogf, {}, pname, param)

    auto& gs = g_glstate;
    switch (pname) {
    case GL_FOG_DENSITY:
        gs.fpe_uniform.fog_density = param;
        return;
    case GL_FOG_START:
        gs.fpe_uniform.fog_start = param;
        return;
    case GL_FOG_END:
        gs.fpe_uniform.fog_end = param;
        return;

    // below should not be handled here
    case GL_FOG_MODE:
    case GL_FOG_INDEX:
    case GL_FOG_COORD_SRC:
        SELF_CALL(glFogi, pname, (GLint)param)
        return;

    default:
        gs.set_error(GL_INVALID_ENUM);
        break;
    }
}

void glFogi(GLenum pname, GLint param) {
    sfpewClientStateBarrier();
    // LOG()
    // LOG_D("glFogi(%s, %s)", glEnumToString(pname), glEnumToString(param))

    LIST_RECORD(glFogi, {}, pname, param)

    auto& gs = g_glstate;
    switch (pname) {
    case GL_FOG_MODE:
        // fog_mode selects generated shader code; an invalid mode used to
        // produce GLSL referencing an undeclared fogFactor.
        if (param != GL_LINEAR && param != GL_EXP && param != GL_EXP2) {
            gs.set_error(GL_INVALID_ENUM);
            break;
        }
        gs.fpe_state.fog_mode = param;
        break;
    case GL_FOG_INDEX:
        gs.fpe_state.fog_index = param;
        break;
    case GL_FOG_COORD_SRC:
        if (param != GL_FRAGMENT_DEPTH && param != GL_FOG_COORD) {
            gs.set_error(GL_INVALID_ENUM);
            break;
        }
        gs.fpe_state.fog_coord_src = param;
        break;

    // below should not be handled here
    case GL_FOG_DENSITY:
    case GL_FOG_START:
    case GL_FOG_END:
        SELF_CALL(glFogf, pname, (GLfloat)param)
        return;
    default:
        gs.set_error(GL_INVALID_ENUM);
        break;
    }
}

void glFogfv(GLenum pname, const GLfloat* params) {
    sfpewClientStateBarrier();
    // LOG()
    // LOG_D("glFogfv(%s, [...])", glEnumToString(pname))

    if (params == nullptr) return; // LIST_RECORD deep-copies via pname_to_count; guard before it
    LIST_RECORD(glFogfv, {{1, PointerUtils::pname_to_count(pname) * sizeof(GLfloat)}}, pname, params)

    auto& gs = g_glstate;
    switch (pname) {
    case GL_FOG_MODE:
    case GL_FOG_INDEX:
    case GL_FOG_COORD_SRC:
        SELF_CALL(glFogi, pname, (GLint)params[0])
        break;
    case GL_FOG_DENSITY:
    case GL_FOG_START:
    case GL_FOG_END:
        SELF_CALL(glFogf, pname, params[0])
        break;
    case GL_FOG_COLOR: {
        auto& fcolor = gs.fpe_uniform.fog_color;
        fcolor = glm::make_vec4(params);
        // LOG_D("[...] = [%.2f, %.2f, %.2f, %.2f]", params[0], params[1], params[2], params[3])
        // LOG_D("fcolor = [%.2f, %.2f, %.2f, %.2f]", fcolor[0], fcolor[1], fcolor[2], fcolor[3])
        break;
    }
    default:
        gs.set_error(GL_INVALID_ENUM);
        break;
    }
}

void glFogiv(GLenum pname, const GLint* params) {
    sfpewClientStateBarrier();
    // LOG()
    // LOG_D("glFogiv(%s, [...])", glEnumToString(pname))

    if (params == nullptr) return;
    LIST_RECORD(glFogiv, {{1, PointerUtils::pname_to_count(pname) * sizeof(GLint)}}, pname, params)

    auto& gs = g_glstate;
    switch (pname) {
    case GL_FOG_COLOR: {
        auto& fcolor = gs.fpe_uniform.fog_color;
        fcolor[0] = (GLfloat)params[0] / (GLfloat)INT32_MAX;
        fcolor[1] = (GLfloat)params[1] / (GLfloat)INT32_MAX;
        fcolor[2] = (GLfloat)params[2] / (GLfloat)INT32_MAX;
        fcolor[3] = (GLfloat)params[3] / (GLfloat)INT32_MAX;
        // LOG_D("[...] = [%d, %d, %d, %d]", params[0], params[1], params[2], params[3])
        break;
    }
    case GL_FOG_MODE:
    case GL_FOG_INDEX:
    case GL_FOG_COORD_SRC:
        SELF_CALL(glFogi, pname, params[0])
        break;
    case GL_FOG_DENSITY:
    case GL_FOG_START:
    case GL_FOG_END:
        SELF_CALL(glFogf, pname, (GLfloat)params[0])
        break;
    default:
        gs.set_error(GL_INVALID_ENUM);
        break;
    }
}

void glShadeModel(GLenum mode) {
    sfpewClientStateBarrier();
    // LOG()
    // LOG_D("glShadeModel(%s)", glEnumToString(mode))

    auto& gs = g_glstate;
    if (mode != GL_FLAT && mode != GL_SMOOTH) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }

    LIST_RECORD(glShadeModel, {}, mode)

    gs.fpe_state.shade_model = mode;
}

void glLightf(GLenum light, GLenum pname, GLfloat param) {
    sfpewClientStateBarrier();
    // LOG()
    // LOG_D("glLightf(%s, %s, %f)", glEnumToString(light), glEnumToString(pname), param)

    LIST_RECORD(glLightf, {}, light, pname, param)

    const int index = light_index(light);
    if (index < 0) return;
    auto& gs = g_glstate;
    auto& lightref = gs.fpe_uniform.lights[index];

    switch (pname) {
    case GL_SPOT_EXPONENT:
        lightref.spot_exp = param;
        break;
    case GL_SPOT_CUTOFF:
        lightref.spot_cutoff = param;
        break;
    case GL_CONSTANT_ATTENUATION:
        lightref.constant_attenuation = param;
        break;
    case GL_LINEAR_ATTENUATION:
        lightref.linear_attenuation = param;
        break;
    case GL_QUADRATIC_ATTENUATION:
        lightref.quadratic_attenuation = param;
        break;
    default:
        gs.set_error(GL_INVALID_ENUM);
        break;
    }
}

void glLighti(GLenum light, GLenum pname, GLint param) {
    sfpewClientStateBarrier();
    // LOG()
    // LOG_D("glLighti(%s, %s, %d)", glEnumToString(light), glEnumToString(pname), param)

    LIST_RECORD(glLighti, {}, light, pname, param)

    SELF_CALL(glLightf, light, pname, (GLfloat)param)
}

void glLightfv(GLenum light, GLenum pname, const GLfloat* params) {
    sfpewClientStateBarrier();
    // LOG()
    // LOG_D("glLightfv(%s, %s, [...])", glEnumToString(light), glEnumToString(pname))

    // Commands that would generate an error are not compiled into display
    // lists, and the record path deep-copies params before any check ran.
    const int index = light_index(light);
    if (index < 0 || params == nullptr) return;

    LIST_RECORD(glLightfv, {{2, PointerUtils::pname_to_count(pname) * sizeof(GLfloat)}}, light, pname, params)

    auto& gs = g_glstate;
    auto& lightref = gs.fpe_uniform.lights[index];

    switch (pname) {
    case GL_SPOT_CUTOFF:
    case GL_SPOT_EXPONENT:
    case GL_CONSTANT_ATTENUATION:
    case GL_LINEAR_ATTENUATION:
    case GL_QUADRATIC_ATTENUATION:
        SELF_CALL(glLightf, light, pname, params[0])
        break;

    case GL_AMBIENT: {
        lightref.ambient = glm::make_vec4(params);
        break;
    }
    case GL_DIFFUSE: {
        lightref.diffuse = glm::make_vec4(params);
        break;
    }
    case GL_SPECULAR: {
        lightref.specular = glm::make_vec4(params);
        break;
    }
    case GL_POSITION: {
        // Desktop GL captures light positions in eye coordinates. In
        // particular, Minecraft rotates the ModelView matrix around the two
        // directional glLight(GL_POSITION) calls and restores it afterwards.
        const auto& model_view =
            gs.fpe_uniform.transformation.matrices[matrix_idx(GL_MODELVIEW)];
        lightref.position = model_view * glm::make_vec4(params);
        break;
    }
    case GL_SPOT_DIRECTION: {
        // Like GL_POSITION, spot directions are captured in eye coordinates
        // using the upper 3x3 of the model-view current at call time.
        const auto& mv = gs.fpe_uniform.transformation.matrices[matrix_idx(GL_MODELVIEW)];
        lightref.spot_direction = glm::mat3(mv) * glm::make_vec3(params);
        break;
    }
    default:
        gs.set_error(GL_INVALID_ENUM);
        break;
    }
}

void glLightiv(GLenum light, GLenum pname, const GLint* params) {
    sfpewClientStateBarrier();
    // LOG()
    // LOG_D("glLightiv(%s, %s, [...])", glEnumToString(light), glEnumToString(pname))

    if (light_index(light) < 0 || params == nullptr) return;

    LIST_RECORD(glLightiv, {{2, PointerUtils::pname_to_count(pname) * sizeof(GLint)}}, light, pname, params)

    auto& gs = g_glstate;
    switch (pname) {
    case GL_SPOT_CUTOFF:
    case GL_SPOT_EXPONENT:
    case GL_CONSTANT_ATTENUATION:
    case GL_LINEAR_ATTENUATION:
    case GL_QUADRATIC_ATTENUATION:
        SELF_CALL(glLighti, light, pname, params[0]);
        break;

    case GL_AMBIENT:
    case GL_DIFFUSE:
    case GL_SPECULAR: {
        GLfloat converted[4];
        for (int i = 0; i < 4; ++i) converted[i] = sfpewNormalizeColorComponent(params[i]);
        SELF_CALL(glLightfv, light, pname, converted)
        break;
    }
    case GL_POSITION: {
        const glm::vec4 vec = glm::make_vec4(params);
        SELF_CALL(glLightfv, light, pname, glm::value_ptr(vec))
        break;
    }
    case GL_SPOT_DIRECTION: {
        const glm::vec3 vec = glm::make_vec3(params);
        SELF_CALL(glLightfv, light, pname, glm::value_ptr(vec))
        break;
    }
    default:
        gs.set_error(GL_INVALID_ENUM);
        break;
    }
}

void glGetLightfv(GLenum light, GLenum pname, GLfloat* params) {
    if (!params) return;
    auto& gs = g_glstate;
    if (light < GL_LIGHT0 || light >= GL_LIGHT0 + MAX_LIGHTS) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    const auto& l = gs.fpe_uniform.lights[light - GL_LIGHT0];
    switch (pname) {
    case GL_AMBIENT:
        memcpy(params, glm::value_ptr(l.ambient), 4 * sizeof(GLfloat));
        break;
    case GL_DIFFUSE:
        memcpy(params, glm::value_ptr(l.diffuse), 4 * sizeof(GLfloat));
        break;
    case GL_SPECULAR:
        memcpy(params, glm::value_ptr(l.specular), 4 * sizeof(GLfloat));
        break;
    case GL_POSITION:
        // Stored in eye coordinates (transformed at call time), which is
        // exactly what GetLight returns per spec.
        memcpy(params, glm::value_ptr(l.position), 4 * sizeof(GLfloat));
        break;
    case GL_SPOT_DIRECTION:
        memcpy(params, glm::value_ptr(l.spot_direction), 3 * sizeof(GLfloat));
        break;
    case GL_SPOT_EXPONENT:
        params[0] = l.spot_exp;
        break;
    case GL_SPOT_CUTOFF:
        params[0] = l.spot_cutoff;
        break;
    case GL_CONSTANT_ATTENUATION:
        params[0] = l.constant_attenuation;
        break;
    case GL_LINEAR_ATTENUATION:
        params[0] = l.linear_attenuation;
        break;
    case GL_QUADRATIC_ATTENUATION:
        params[0] = l.quadratic_attenuation;
        break;
    default:
        gs.set_error(GL_INVALID_ENUM);
        break;
    }
}

void glGetLightiv(GLenum light, GLenum pname, GLint* params) {
    if (!params) return;
    GLfloat staging[4] = {};
    glGetLightfv(light, pname, staging);
    const int count = (pname == GL_AMBIENT || pname == GL_DIFFUSE || pname == GL_SPECULAR ||
                       pname == GL_POSITION)
                          ? 4
                          : (pname == GL_SPOT_DIRECTION ? 3 : 1);
    for (int i = 0; i < count; ++i) params[i] = static_cast<GLint>(staging[i]);
}

void glLightModelf(GLenum pname, GLfloat param) {
    sfpewClientStateBarrier();
    // LOG()
    // LOG_D("glLightModelf(%s, %f)", glEnumToString(pname), param)

    LIST_RECORD(glLightModelf, {}, pname, param)

    auto& gs = g_glstate;
    switch (pname) {
    case GL_LIGHT_MODEL_LOCAL_VIEWER:
    case GL_LIGHT_MODEL_COLOR_CONTROL:
    case GL_LIGHT_MODEL_TWO_SIDE:
        SELF_CALL(glLightModeli, pname, (GLint)param)
        break; // previously fell through into the (then-empty) default
    default:
        gs.set_error(GL_INVALID_ENUM);
        break;
    }
}

void glLightModeli(GLenum pname, GLint param) {
    sfpewClientStateBarrier();
    // LOG()
    // LOG_D("glLightModelf(%s, %d)", glEnumToString(pname), param)

    LIST_RECORD(glLightModeli, {}, pname, param)

    auto& gs = g_glstate;
    switch (pname) {
    case GL_LIGHT_MODEL_COLOR_CONTROL:
        gs.fpe_state.light_model_color_ctrl = param;
        break;
    case GL_LIGHT_MODEL_LOCAL_VIEWER:
        gs.fpe_state.light_model_local_viewer = param;
        break;
    case GL_LIGHT_MODEL_TWO_SIDE:
        gs.fpe_state.light_model_two_side = param;
        break;
    default:
        gs.set_error(GL_INVALID_ENUM);
        break;
    }
}

void glLightModelfv(GLenum pname, const GLfloat* params) {
    sfpewClientStateBarrier();
    // LOG()
    // LOG_D("glLightModelfv(%s, [...])", glEnumToString(pname))

    if (params == nullptr) return;
    LIST_RECORD(glLightModelfv, {{1, PointerUtils::pname_to_count(pname) * sizeof(GLfloat)}}, pname, params)

    auto& gs = g_glstate;
    switch (pname) {
    case GL_LIGHT_MODEL_AMBIENT:
        gs.fpe_uniform.light_model_ambient = glm::make_vec4(params);
        break;
    case GL_LIGHT_MODEL_COLOR_CONTROL:
    case GL_LIGHT_MODEL_LOCAL_VIEWER:
    case GL_LIGHT_MODEL_TWO_SIDE:
        SELF_CALL(glLightModelf, pname, params[0]);
        break;
    default:
        gs.set_error(GL_INVALID_ENUM);
        break;
    }
}

void glLightModeliv(GLenum pname, const GLint* params) {
    sfpewClientStateBarrier();
    // LOG()
    // LOG_D("glLightModeliv(%s, [...])", glEnumToString(pname))

    if (params == nullptr) return;
    LIST_RECORD(glLightModeliv, {{1, PointerUtils::pname_to_count(pname) * sizeof(GLint)}}, pname, params)

    auto& gs = g_glstate;
    switch (pname) {
    case GL_LIGHT_MODEL_AMBIENT: {
        GLfloat converted[4];
        for (int i = 0; i < 4; ++i) converted[i] = sfpewNormalizeColorComponent(params[i]);
        SELF_CALL(glLightModelfv, pname, converted)
        break;
    }
    case GL_LIGHT_MODEL_COLOR_CONTROL:
    case GL_LIGHT_MODEL_LOCAL_VIEWER:
    case GL_LIGHT_MODEL_TWO_SIDE:
        SELF_CALL(glLightModeli, pname, params[0]);
        break;
    default:
        gs.set_error(GL_INVALID_ENUM);
        break;
    }
}

void glColorMaterial(GLenum face, GLenum mode) {
    sfpewClientStateBarrier();
    LIST_RECORD(glColorMaterial, {}, face, mode)

    if (face != GL_FRONT && face != GL_BACK && face != GL_FRONT_AND_BACK) return;
    auto& gs = g_glstate;
    switch (mode) {
    case GL_AMBIENT:
    case GL_DIFFUSE:
    case GL_SPECULAR:
    case GL_EMISSION:
    case GL_AMBIENT_AND_DIFFUSE:
        gs.fpe_state.color_material_face = face;
        gs.fpe_state.color_material_mode = mode;
        break;
    default:
        break;
    }
}

void glMaterialf(GLenum face, GLenum pname, GLfloat param) {
    sfpewClientStateBarrier();
    LIST_RECORD(glMaterialf, {}, face, pname, param)

    if (pname != GL_SHININESS || param < 0.0f || param > 128.0f) return;
    for_each_material(face, [param](material_t& material) { material.shininess = param; });
}

void glMateriali(GLenum face, GLenum pname, GLint param) {
    sfpewClientStateBarrier();
    LIST_RECORD(glMateriali, {}, face, pname, param)

    SELF_CALL(glMaterialf, face, pname, (GLfloat)param)
}

void glMaterialfv(GLenum face, GLenum pname, const GLfloat* params) {
    sfpewClientStateBarrier();
    if (params == nullptr) return;
    LIST_RECORD(glMaterialfv, {{2, material_param_count(pname) * sizeof(GLfloat)}}, face, pname, params)

    if (!params) return;
    switch (pname) {
    case GL_SHININESS:
        SELF_CALL(glMaterialf, face, pname, params[0])
        break;
    case GL_AMBIENT:
        for_each_material(face, [params](material_t& material) { material.ambient = glm::make_vec4(params); });
        break;
    case GL_DIFFUSE:
        for_each_material(face, [params](material_t& material) { material.diffuse = glm::make_vec4(params); });
        break;
    case GL_SPECULAR:
        for_each_material(face, [params](material_t& material) { material.specular = glm::make_vec4(params); });
        break;
    case GL_EMISSION:
        for_each_material(face, [params](material_t& material) { material.emission = glm::make_vec4(params); });
        break;
    case GL_AMBIENT_AND_DIFFUSE:
        for_each_material(face, [params](material_t& material) {
            material.ambient = glm::make_vec4(params);
            material.diffuse = glm::make_vec4(params);
        });
        break;
    case GL_COLOR_INDEXES:
        for_each_material(face, [params](material_t& material) { material.color_indexes = glm::make_vec3(params); });
        break;
    default:
        break;
    }
}

void glMaterialiv(GLenum face, GLenum pname, const GLint* params) {
    sfpewClientStateBarrier();
    if (params == nullptr) return;
    LIST_RECORD(glMaterialiv, {{2, material_param_count(pname) * sizeof(GLint)}}, face, pname, params)

    if (!params) return;
    if (pname == GL_SHININESS) {
        SELF_CALL(glMateriali, face, pname, params[0])
        return;
    }

    GLfloat converted[4] = {};
    const int count = material_param_count(pname);
    for (int i = 0; i < count; ++i) {
        converted[i] = pname == GL_COLOR_INDEXES ? (GLfloat)params[i]
                                                  : sfpewNormalizeColorComponent(params[i]);
    }
    SELF_CALL(glMaterialfv, face, pname, converted)
}

void glGetMaterialfv(GLenum face, GLenum pname, GLfloat* params) {
    if (!params) return;
    auto& gs = g_glstate;
    // GL_FRONT_AND_BACK is valid for setting but not for querying.
    if (face != GL_FRONT && face != GL_BACK) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    const auto& material = gs.fpe_uniform.materials[face == GL_FRONT ? 0 : 1];
    switch (pname) {
    case GL_AMBIENT:
        memcpy(params, glm::value_ptr(material.ambient), 4 * sizeof(GLfloat));
        break;
    case GL_DIFFUSE:
        memcpy(params, glm::value_ptr(material.diffuse), 4 * sizeof(GLfloat));
        break;
    case GL_SPECULAR:
        memcpy(params, glm::value_ptr(material.specular), 4 * sizeof(GLfloat));
        break;
    case GL_EMISSION:
        memcpy(params, glm::value_ptr(material.emission), 4 * sizeof(GLfloat));
        break;
    case GL_SHININESS:
        params[0] = material.shininess;
        break;
    case GL_COLOR_INDEXES:
        memcpy(params, glm::value_ptr(material.color_indexes), 3 * sizeof(GLfloat));
        break;
    default:
        gs.set_error(GL_INVALID_ENUM);
        break;
    }
}

void glGetMaterialiv(GLenum face, GLenum pname, GLint* params) {
    if (!params) return;
    GLfloat staging[4] = {};
    glGetMaterialfv(face, pname, staging);
    const int count = pname == GL_SHININESS ? 1 : (pname == GL_COLOR_INDEXES ? 3 : 4);
    for (int i = 0; i < count; ++i) params[i] = static_cast<GLint>(staging[i]);
}

void glTexEnvf(GLenum target, GLenum pname, GLfloat param) {
    sfpewClientStateBarrier();
    LIST_RECORD(glTexEnvf, {}, target, pname, param)

    auto& gs = g_glstate;
    auto& env = current_texture_env(gs);
    if (target == GL_TEXTURE_FILTER_CONTROL && pname == GL_TEXTURE_LOD_BIAS) {
        env.lod_bias = param;
        return;
    }
    if (target == GL_POINT_SPRITE) {
        tex_env_set_int(gs, target, pname, (GLint)param);
        return;
    }
    if (target != GL_TEXTURE_ENV) return;

    switch (pname) {
    case GL_RGB_SCALE:
        env.rgb_scale = param;
        break;
    case GL_ALPHA_SCALE:
        env.alpha_scale = param;
        break;
    default:
        tex_env_set_int(gs, target, pname, (GLint)param);
        break;
    }
}

void glTexEnvi(GLenum target, GLenum pname, GLint param) {
    sfpewClientStateBarrier();
    LIST_RECORD(glTexEnvi, {}, target, pname, param)

    tex_env_set_int(g_glstate, target, pname, param);
}

void glTexEnvfv(GLenum target, GLenum pname, const GLfloat* params) {
    sfpewClientStateBarrier();
    if (params == nullptr) return;
    LIST_RECORD(glTexEnvfv, {{2, tex_env_param_count(pname) * sizeof(GLfloat)}}, target, pname, params)

    auto& gs = g_glstate;
    if (target == GL_TEXTURE_ENV && pname == GL_TEXTURE_ENV_COLOR) {
        current_texture_env(gs).color = glm::make_vec4(params);
        return;
    }
    const GLfloat param = params[0];
    auto& env = current_texture_env(gs);
    if (target == GL_TEXTURE_FILTER_CONTROL && pname == GL_TEXTURE_LOD_BIAS) {
        env.lod_bias = param;
        return;
    }
    if (target == GL_POINT_SPRITE) {
        tex_env_set_int(gs, target, pname, (GLint)param);
        return;
    }
    if (target != GL_TEXTURE_ENV) return;
    switch (pname) {
    case GL_RGB_SCALE:
        env.rgb_scale = param;
        break;
    case GL_ALPHA_SCALE:
        env.alpha_scale = param;
        break;
    default:
        tex_env_set_int(gs, target, pname, (GLint)param);
        break;
    }
}

void glTexEnviv(GLenum target, GLenum pname, const GLint* params) {
    sfpewClientStateBarrier();
    if (params == nullptr) return;
    LIST_RECORD(glTexEnviv, {{2, tex_env_param_count(pname) * sizeof(GLint)}}, target, pname, params)

    auto& gs = g_glstate;
    if (target == GL_TEXTURE_ENV && pname == GL_TEXTURE_ENV_COLOR) {
        GLfloat converted[4];
        for (int i = 0; i < 4; ++i) converted[i] = sfpewNormalizeColorComponent(params[i]);
        current_texture_env(gs).color = glm::make_vec4(converted);
        return;
    }
    tex_env_set_int(gs, target, pname, params[0]);
}

void glGetTexEnvfv(GLenum target, GLenum pname, GLfloat* params) {
    if (!params) return;
    auto& gs = g_glstate;
    const int unit = std::clamp(static_cast<int>(sfpewLogicalActiveTexture() - GL_TEXTURE0), 0, MAX_TEX - 1);
    // defects-plan-2.md 2.2.
    if (target == GL_POINT_SPRITE && pname == GL_COORD_REPLACE) {
        params[0] = gs.fpe_state.fpe_bools.point_sprite_coord_replace[unit] ? 1.0f : 0.0f;
        return;
    }
    if (target != GL_TEXTURE_ENV) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    const auto& env = gs.fpe_uniform.texture_env[unit];
    switch (pname) {
    case GL_TEXTURE_ENV_MODE:
        params[0] = static_cast<GLfloat>(env.mode);
        break;
    case GL_TEXTURE_ENV_COLOR:
        memcpy(params, glm::value_ptr(env.color), 4 * sizeof(GLfloat));
        break;
    case GL_COMBINE_RGB:
        params[0] = static_cast<GLfloat>(env.combine_rgb);
        break;
    case GL_COMBINE_ALPHA:
        params[0] = static_cast<GLfloat>(env.combine_alpha);
        break;
    case GL_SRC0_RGB:
    case GL_SRC1_RGB:
    case GL_SRC2_RGB:
        params[0] = static_cast<GLfloat>(env.source_rgb[pname - GL_SRC0_RGB]);
        break;
    case GL_SRC0_ALPHA:
    case GL_SRC1_ALPHA:
    case GL_SRC2_ALPHA:
        params[0] = static_cast<GLfloat>(env.source_alpha[pname - GL_SRC0_ALPHA]);
        break;
    case GL_OPERAND0_RGB:
    case GL_OPERAND1_RGB:
    case GL_OPERAND2_RGB:
        params[0] = static_cast<GLfloat>(env.operand_rgb[pname - GL_OPERAND0_RGB]);
        break;
    case GL_OPERAND0_ALPHA:
    case GL_OPERAND1_ALPHA:
    case GL_OPERAND2_ALPHA:
        params[0] = static_cast<GLfloat>(env.operand_alpha[pname - GL_OPERAND0_ALPHA]);
        break;
    case GL_RGB_SCALE:
        params[0] = env.rgb_scale;
        break;
    case GL_ALPHA_SCALE:
        params[0] = env.alpha_scale;
        break;
    default:
        gs.set_error(GL_INVALID_ENUM);
        break;
    }
}

void glGetTexEnviv(GLenum target, GLenum pname, GLint* params) {
    if (!params) return;
    GLfloat staging[4] = {};
    glGetTexEnvfv(target, pname, staging);
    const int count = pname == GL_TEXTURE_ENV_COLOR ? 4 : 1;
    for (int i = 0; i < count; ++i) params[i] = static_cast<GLint>(staging[i]);
}

// The original implementation only defined a few GLfloat scalar immediate-mode
// entry points even though the public GL header declared the complete family.
// Keep one float-backed draw state, but expose the desktop aliases applications
// (notably LWJGL's legacy bindings) resolve independently.

#define DEFINE_VERTEX2(SUFFIX, TYPE)                                                                                  \
    void glVertex2##SUFFIX(TYPE x, TYPE y) {                                                                          \
        LIST_RECORD(glVertex2##SUFFIX, {}, x, y)                                                                      \
        mglVertex<TYPE, 2>({x, y});                                                                                   \
    }

#define DEFINE_VERTEX3(SUFFIX, TYPE)                                                                                  \
    void glVertex3##SUFFIX(TYPE x, TYPE y, TYPE z) {                                                                  \
        LIST_RECORD(glVertex3##SUFFIX, {}, x, y, z)                                                                   \
        mglVertex<TYPE, 3>({x, y, z});                                                                                \
    }

#define DEFINE_VERTEX4(SUFFIX, TYPE)                                                                                  \
    void glVertex4##SUFFIX(TYPE x, TYPE y, TYPE z, TYPE w) {                                                          \
        LIST_RECORD(glVertex4##SUFFIX, {}, x, y, z, w)                                                                \
        mglVertex<TYPE, 4>({x, y, z, w});                                                                             \
    }

#define DEFINE_VERTEX_VECTOR(N, SUFFIX, TYPE)                                                                         \
    void glVertex##N##SUFFIX##v(const TYPE* v) {                                                                      \
        LIST_RECORD(glVertex##N##SUFFIX##v, {{0, sizeof(TYPE) * N}}, v)                                                \
        if (!v) return;                                                                                                \
        if constexpr (N == 2)                                                                                         \
            mglVertex<TYPE, 2>({v[0], v[1]});                                                                         \
        else if constexpr (N == 3)                                                                                    \
            mglVertex<TYPE, 3>({v[0], v[1], v[2]});                                                                   \
        else                                                                                                           \
            mglVertex<TYPE, 4>({v[0], v[1], v[2], v[3]});                                                             \
    }

DEFINE_VERTEX2(d, GLdouble)
DEFINE_VERTEX2(f, GLfloat)
DEFINE_VERTEX2(i, GLint)
DEFINE_VERTEX2(s, GLshort)
DEFINE_VERTEX3(d, GLdouble)
DEFINE_VERTEX3(i, GLint)
DEFINE_VERTEX3(s, GLshort)
DEFINE_VERTEX4(d, GLdouble)
DEFINE_VERTEX4(i, GLint)
DEFINE_VERTEX4(s, GLshort)

DEFINE_VERTEX_VECTOR(2, d, GLdouble)
DEFINE_VERTEX_VECTOR(2, f, GLfloat)
DEFINE_VERTEX_VECTOR(2, i, GLint)
DEFINE_VERTEX_VECTOR(2, s, GLshort)
DEFINE_VERTEX_VECTOR(3, d, GLdouble)
DEFINE_VERTEX_VECTOR(3, f, GLfloat)
DEFINE_VERTEX_VECTOR(3, i, GLint)
DEFINE_VERTEX_VECTOR(3, s, GLshort)
DEFINE_VERTEX_VECTOR(4, d, GLdouble)
DEFINE_VERTEX_VECTOR(4, f, GLfloat)
DEFINE_VERTEX_VECTOR(4, i, GLint)
DEFINE_VERTEX_VECTOR(4, s, GLshort)

#undef DEFINE_VERTEX_VECTOR
#undef DEFINE_VERTEX4
#undef DEFINE_VERTEX3
#undef DEFINE_VERTEX2

template <typename T>
void set_normal(T x, T y, T z) {
    mglNormal<GLfloat, 3>({sfpewNormalizeColorComponent(x), sfpewNormalizeColorComponent(y),
                           sfpewNormalizeColorComponent(z)});
}

#define DEFINE_NORMAL_SCALAR(SUFFIX, TYPE)                                                                            \
    void glNormal3##SUFFIX(TYPE x, TYPE y, TYPE z) {                                                                  \
        LIST_RECORD(glNormal3##SUFFIX, {}, x, y, z)                                                                   \
        set_normal(x, y, z);                                                                                          \
    }

#define DEFINE_NORMAL_VECTOR(SUFFIX, TYPE)                                                                            \
    void glNormal3##SUFFIX##v(const TYPE* v) {                                                                        \
        LIST_RECORD(glNormal3##SUFFIX##v, {{0, sizeof(TYPE) * 3}}, v)                                                  \
        if (!v) return;                                                                                                \
        set_normal(v[0], v[1], v[2]);                                                                                 \
    }

DEFINE_NORMAL_SCALAR(b, GLbyte)
DEFINE_NORMAL_SCALAR(d, GLdouble)
DEFINE_NORMAL_SCALAR(i, GLint)
DEFINE_NORMAL_SCALAR(s, GLshort)
DEFINE_NORMAL_VECTOR(b, GLbyte)
DEFINE_NORMAL_VECTOR(d, GLdouble)
DEFINE_NORMAL_VECTOR(f, GLfloat)
DEFINE_NORMAL_VECTOR(i, GLint)
DEFINE_NORMAL_VECTOR(s, GLshort)

#undef DEFINE_NORMAL_VECTOR
#undef DEFINE_NORMAL_SCALAR

template <typename T>
void set_color3(T red, T green, T blue) {
    mglColor<GLfloat, 4>(
        {sfpewNormalizeColorComponent(red), sfpewNormalizeColorComponent(green),
         sfpewNormalizeColorComponent(blue), 1.0f});
}

template <typename T>
void set_color4(T red, T green, T blue, T alpha) {
    mglColor<GLfloat, 4>({sfpewNormalizeColorComponent(red), sfpewNormalizeColorComponent(green),
                          sfpewNormalizeColorComponent(blue), sfpewNormalizeColorComponent(alpha)});
}

#define DEFINE_COLOR3_SCALAR(SUFFIX, TYPE)                                                                            \
    void glColor3##SUFFIX(TYPE red, TYPE green, TYPE blue) {                                                          \
        LIST_RECORD(glColor3##SUFFIX, {}, red, green, blue)                                                            \
        set_color3(red, green, blue);                                                                                  \
    }

#define DEFINE_COLOR4_SCALAR(SUFFIX, TYPE)                                                                            \
    void glColor4##SUFFIX(TYPE red, TYPE green, TYPE blue, TYPE alpha) {                                               \
        LIST_RECORD(glColor4##SUFFIX, {}, red, green, blue, alpha)                                                     \
        set_color4(red, green, blue, alpha);                                                                           \
    }

#define DEFINE_COLOR3_VECTOR(SUFFIX, TYPE)                                                                            \
    void glColor3##SUFFIX##v(const TYPE* v) {                                                                         \
        LIST_RECORD(glColor3##SUFFIX##v, {{0, sizeof(TYPE) * 3}}, v)                                                   \
        if (!v) return;                                                                                                \
        set_color3(v[0], v[1], v[2]);                                                                                 \
    }

#define DEFINE_COLOR4_VECTOR(SUFFIX, TYPE)                                                                            \
    void glColor4##SUFFIX##v(const TYPE* v) {                                                                         \
        LIST_RECORD(glColor4##SUFFIX##v, {{0, sizeof(TYPE) * 4}}, v)                                                   \
        if (!v) return;                                                                                                \
        set_color4(v[0], v[1], v[2], v[3]);                                                                           \
    }

DEFINE_COLOR3_SCALAR(b, GLbyte)
DEFINE_COLOR3_SCALAR(d, GLdouble)
DEFINE_COLOR3_SCALAR(i, GLint)
DEFINE_COLOR3_SCALAR(s, GLshort)
DEFINE_COLOR3_SCALAR(ub, GLubyte)
DEFINE_COLOR3_SCALAR(ui, GLuint)
DEFINE_COLOR3_SCALAR(us, GLushort)
DEFINE_COLOR4_SCALAR(b, GLbyte)
DEFINE_COLOR4_SCALAR(d, GLdouble)
DEFINE_COLOR4_SCALAR(i, GLint)
DEFINE_COLOR4_SCALAR(s, GLshort)
DEFINE_COLOR4_SCALAR(ub, GLubyte)
DEFINE_COLOR4_SCALAR(ui, GLuint)
DEFINE_COLOR4_SCALAR(us, GLushort)

DEFINE_COLOR3_VECTOR(b, GLbyte)
DEFINE_COLOR3_VECTOR(d, GLdouble)
DEFINE_COLOR3_VECTOR(f, GLfloat)
DEFINE_COLOR3_VECTOR(i, GLint)
DEFINE_COLOR3_VECTOR(s, GLshort)
DEFINE_COLOR3_VECTOR(ub, GLubyte)
DEFINE_COLOR3_VECTOR(ui, GLuint)
DEFINE_COLOR3_VECTOR(us, GLushort)
DEFINE_COLOR4_VECTOR(b, GLbyte)
DEFINE_COLOR4_VECTOR(d, GLdouble)
DEFINE_COLOR4_VECTOR(f, GLfloat)
DEFINE_COLOR4_VECTOR(i, GLint)
DEFINE_COLOR4_VECTOR(s, GLshort)
DEFINE_COLOR4_VECTOR(ub, GLubyte)
DEFINE_COLOR4_VECTOR(ui, GLuint)
DEFINE_COLOR4_VECTOR(us, GLushort)

#undef DEFINE_COLOR4_VECTOR
#undef DEFINE_COLOR3_VECTOR
#undef DEFINE_COLOR4_SCALAR
#undef DEFINE_COLOR3_SCALAR

// glEdgeFlag* (GL 1.0 spec 2.6.3): legal inside Begin/End, part of the
// current-vertex-state family like color/normal. Per-edge suppression in
// GL_LINE polygon mode is consumed downstream by sfpewBuildWireframeIndices
// (fpe.cpp), fed from the collected values here; see gtest_edgeflag.cc.
void glEdgeFlag(GLboolean flag) {
    LIST_RECORD(glEdgeFlag, {}, flag)
    g_glstate.fpe_state.fpe_draw.current_data.edge_flag = flag;
}

void glEdgeFlagv(const GLboolean* flag) {
    LIST_RECORD(glEdgeFlagv, {{0, sizeof(GLboolean)}}, flag)
    if (!flag) return;
    g_glstate.fpe_state.fpe_draw.current_data.edge_flag = *flag;
}

// Complete the glTexCoord/glMultiTexCoord families the same way as the
// Vertex/Normal/Color families above: one float-backed draw state behind
// desktop aliases. Per the GL spec texture coordinates are converted
// directly (NOT normalized) for integer variants, so the raw cast inside
// mglTexCoord is the correct conversion.

#define DEFINE_TEXCOORD(N, SUFFIX, TYPE, PARAMS, ARGS)                                                                 \
    void glTexCoord##N##SUFFIX PARAMS {                                                                                \
        LIST_RECORD(glTexCoord##N##SUFFIX, {}, ARGS_LIST ARGS)                                                         \
        mglTexCoord<TYPE, N>({ARGS_LIST ARGS}, 0);                                                                     \
    }

#define ARGS_LIST(...) __VA_ARGS__

#define DEFINE_TEXCOORD_ALL(SUFFIX, TYPE)                                                                              \
    DEFINE_TEXCOORD(1, SUFFIX, TYPE, (TYPE s), (s))                                                                    \
    DEFINE_TEXCOORD(2, SUFFIX, TYPE, (TYPE s, TYPE t), (s, t))                                                         \
    DEFINE_TEXCOORD(3, SUFFIX, TYPE, (TYPE s, TYPE t, TYPE r), (s, t, r))                                              \
    DEFINE_TEXCOORD(4, SUFFIX, TYPE, (TYPE s, TYPE t, TYPE r, TYPE q), (s, t, r, q))

DEFINE_TEXCOORD_ALL(d, GLdouble)
DEFINE_TEXCOORD_ALL(i, GLint)
DEFINE_TEXCOORD_ALL(s, GLshort)
DEFINE_TEXCOORD(1, f, GLfloat, (GLfloat s), (s))
DEFINE_TEXCOORD(3, f, GLfloat, (GLfloat s, GLfloat t, GLfloat r), (s, t, r))
// 2f/4f live in drawing1x.cpp since the original implementation.

#define DEFINE_TEXCOORD_VECTOR(N, SUFFIX, TYPE)                                                                        \
    void glTexCoord##N##SUFFIX##v(const TYPE* v) {                                                                     \
        if (!v) return;                                                                                                \
        LIST_RECORD(glTexCoord##N##SUFFIX##v, {{0, sizeof(TYPE) * N}}, v)                                              \
        if constexpr (N == 1)                                                                                          \
            mglTexCoord<TYPE, 1>({v[0]}, 0);                                                                           \
        else if constexpr (N == 2)                                                                                     \
            mglTexCoord<TYPE, 2>({v[0], v[1]}, 0);                                                                     \
        else if constexpr (N == 3)                                                                                     \
            mglTexCoord<TYPE, 3>({v[0], v[1], v[2]}, 0);                                                               \
        else                                                                                                           \
            mglTexCoord<TYPE, 4>({v[0], v[1], v[2], v[3]}, 0);                                                         \
    }

#define DEFINE_TEXCOORD_VECTOR_ALL(SUFFIX, TYPE)                                                                       \
    DEFINE_TEXCOORD_VECTOR(1, SUFFIX, TYPE)                                                                            \
    DEFINE_TEXCOORD_VECTOR(2, SUFFIX, TYPE)                                                                            \
    DEFINE_TEXCOORD_VECTOR(3, SUFFIX, TYPE)                                                                            \
    DEFINE_TEXCOORD_VECTOR(4, SUFFIX, TYPE)

DEFINE_TEXCOORD_VECTOR_ALL(d, GLdouble)
DEFINE_TEXCOORD_VECTOR_ALL(f, GLfloat)
DEFINE_TEXCOORD_VECTOR_ALL(i, GLint)
DEFINE_TEXCOORD_VECTOR_ALL(s, GLshort)

// MultiTexCoord: validate the unit before recording (invalid enums are not
// compiled into display lists) and before indexing texcoord[MAX_TEX].
#define DEFINE_MULTITEXCOORD(N, SUFFIX, TYPE, PARAMS, ARGS)                                                            \
    void glMultiTexCoord##N##SUFFIX PARAMS {                                                                           \
        if (target < GL_TEXTURE0 || target - GL_TEXTURE0 >= MAX_TEX) {                                                 \
            g_glstate.set_error(GL_INVALID_ENUM);                                                                      \
            return;                                                                                                    \
        }                                                                                                              \
        LIST_RECORD(glMultiTexCoord##N##SUFFIX, {}, target, ARGS_LIST ARGS)                                            \
        mglTexCoord<TYPE, N>({ARGS_LIST ARGS}, (GLint)(target - GL_TEXTURE0));                                         \
    }

#define DEFINE_MULTITEXCOORD_ALL(SUFFIX, TYPE)                                                                         \
    DEFINE_MULTITEXCOORD(1, SUFFIX, TYPE, (GLenum target, TYPE s), (s))                                                \
    DEFINE_MULTITEXCOORD(2, SUFFIX, TYPE, (GLenum target, TYPE s, TYPE t), (s, t))                                     \
    DEFINE_MULTITEXCOORD(3, SUFFIX, TYPE, (GLenum target, TYPE s, TYPE t, TYPE r), (s, t, r))                          \
    DEFINE_MULTITEXCOORD(4, SUFFIX, TYPE, (GLenum target, TYPE s, TYPE t, TYPE r, TYPE q), (s, t, r, q))

DEFINE_MULTITEXCOORD_ALL(d, GLdouble)
DEFINE_MULTITEXCOORD_ALL(i, GLint)
DEFINE_MULTITEXCOORD_ALL(s, GLshort)
DEFINE_MULTITEXCOORD(1, f, GLfloat, (GLenum target, GLfloat s), (s))
DEFINE_MULTITEXCOORD(3, f, GLfloat, (GLenum target, GLfloat s, GLfloat t, GLfloat r), (s, t, r))
// 2f/4f live in drawing1x.cpp since the original implementation.

#define DEFINE_MULTITEXCOORD_VECTOR(N, SUFFIX, TYPE)                                                                   \
    void glMultiTexCoord##N##SUFFIX##v(GLenum target, const TYPE* v) {                                                 \
        if (target < GL_TEXTURE0 || target - GL_TEXTURE0 >= MAX_TEX) {                                                 \
            g_glstate.set_error(GL_INVALID_ENUM);                                                                      \
            return;                                                                                                    \
        }                                                                                                              \
        if (!v) return;                                                                                                \
        LIST_RECORD(glMultiTexCoord##N##SUFFIX##v, {{1, sizeof(TYPE) * N}}, target, v)                                 \
        const GLint unit = (GLint)(target - GL_TEXTURE0);                                                              \
        if constexpr (N == 1)                                                                                          \
            mglTexCoord<TYPE, 1>({v[0]}, unit);                                                                        \
        else if constexpr (N == 2)                                                                                     \
            mglTexCoord<TYPE, 2>({v[0], v[1]}, unit);                                                                  \
        else if constexpr (N == 3)                                                                                     \
            mglTexCoord<TYPE, 3>({v[0], v[1], v[2]}, unit);                                                            \
        else                                                                                                           \
            mglTexCoord<TYPE, 4>({v[0], v[1], v[2], v[3]}, unit);                                                      \
    }

#define DEFINE_MULTITEXCOORD_VECTOR_ALL(SUFFIX, TYPE)                                                                  \
    DEFINE_MULTITEXCOORD_VECTOR(1, SUFFIX, TYPE)                                                                       \
    DEFINE_MULTITEXCOORD_VECTOR(2, SUFFIX, TYPE)                                                                       \
    DEFINE_MULTITEXCOORD_VECTOR(3, SUFFIX, TYPE)                                                                       \
    DEFINE_MULTITEXCOORD_VECTOR(4, SUFFIX, TYPE)

DEFINE_MULTITEXCOORD_VECTOR_ALL(d, GLdouble)
DEFINE_MULTITEXCOORD_VECTOR_ALL(f, GLfloat)
DEFINE_MULTITEXCOORD_VECTOR_ALL(i, GLint)
DEFINE_MULTITEXCOORD_VECTOR_ALL(s, GLshort)

namespace {

int texgen_coord_index(GLenum coord) {
    switch (coord) {
    case GL_S: return 0;
    case GL_T: return 1;
    case GL_R: return 2;
    case GL_Q: return 3;
    default: return -1;
    }
}

bool texgen_mode_valid(GLenum coord, GLenum mode) {
    switch (mode) {
    case GL_OBJECT_LINEAR:
    case GL_EYE_LINEAR:
        return true;
    case GL_SPHERE_MAP:
        return coord == GL_S || coord == GL_T; // spec: S/T only
    case GL_NORMAL_MAP:
    case GL_REFLECTION_MAP:
        return coord != GL_Q;
    default:
        return false;
    }
}

} // namespace

void glTexGeni(GLenum coord, GLenum pname, GLint param) {
    sfpewClientStateBarrier();
    const int c = texgen_coord_index(coord);
    auto& gs = g_glstate;
    if (c < 0 || pname != GL_TEXTURE_GEN_MODE) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (!texgen_mode_valid(coord, (GLenum)param)) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    LIST_RECORD(glTexGeni, {}, coord, pname, param)
    gs.fpe_state.texture_gen_mode[active_texture_index()][c] = (GLenum)param;
}

void glTexGenf(GLenum coord, GLenum pname, GLfloat param) { glTexGeni(coord, pname, (GLint)param); }
void glTexGend(GLenum coord, GLenum pname, GLdouble param) { glTexGeni(coord, pname, (GLint)param); }

void glTexGenfv(GLenum coord, GLenum pname, const GLfloat* params) {
    sfpewClientStateBarrier();
    const int c = texgen_coord_index(coord);
    auto& gs = g_glstate;
    if (c < 0) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (params == nullptr) return;
    if (pname == GL_TEXTURE_GEN_MODE) {
        SELF_CALL(glTexGeni, coord, pname, (GLint)params[0])
        return;
    }
    LIST_RECORD(glTexGenfv, {{2, sizeof(GLfloat) * 4}}, coord, pname, params)
    const int unit = active_texture_index();
    if (pname == GL_OBJECT_PLANE) {
        gs.fpe_uniform.texgen_object_plane[unit][c] = glm::make_vec4(params);
    } else if (pname == GL_EYE_PLANE) {
        // Spec: eye planes are transformed by the inverse of the current
        // model-view at call time.
        const auto& mv = gs.fpe_uniform.transformation.matrices[matrix_idx(GL_MODELVIEW)];
        gs.fpe_uniform.texgen_eye_plane[unit][c] =
            glm::transpose(glm::inverse(mv)) * glm::make_vec4(params);
    } else {
        gs.set_error(GL_INVALID_ENUM);
    }
}

void glTexGeniv(GLenum coord, GLenum pname, const GLint* params) {
    if (params == nullptr) return;
    GLfloat converted[4] = {(GLfloat)params[0], 0, 0, 0};
    if (pname != GL_TEXTURE_GEN_MODE)
        for (int i = 1; i < 4; ++i) converted[i] = (GLfloat)params[i];
    SELF_CALL(glTexGenfv, coord, pname, converted)
}

void glTexGendv(GLenum coord, GLenum pname, const GLdouble* params) {
    if (params == nullptr) return;
    GLfloat converted[4] = {(GLfloat)params[0], 0, 0, 0};
    if (pname != GL_TEXTURE_GEN_MODE)
        for (int i = 1; i < 4; ++i) converted[i] = (GLfloat)params[i];
    SELF_CALL(glTexGenfv, coord, pname, converted)
}

namespace {
int texgenCoordIndex(GLenum coord) {
    switch (coord) {
    case GL_S: return 0;
    case GL_T: return 1;
    case GL_R: return 2;
    case GL_Q: return 3;
    default: return -1;
    }
}
} // namespace

void glGetTexGenfv(GLenum coord, GLenum pname, GLfloat* params) {
    if (!params) return;
    auto& gs = g_glstate;
    const int c = texgenCoordIndex(coord);
    if (c < 0) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    const int unit = std::clamp(static_cast<int>(sfpewLogicalActiveTexture() - GL_TEXTURE0), 0, MAX_TEX - 1);
    switch (pname) {
    case GL_TEXTURE_GEN_MODE:
        params[0] = static_cast<GLfloat>(gs.fpe_state.texture_gen_mode[unit][c]);
        break;
    case GL_OBJECT_PLANE:
        memcpy(params, glm::value_ptr(gs.fpe_uniform.texgen_object_plane[unit][c]), 4 * sizeof(GLfloat));
        break;
    case GL_EYE_PLANE:
        memcpy(params, glm::value_ptr(gs.fpe_uniform.texgen_eye_plane[unit][c]), 4 * sizeof(GLfloat));
        break;
    default:
        gs.set_error(GL_INVALID_ENUM);
        break;
    }
}

void glGetTexGeniv(GLenum coord, GLenum pname, GLint* params) {
    if (!params) return;
    GLfloat staging[4] = {};
    glGetTexGenfv(coord, pname, staging);
    const int count = pname == GL_TEXTURE_GEN_MODE ? 1 : 4;
    for (int i = 0; i < count; ++i) params[i] = static_cast<GLint>(staging[i]);
}

void glGetTexGendv(GLenum coord, GLenum pname, GLdouble* params) {
    if (!params) return;
    GLfloat staging[4] = {};
    glGetTexGenfv(coord, pname, staging);
    const int count = pname == GL_TEXTURE_GEN_MODE ? 1 : 4;
    for (int i = 0; i < count; ++i) params[i] = static_cast<GLdouble>(staging[i]);
}

void glPixelZoom(GLfloat xfactor, GLfloat yfactor) {
    sfpewClientStateBarrier();
    LIST_RECORD(glPixelZoom, {}, xfactor, yfactor)
    auto& gs = g_glstate;
    gs.fpe_uniform.pixel_zoom_x = xfactor;
    gs.fpe_uniform.pixel_zoom_y = yfactor;
}

void glPixelTransferf(GLenum pname, GLfloat param) {
    sfpewClientStateBarrier();
    LIST_RECORD(glPixelTransferf, {}, pname, param)
    auto& gs = g_glstate;
    auto& un = gs.fpe_uniform;
    switch (pname) {
    case GL_RED_SCALE: un.pixel_scale[0] = param; break;
    case GL_GREEN_SCALE: un.pixel_scale[1] = param; break;
    case GL_BLUE_SCALE: un.pixel_scale[2] = param; break;
    case GL_ALPHA_SCALE: un.pixel_scale[3] = param; break;
    case GL_DEPTH_SCALE: un.pixel_scale[4] = param; break;
    case GL_RED_BIAS: un.pixel_bias[0] = param; break;
    case GL_GREEN_BIAS: un.pixel_bias[1] = param; break;
    case GL_BLUE_BIAS: un.pixel_bias[2] = param; break;
    case GL_ALPHA_BIAS: un.pixel_bias[3] = param; break;
    case GL_DEPTH_BIAS: un.pixel_bias[4] = param; break;
    case GL_MAP_COLOR: un.pixel_map_color = param != 0.0f; break;
    case GL_MAP_STENCIL: un.pixel_map_stencil = param != 0.0f; break;
    case GL_POST_CONVOLUTION_RED_SCALE:
    case GL_POST_CONVOLUTION_GREEN_SCALE:
    case GL_POST_CONVOLUTION_BLUE_SCALE:
    case GL_POST_CONVOLUTION_ALPHA_SCALE:
        un.post_convolution_scale[pname - GL_POST_CONVOLUTION_RED_SCALE] = param;
        break;
    case GL_POST_CONVOLUTION_RED_BIAS:
    case GL_POST_CONVOLUTION_GREEN_BIAS:
    case GL_POST_CONVOLUTION_BLUE_BIAS:
    case GL_POST_CONVOLUTION_ALPHA_BIAS:
        un.post_convolution_bias[pname - GL_POST_CONVOLUTION_RED_BIAS] = param;
        break;
    case GL_POST_COLOR_MATRIX_RED_SCALE:
    case GL_POST_COLOR_MATRIX_GREEN_SCALE:
    case GL_POST_COLOR_MATRIX_BLUE_SCALE:
    case GL_POST_COLOR_MATRIX_ALPHA_SCALE:
        un.post_color_matrix_scale[pname - GL_POST_COLOR_MATRIX_RED_SCALE] = param;
        break;
    case GL_POST_COLOR_MATRIX_RED_BIAS:
    case GL_POST_COLOR_MATRIX_GREEN_BIAS:
    case GL_POST_COLOR_MATRIX_BLUE_BIAS:
    case GL_POST_COLOR_MATRIX_ALPHA_BIAS:
        un.post_color_matrix_bias[pname - GL_POST_COLOR_MATRIX_RED_BIAS] = param;
        break;
    // Index shift/offset belong to color-index mode, which this
    // implementation does not provide (plans/10, 10.5).
    case GL_INDEX_SHIFT:
    case GL_INDEX_OFFSET:
        break;
    default:
        gs.set_error(GL_INVALID_ENUM);
        break;
    }
}

void glPixelTransferi(GLenum pname, GLint param) { glPixelTransferf(pname, (GLfloat)param); }

void glPolygonStipple(const GLubyte* mask) {
    sfpewClientStateBarrier();
    if (mask == nullptr) return;
    LIST_RECORD(glPolygonStipple, {{0, 128}}, mask)
    auto& gs = g_glstate;
    auto& un = gs.fpe_uniform;
    std::memcpy(un.polygon_stipple, mask, 128);
    // Repack rows for the shader: with default unpack state (LSB_FIRST
    // false) window x0 sits in each byte's MSB; the shader tests bit
    // (x & 31) LSB-first.
    const bool lsb_first = gs.pixel_store_unpack_lsb_first;
    for (int row = 0; row < 32; ++row) {
        GLuint packed = 0;
        for (int x = 0; x < 32; ++x) {
            const GLubyte byte = mask[row * 4 + x / 8];
            const int bit = lsb_first ? (x % 8) : (7 - x % 8);
            if ((byte >> bit) & 1u) packed |= 1u << x;
        }
        un.polygon_stipple_rows[row] = packed;
    }
}

void glGetPolygonStipple(GLubyte* mask) {
    if (mask == nullptr) return;
    auto& gs = g_glstate;
    std::memcpy(mask, gs.fpe_uniform.polygon_stipple, 128);
}

void glLineStipple(GLint factor, GLushort pattern) {
    sfpewClientStateBarrier();
    if (factor < 1) factor = 1;
    if (factor > 256) factor = 256;
    LIST_RECORD(glLineStipple, {}, factor, pattern)
    auto& gs = g_glstate;
    gs.fpe_uniform.line_stipple_factor = factor;
    gs.fpe_uniform.line_stipple_pattern = pattern;
    // Consumed by sfpewDrawStippledLines (fpe/linestipple.cpp) for the
    // immediate-mode GL_LINES/GL_LINE_STRIP/GL_LINE_LOOP path when
    // GL_LINE_STIPPLE is enabled; see that file's header for scope.
}

namespace {

// Shared glRasterPos backend: run the full fixed-function transform and
// store the resulting window coordinates (plans/08, 8.1).
void set_raster_pos(GLfloat x, GLfloat y, GLfloat z, GLfloat w) {
    sfpewEntryBarrier();
    auto& gs = g_glstate;
    auto& un = gs.fpe_uniform;
    const glm::vec4 clip = un.transformation.matrices[matrix_idx(GL_PROJECTION)] *
                           un.transformation.matrices[matrix_idx(GL_MODELVIEW)] * glm::vec4(x, y, z, w);
    auto& st = gs.fpe_uniform;
    if (clip.w <= 0.0f) {
        st.raster_position_valid = false;
        return;
    }
    const glm::vec3 ndc = glm::vec3(clip) / clip.w;
    st.raster_position_valid =
        ndc.x >= -1.0f && ndc.x <= 1.0f && ndc.y >= -1.0f && ndc.y <= 1.0f && ndc.z >= -1.0f && ndc.z <= 1.0f;

    GLint viewport[4] = {0, 0, 0, 0};
    if (g_glFuncs.glGetIntegerv != nullptr) g_glFuncs.glGetIntegerv(GL_VIEWPORT, viewport);
    st.raster_position = {viewport[0] + (ndc.x * 0.5f + 0.5f) * (GLfloat)viewport[2],
                          viewport[1] + (ndc.y * 0.5f + 0.5f) * (GLfloat)viewport[3],
                          ndc.z * 0.5f + 0.5f, clip.w};
    st.raster_color = gs.fpe_state.fpe_draw.current_data.color;
    st.raster_texcoord = gs.fpe_state.fpe_draw.current_data.texcoord[0];
}

void set_window_pos(GLfloat x, GLfloat y, GLfloat z) {
    sfpewEntryBarrier();
    auto& gs = g_glstate;
    auto& st = gs.fpe_uniform;
    st.raster_position = {x, y, z, 1.0f};
    st.raster_position_valid = true; // WindowPos never clips
    st.raster_color = gs.fpe_state.fpe_draw.current_data.color;
    st.raster_texcoord = gs.fpe_state.fpe_draw.current_data.texcoord[0];
}

} // namespace

#define DEFINE_RASTERPOS(N, SUFFIX, TYPE, PARAMS, X, Y, Z, W)                                                          \
    void glRasterPos##N##SUFFIX PARAMS {                                                                               \
        LIST_RECORD(glRasterPos##N##SUFFIX, {}, ARGS_LIST(X, Y, Z, W))                                                 \
        set_raster_pos((GLfloat)(X), (GLfloat)(Y), (GLfloat)(Z), (GLfloat)(W));                                        \
    }
#define DEFINE_RASTERPOS_FAMILY(SUFFIX, TYPE)                                                                          \
    void glRasterPos2##SUFFIX(TYPE x, TYPE y) { set_raster_pos((GLfloat)x, (GLfloat)y, 0.0f, 1.0f); }                  \
    void glRasterPos3##SUFFIX(TYPE x, TYPE y, TYPE z) { set_raster_pos((GLfloat)x, (GLfloat)y, (GLfloat)z, 1.0f); }    \
    void glRasterPos4##SUFFIX(TYPE x, TYPE y, TYPE z, TYPE w) {                                                        \
        set_raster_pos((GLfloat)x, (GLfloat)y, (GLfloat)z, (GLfloat)w);                                                \
    }                                                                                                                  \
    void glRasterPos2##SUFFIX##v(const TYPE* v) {                                                                      \
        if (v) set_raster_pos((GLfloat)v[0], (GLfloat)v[1], 0.0f, 1.0f);                                               \
    }                                                                                                                  \
    void glRasterPos3##SUFFIX##v(const TYPE* v) {                                                                      \
        if (v) set_raster_pos((GLfloat)v[0], (GLfloat)v[1], (GLfloat)v[2], 1.0f);                                      \
    }                                                                                                                  \
    void glRasterPos4##SUFFIX##v(const TYPE* v) {                                                                      \
        if (v) set_raster_pos((GLfloat)v[0], (GLfloat)v[1], (GLfloat)v[2], (GLfloat)v[3]);                             \
    }

DEFINE_RASTERPOS_FAMILY(d, GLdouble)
DEFINE_RASTERPOS_FAMILY(f, GLfloat)
DEFINE_RASTERPOS_FAMILY(i, GLint)
DEFINE_RASTERPOS_FAMILY(s, GLshort)

#define DEFINE_WINDOWPOS_FAMILY(SUFFIX, TYPE)                                                                          \
    void glWindowPos2##SUFFIX(TYPE x, TYPE y) { set_window_pos((GLfloat)x, (GLfloat)y, 0.0f); }                        \
    void glWindowPos3##SUFFIX(TYPE x, TYPE y, TYPE z) { set_window_pos((GLfloat)x, (GLfloat)y, (GLfloat)z); }          \
    void glWindowPos2##SUFFIX##v(const TYPE* v) {                                                                      \
        if (v) set_window_pos((GLfloat)v[0], (GLfloat)v[1], 0.0f);                                                     \
    }                                                                                                                  \
    void glWindowPos3##SUFFIX##v(const TYPE* v) {                                                                      \
        if (v) set_window_pos((GLfloat)v[0], (GLfloat)v[1], (GLfloat)v[2]);                                            \
    }

DEFINE_WINDOWPOS_FAMILY(d, GLdouble)
DEFINE_WINDOWPOS_FAMILY(f, GLfloat)
DEFINE_WINDOWPOS_FAMILY(i, GLint)
DEFINE_WINDOWPOS_FAMILY(s, GLshort)

void glPolygonMode(GLenum face, GLenum mode) {
    sfpewClientStateBarrier();
    auto& gs = g_glstate;
    if (mode != GL_FILL && mode != GL_LINE && mode != GL_POINT) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (face != GL_FRONT && face != GL_BACK && face != GL_FRONT_AND_BACK) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    LIST_RECORD(glPolygonMode, {}, face, mode)
    if (face == GL_FRONT || face == GL_FRONT_AND_BACK) gs.fpe_uniform.polygon_mode_front = mode;
    if (face == GL_BACK || face == GL_FRONT_AND_BACK) gs.fpe_uniform.polygon_mode_back = mode;
}

void glClipPlane(GLenum plane, const GLdouble* equation) {
    sfpewClientStateBarrier();
    auto& gs = g_glstate;
    if (plane < GL_CLIP_PLANE0 || plane >= GL_CLIP_PLANE0 + 6) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    if (equation == nullptr) return;
    LIST_RECORD(glClipPlane, {{1, sizeof(GLdouble) * 4}}, plane, equation)
    // Spec: the stored plane is the given equation transformed by the
    // inverse of the model-view matrix current at call time.
    const auto& mv = gs.fpe_uniform.transformation.matrices[matrix_idx(GL_MODELVIEW)];
    const glm::vec4 eye = glm::transpose(glm::inverse(mv)) *
                          glm::vec4((float)equation[0], (float)equation[1], (float)equation[2], (float)equation[3]);
    gs.fpe_uniform.clip_planes[plane - GL_CLIP_PLANE0] = glm::dvec4(eye);
}

void glGetClipPlane(GLenum plane, GLdouble* equation) {
    if (equation == nullptr) return;
    auto& gs = g_glstate;
    if (plane < GL_CLIP_PLANE0 || plane >= GL_CLIP_PLANE0 + 6) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    const auto& p = gs.fpe_uniform.clip_planes[plane - GL_CLIP_PLANE0];
    for (int i = 0; i < 4; ++i) equation[i] = p[i];
}

void glPointSize(GLfloat size) {
    sfpewClientStateBarrier();
    auto& gs = g_glstate;
    if (size <= 0.0f) {
        gs.set_error(GL_INVALID_VALUE);
        return;
    }
    LIST_RECORD(glPointSize, {}, size)
    gs.fpe_uniform.point_size = size;
}

void glPointParameterfv(GLenum pname, const GLfloat* params) {
    auto& gs = g_glstate;
    if (params == nullptr) return;
    const size_t count = pname == GL_POINT_DISTANCE_ATTENUATION ? 3u : 1u;
    LIST_RECORD(glPointParameterfv, {{1, count * sizeof(GLfloat)}}, pname, params)
    sfpewEntryBarrier();
    sfpewInitializePointSizeMax(gs);

    auto& uniform = gs.fpe_uniform;
    switch (pname) {
    case GL_POINT_SIZE_MIN:
        if (params[0] < 0.0f) {
            gs.set_error(GL_INVALID_VALUE);
            return;
        }
        uniform.point_size_min = params[0];
        break;
    case GL_POINT_SIZE_MAX:
        if (params[0] < 0.0f) {
            gs.set_error(GL_INVALID_VALUE);
            return;
        }
        uniform.point_size_max = params[0];
        uniform.point_size_max_initialized = true;
        break;
    case GL_POINT_FADE_THRESHOLD_SIZE:
        if (params[0] < 0.0f) {
            gs.set_error(GL_INVALID_VALUE);
            return;
        }
        // defects-plan-2.md 2.3: alpha fading below this threshold is real,
        // see vPointFadeAlpha in fpe_shadergen.cpp.
        uniform.point_fade_threshold_size = params[0];
        break;
    case GL_POINT_DISTANCE_ATTENUATION:
        uniform.point_distance_attenuation = {params[0], params[1], params[2]};
        gs.fpe_state.point_attenuation_active =
            params[0] != 1.0f || params[1] != 0.0f || params[2] != 0.0f;
        break;
    case GL_POINT_SPRITE_COORD_ORIGIN:
        if (params[0] != static_cast<GLfloat>(GL_LOWER_LEFT) &&
            params[0] != static_cast<GLfloat>(GL_UPPER_LEFT)) {
            gs.set_error(GL_INVALID_VALUE);
            return;
        }
        gs.fpe_state.point_sprite_coord_origin = static_cast<GLenum>(params[0]);
        break;
    default:
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
}

void glPointParameterf(GLenum pname, GLfloat param) {
    auto& gs = g_glstate;
    if (pname == GL_POINT_DISTANCE_ATTENUATION) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    LIST_RECORD(glPointParameterf, {}, pname, param)
    SELF_CALL(glPointParameterfv, pname, &param)
}

void glPointParameteriv(GLenum pname, const GLint* params) {
    if (params == nullptr) return;
    const size_t count = pname == GL_POINT_DISTANCE_ATTENUATION ? 3u : 1u;
    LIST_RECORD(glPointParameteriv, {{1, count * sizeof(GLint)}}, pname, params)
    GLfloat converted[3] = {static_cast<GLfloat>(params[0]), 0.0f, 0.0f};
    for (size_t i = 1; i < count; ++i) converted[i] = static_cast<GLfloat>(params[i]);
    SELF_CALL(glPointParameterfv, pname, converted)
}

void glPointParameteri(GLenum pname, GLint param) {
    auto& gs = g_glstate;
    if (pname == GL_POINT_DISTANCE_ATTENUATION) {
        gs.set_error(GL_INVALID_ENUM);
        return;
    }
    LIST_RECORD(glPointParameteri, {}, pname, param)
    const GLfloat converted = static_cast<GLfloat>(param);
    SELF_CALL(glPointParameterfv, pname, &converted)
}

// glRect: GL 2.1 defines it as the equivalent Begin/Vertex2/End sequence.
// Delegating to the public entry points keeps display-list recording and
// glyph batching semantics identical to the expanded form.
#define DEFINE_RECT(SUFFIX, TYPE)                                                                                      \
    void glRect##SUFFIX(TYPE x1, TYPE y1, TYPE x2, TYPE y2) {                                                          \
        glBegin(GL_QUADS);                                                                                             \
        glVertex2##SUFFIX(x1, y1);                                                                                     \
        glVertex2##SUFFIX(x2, y1);                                                                                     \
        glVertex2##SUFFIX(x2, y2);                                                                                     \
        glVertex2##SUFFIX(x1, y2);                                                                                     \
        glEnd();                                                                                                       \
    }                                                                                                                  \
    void glRect##SUFFIX##v(const TYPE* v1, const TYPE* v2) {                                                           \
        if (!v1 || !v2) return;                                                                                        \
        glRect##SUFFIX(v1[0], v1[1], v2[0], v2[1]);                                                                    \
    }

DEFINE_RECT(d, GLdouble)
DEFINE_RECT(f, GLfloat)
DEFINE_RECT(i, GLint)
DEFINE_RECT(s, GLshort)
