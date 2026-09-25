// SimpleFPEWrapper - SimpleFPEWrapper/fpe/ffp_state_query.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "../init.h"
#include "fpe.hpp"
#include "list.h"
#include "vertexpointer_utils.h"
#include <glm/gtc/type_ptr.hpp>
#include <algorithm>
#include <cmath>

namespace {

// pnames the wrapper answers itself through glGetIntegerv (scalar integers).
// The fixed-function state is NOT here - fixedFunctionState() below answers
// that for all four getters at once; this is what is left: context and
// binding state that only makes sense as an integer.
bool isWrapperIntegerPname(GLenum pname) {
    switch (pname) {
    case GL_CONTEXT_PROFILE_MASK:
    case GL_CONTEXT_FLAGS:
    case GL_MAJOR_VERSION:
    case GL_MINOR_VERSION:
    case GL_NUM_EXTENSIONS:
    case GL_CURRENT_PROGRAM:
    case GL_ARRAY_BUFFER_BINDING:
    case GL_VERTEX_ARRAY_BINDING:
    case GL_ELEMENT_ARRAY_BUFFER_BINDING:
        return true;
    default:
        return false;
    }
}

// Component counts for common float-domain pnames, needed because
// glGetDoublev has no backend equivalent on GLES and must know how many
// values the backend wrote into the staging buffer.
int floatPnameComponentCount(GLenum pname) {
    switch (pname) {
    case GL_MODELVIEW_MATRIX:
    case GL_PROJECTION_MATRIX:
    case GL_TEXTURE_MATRIX:
    case GL_COLOR_MATRIX:
        return 16;
    case GL_VIEWPORT:
    case GL_SCISSOR_BOX:
    case GL_COLOR_CLEAR_VALUE:
    case GL_BLEND_COLOR:
    case GL_FOG_COLOR:
    case GL_LIGHT_MODEL_AMBIENT:
    case GL_CURRENT_COLOR:
        return 4;
    case GL_DEPTH_RANGE:
    case GL_ALIASED_LINE_WIDTH_RANGE:
    case GL_ALIASED_POINT_SIZE_RANGE:
    case GL_MAX_VIEWPORT_DIMS:
        return 2;
    default:
        return 1;
    }
}

} // namespace

namespace {

// ---- GL 2.1 fixed-function state --------------------------------------
// Around 250 state variables exist in GL 2.1 that neither an ES 3.0+ nor a
// GL 3.2+ core backend can answer, because they belong to the pipeline this
// wrapper emulates. Passing them through returned GL_INVALID_ENUM and left
// the caller's buffer untouched - silently, since a query that writes
// nothing looks exactly like one that wrote a zero. Sodium's fog occlusion
// found that the hard way: it reads GL_FOG_MODE, then the matching fog
// distance, and culls chunks on the CPU against the result, so an unanswered
// query became a cutoff of zero and the world stopped drawing.
//
// So they are answered here, in one table, which is also what makes the four
// glGet entry points and glIsEnabled agree by construction rather than by
// four switches staying in sync.
//
// Values leave as doubles because that is the widest state type, and the
// conversion runs one way from there (GL 2.1 section 6.1.2): booleans are
// 0 or 1, enums keep their numeric value, and colors and normals are the
// only values an integer query rescales instead of rounding - which is what
// `color` reports.
enum array_field_t { kArrayEnabled, kArraySize, kArrayType, kArrayStride, kArrayBuffer };

// GL_RED_BITS and its family: ES 3 still answers them, GL 3.1 core removed
// them, so neither backend can be asked directly without breaking on the
// other. The framebuffer knows, and both backends answer THAT - which is
// also the more correct answer, since the depth of what is being drawn into
// is a property of the bound framebuffer, not of the context.
bool framebufferBits(GLenum pname, GLdouble* out) {
    GLenum size_pname = 0;
    int attachment_kind = 0; // 0 color, 1 depth, 2 stencil
    switch (pname) {
    case GL_RED_BITS: size_pname = GL_FRAMEBUFFER_ATTACHMENT_RED_SIZE; break;
    case GL_GREEN_BITS: size_pname = GL_FRAMEBUFFER_ATTACHMENT_GREEN_SIZE; break;
    case GL_BLUE_BITS: size_pname = GL_FRAMEBUFFER_ATTACHMENT_BLUE_SIZE; break;
    case GL_ALPHA_BITS: size_pname = GL_FRAMEBUFFER_ATTACHMENT_ALPHA_SIZE; break;
    case GL_DEPTH_BITS:
        size_pname = GL_FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE;
        attachment_kind = 1;
        break;
    case GL_STENCIL_BITS:
        size_pname = GL_FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE;
        attachment_kind = 2;
        break;
    default:
        return false;
    }

    *out = 0;
    if (!sfpewEnsureBackend() || g_glFuncs.glGetFramebufferAttachmentParameteriv == nullptr ||
        g_glFuncs.glGetIntegerv == nullptr) {
        return true;
    }

    GLint framebuffer = 0;
    g_glFuncs.glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &framebuffer);
    GLenum attachment;
    if (framebuffer == 0) {
        // The default framebuffer names its color buffer differently on the
        // two backends; depth and stencil agree.
        int major = 0, minor = 0;
        const bool es_backend = sfpewDesktopGLVersion(&major, &minor);
        attachment = attachment_kind == 1   ? GL_DEPTH
                     : attachment_kind == 2 ? GL_STENCIL
                     : es_backend           ? GL_BACK
                                            : GL_BACK_LEFT;
    } else {
        attachment = attachment_kind == 1   ? GL_DEPTH_ATTACHMENT
                     : attachment_kind == 2 ? GL_STENCIL_ATTACHMENT
                                            : GL_COLOR_ATTACHMENT0;
    }

    // Asking a size of an attachment that holds nothing is an error, so ask
    // what is there first. Nothing attached means nothing to be deep.
    GLint object_type = GL_NONE;
    g_glFuncs.glGetFramebufferAttachmentParameteriv(
        GL_DRAW_FRAMEBUFFER, attachment, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &object_type);
    if (object_type == GL_NONE) return true;

