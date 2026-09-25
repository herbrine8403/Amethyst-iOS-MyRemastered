// SimpleFPEWrapper - SimpleFPEWrapper/shader/userprogram.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

// plans/09 9.3 (first half): user programs whose translated shaders
// reference compatibility builtins receive the wrapper's fixed-function
// state through the injected fpe_* uniforms. Locations are resolved
// lazily per program and values are re-fed before every passthrough draw
// with cheap change detection.

#include "../init.h"
#include "../log.h"
#include "../fpe/fpe.hpp"
#include "../fpe/transformation.h"

#include <glm/gtc/matrix_inverse.hpp>
#include <glm/gtc/type_ptr.hpp>
#include <cmath>
#include <cstring>
#include <mutex>
#include <unordered_map>

namespace {

struct user_program_uniforms_t {
    bool resolved = false;
    bool any = false;
    GLint model_view = -1, projection = -1, mvp = -1, normal = -1;
    GLint model_view_inverse = -1, projection_inverse = -1;
    GLint texture_matrix = -1; // array location (element 0)
    GLint front_ambient = -1, front_diffuse = -1, front_specular = -1, front_emission = -1,
          front_shininess = -1;
    GLint fog_color = -1, fog_density = -1, fog_start = -1, fog_end = -1, fog_scale = -1;
    GLint light_model_ambient = -1;
    GLint back_ambient = -1, back_diffuse = -1, back_specular = -1, back_emission = -1,
          back_shininess = -1;
    // Emulated alpha test (GL 2.1 per-fragment op; absent from GLES).
    GLint alpha_test_func = -1, alpha_test_ref = -1;
    GLint light_ambient[MAX_LIGHTS], light_diffuse[MAX_LIGHTS], light_specular[MAX_LIGHTS],
        light_position[MAX_LIGHTS], light_half_vector[MAX_LIGHTS], light_spot_direction[MAX_LIGHTS],
        light_spot_exponent[MAX_LIGHTS], light_spot_cutoff[MAX_LIGHTS],
        light_spot_cos_cutoff[MAX_LIGHTS], light_const_atten[MAX_LIGHTS],
        light_linear_atten[MAX_LIGHTS], light_quadratic_atten[MAX_LIGHTS];
    // fpe_* attribute locations, slot-indexed like vertex_pointer_array_t
    // (plans/09 S9: fixed-function arrays feed the user program's inputs).
    bool attrs_resolved = false;
    GLint attr_locations[VERTEX_POINTER_COUNT];
    // change-detection mirrors
    glm::mat4 last_mv{0.0f}, last_proj{0.0f};

