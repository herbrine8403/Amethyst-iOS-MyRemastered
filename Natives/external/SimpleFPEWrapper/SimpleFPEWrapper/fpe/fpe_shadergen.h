// SimpleFPEWrapper - SimpleFPEWrapper/fpe/fpe_shadergen.h
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#pragma once

#include <string>
#include "defines.h"

struct scratch_t {
    bool texgen_no_input[16] = {}; // units whose coords come only from texgen
    bool primary_color_saved = false;
    std::string last_stage_linkage;
    std::string vs_body;

    bool has_color_input = false;
    bool has_normal_input = false;
    bool has_vertex_color = false;
    bool has_back_vertex_color = false;
    bool has_texcoord[MAX_TEX] = {false};
    bool has_fog_coord_input = false; // glFogCoord*/glFogCoordPointer fed
    bool has_secondary_color_input = false; // glSecondaryColor3*/Pointer fed
};

// defects-plan.md 1.7: which sampler type (if any) a unit samples from.
// GL 2.1 3.8.14's texture application priority when more than one target is
// enabled on the same unit: cube map, then 3D, then 2D, then 1D (1D shares
// the 2D enable - see GL_TEXTURE_1D in state.cpp's hijack_fpe_states).
// Shared with glstate.cpp's program-hash cache/hash building, which must
// agree with the shader generator about which units are "textured" for
// GL_COMBINE-parameter staleness purposes - see active_texture_target's
// definition in fpe_shadergen.cpp for the texgen composition boundary this
// deliberately does not cover.
enum class texture_target_kind_t { none, tex2d, tex3d, cube };
texture_target_kind_t active_texture_target(const struct fixed_function_state_t& state, int unit);

class fpe_shader_generator {
public:
    fpe_shader_generator(const struct fixed_function_state_t& state) : state_(state) {}

    struct program_t generate_program();

private:
    static std::string vertex_shader(const struct fixed_function_state_t& state, scratch_t& scratch);
    static std::string fragment_shader(const struct fixed_function_state_t& state, scratch_t& scratch);

    const fixed_function_state_t& state_;
    scratch_t scratch_;
};