    GLint bits = 0;
    g_glFuncs.glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, attachment, size_pname,
                                                    &bits);
    *out = bits;
    return true;
}

// `enable` marks the subset glIsEnabled may answer for: a capability, not
// just any state that happens to be 0 or 1. Without it glIsEnabled(GL_FOG_MODE)
// would return a value where the spec wants GL_INVALID_ENUM.
bool fixedFunctionState(GLenum pname, GLdouble* values, int* count, bool* color, bool* enable) {
    auto& gs = g_glstate;
    const auto& ff = gs.fpe_state;
    const auto& bools = ff.fpe_bools;
    const auto& uni = gs.fpe_uniform;
    const auto& current = ff.fpe_draw.current_data;
    const auto& arrays = ff.vertexpointer_array;
    const int unit =
        std::clamp(static_cast<int>(sfpewLogicalActiveTexture() - GL_TEXTURE0), 0, MAX_TEX - 1);

    *count = 1;
    *color = false;
    *enable = false;

    const auto scalar = [&](GLdouble value) {
        values[0] = value;
        return true;
    };
    // A capability: same value, but also legal to ask glIsEnabled about.
    const auto capability = [&](bool on) {
        *enable = true;
        values[0] = on ? 1 : 0;
        return true;
    };
    const auto vector = [&](const GLfloat* source, int n) {
        for (int i = 0; i < n; ++i) values[i] = source[i];
        *count = n;
        return true;
    };
    // Colors and normals: same values, but an integer query maps them onto
    // the full integer range rather than rounding them to 0 or 1.
    const auto signal = [&](const GLfloat* source, int n) {
        *color = true;
        return vector(source, n);
    };
    const auto matrix = [&](const glm::mat4& m, bool transpose) {
        const GLfloat* source = glm::value_ptr(m);
        for (int i = 0; i < 16; ++i) values[i] = transpose ? source[(i % 4) * 4 + i / 4] : source[i];
        *count = 16;
        return true;
    };
    // One accessor for every client array: which array is named by the
    // GL_*_ARRAY enum the query family belongs to. An array that was never
    // specified reports the spec's initial values rather than the contents
    // of a slot nobody filled.
    const auto array = [&](GLenum which, array_field_t field) -> GLdouble {
        const int slot = vp2idx(which);
        if (slot < 0) return 0;
        const auto& attr = arrays.attributes[slot];
        const bool specified = attr.type != 0;
        switch (field) {
        case kArrayEnabled:
            return (arrays.enabled_pointers & vp_mask(which)) != 0 ? 1 : 0;
        case kArraySize:
            if (specified) return attr.size;
            return which == GL_SECONDARY_COLOR_ARRAY ? 3 : 4;
        case kArrayType:
            return specified ? attr.type : GL_FLOAT;
        case kArrayStride:
            return specified ? attr.stride : 0;
        case kArrayBuffer:
            return ff.client_array_buffer_bindings[slot];
        }
        return 0;
    };

    // The evaluator maps and their grid live in evaluators.cpp. Everything
    // it answers except the grid is a capability.
    if (sfpewEvaluatorStateQuery(pname, values, count)) {
        *enable = pname != GL_MAP1_GRID_DOMAIN && pname != GL_MAP1_GRID_SEGMENTS &&
                  pname != GL_MAP2_GRID_DOMAIN && pname != GL_MAP2_GRID_SEGMENTS;
        return true;
    }

    // Lights and clip planes are ranges, not single enums.
    if (pname >= GL_LIGHT0 && pname < GL_LIGHT0 + MAX_LIGHTS)
        return capability(bools.light_enable[pname - GL_LIGHT0]);
    if (pname >= GL_CLIP_PLANE0 && pname < GL_CLIP_PLANE0 + 6)
        return capability(bools.clip_plane_enable[pname - GL_CLIP_PLANE0]);

    switch (pname) {
    // ---- enables the wrapper implements ----
    case GL_FOG: return capability(bools.fog_enable);
    case GL_LIGHTING: return capability(bools.lighting_enable);
    case GL_ALPHA_TEST: return capability(bools.alpha_test_enable);
    case GL_COLOR_MATERIAL: return capability(bools.color_material_enable);
    case GL_NORMALIZE: return capability(bools.normalize_enable);
    case GL_RESCALE_NORMAL: return capability(bools.rescale_normal_enable);
    case GL_POLYGON_STIPPLE: return capability(bools.polygon_stipple_enable);
    case GL_LINE_STIPPLE: return capability(bools.line_stipple_enable);
    case GL_TEXTURE_2D: return capability(bools.texture_2d_enable[unit]);
    // 1D textures are carried on 2D storage here, so they share the enable.
    case GL_TEXTURE_1D: return capability(bools.texture_2d_enable[unit]);
    case GL_TEXTURE_GEN_S: return capability(bools.texture_gen_enable[unit][0]);
    case GL_TEXTURE_GEN_T: return capability(bools.texture_gen_enable[unit][1]);
    case GL_TEXTURE_GEN_R: return capability(bools.texture_gen_enable[unit][2]);
    case GL_TEXTURE_GEN_Q: return capability(bools.texture_gen_enable[unit][3]);
    // defects-plan.md 1.7.
    case GL_TEXTURE_3D: return capability(bools.texture_3d_enable[unit]);
    case GL_TEXTURE_CUBE_MAP: return capability(bools.texture_cube_enable[unit]);
    // defects-plan-2.md 2.2/2.4: both have a real rendering effect now (see
    // fpe_shadergen.cpp), unlike GL_LINE_SMOOTH/GL_POLYGON_SMOOTH below.
    case GL_POINT_SPRITE: return capability(bools.point_sprite_enable);
    case GL_POINT_SMOOTH: return capability(bools.point_smooth_enable);

    // ---- enables for wrapper-side and unsupported pipeline stages ----
    // defects-plan-2.md's scope decisions: GL_LINE_SMOOTH/GL_POLYGON_SMOOTH
    // would need per-primitive geometry processing (line thickening,
    // polygon edge distance) this wrapper's native-rasterizer draw path
    // doesn't have - unlike GL_POINT_SMOOTH above, a real per-point radial
    // falloff needs nothing more than gl_PointCoord. GL_POLYGON_OFFSET_LINE/
    // GL_POLYGON_OFFSET_POINT would need the offset triangle's own depth
    // slope re-applied while the wireframe-expansion path
    // (sfpewDrawMixedPolygonMode) emits its line/point geometry, which it
    // doesn't currently carry through. Same honest-state-no-fake-effect
    // treatment as GL_COLOR_LOGIC_OP/GL_INDEX_LOGIC_OP below, not an
    // oversight.
    case GL_LINE_SMOOTH:
    case GL_POLYGON_SMOOTH:
    case GL_POLYGON_OFFSET_LINE:
    case GL_POLYGON_OFFSET_POINT:
    // glLogicOp itself is real (state.cpp) and GL_LOGIC_OP_MODE reads it
    // back exactly; these two enables stay false deliberately - ES 3.0 core
    // has no fixed-function logic op and no extension-free way to emulate
    // one, so there is no render effect to honestly report as present.
    case GL_COLOR_LOGIC_OP:
    case GL_INDEX_LOGIC_OP:
    case GL_VERTEX_PROGRAM_POINT_SIZE:
    case GL_VERTEX_PROGRAM_TWO_SIDE:
        return capability(false);
    case GL_COLOR_TABLE: return capability(gs.color_tables[0].enabled);
    case GL_POST_CONVOLUTION_COLOR_TABLE: return capability(gs.color_tables[1].enabled);
    case GL_POST_COLOR_MATRIX_COLOR_TABLE: return capability(gs.color_tables[2].enabled);
    case GL_CONVOLUTION_1D: return capability(gs.convolutions[0].enabled);
    case GL_CONVOLUTION_2D: return capability(gs.convolutions[1].enabled);
    case GL_SEPARABLE_2D: return capability(gs.convolutions[2].enabled);
    case GL_HISTOGRAM: return capability(gs.histogram.enabled);
    case GL_MINMAX: return capability(gs.minmax.enabled);
    case GL_COLOR_SUM: return capability(bools.color_sum_enable);

    // ---- current vertex attributes ----
    case GL_CURRENT_COLOR: return signal(glm::value_ptr(current.color), 4);
    case GL_CURRENT_NORMAL: return signal(glm::value_ptr(current.normal), 3);
    case GL_CURRENT_SECONDARY_COLOR: return signal(glm::value_ptr(current.secondary_color), 4);
    case GL_CURRENT_TEXTURE_COORDS: return vector(glm::value_ptr(current.texcoord[unit]), 4);
    case GL_CURRENT_FOG_COORD: return scalar(current.fog_coord);
    case GL_EDGE_FLAG: return scalar(current.edge_flag ? 1 : 0);
    case GL_CURRENT_RASTER_POSITION: return vector(glm::value_ptr(uni.raster_position), 4);
    case GL_CURRENT_RASTER_POSITION_VALID: return scalar(uni.raster_position_valid ? 1 : 0);
    case GL_CURRENT_RASTER_COLOR: return signal(glm::value_ptr(uni.raster_color), 4);
    case GL_CURRENT_RASTER_TEXTURE_COORDS: return vector(glm::value_ptr(uni.raster_texcoord), 4);
    case GL_CURRENT_RASTER_DISTANCE: return scalar(0);
    // Color-index mode does not exist here; its state keeps its initial
    // values so a query cannot mistake absence for a written zero.
    case GL_CURRENT_INDEX:
    case GL_CURRENT_RASTER_INDEX: return scalar(1);
    case GL_CURRENT_RASTER_SECONDARY_COLOR: {
        static const GLfloat black[4] = {0, 0, 0, 1};
        return signal(black, 4);
    }

    // ---- fog ----
    case GL_FOG_MODE: return scalar(ff.fog_mode);
    case GL_FOG_DENSITY: return scalar(uni.fog_density);
    case GL_FOG_START: return scalar(uni.fog_start);
    case GL_FOG_END: return scalar(uni.fog_end);
    case GL_FOG_COLOR: return signal(glm::value_ptr(uni.fog_color), 4);
    case GL_FOG_INDEX: return scalar(ff.fog_index);
    case GL_FOG_COORD_SRC: return scalar(ff.fog_coord_src);

    // ---- lighting and materials ----
    case GL_LIGHT_MODEL_AMBIENT: return signal(glm::value_ptr(uni.light_model_ambient), 4);
    case GL_LIGHT_MODEL_COLOR_CONTROL: return scalar(ff.light_model_color_ctrl);
    case GL_LIGHT_MODEL_LOCAL_VIEWER: return scalar(ff.light_model_local_viewer ? 1 : 0);
    case GL_LIGHT_MODEL_TWO_SIDE: return scalar(ff.light_model_two_side ? 1 : 0);
    case GL_SHADE_MODEL: return scalar(ff.shade_model);
    case GL_COLOR_MATERIAL_FACE: return scalar(ff.color_material_face);
    case GL_COLOR_MATERIAL_PARAMETER: return scalar(ff.color_material_mode);

    // ---- alpha test, point, line, polygon ----
    case GL_ALPHA_TEST_FUNC: return scalar(ff.alpha_func);
    case GL_ALPHA_TEST_REF: return scalar(uni.alpha_ref);
    case GL_POINT_SIZE: return scalar(uni.point_size);
    case GL_LINE_STIPPLE_PATTERN: return scalar(uni.line_stipple_pattern);
    case GL_LINE_STIPPLE_REPEAT: return scalar(uni.line_stipple_factor);
    case GL_POLYGON_MODE:
        values[0] = uni.polygon_mode_front;
        values[1] = uni.polygon_mode_back;
        *count = 2;
        return true;
    case GL_POINT_SIZE_MIN: return scalar(uni.point_size_min);
    case GL_POINT_SIZE_MAX:
        sfpewInitializePointSizeMax(gs);
        return scalar(uni.point_size_max);
    case GL_POINT_FADE_THRESHOLD_SIZE: return scalar(uni.point_fade_threshold_size);
    case GL_POINT_DISTANCE_ATTENUATION:
        return vector(glm::value_ptr(uni.point_distance_attenuation), 3);
    case GL_POINT_SPRITE_COORD_ORIGIN: return scalar(ff.point_sprite_coord_origin);
    case GL_LOGIC_OP_MODE: return scalar(ff.logic_op_mode);
    // GL 2.1 names the antialiased range GL_SMOOTH_*_RANGE and the plain one
    // GL_POINT_SIZE_RANGE / GL_LINE_WIDTH_RANGE - the same enum either way.
    // A GLES backend reports only its aliased range, which is the range that
    // actually applies here since neither smooth points nor smooth lines
    // exist; a desktop backend knows these names itself, and does not know
    // GL_ALIASED_POINT_SIZE_RANGE at all.
    case GL_POINT_SIZE_RANGE:
    case GL_LINE_WIDTH_RANGE: {
        GLfloat range[2] = {1.0f, 1.0f};
        if (sfpewEnsureBackend() && g_glFuncs.glGetFloatv != nullptr) {
            int major = 0, minor = 0;
            GLenum ask = pname;
            if (sfpewDesktopGLVersion(&major, &minor))
                ask = pname == GL_LINE_WIDTH_RANGE ? GL_ALIASED_LINE_WIDTH_RANGE
                                                   : GL_ALIASED_POINT_SIZE_RANGE;
            g_glFuncs.glGetFloatv(ask, range);
        }
        return vector(range, 2);
    }
    // No backend reports a step size, and a step of one is the claim that
    // cannot promise more than it delivers.
    case GL_POINT_SIZE_GRANULARITY:
    case GL_LINE_WIDTH_GRANULARITY: return scalar(1);
    // The single-buffer name GL 2.1 uses for what GLES calls draw buffer 0.
    case GL_DRAW_BUFFER: {
        GLint buffer = GL_BACK;
        if (sfpewEnsureBackend() && g_glFuncs.glGetIntegerv != nullptr)
            g_glFuncs.glGetIntegerv(GL_DRAW_BUFFER0, &buffer);
        return scalar(buffer);
    }
    // defects-plan-2.md 2.1: real backend state (glReadBuffer sets it
    // directly, GL_READ_BUFFER is a real ES3/GL3.2 pname), no wrapper-side
    // shadow needed - same reasoning as GL_DRAW_BUFFER above.
    case GL_READ_BUFFER: {
        GLint buffer = GL_BACK;
        if (sfpewEnsureBackend() && g_glFuncs.glGetIntegerv != nullptr)
            g_glFuncs.glGetIntegerv(GL_READ_BUFFER, &buffer);
        return scalar(buffer);
    }

    // ---- matrices and their stacks ----
    case GL_MATRIX_MODE: return scalar(uni.transformation.matrix_mode);
    case GL_MODELVIEW_MATRIX:
    case GL_TRANSPOSE_MODELVIEW_MATRIX: {
        const bool transpose = pname == GL_TRANSPOSE_MODELVIEW_MATRIX;
        const auto& m = uni.transformation.matrices[matrix_idx(GL_MODELVIEW)];
        // Minecraft builds its view frustum from this read-back and culls
        // every chunk against it, so a wrong answer here empties the world
        // without a single draw call going missing.
        if (!transpose)
            sfpewListLogMatrixQuery("MODELVIEW", 0,
                                    uni.transformation.matrices_stack[matrix_idx(GL_MODELVIEW)].size(),
                                    glm::value_ptr(m));
        return matrix(m, transpose);
    }
    case GL_PROJECTION_MATRIX:
    case GL_TRANSPOSE_PROJECTION_MATRIX: {
        const bool transpose = pname == GL_TRANSPOSE_PROJECTION_MATRIX;
        const auto& m = uni.transformation.matrices[matrix_idx(GL_PROJECTION)];
        if (!transpose)
            sfpewListLogMatrixQuery("PROJECTION", 1,
                                    uni.transformation.matrices_stack[matrix_idx(GL_PROJECTION)].size(),
                                    glm::value_ptr(m));
        return matrix(m, transpose);
    }
    case GL_TEXTURE_MATRIX:
        return matrix(uni.transformation.texture_matrices[unit], false);
    case GL_TRANSPOSE_TEXTURE_MATRIX:
        return matrix(uni.transformation.texture_matrices[unit], true);
    case GL_COLOR_MATRIX:
        return matrix(uni.transformation.matrices[matrix_idx(GL_COLOR)], false);
    case GL_TRANSPOSE_COLOR_MATRIX:
        return matrix(uni.transformation.matrices[matrix_idx(GL_COLOR)], true);
    // Stack depth counts the current, unpushed matrix as well.
    case GL_MODELVIEW_STACK_DEPTH:
        return scalar(uni.transformation.matrices_stack[matrix_idx(GL_MODELVIEW)].size() + 1);
    case GL_PROJECTION_STACK_DEPTH:
        return scalar(uni.transformation.matrices_stack[matrix_idx(GL_PROJECTION)].size() + 1);
    case GL_TEXTURE_STACK_DEPTH:
        return scalar(uni.transformation.texture_matrices_stack[unit].size() + 1);
    case GL_COLOR_MATRIX_STACK_DEPTH:
        return scalar(uni.transformation.matrices_stack[matrix_idx(GL_COLOR)].size() + 1);
    case GL_MAX_MODELVIEW_STACK_DEPTH: return scalar(MAX_MODELVIEW_STACK_DEPTH);
    case GL_MAX_PROJECTION_STACK_DEPTH: return scalar(MAX_PROJECTION_STACK_DEPTH);
    case GL_MAX_TEXTURE_STACK_DEPTH: return scalar(MAX_TEXTURE_STACK_DEPTH);
    case GL_MAX_COLOR_MATRIX_STACK_DEPTH: return scalar(MAX_COLOR_STACK_DEPTH);

    // ---- fixed-function capacities ----
    case GL_MAX_LIGHTS: return scalar(MAX_LIGHTS);
    case GL_MAX_CLIP_PLANES: return scalar(6);
    // The conventional fixed-function unit count, not MAX_TEX: plans/03
    // keeps the advertised surface at the well-tested subset.
    case GL_MAX_TEXTURE_UNITS:
    case GL_MAX_TEXTURE_COORDS: return scalar(8);
    case GL_MAX_LIST_NESTING: return scalar(64);
    case GL_MAX_NAME_STACK_DEPTH: return scalar(64);
    case GL_MAX_EVAL_ORDER: return scalar(32);
    case GL_MAX_PIXEL_MAP_TABLE: return scalar(SFPEW_MAX_PIXEL_MAP_TABLE);
    case GL_MAX_CONVOLUTION_WIDTH:
    case GL_MAX_CONVOLUTION_HEIGHT: return scalar(SFPEW_MAX_CONVOLUTION_SIZE);

    // ---- client vertex arrays ----
    case GL_CLIENT_ACTIVE_TEXTURE: return scalar(ff.client_active_texture);
    // The client-side array enables are capabilities too: glIsEnabled takes
    // them, and glEnableClientState is what turns them on.
    case GL_VERTEX_ARRAY: return capability(array(GL_VERTEX_ARRAY, kArrayEnabled) != 0);
    case GL_VERTEX_ARRAY_SIZE: return scalar(array(GL_VERTEX_ARRAY, kArraySize));
    case GL_VERTEX_ARRAY_TYPE: return scalar(array(GL_VERTEX_ARRAY, kArrayType));
    case GL_VERTEX_ARRAY_STRIDE: return scalar(array(GL_VERTEX_ARRAY, kArrayStride));
    case GL_VERTEX_ARRAY_BUFFER_BINDING: return scalar(array(GL_VERTEX_ARRAY, kArrayBuffer));
    case GL_NORMAL_ARRAY: return capability(array(GL_NORMAL_ARRAY, kArrayEnabled) != 0);
    case GL_NORMAL_ARRAY_TYPE: return scalar(array(GL_NORMAL_ARRAY, kArrayType));
    case GL_NORMAL_ARRAY_STRIDE: return scalar(array(GL_NORMAL_ARRAY, kArrayStride));
    case GL_NORMAL_ARRAY_BUFFER_BINDING: return scalar(array(GL_NORMAL_ARRAY, kArrayBuffer));
    case GL_COLOR_ARRAY: return capability(array(GL_COLOR_ARRAY, kArrayEnabled) != 0);
    case GL_COLOR_ARRAY_SIZE: return scalar(array(GL_COLOR_ARRAY, kArraySize));
    case GL_COLOR_ARRAY_TYPE: return scalar(array(GL_COLOR_ARRAY, kArrayType));
    case GL_COLOR_ARRAY_STRIDE: return scalar(array(GL_COLOR_ARRAY, kArrayStride));
    case GL_COLOR_ARRAY_BUFFER_BINDING: return scalar(array(GL_COLOR_ARRAY, kArrayBuffer));
    case GL_SECONDARY_COLOR_ARRAY: return capability(array(GL_SECONDARY_COLOR_ARRAY, kArrayEnabled) != 0);
    case GL_SECONDARY_COLOR_ARRAY_SIZE: return scalar(array(GL_SECONDARY_COLOR_ARRAY, kArraySize));
    case GL_SECONDARY_COLOR_ARRAY_TYPE: return scalar(array(GL_SECONDARY_COLOR_ARRAY, kArrayType));
    case GL_SECONDARY_COLOR_ARRAY_STRIDE:
        return scalar(array(GL_SECONDARY_COLOR_ARRAY, kArrayStride));
    case GL_SECONDARY_COLOR_ARRAY_BUFFER_BINDING:
        return scalar(array(GL_SECONDARY_COLOR_ARRAY, kArrayBuffer));
    case GL_TEXTURE_COORD_ARRAY: return capability(array(GL_TEXTURE_COORD_ARRAY, kArrayEnabled) != 0);
    case GL_TEXTURE_COORD_ARRAY_SIZE: return scalar(array(GL_TEXTURE_COORD_ARRAY, kArraySize));
    case GL_TEXTURE_COORD_ARRAY_TYPE: return scalar(array(GL_TEXTURE_COORD_ARRAY, kArrayType));
    case GL_TEXTURE_COORD_ARRAY_STRIDE: return scalar(array(GL_TEXTURE_COORD_ARRAY, kArrayStride));
    case GL_TEXTURE_COORD_ARRAY_BUFFER_BINDING:
        return scalar(array(GL_TEXTURE_COORD_ARRAY, kArrayBuffer));
    case GL_FOG_COORD_ARRAY: return capability(array(GL_FOG_COORD_ARRAY, kArrayEnabled) != 0);
    case GL_FOG_COORD_ARRAY_TYPE: return scalar(array(GL_FOG_COORD_ARRAY, kArrayType));
    case GL_FOG_COORD_ARRAY_STRIDE: return scalar(array(GL_FOG_COORD_ARRAY, kArrayStride));
    case GL_FOG_COORD_ARRAY_BUFFER_BINDING: return scalar(array(GL_FOG_COORD_ARRAY, kArrayBuffer));
    case GL_EDGE_FLAG_ARRAY: return capability(array(GL_EDGE_FLAG_ARRAY, kArrayEnabled) != 0);
    case GL_EDGE_FLAG_ARRAY_STRIDE: return scalar(array(GL_EDGE_FLAG_ARRAY, kArrayStride));
    case GL_EDGE_FLAG_ARRAY_BUFFER_BINDING: return scalar(array(GL_EDGE_FLAG_ARRAY, kArrayBuffer));
    case GL_INDEX_ARRAY: return capability(array(GL_INDEX_ARRAY, kArrayEnabled) != 0);
    case GL_INDEX_ARRAY_TYPE: return scalar(array(GL_INDEX_ARRAY, kArrayType));
    case GL_INDEX_ARRAY_STRIDE: return scalar(array(GL_INDEX_ARRAY, kArrayStride));
    case GL_INDEX_ARRAY_BUFFER_BINDING: return scalar(array(GL_INDEX_ARRAY, kArrayBuffer));

    // ---- display lists ----
    case GL_LIST_BASE: return scalar(DisplayListManager::listBase());
    case GL_LIST_INDEX: return scalar(DisplayListManager::currentList());
    case GL_LIST_MODE:
        return scalar(DisplayListManager::currentList() != 0
                          ? static_cast<GLdouble>(DisplayListManager::currentListMode())
                          : 0);

    // ---- selection and feedback ----
    case GL_RENDER_MODE: return scalar(gs.render_mode);
    case GL_SELECTION_BUFFER_SIZE: return scalar(gs.select_buffer_size);
    case GL_FEEDBACK_BUFFER_SIZE: return scalar(gs.feedback_buffer_size);
    case GL_FEEDBACK_BUFFER_TYPE: return scalar(gs.feedback_type);
    case GL_NAME_STACK_DEPTH: return scalar(gs.name_stack.size());

    // ---- attribute stacks ----
    case GL_ATTRIB_STACK_DEPTH:
    case GL_CLIENT_ATTRIB_STACK_DEPTH:
    case GL_MAX_ATTRIB_STACK_DEPTH:
    case GL_MAX_CLIENT_ATTRIB_STACK_DEPTH: {
        int server = 0, client = 0, maxDepth = 0;
        sfpewAttribStackDepths(&server, &client, &maxDepth);
        if (pname == GL_ATTRIB_STACK_DEPTH) return scalar(server);
        if (pname == GL_CLIENT_ATTRIB_STACK_DEPTH) return scalar(client);
        return scalar(maxDepth);
    }

    // ---- pixel transfer, storage and zoom ----
    case GL_ZOOM_X: return scalar(uni.pixel_zoom_x);
    case GL_ZOOM_Y: return scalar(uni.pixel_zoom_y);
    case GL_RED_SCALE: return scalar(uni.pixel_scale[0]);
    case GL_GREEN_SCALE: return scalar(uni.pixel_scale[1]);
    case GL_BLUE_SCALE: return scalar(uni.pixel_scale[2]);
    case GL_ALPHA_SCALE: return scalar(uni.pixel_scale[3]);
    case GL_DEPTH_SCALE: return scalar(uni.pixel_scale[4]);
    case GL_RED_BIAS: return scalar(uni.pixel_bias[0]);
    case GL_GREEN_BIAS: return scalar(uni.pixel_bias[1]);
    case GL_BLUE_BIAS: return scalar(uni.pixel_bias[2]);
    case GL_ALPHA_BIAS: return scalar(uni.pixel_bias[3]);
    case GL_DEPTH_BIAS: return scalar(uni.pixel_bias[4]);
    case GL_MAP_COLOR: return scalar(uni.pixel_map_color ? 1 : 0);
    case GL_MAP_STENCIL: return scalar(uni.pixel_map_stencil ? 1 : 0);
    case GL_UNPACK_SWAP_BYTES: return scalar(gs.pixel_store_unpack_swap_bytes ? 1 : 0);
    case GL_UNPACK_LSB_FIRST: return scalar(gs.pixel_store_unpack_lsb_first ? 1 : 0);
    case GL_PACK_SWAP_BYTES: return scalar(gs.pixel_store_pack_swap_bytes ? 1 : 0);
    case GL_PACK_LSB_FIRST: return scalar(gs.pixel_store_pack_lsb_first ? 1 : 0);
    // Pack-side 3D skips have no GLES equivalent and nothing reads them.
    case GL_PACK_IMAGE_HEIGHT:
    case GL_PACK_SKIP_IMAGES:
    case GL_INDEX_SHIFT:
    case GL_INDEX_OFFSET: return scalar(0);
    case GL_PIXEL_MAP_I_TO_I_SIZE:
    case GL_PIXEL_MAP_S_TO_S_SIZE:
    case GL_PIXEL_MAP_I_TO_R_SIZE:
    case GL_PIXEL_MAP_I_TO_G_SIZE:
    case GL_PIXEL_MAP_I_TO_B_SIZE:
    case GL_PIXEL_MAP_I_TO_A_SIZE:
    case GL_PIXEL_MAP_R_TO_R_SIZE:
    case GL_PIXEL_MAP_G_TO_G_SIZE:
    case GL_PIXEL_MAP_B_TO_B_SIZE:
    case GL_PIXEL_MAP_A_TO_A_SIZE:
        return scalar(gs.pixel_maps[pname - GL_PIXEL_MAP_I_TO_I_SIZE].size());
    case GL_POST_CONVOLUTION_RED_SCALE:
    case GL_POST_CONVOLUTION_GREEN_SCALE:
    case GL_POST_CONVOLUTION_BLUE_SCALE:
    case GL_POST_CONVOLUTION_ALPHA_SCALE:
        return scalar(uni.post_convolution_scale[pname - GL_POST_CONVOLUTION_RED_SCALE]);
    case GL_POST_COLOR_MATRIX_RED_SCALE:
    case GL_POST_COLOR_MATRIX_GREEN_SCALE:
    case GL_POST_COLOR_MATRIX_BLUE_SCALE:
    case GL_POST_COLOR_MATRIX_ALPHA_SCALE:
        return scalar(uni.post_color_matrix_scale[pname - GL_POST_COLOR_MATRIX_RED_SCALE]);
    case GL_POST_CONVOLUTION_RED_BIAS:
    case GL_POST_CONVOLUTION_GREEN_BIAS:
    case GL_POST_CONVOLUTION_BLUE_BIAS:
    case GL_POST_CONVOLUTION_ALPHA_BIAS:
        return scalar(uni.post_convolution_bias[pname - GL_POST_CONVOLUTION_RED_BIAS]);
    case GL_POST_COLOR_MATRIX_RED_BIAS:
    case GL_POST_COLOR_MATRIX_GREEN_BIAS:
    case GL_POST_COLOR_MATRIX_BLUE_BIAS:
    case GL_POST_COLOR_MATRIX_ALPHA_BIAS:
        return scalar(uni.post_color_matrix_bias[pname - GL_POST_COLOR_MATRIX_RED_BIAS]);

    // ---- accumulation buffer ----
    // Emulated on an RGBA16F attachment (pixelops.cpp), which is what the
    // bit depths report.
    case GL_ACCUM_RED_BITS:
    case GL_ACCUM_GREEN_BITS:
    case GL_ACCUM_BLUE_BITS:
    case GL_ACCUM_ALPHA_BITS: return scalar(16);
    case GL_ACCUM_CLEAR_VALUE: {
        GLfloat rgba[4] = {};
        sfpewAccumClearValue(rgba);
        return signal(rgba, 4);
    }

    // ---- framebuffer and context properties GLES has no query for ----
    case GL_RED_BITS:
    case GL_GREEN_BITS:
    case GL_BLUE_BITS:
    case GL_ALPHA_BITS:
    case GL_DEPTH_BITS:
    case GL_STENCIL_BITS:
        return framebufferBits(pname, values);
    case GL_RGBA_MODE: return scalar(1);
    case GL_INDEX_MODE: return scalar(0);
    case GL_STEREO: return scalar(0);
    case GL_AUX_BUFFERS: return scalar(0);
    case GL_INDEX_BITS: return scalar(0);
    case GL_INDEX_CLEAR_VALUE: return scalar(0);
    case GL_INDEX_WRITEMASK: return scalar(~0u);
    // EGL window surfaces are double buffered; a pbuffer is single buffered
    // but nothing in a legacy frontend branches on this.
    case GL_DOUBLEBUFFER: return scalar(1);

    // ---- hints one of the two floors cannot take, from their shadow ----
    // GL_GENERATE_MIPMAP_HINT is the one that goes the other way: ES 3 has
    // it, a core context rejects it, and NVIDIA's core profile does reject
    // it where Mesa's lets it through.
    case GL_FOG_HINT:
    case GL_LINE_SMOOTH_HINT:
    case GL_PERSPECTIVE_CORRECTION_HINT:
    case GL_POINT_SMOOTH_HINT:
    case GL_POLYGON_SMOOTH_HINT:
    case GL_TEXTURE_COMPRESSION_HINT:
    case GL_GENERATE_MIPMAP_HINT: {
        const int slot = sfpewLegacyHintSlot(pname);
        return scalar(slot >= 0 ? gs.legacy_hints[slot] : GL_DONT_CARE);
    }

    // 1D textures live on 2D storage, so they share its binding.
    case GL_TEXTURE_BINDING_1D: return scalar(sfpewLogicalTextureBinding(GL_TEXTURE_2D));

    default:
        return false;
    }
}

} // namespace