    // Last value sent for every scalar/vec4 uniform, so an unchanged one costs
    // a compare instead of a driver call. Legacy fixed-function state barely
    // moves between draws while this function ran unconditionally, and a
    // translated app shader resolves only a couple of these:
    // 1.16-Sodium/1-frame5312.rdc re-sent the same alpha-test pair on 602 of
    // 607 draws - together 27.6% of that frame's GL calls.
    //
    // Only uniforms the program actually declares are ever compared, so the
    // per-draw cost is proportional to what the shader uses, not to the size
    // of the fixed-function state.
    enum : int {
        SLOT_FRONT_AMBIENT, SLOT_FRONT_DIFFUSE, SLOT_FRONT_SPECULAR, SLOT_FRONT_EMISSION,
        SLOT_FRONT_SHININESS,
        SLOT_BACK_AMBIENT, SLOT_BACK_DIFFUSE, SLOT_BACK_SPECULAR, SLOT_BACK_EMISSION,
        SLOT_BACK_SHININESS,
        SLOT_FOG_COLOR, SLOT_FOG_DENSITY, SLOT_FOG_START, SLOT_FOG_END, SLOT_FOG_SCALE,
        SLOT_LIGHT_MODEL_AMBIENT,
        SLOT_ALPHA_FUNC, SLOT_ALPHA_REF,
        SLOT_LIGHT_BASE,
        SLOT_PER_LIGHT = 12,
        SLOT_COUNT = SLOT_LIGHT_BASE + MAX_LIGHTS * SLOT_PER_LIGHT,
    };
    glm::vec4 last_uniform[SLOT_COUNT];
    bool last_uniform_valid[SLOT_COUNT] = {};
};

std::mutex g_user_program_mutex;
std::unordered_map<GLuint, user_program_uniforms_t>& userPrograms() {
    static std::unordered_map<GLuint, user_program_uniforms_t> programs;
    return programs;
}

void resolve(GLuint program, user_program_uniforms_t& u) {
    u.resolved = true;
    if (g_glFuncs.glGetUniformLocation == nullptr) return;
    const auto loc = [&](const char* name) { return g_glFuncs.glGetUniformLocation(program, name); };
    u.model_view = loc("fpe_ModelViewMatrix");
    u.projection = loc("fpe_ProjectionMatrix");
    u.mvp = loc("fpe_ModelViewProjectionMatrix");
    u.normal = loc("fpe_NormalMatrix");
    u.model_view_inverse = loc("fpe_ModelViewMatrixInverse");
    u.projection_inverse = loc("fpe_ProjectionMatrixInverse");
    u.texture_matrix = loc("fpe_TextureMatrix[0]");
    u.front_ambient = loc("fpe_FrontMaterial.ambient");
    u.front_diffuse = loc("fpe_FrontMaterial.diffuse");
    u.front_specular = loc("fpe_FrontMaterial.specular");
    u.front_emission = loc("fpe_FrontMaterial.emission");
    u.front_shininess = loc("fpe_FrontMaterial.shininess");
    u.fog_color = loc("fpe_Fog.color");
    u.fog_density = loc("fpe_Fog.density");
    u.fog_start = loc("fpe_Fog.start");
    u.fog_end = loc("fpe_Fog.end");
    u.fog_scale = loc("fpe_Fog.scale");
    u.light_model_ambient = loc("fpe_LightModel.ambient");
    u.back_ambient = loc("fpe_BackMaterial.ambient");
    u.back_diffuse = loc("fpe_BackMaterial.diffuse");
    u.back_specular = loc("fpe_BackMaterial.specular");
    u.back_emission = loc("fpe_BackMaterial.emission");
    u.back_shininess = loc("fpe_BackMaterial.shininess");
    u.alpha_test_func = loc("fpe_AlphaTestFunc");
    u.alpha_test_ref = loc("fpe_AlphaTestRef");
    char name[64];
    const auto light_loc = [&](int i, const char* field) {
        std::snprintf(name, sizeof(name), "fpe_LightSource[%d].%s", i, field);
        return loc(name);
    };
    for (int i = 0; i < MAX_LIGHTS; ++i) {
        u.light_ambient[i] = light_loc(i, "ambient");
        u.light_diffuse[i] = light_loc(i, "diffuse");
        u.light_specular[i] = light_loc(i, "specular");
        u.light_position[i] = light_loc(i, "position");
        u.light_half_vector[i] = light_loc(i, "halfVector");
        u.light_spot_direction[i] = light_loc(i, "spotDirection");
        u.light_spot_exponent[i] = light_loc(i, "spotExponent");
        u.light_spot_cutoff[i] = light_loc(i, "spotCutoff");
        u.light_spot_cos_cutoff[i] = light_loc(i, "spotCosCutoff");
        u.light_const_atten[i] = light_loc(i, "constantAttenuation");
        u.light_linear_atten[i] = light_loc(i, "linearAttenuation");
        u.light_quadratic_atten[i] = light_loc(i, "quadraticAttenuation");
    }
    u.any = u.model_view >= 0 || u.projection >= 0 || u.mvp >= 0 || u.normal >= 0 ||
            u.texture_matrix >= 0 || u.front_ambient >= 0 || u.back_ambient >= 0 ||
            u.fog_color >= 0 || u.light_model_ambient >= 0 || u.alpha_test_func >= 0;
    for (int i = 0; i < MAX_LIGHTS && !u.any; ++i)
        u.any = u.light_ambient[i] >= 0 || u.light_diffuse[i] >= 0 || u.light_position[i] >= 0 ||
                u.light_const_atten[i] >= 0 || u.light_spot_direction[i] >= 0;
}

// Bytes one element of an application-declared array occupies, for stepping
// past base_vertex rows when the array has no explicit stride. The packed
// 10/10/10/2 types are one 32-bit word whatever the declared size says.
size_t appAttribElementBytes(const app_vertex_attrib_array_t& attribute) {
    if (attribute.type == GL_UNSIGNED_INT_2_10_10_10_REV ||
        attribute.type == GL_INT_2_10_10_10_REV) {
        return 4u;
    }
    const GLsizei component = type_size(attribute.type);
    if (component <= 0) return 0u;
    const GLint components = attribute.size == (GLint)GL_BGRA ? 4 : attribute.size;
    if (components <= 0) return 0u;
    return static_cast<size_t>(component) * static_cast<size_t>(components);
}

// Replays the app's own generic attribute arrays into fpe_user_vao. Returns
// the mask of locations it enabled, which the caller folds into its own so
// the stale sweep treats them like any other.
//
// Locations the fixed-function attributes already claimed are skipped: the
// linker cannot assign two active attributes the same location, so this only
// fires if a program somehow declares both, and in that case the
// fixed-function feed is the one this whole path exists for.
uint64_t mirrorAppAttribArrays(const GLint locations[VERTEX_POINTER_COUNT],
                               const user_program_array_mirror_t& mirror) {
    auto& gs = g_glstate_c;
    if (!gs.app_attrib_arrays_used) return 0;
    const auto found = gs.app_attrib_arrays.find(sfpewLogicalVertexArrayBinding());
    if (found == gs.app_attrib_arrays.end() || found->second.enabled_mask == 0) return 0;
    const auto& record = found->second;

    uint64_t claimed = 0;
    for (int i = 0; i < VERTEX_POINTER_COUNT; ++i) {
        if (locations[i] >= 0 && locations[i] < 64) claimed |= 1ull << locations[i];
    }

    auto& st = gs.fpe_state;
    uint64_t enabled_now = 0;
    GLuint bound_buffer = mirror.source_buffer;
    for (int index = 0; index < SFPEW_TRACKED_VERTEX_ATTRIBS; ++index) {
        if (((record.enabled_mask >> index) & 1u) == 0u) continue;
        if ((claimed >> index) & 1ull) continue;
        const auto& attribute = record.attribs[index];
        if (!attribute.declared) continue;
        // Falling back to the float form would silently convert what the
        // shader declared as an integer input, which is worse than the
        // constant. Unreachable in practice: the recording entry point
        // returns early without this same pointer.
        if (attribute.integer && g_glFuncs.glVertexAttribIPointer == nullptr) continue;
        if (attribute.buffer == 0) {
            // A client-memory generic array cannot be replayed: GLES 3 and
            // desktop core both reject a client pointer while a VAO is bound,
            // and re-uploading it needs a vertex extent this call does not
            // have. Said once - a renderer built this way does it every frame.
            static bool warned = false;
            if (!warned) {
                warned = true;
                SFPEW_LOGW("generic vertex attribute array %d is client memory; a user program "
                           "fed by the fixed-function arrays cannot consume it and will read the "
                           "constant current value instead", index);
            }
            continue;
        }
        const void* pointer = attribute.pointer;
        if (mirror.base_vertex > 0) {
            const size_t step = attribute.stride > 0 ? static_cast<size_t>(attribute.stride)
                                                     : appAttribElementBytes(attribute);
            if (step == 0) continue; // unusable declaration; leave the constant
            pointer = reinterpret_cast<const void*>(reinterpret_cast<uintptr_t>(pointer) +
                                                    static_cast<uintptr_t>(mirror.base_vertex) *
                                                        step);
        }
        if (bound_buffer != attribute.buffer) {
            g_glFuncs.glBindBuffer(GL_ARRAY_BUFFER, attribute.buffer);
            bound_buffer = attribute.buffer;
        }
        if (attribute.integer) {
            g_glFuncs.glVertexAttribIPointer((GLuint)index, attribute.size, attribute.type,
                                             attribute.stride, pointer);
        } else {
            g_glFuncs.glVertexAttribPointer((GLuint)index, attribute.size, attribute.type,
                                            (GLboolean)(attribute.normalized ? GL_TRUE : GL_FALSE),
                                            attribute.stride, pointer);
        }
        if (((st.fpe_user_vao_enabled >> index) & 1ull) == 0ull)
            g_glFuncs.glEnableVertexAttribArray((GLuint)index);
        enabled_now |= 1ull << index;
    }
    if (bound_buffer != mirror.source_buffer)
        g_glFuncs.glBindBuffer(GL_ARRAY_BUFFER, mirror.source_buffer);
    return enabled_now;
}

} // namespace

