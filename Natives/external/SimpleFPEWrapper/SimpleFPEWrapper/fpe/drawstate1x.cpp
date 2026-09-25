// SimpleFPEWrapper - SimpleFPEWrapper/fpe/drawstate1x.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "types.h"
#include <atomic>
#include <cstring>

#define DEBUG 0

uint64_t sfpewNextSizesEpoch() {
    // Relaxed is enough: the value only has to be distinct from every other
    // stamp, and it is always published together with the sizes it describes
    // through the same (per-context) state the reader already owns.
    static std::atomic<uint64_t> counter{0};
    return counter.fetch_add(1, std::memory_order_relaxed) + 1;
}

void fixed_function_draw_state_t::reset() {
    primitive = kNoPrimitive;
    vertex_count = 0;
    vb.clear();
    edge_flags.clear();
    repacked = false;
}

// How many floats attribute slot `s` contributes to the interleaved stream.
// The one answer for both the layout advance() packs to and the repack that
// rewrites already-collected vertices into a wider one: each used to carry
// its own hand-written model of the same thing, and they disagreed about the
// fog coordinate and the secondary color - which land BETWEEN the color and
// the texture coordinates, so leaving them out of the repack's stride took
// every vertex from the wrong base.
static GLint packed_slot_floats(const fixed_function_draw_size_t& sizes, int slot) {
    const GLint size = sizes.data[slot];
    if (size <= 0) return 0;
    switch (slot) {
    // The color index and the edge flag never reach a shader (edge flags have
    // their own byte vector), but compile_vertexattrib() sizes every slot it
    // sees, so one that is sized and not packed would shift every later
    // attribute.
    case 3:
    case 4: return 0;
    // glFogCoord* is a single float whatever the slot was sized with.
    case 5: return 1;
    default: return size;
    }
}

void fixed_function_draw_state_t::repack_for_attribute(int slot, GLint requested) {
    GLint& stored = current_data.sizes.data[slot];
    // Repack every collected vertex from the old layout to the new one, in
    // the ascending slot order advance() packs in.
    size_t old_stride = 0;
    for (int s = 0; s < VERTEX_POINTER_COUNT; ++s)
        old_stride += (size_t)packed_slot_floats(current_data.sizes, s);
    if (old_stride == 0 || vb.size() < old_stride * vertex_count) {
        stored = requested;
        return;
    }

    // Backfill value for vertices collected before this attribute existed:
    // its current value right now (the caller has not overwritten it yet).
    const GLfloat* previous_value = nullptr;
    if (slot == 0)
        previous_value = glm::value_ptr(current_data.vertex);
    else if (slot == 1)
        previous_value = glm::value_ptr(current_data.normal);
    else if (slot == 2)
        previous_value = glm::value_ptr(current_data.color);
    else
        previous_value = glm::value_ptr(current_data.texcoord[slot - 7]);
    static constexpr GLfloat kComponentDefaults[4] = {0.0f, 0.0f, 0.0f, 1.0f};

    repacked = true;
    sfpew_vertex_buffer_t repacked_vb;
    repacked_vb.reserve((old_stride + (size_t)(requested - stored)) * vertex_count);
    for (size_t v = 0; v < vertex_count; ++v) {
        const GLfloat* src = vb.data() + v * old_stride;
        size_t consumed = 0;
        for (int s = 0; s < VERTEX_POINTER_COUNT; ++s) {
            const GLint sz = packed_slot_floats(current_data.sizes, s);
            if (s == slot) {
                for (GLint c = 0; c < requested; ++c) {
                    if (c < sz)
                        repacked_vb.push_back(src[consumed + c]);
                    else if (sz == 0)
                        repacked_vb.push_back(previous_value[c]);
                    else
                        repacked_vb.push_back(kComponentDefaults[c]);
                }
            } else {
                for (GLint c = 0; c < sz; ++c) repacked_vb.push_back(src[consumed + c]);
            }
            consumed += (size_t)sz;
        }
    }
    vb = std::move(repacked_vb);
    stored = requested;
    current_data.sizes_epoch = sfpewNextSizesEpoch();
}