// The client-array pointers, which no glGet* variant can return - they are
// pointers, so they get their own entry point. GLES has none of these
// arrays, and the two buffers below live entirely on the wrapper's side.
void glGetPointerv(GLenum pname, GLvoid** params) {
    if (!params) return;
    auto& gs = g_glstate;
    const auto& arrays = gs.fpe_state.vertexpointer_array;

    GLenum array = 0;
    switch (pname) {
    case GL_VERTEX_ARRAY_POINTER: array = GL_VERTEX_ARRAY; break;
    case GL_NORMAL_ARRAY_POINTER: array = GL_NORMAL_ARRAY; break;
    case GL_COLOR_ARRAY_POINTER: array = GL_COLOR_ARRAY; break;
    case GL_INDEX_ARRAY_POINTER: array = GL_INDEX_ARRAY; break;
    case GL_TEXTURE_COORD_ARRAY_POINTER: array = GL_TEXTURE_COORD_ARRAY; break;
    case GL_EDGE_FLAG_ARRAY_POINTER: array = GL_EDGE_FLAG_ARRAY; break;
    case GL_SECONDARY_COLOR_ARRAY_POINTER: array = GL_SECONDARY_COLOR_ARRAY; break;
    case GL_FOG_COORD_ARRAY_POINTER: array = GL_FOG_COORD_ARRAY; break;
    case GL_FEEDBACK_BUFFER_POINTER:
        *params = gs.feedback_buffer;
        return;
    case GL_SELECTION_BUFFER_POINTER:
        *params = gs.select_buffer;
        return;
    default:
        // Modern pointer queries (GL_DEBUG_CALLBACK_*, mapped buffers) are
        // the backend's; an unknown pname is its error to raise.
        if (sfpewEnsureBackend() && g_glFuncs.glGetPointerv != nullptr)
            g_glFuncs.glGetPointerv(pname, params);
        else
            gs.set_error(GL_INVALID_ENUM);
        return;
    }

    const int slot = vp2idx(array);
    *params = slot >= 0 ? const_cast<GLvoid*>(arrays.attributes[slot].pointer) : nullptr;
}