void sfpewForgetUserProgram(GLuint program) {
    std::lock_guard<std::mutex> lock(g_user_program_mutex);
    userPrograms().erase(program);
}

// Slot layout mirrors vp2idx(): 0 vertex, 1 normal, 2 color, 3 index,
// 4 edge flag, 5 fog coord, 6 secondary color, 7+u texcoord unit u.
// True when the program has EXACTLY ONE non-builtin active attribute AND that
// attribute sits at location 0. A shader with multiple attributes manages its
// own vertex state (it pairs with its own VAO/VBO) and must not be fed by the
// fixed-function vertex arrays. The one-attribute restriction catches the
// MC 1.16 PostPass/blit shape ("in vec4 Position;" only) while leaving
// OptiFine's world shader (position + color + texcoord + ...) untouched.
bool programIsSingleAttribAtLocationZero(GLuint program) {
    if (g_glFuncs.glGetProgramiv == nullptr || g_glFuncs.glGetActiveAttrib == nullptr ||
        g_glFuncs.glGetAttribLocation == nullptr) {
        return false;
    }
    GLint count = 0;
    g_glFuncs.glGetProgramiv(program, GL_ACTIVE_ATTRIBUTES, &count);
    if (count <= 0) return false;
    GLint max_len = 0;
    g_glFuncs.glGetProgramiv(program, GL_ACTIVE_ATTRIBUTE_MAX_LENGTH, &max_len);
    if (max_len <= 0) max_len = 128;
    std::vector<char> name(static_cast<size_t>(max_len) + 1u);
    int non_builtin = 0;
    bool has_loc0 = false;
    for (GLint i = 0; i < count; ++i) {
        GLint size = 0;
        GLenum type = 0;
        GLsizei written = 0;
        name[0] = '\0';
        g_glFuncs.glGetActiveAttrib(program, static_cast<GLuint>(i), max_len, &written, &size, &type,
                                    name.data());
        if (written <= 0) continue;
        name[static_cast<size_t>(written)] = '\0';
        if (std::strncmp(name.data(), "gl_", 3) == 0) continue;
        ++non_builtin;
        if (g_glFuncs.glGetAttribLocation(program, name.data()) == 0) has_loc0 = true;
    }
    return non_builtin == 1 && has_loc0;
}