void fixed_function_draw_state_t::rebuild_packed_layout() {
    packed_span_count = 0;
    packed_floats = 0;
    const auto* base = reinterpret_cast<const GLfloat*>(&current_data);
    const auto add = [&](const GLfloat* src, GLint count) {
        if (count <= 0) return;
        const auto offset = static_cast<uint16_t>(src - base);
        // Merge with the previous span when the source is contiguous; the
        // destination always is.
        if (packed_span_count > 0) {
            auto& last = packed_spans[packed_span_count - 1];
            if (last.src_offset + last.count == offset) {
                last.count = static_cast<uint16_t>(last.count + count);
                packed_floats += static_cast<size_t>(count);
                return;
            }
        }
        packed_spans[packed_span_count++] = {offset, static_cast<uint16_t>(count)};
        packed_floats += static_cast<size_t>(count);
    };

    const auto& sizes = current_data.sizes;
    for (int slot = 0; slot < VERTEX_POINTER_COUNT; ++slot) {
        const GLint count = packed_slot_floats(sizes, slot);
        if (count <= 0) continue;
        const GLfloat* src = nullptr;
        switch (slot) {
        case 0: src = glm::value_ptr(current_data.vertex); break;
        case 1: src = glm::value_ptr(current_data.normal); break;
        case 2: src = glm::value_ptr(current_data.color); break;
        case 5: src = &current_data.fog_coord; break;
        case 6: src = glm::value_ptr(current_data.secondary_color); break;
        default: src = glm::value_ptr(current_data.texcoord[slot - 7]); break;
        }
        add(src, count);
    }
    packed_layout_sizes = sizes;
    packed_layout_epoch = current_data.sizes_epoch;
}



void fixed_function_draw_state_t::compile_vertexattrib(vertex_pointer_array_t& va) const {
    va.reset();

    va.dirty = true;
    va.buffer_based = false;

    const auto& sizes = current_data.sizes;
    uintptr_t offset = 0;

    // vertex
    if (sizes.vertex_size > 0) {
        va.enabled_pointers |= vp_mask(GL_VERTEX_ARRAY);

        va.attributes[vp2idx(GL_VERTEX_ARRAY)] = {
            .size = sizes.vertex_size,
            .usage = GL_VERTEX_ARRAY,
            .type = GL_FLOAT,
            .normalized = GL_FALSE,
            .stride = 0,
            .pointer = (const void*)offset,
            //                .varying = true
        };
        offset += sizes.vertex_size * sizeof(GLfloat);
    }

    // normal
    if (sizes.normal_size > 0) {
        va.enabled_pointers |= vp_mask(GL_NORMAL_ARRAY);

        va.attributes[vp2idx(GL_NORMAL_ARRAY)] = {
            .size = sizes.normal_size,
            .usage = GL_NORMAL_ARRAY,
            .type = GL_FLOAT,
            .normalized = GL_FALSE,
            .stride = 0,
            .pointer = (const void*)offset,
            //                .varying = true
        };
        offset += sizes.normal_size * sizeof(GLfloat);
    }

    // color
    if (sizes.color_size > 0) {
        va.enabled_pointers |= vp_mask(GL_COLOR_ARRAY);
        va.attributes[vp2idx(GL_COLOR_ARRAY)] = {
            .size = sizes.color_size,
            .usage = GL_COLOR_ARRAY,
            .type = GL_FLOAT,
            .normalized = GL_FALSE,
            .stride = 0,
            .pointer = (const void*)offset,
            //                .varying = true
        };
        offset += sizes.color_size * sizeof(GLfloat);
    }

    // fog coord (slot 5) - declaration order must match advance()'s packing
    if (sizes.fog_size > 0) {
        va.enabled_pointers |= vp_mask(GL_FOG_COORD_ARRAY);
        va.attributes[vp2idx(GL_FOG_COORD_ARRAY)] = {
            .size = 1,
            .usage = GL_FOG_COORD_ARRAY,
            .type = GL_FLOAT,
            .normalized = GL_FALSE,
            .stride = 0,
            .pointer = (const void*)offset,
        };
        offset += sizeof(GLfloat);
    }

    // secondary color (slot 6)
    if (sizes.secondary_color_size > 0) {
        va.enabled_pointers |= vp_mask(GL_SECONDARY_COLOR_ARRAY);
        va.attributes[vp2idx(GL_SECONDARY_COLOR_ARRAY)] = {
            .size = sizes.secondary_color_size,
            .usage = GL_SECONDARY_COLOR_ARRAY,
            .type = GL_FLOAT,
            .normalized = GL_FALSE,
            .stride = 0,
            .pointer = (const void*)offset,
        };
        offset += sizes.secondary_color_size * sizeof(GLfloat);
    }

    // texcoord
    for (GLint i = 0; i < MAX_TEX; ++i) {
        if (sizes.texcoord_size[i] > 0) {
            // TODO: fix vp_mask()/vp2idx(), make it adapt to here
            va.enabled_pointers |= (1 << (7 + i));
            va.attributes[7 + i] = {
                .size = sizes.texcoord_size[i],
                .usage = GL_TEXTURE_COORD_ARRAY,
                .type = GL_FLOAT,
                .normalized = GL_FALSE,
                .stride = 0,
                .pointer = (const void*)offset,
                //                    .varying = true
            };
            offset += sizes.texcoord_size[i] * sizeof(GLfloat);
        }
    }

    va.stride = (GLsizei)offset;
}