GLboolean glIsEnabled(GLenum cap) {
    // Every fixed-function enable comes from the same table the glGet family
    // reads, so the two can never disagree about whether fog is on.
    GLdouble values[16] = {};
    int count = 0;
    bool color = false, enable = false;
    if (fixedFunctionState(cap, values, &count, &color, &enable) && enable)
        return values[0] != 0 ? GL_TRUE : GL_FALSE;
    if (!sfpewEnsureBackend() || g_glFuncs.glIsEnabled == nullptr) return GL_FALSE;
    return g_glFuncs.glIsEnabled(cap);
}

void glGetBooleanv(GLenum pname, GLboolean* params) {
    if (!params) return;
    GLdouble values[16] = {};
    int count = 0;
    bool color = false, enable = false;
    if (fixedFunctionState(pname, values, &count, &color, &enable)) {
        // "GL_FALSE if and only if it is 0.0" - no rounding, no scaling.
        for (int i = 0; i < count; ++i) params[i] = values[i] != 0.0 ? GL_TRUE : GL_FALSE;
        return;
    }
    if (isWrapperIntegerPname(pname)) {
        GLint value = 0;
        glGetIntegerv(pname, &value);
        params[0] = value != 0 ? GL_TRUE : GL_FALSE;
        return;
    }
    if (!sfpewEnsureBackend() || g_glFuncs.glGetBooleanv == nullptr) return;
    g_glFuncs.glGetBooleanv(pname, params);
}