bool sfpewUserProgramAttribLocations(GLuint program, GLint out_locations[VERTEX_POINTER_COUNT]) {
    if (program == 0 || g_glFuncs.glGetAttribLocation == nullptr) return false;
    // Defense in depth for the self-adoption guards: a program the wrapper
    // itself created must never be treated as an app shader to feed - if one
    // reaches here through any yet-unknown shadow-poisoning window, routing
    // fixed-function draws onto it drops program binds, uploads and uniforms
    // wholesale (the on-device flicker). Cached below per program, so this
    // costs one set lookup on first resolve only.
    if (g_glstate_c.internal_programs.count(static_cast<int>(program)) != 0) return false;
    std::lock_guard<std::mutex> lock(g_user_program_mutex);
    auto& u = userPrograms()[program];
    if (!u.attrs_resolved) {
        for (int i = 0; i < VERTEX_POINTER_COUNT; ++i) u.attr_locations[i] = -1;
        u.attr_locations[0] = g_glFuncs.glGetAttribLocation(program, "fpe_Vertex");
        u.attr_locations[1] = g_glFuncs.glGetAttribLocation(program, "fpe_Normal");
        u.attr_locations[2] = g_glFuncs.glGetAttribLocation(program, "fpe_Color");
        u.attr_locations[5] = g_glFuncs.glGetAttribLocation(program, "fpe_FogCoord");
        u.attr_locations[6] = g_glFuncs.glGetAttribLocation(program, "fpe_SecondaryColor");
        char name[32];
        for (int unit = 0; unit + 7 < VERTEX_POINTER_COUNT; ++unit) {
            std::snprintf(name, sizeof(name), "fpe_MultiTexCoord%d", unit);
            u.attr_locations[7 + unit] = g_glFuncs.glGetAttribLocation(program, name);
        }

        // GL 2.1 aliases generic attribute 0 with gl_Vertex, so a shader that
        // declares its OWN position input and expects glVertexPointer to feed it
        // is legal and works on desktop GL. Minecraft's post/composite shaders
        // are exactly that shape ("in vec4 Position;" and nothing else): no
        // gl_Vertex for the translator to rename, hence no fpe_Vertex to find.
        // Without this fallback the draw took the raw passthrough, which handed
        // GL_QUADS to a GLES backend with nothing bound to Position - every
        // vertex read the default (0,0,0,1) and the whole quad collapsed to one
        // point (RenderDoc, 1.16 fabulous, EID 1844).
        if (u.attr_locations[0] < 0 && programIsSingleAttribAtLocationZero(program))
            u.attr_locations[0] = 0;

        u.attrs_resolved = true;
    }
    std::memcpy(out_locations, u.attr_locations, sizeof(u.attr_locations));
    // Without a position input the program does not consume fixed-function
    // vertex data at all (e.g. piglit-style tests feeding attribs directly).
    return u.attr_locations[0] >= 0;
}

// Submits the normalized array layout onto the user program's attribute
// locations. Caller has fpe_user_vao + the source buffer bound; the mask
// in fpe_state tracks which locations stay enabled between draws.
void sfpewSendUserProgramAttributes(const GLint locations[VERTEX_POINTER_COUNT],
                                    const vertex_pointer_array_t& va, GLintptr binding_offset,
                                    const user_program_array_mirror_t& mirror) {
    auto& st = g_glstate.fpe_state;
    const auto& cur = st.fpe_draw.current_data;
    uint64_t enabled_now = 0;
#ifdef SFPEW_DEBUG_USERATTRIBS
    fprintf(stderr, "[userattribs] enabled_pointers=0x%x stride=%d prev_mask=0x%llx\n",
            va.enabled_pointers, va.stride, (unsigned long long)st.fpe_user_vao_enabled);
#endif
    for (int i = 0; i < VERTEX_POINTER_COUNT; ++i) {
        const GLint loc = locations[i];
        if (loc < 0 || loc >= 64) continue;
        const bool array_on = ((va.enabled_pointers >> i) & 1u) != 0;
        if (array_on) {
            const auto& vp = va.attributes[i];
            const void* pointer = reinterpret_cast<const void*>(
                reinterpret_cast<uintptr_t>(vp.pointer) + static_cast<uintptr_t>(binding_offset));
            // Per-attribute vp.stride, not the struct-level va.stride: after
            // normalize()/gather_client_arrays the two always agree (both
            // force every enabled attribute to one shared value), but a
            // single_buffer draw (plans/13 13.3) now passes raw_vpa straight
            // through - only vp.stride, set directly by its own gl*Pointer
            // call, is populated there. va.stride would silently be 0 for
            // every such draw, sending every attribute as tightly packed.
            g_glFuncs.glVertexAttribPointer((GLuint)loc, vp.size, vp.type,
                                            (GLboolean)(vp.normalized != 0), vp.stride, pointer);
            // Enable state is per-VAO and persists; fpe_user_vao is wrapper-
            // owned, so the mask is authoritative and a re-enable is a no-op.
            // The pointer above still has to be re-sent every draw: it bakes
            // the currently bound ARRAY_BUFFER into the VAO, and that buffer
            // changes per draw even when the format is identical.
            if (((st.fpe_user_vao_enabled >> loc) & 1ull) == 0ull)
                g_glFuncs.glEnableVertexAttribArray((GLuint)loc);
#ifdef SFPEW_DEBUG_USERATTRIBS
            fprintf(stderr, "[userattribs] slot %d -> loc %d size=%d type=0x%x stride=%d ptr=%p\n",
                    i, loc, vp.size, vp.type, va.stride, pointer);
#endif
            enabled_now |= 1ull << loc;
            continue;
        }
        // Array disabled but the program reads the input: legacy current-
        // value semantics (glColor4f/glNormal3f/glTexCoord2f between draws).
        if ((st.fpe_user_vao_enabled >> loc) & 1ull)
            g_glFuncs.glDisableVertexAttribArray((GLuint)loc);
        switch (i) {
        case 1:
            g_glFuncs.glVertexAttrib4f((GLuint)loc, cur.normal.x, cur.normal.y, cur.normal.z, 0.0f);
            break;
        case 2:
            g_glFuncs.glVertexAttrib4fv((GLuint)loc, glm::value_ptr(cur.color));
            break;
        default:
            if (i >= 7) {
                g_glFuncs.glVertexAttrib4fv((GLuint)loc, glm::value_ptr(cur.texcoord[i - 7]));
            } else {
                g_glFuncs.glVertexAttrib4f((GLuint)loc, 0.0f, 0.0f, 0.0f, 1.0f);
            }
            break;
        }
    }
    // The app's own generic attribute arrays live in ITS vao, which this one
    // replaced; without replaying them the shader reads the constant current
    // value for every input the fixed-function slots do not cover (plans/16
    // H6, the OptiFine mc_Entity shape).
    if (mirror.active) enabled_now |= mirrorAppAttribArrays(locations, mirror);

    // Disable locations left over from a previous layout in this VAO.
    uint64_t stale = st.fpe_user_vao_enabled & ~enabled_now;
    for (int loc = 0; loc < 64; ++loc) {
        if ((stale >> loc) & 1ull) g_glFuncs.glDisableVertexAttribArray((GLuint)loc);
    }
    st.fpe_user_vao_enabled = enabled_now;
}