void glGetDoublev(GLenum pname, GLdouble* params) {
    if (!params) return;
    int count = 0;
    bool color = false, enable = false;
    if (fixedFunctionState(pname, params, &count, &color, &enable)) return;
    if (isWrapperIntegerPname(pname)) {
        GLint value = 0;
        glGetIntegerv(pname, &value);
        params[0] = static_cast<GLdouble>(value);
        return;
    }
    // Everything else is float-domain: stage through the (wrapper) float
    // getter and widen; the count table bounds how much we copy out.
    GLfloat staging[16] = {};
    glGetFloatv(pname, staging);
    const int count_f = floatPnameComponentCount(pname);
    for (int i = 0; i < count_f; ++i) params[i] = static_cast<GLdouble>(staging[i]);
}

void glGetIntegerv(GLenum pname, GLint* params) {
    // A null out-pointer is caller error; GL never throws. Returning quietly
    // here keeps C callers alive (error injection arrives with the S2 error
    // machine).
    if (!params) return;
    // Fixed-function state first, and without needing a backend: it is the
    // wrapper's own, and the conversion to integers is the spec's - round,
    // except colors and normals, which map onto the whole integer range.
    {
        GLdouble values[16] = {};
        int count = 0;
        bool color = false, enable = false;
        if (fixedFunctionState(pname, values, &count, &color, &enable)) {
            for (int i = 0; i < count; ++i) {
                const double scaled =
                    color ? std::clamp(values[i], -1.0, 1.0) * 2147483647.0 : values[i];
                params[i] = static_cast<GLint>(std::clamp(std::round(scaled), -2147483648.0,
                                                          2147483647.0));
            }
            return;
        }
    }
    if (!sfpewEnsureBackend() || g_glFuncs.glGetIntegerv == nullptr) return;

    switch (pname) {
    case GL_CONTEXT_PROFILE_MASK:
        *params = GL_CONTEXT_COMPATIBILITY_PROFILE_BIT;
        break;
    case GL_CONTEXT_FLAGS:
        *params = 0;
        break;
    case GL_MAJOR_VERSION:
    case GL_MINOR_VERSION: {
        // Must agree with the desktop level glGetString(GL_VERSION) reports:
        // a loader that trusts one and validates the other would otherwise
        // see GL 4.5 in the string and 3.2 in the integers.
        int major = 0, minor = 0;
        if (sfpewDesktopGLVersion(&major, &minor)) {
            *params = pname == GL_MAJOR_VERSION ? major : minor;
        } else {
            g_glFuncs.glGetIntegerv(pname, params);
        }
        break;
    }
    case GL_NUM_EXTENSIONS: {
        static GLint cachedNumExtensions = -1;
        if (cachedNumExtensions < 0) {
            // Without a current context the backend leaves the out-param
            // untouched; only cache a value the backend actually wrote.
            GLint backendCount = -1;
            g_glFuncs.glGetIntegerv(GL_NUM_EXTENSIONS, &backendCount);
            if (backendCount < 0) {
                *params = 0;
                return;
            }
            cachedNumExtensions = backendCount + kDesktopExtensionCount +
                                  (sfpewTextureBorderClampSupported() ? 1 : 0);
        }
        *params = cachedNumExtensions;
        break;
    }
    // The four bindings a fixed-function draw takes over. Its deferred save
    // (plans/12) leaves the backend holding the wrapper's FPE program, fpe_vao,
    // ring buffer and element ring until the next entry barrier, so forwarding
    // any of these hands the app an internal name - which it then believes is
    // its own and "restores". Measured for the two that were missing: 0 before
    // a draw, the element ring after it (plans/16 M7).
    //
    // Answered from the same shadows the draw paths resolve them from, NOT by
    // taking the barrier here: glGetIntegerv is one of the hottest entry points
    // a legacy frontend has, and a restore per query would undo the deferral
    // the shadows exist to make possible.
    case GL_CURRENT_PROGRAM:
        *params = sfpewLogicalProgram();
        break;
    case GL_ARRAY_BUFFER_BINDING:
        *params = static_cast<GLint>(sfpewLogicalArrayBufferBinding());
        break;
    case GL_VERTEX_ARRAY_BINDING:
        *params = static_cast<GLint>(sfpewLogicalVertexArrayBinding());
        break;
    // The one that cannot always come from a shadow: an element binding is VAO
    // state and only VAO 0's is tracked, so a non-zero app VAO restores and
    // takes the real query inside the helper. Sharing it with the indexed draw
    // paths is deliberate - what this reports and what an indexed draw treats
    // `indices` as an offset into must never disagree.
    case GL_ELEMENT_ARRAY_BUFFER_BINDING:
        *params = sfpewResolveElementArrayBinding();
        break;
    default:
        g_glFuncs.glGetIntegerv(pname, params);
        break;
    }
}

void glGetFloatv(GLenum pname, GLfloat* params) {
    if (!params) return;
    // The fixed-function table answers in doubles; float is a narrowing of
    // the same values, and integers in it (enums, counts) become floats.
    GLdouble values[16] = {};
    int count = 0;
    bool color = false, enable = false;
    if (fixedFunctionState(pname, values, &count, &color, &enable)) {
        for (int i = 0; i < count; ++i) params[i] = static_cast<GLfloat>(values[i]);
        return;
    }
    if (isWrapperIntegerPname(pname)) {
        GLint value = 0;
        glGetIntegerv(pname, &value);
        params[0] = static_cast<GLfloat>(value);
        return;
    }
    if (sfpewEnsureBackend() && g_glFuncs.glGetFloatv != nullptr) g_glFuncs.glGetFloatv(pname, params);
}