// Called before passthrough draws while a user program is current.
void sfpewFeedUserProgramUniforms(GLuint program) {
    if (program == 0 || g_glFuncs.glUniformMatrix4fv == nullptr || g_glFuncs.glUniform4fv == nullptr)
        return;

    user_program_uniforms_t* u;
    {
        std::lock_guard<std::mutex> lock(g_user_program_mutex);
        u = &userPrograms()[program];
        if (!u->resolved) resolve(program, *u);
    }
    if (!u->any) return;

    using U = user_program_uniforms_t;
    const auto& un = g_glstate.fpe_uniform;
    const auto& mv = un.transformation.matrices[matrix_idx(GL_MODELVIEW)];
    const auto& proj = un.transformation.matrices[matrix_idx(GL_PROJECTION)];
    const bool mv_changed = std::memcmp(&mv, &u->last_mv, sizeof(mv)) != 0;
    const bool proj_changed = std::memcmp(&proj, &u->last_proj, sizeof(proj)) != 0;

    if (mv_changed) {
        if (u->model_view >= 0) g_glFuncs.glUniformMatrix4fv(u->model_view, 1, GL_FALSE, glm::value_ptr(mv));
        if (u->normal >= 0) {
            const glm::mat3 normal_matrix = glm::inverseTranspose(glm::mat3(mv));
            g_glFuncs.glUniformMatrix3fv(u->normal, 1, GL_FALSE, glm::value_ptr(normal_matrix));
        }
        if (u->model_view_inverse >= 0) {
            const glm::mat4 inv = glm::inverse(mv);
            g_glFuncs.glUniformMatrix4fv(u->model_view_inverse, 1, GL_FALSE, glm::value_ptr(inv));
        }
        u->last_mv = mv;
    }
    if (proj_changed) {
        if (u->projection >= 0) g_glFuncs.glUniformMatrix4fv(u->projection, 1, GL_FALSE, glm::value_ptr(proj));
        if (u->projection_inverse >= 0) {
            const glm::mat4 inv = glm::inverse(proj);
            g_glFuncs.glUniformMatrix4fv(u->projection_inverse, 1, GL_FALSE, glm::value_ptr(inv));
        }
        u->last_proj = proj;
    }
    if ((mv_changed || proj_changed) && u->mvp >= 0) {
        const glm::mat4 mvp = proj * mv;
        g_glFuncs.glUniformMatrix4fv(u->mvp, 1, GL_FALSE, glm::value_ptr(mvp));
    }

    if (u->texture_matrix >= 0) {
        // 8 matrices in one call; drivers accept partial arrays.
        g_glFuncs.glUniformMatrix4fv(u->texture_matrix, 8, GL_FALSE,
                                     glm::value_ptr(un.transformation.texture_matrices[0]));
    }

    // Send only on change. The cache is keyed by slot rather than by location
    // so a program that does not declare a uniform never touches it.
    const auto changed = [&](int slot, const glm::vec4& value) {
        if (u->last_uniform_valid[slot] && u->last_uniform[slot] == value) return false;
        u->last_uniform[slot] = value;
        u->last_uniform_valid[slot] = true;
        return true;
    };
    const auto send4fv = [&](GLint loc, int slot, const glm::vec4& value) {
        if (loc >= 0 && changed(slot, value)) g_glFuncs.glUniform4fv(loc, 1, glm::value_ptr(value));
    };
    const auto send3fv = [&](GLint loc, int slot, const glm::vec3& value) {
        if (loc >= 0 && changed(slot, glm::vec4(value, 0.0f)))
            g_glFuncs.glUniform3fv(loc, 1, glm::value_ptr(value));
    };
    const auto send1f = [&](GLint loc, int slot, GLfloat value) {
        if (loc >= 0 && changed(slot, glm::vec4(value, 0.0f, 0.0f, 0.0f)))
            g_glFuncs.glUniform1f(loc, value);
    };
    const auto send1i = [&](GLint loc, int slot, GLint value) {
        if (loc >= 0 && changed(slot, glm::vec4((float)value, 0.0f, 0.0f, 0.0f)))
            g_glFuncs.glUniform1i(loc, value);
    };

    const auto& mat = un.materials[0];
    send4fv(u->front_ambient, U::SLOT_FRONT_AMBIENT, mat.ambient);
    send4fv(u->front_diffuse, U::SLOT_FRONT_DIFFUSE, mat.diffuse);
    send4fv(u->front_specular, U::SLOT_FRONT_SPECULAR, mat.specular);
    send4fv(u->front_emission, U::SLOT_FRONT_EMISSION, mat.emission);
    send1f(u->front_shininess, U::SLOT_FRONT_SHININESS, mat.shininess);

    send4fv(u->fog_color, U::SLOT_FOG_COLOR, un.fog_color);
    send1f(u->fog_density, U::SLOT_FOG_DENSITY, un.fog_density);
    send1f(u->fog_start, U::SLOT_FOG_START, un.fog_start);
    send1f(u->fog_end, U::SLOT_FOG_END, un.fog_end);
    if (u->fog_scale >= 0) {
        const float span = un.fog_end - un.fog_start;
        send1f(u->fog_scale, U::SLOT_FOG_SCALE, span != 0.0f ? 1.0f / span : 1.0f);
    }
    send4fv(u->light_model_ambient, U::SLOT_LIGHT_MODEL_AMBIENT, un.light_model_ambient);

    // The generated main() reads these; func 0 means "test disabled" so a
    // GL_ALWAYS state and a disabled state both skip the branch cheaply.
    if (u->alpha_test_func >= 0) {
        const GLint func = g_glstate.fpe_state.fpe_bools.alpha_test_enable
                               ? (GLint)g_glstate.fpe_state.alpha_func
                               : 0;
        send1i(u->alpha_test_func, U::SLOT_ALPHA_FUNC, func == GL_ALWAYS ? 0 : func);
    }
    send1f(u->alpha_test_ref, U::SLOT_ALPHA_REF, un.alpha_ref);

    const auto& back = un.materials[1];
    send4fv(u->back_ambient, U::SLOT_BACK_AMBIENT, back.ambient);
    send4fv(u->back_diffuse, U::SLOT_BACK_DIFFUSE, back.diffuse);
    send4fv(u->back_specular, U::SLOT_BACK_SPECULAR, back.specular);
    send4fv(u->back_emission, U::SLOT_BACK_EMISSION, back.emission);
    send1f(u->back_shininess, U::SLOT_BACK_SHININESS, back.shininess);

    for (int i = 0; i < MAX_LIGHTS; ++i) {
        const auto& light = un.lights[i];
        const int base = U::SLOT_LIGHT_BASE + i * U::SLOT_PER_LIGHT;
        send4fv(u->light_ambient[i], base + 0, light.ambient);
        send4fv(u->light_diffuse[i], base + 1, light.diffuse);
        send4fv(u->light_specular[i], base + 2, light.specular);
        send4fv(u->light_position[i], base + 3, light.position);
        if (u->light_half_vector[i] >= 0) {
            // Infinite-viewer half vector of legacy lighting: only exact for
            // directional lights, which is the case gl_LightSource.halfVector
            // is specified for.
            const glm::vec3 to_light = glm::normalize(glm::vec3(light.position));
            const glm::vec3 half = glm::normalize(to_light + glm::vec3(0.0f, 0.0f, 1.0f));
            send4fv(u->light_half_vector[i], base + 4, glm::vec4(half, 1.0f));
        }
        send3fv(u->light_spot_direction[i], base + 5, light.spot_direction);
        send1f(u->light_spot_exponent[i], base + 6, light.spot_exp);
        send1f(u->light_spot_cutoff[i], base + 7, light.spot_cutoff);
        if (u->light_spot_cos_cutoff[i] >= 0) {
            send1f(u->light_spot_cos_cutoff[i], base + 8,
                   light.spot_cutoff == 180.0f ? -1.0f
                                               : std::cos(glm::radians(light.spot_cutoff)));
        }
        send1f(u->light_const_atten[i], base + 9, light.constant_attenuation);
        send1f(u->light_linear_atten[i], base + 10, light.linear_attenuation);
        send1f(u->light_quadratic_atten[i], base + 11, light.quadratic_attenuation);
    }
}
