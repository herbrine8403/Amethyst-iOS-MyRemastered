// SimpleFPEWrapper - SimpleFPEWrapper/shader/translator.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

// plans/09 9.1: user GLSL 1.10/1.20 -> ESSL 3.00. The preprocessor only
// does what the toolchain cannot: rewriting compatibility-profile builtins
// (gl_Vertex, gl_ModelViewMatrix, gl_LightSource, ...) onto fpe_* symbols
// declared in an injected prelude, because gl_-prefixed names are reserved
// and cannot be #define'd. Syntax-level conversion (attribute/varying,
// gl_FragColor, texture2D, ...) is glslang's and SPIRV-Cross's job.

#include "translator.h"
#include "../log.h"
#include "../init.h"

#include <glslang/Public/ShaderLang.h>
#include <glslang/Public/ResourceLimits.h>
#include <SPIRV/GlslangToSpv.h>
#include <spirv_glsl.hpp>

#include <cctype>
#include <memory>
#include <mutex>
#include <map>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <cstdlib>
#include <cstring>
#include <algorithm>

namespace SFPEW::Shader {

namespace {

// CompilerGLSL subclass so the protected IR is reachable: GLSL 1.20
// uniform initializers survive into the SPIR-V as OpVariable initializers
// and would be re-emitted verbatim, which every ESSL dialect rejects.
// Scrape the constant values for post-link glUniform* application and
// clear the initializer before compile().
class EsslCompiler : public spirv_cross::CompilerGLSL {
public:
    using spirv_cross::CompilerGLSL::CompilerGLSL;

    // Anonymous struct types get SPIRV-Cross auto-names ("_12") whose ids
    // differ between the independently-translated stages; strict ESSL
    // linkers then reject the shared struct uniform ("struct type
    // mismatch"). Name them deterministically from their member layout so
    // both stages agree.
    void nameAnonymousStructs() {
        const auto resources = get_shader_resources();
        for (const auto& r : resources.gl_plain_uniforms) nameStructDeep(get_type(r.base_type_id));
    }

    std::vector<uniform_initializer_t> scrapeUniformInitializers() {
        std::vector<uniform_initializer_t> scraped;
        ir.for_each_typed_id<spirv_cross::SPIRVariable>(
            [&](uint32_t, spirv_cross::SPIRVariable& var) {
                if (var.storage != spv::StorageClassUniformConstant || var.initializer == 0)
                    return;
                const auto* constant =
                    maybe_get<spirv_cross::SPIRConstant>(var.initializer);
                var.initializer = spirv_cross::ID(0);
                if (constant == nullptr) return;
                emit(get_name(var.self), get_variable_data_type(var), *constant, scraped);
            });
        return scraped;
    }

private:
    void nameStructDeep(const spirv_cross::SPIRType& type) {
        if (type.basetype != spirv_cross::SPIRType::Struct) return;
        std::string layout;
        for (uint32_t m = 0; m < type.member_types.size(); ++m) {
            const auto& mt = get<spirv_cross::SPIRType>(type.member_types[m]);
            nameStructDeep(mt);
            layout += get_member_name(type.self, m) + ':' + std::to_string((int)mt.basetype) +
                      'v' + std::to_string(mt.vecsize) + 'c' + std::to_string(mt.columns);
            for (uint32_t d : mt.array) layout += 'a' + std::to_string(d);
            layout += ';';
        }
        if (get_name(type.self).empty()) {
            char buf[32];
            std::snprintf(buf, sizeof(buf), "fpe_anon_%08zx",
                          (size_t)(std::hash<std::string>{}(layout) & 0xffffffffu));
            set_name(type.self, buf);
        }
    }

    // Structs decompose into one entry per leaf member ("s.m", "s[2].m"):
    // that matches both glGetUniformLocation naming and the one-call-per-
    // member granularity of the glUniform* API.
    void emit(const std::string& name, const spirv_cross::SPIRType& type,
              const spirv_cross::SPIRConstant& c, std::vector<uniform_initializer_t>& out) {
        if (name.empty() || type.array.size() > 1) return;
        if (!type.array.empty() && !type.array_size_literal.front()) return;
        const bool is_struct = type.basetype == spirv_cross::SPIRType::Struct;
        if (!type.array.empty() && is_struct) {
            const auto& elem = get<spirv_cross::SPIRType>(type.parent_type);
            for (uint32_t i = 0; i < c.subconstants.size(); ++i) {
                const auto* sc = maybe_get<spirv_cross::SPIRConstant>(c.subconstants[i]);
                if (sc != nullptr) emit(name + "[" + std::to_string(i) + "]", elem, *sc, out);
            }
            return;
        }
        if (is_struct) {
            for (uint32_t m = 0; m < type.member_types.size() && m < c.subconstants.size(); ++m) {
                const std::string member = get_member_name(type.self, m);
                const auto* sc = maybe_get<spirv_cross::SPIRConstant>(c.subconstants[m]);
                if (member.empty() || sc == nullptr) continue;
                emit(name + "." + member, get<spirv_cross::SPIRType>(type.member_types[m]), *sc,
                     out);
            }
            return;
        }
        uniform_initializer_t init;
        switch (type.basetype) {
        case spirv_cross::SPIRType::Float:
            init.base = uniform_initializer_t::base_t::f32;
            break;
        case spirv_cross::SPIRType::Int:
            init.base = uniform_initializer_t::base_t::i32;
            break;
        case spirv_cross::SPIRType::UInt:
            init.base = uniform_initializer_t::base_t::u32;
            break;
        case spirv_cross::SPIRType::Boolean:
            init.base = uniform_initializer_t::base_t::b32;
            break;
        default:
            return; // doubles etc.: value dropped, output stays legal
        }
        init.name = name;
        init.columns = type.columns;
        init.vecsize = type.vecsize;
        init.array_size = type.array.empty() ? 1u : std::max(1u, type.array.front());
        flatten(c, type, init);
        out.push_back(std::move(init));
    }
    void flatten(const spirv_cross::SPIRConstant& c, const spirv_cross::SPIRType& type,
                 uniform_initializer_t& out) {
        if (!c.subconstants.empty()) {
            const auto& inner = get<spirv_cross::SPIRType>(type.parent_type);
            for (const auto& sub : c.subconstants) {
                const auto* sc = maybe_get<spirv_cross::SPIRConstant>(sub);
                if (sc != nullptr) flatten(*sc, inner, out);
            }
            return;
        }
        for (uint32_t col = 0; col < type.columns; ++col) {
            for (uint32_t row = 0; row < type.vecsize; ++row) {
                switch (out.base) {
                case uniform_initializer_t::base_t::f32:
                    out.f.push_back(c.scalar_f32(col, row));
                    break;
                case uniform_initializer_t::base_t::i32:
                    out.i.push_back(c.scalar_i32(col, row));
                    break;
                case uniform_initializer_t::base_t::u32:
                    out.i.push_back((int)c.scalar(col, row));
                    break;
                case uniform_initializer_t::base_t::b32:
                    out.i.push_back(c.scalar(col, row) != 0 ? 1 : 0);
                    break;
                }
            }
        }
    }
};

// Strict backends (NVIDIA C1068) refuse to compile provably out-of-bounds
// array/vector/matrix indices, while desktop GL treats them as undefined
// values - and legacy shaders rely on that. Clamp every index used in an
// OpAccessChain into range (Mesa's robustness strategy): in-bounds
// accesses are unchanged, out-of-bounds ones read/write the last element.
// Struct member indices are compile-time constants by construction and
// are never touched.
void clampAccessChainIndices(std::vector<unsigned int>& spirv) {
    if (spirv.size() <= 5) return;
    enum : uint32_t {
        OpExtInstImport = 11,
        OpExtInst = 12,
        OpTypeInt = 21,
        OpTypeVector = 23,
        OpTypeMatrix = 24,
        OpTypeArray = 28,
        OpTypeStruct = 30,
        OpTypePointer = 32,
        OpConstant = 43,
        OpFunction = 54,
        OpFunctionParameter = 55,
        OpVariable = 59,
        OpAccessChain = 65,
        OpInBoundsAccessChain = 66,
        GLSLstd450UClamp = 44,
        GLSLstd450SClamp = 45,
    };
    // Instructions that may produce an integer index; all use the standard
    // (result type, result id) word layout. Anything not listed simply
    // never gets clamped - in-bounds behavior is unaffected either way.
    const auto produces_value = [](uint32_t opcode) {
        switch (opcode) {
        case 12 /*ExtInst*/: case 57 /*FunctionCall*/: case 61 /*Load*/:
        case 77 /*VectorExtractDynamic*/: case 81 /*CompositeExtract*/:
        case 124 /*Bitcast*/: case 126 /*SNegate*/: case 128 /*IAdd*/:
        case 130 /*ISub*/: case 132 /*IMul*/: case 134 /*UDiv*/:
        case 135 /*SDiv*/: case 137 /*UMod*/: case 138 /*SRem*/:
        case 139 /*SMod*/: case 169 /*Select*/: case 194: case 195:
        case 196 /*shifts*/: case 197: case 198: case 199 /*bitwise*/:
        case 245 /*Phi*/:
            return true;
        default:
            return false;
        }
    };
    struct type_info_t {
        uint32_t opcode = 0;
        uint32_t inner = 0;   // element/component/column/pointee type
        uint32_t count = 0;   // vector size / matrix columns / array length id
        bool int_signed = false;
        std::vector<uint32_t> members; // struct member types
    };
    std::unordered_map<uint32_t, type_info_t> types;
    std::unordered_map<uint32_t, std::pair<uint32_t, uint32_t>> constants; // id -> (type, word)
    std::unordered_map<uint32_t, uint32_t> value_types; // variable/chain id -> type id
    uint32_t glsl_set = 0;

    const auto instr_at = [&](size_t off) { return spirv[off]; };
    size_t off = 5;
    std::vector<std::pair<size_t, uint32_t>> chains; // (offset, base type id)
    size_t first_function = 0;
    while (off < spirv.size()) {
        const uint32_t opcode = instr_at(off) & 0xffffu;
        const uint32_t len = instr_at(off) >> 16;
        if (len == 0 || off + len > spirv.size()) return; // malformed: leave as-is
        switch (opcode) {
        case OpExtInstImport: {
            // Operand is a string literal; glslang emits "GLSL.std.450".
            const char* name = (const char*)&spirv[off + 2];
            if (std::strncmp(name, "GLSL.std.450", 12) == 0) glsl_set = spirv[off + 1];
            break;
        }
        case OpTypeInt:
            types[spirv[off + 1]] = {opcode, 0, 0, spirv[off + 3] != 0, {}};
            break;
        case OpTypeVector:
            types[spirv[off + 1]] = {opcode, spirv[off + 2], spirv[off + 3], false, {}};
            break;
        case OpTypeMatrix:
            types[spirv[off + 1]] = {opcode, spirv[off + 2], spirv[off + 3], false, {}};
            break;
        case OpTypeArray:
            types[spirv[off + 1]] = {opcode, spirv[off + 2], spirv[off + 3], false, {}};
            break;
        case OpTypeStruct: {
            type_info_t info;
            info.opcode = opcode;
            for (uint32_t w = 2; w < len; ++w) info.members.push_back(spirv[off + w]);
            types[spirv[off + 1]] = std::move(info);
            break;
        }
        case OpTypePointer:
            types[spirv[off + 1]] = {opcode, spirv[off + 3], 0, false, {}};
            break;
        case OpConstant:
            constants[spirv[off + 2]] = {spirv[off + 1], spirv[off + 3]};
            break;
        case OpVariable:
        case OpFunctionParameter:
            value_types[spirv[off + 2]] = spirv[off + 1];
            break;
        case OpFunction:
            if (first_function == 0) first_function = off;
            value_types[spirv[off + 2]] = spirv[off + 1];
            break;
        case OpAccessChain:
        case OpInBoundsAccessChain: {
            value_types[spirv[off + 2]] = spirv[off + 1];
            auto base_type = value_types.find(spirv[off + 3]);
            if (base_type != value_types.end()) {
                auto ptr = types.find(base_type->second);
                if (ptr != types.end() && ptr->second.opcode == OpTypePointer)
                    chains.emplace_back(off, ptr->second.inner);
            }
            break;
        }
        default:
            if (produces_value(opcode) && len >= 3) value_types[spirv[off + 2]] = spirv[off + 1];
            break;
        }
        off += len;
    }
    if (glsl_set == 0 || chains.empty() || first_function == 0) return;

    // Work out which chain indices need a clamp.
    struct clamp_t {
        size_t instr_off;
        uint32_t word;      // operand slot within the instruction
        uint32_t index_id;
        uint32_t int_type;
        bool int_signed;
        uint32_t max_value;
        uint32_t result_id = 0;
    };
    std::vector<clamp_t> clamps;
    for (const auto& [chain_off, base] : chains) {
        uint32_t current = base;
        const uint32_t len = instr_at(chain_off) >> 16;
        for (uint32_t w = 4; w < len; ++w) {
            auto tit = types.find(current);
            if (tit == types.end()) break;
            const auto& t = tit->second;
            uint32_t size = 0;
            if (t.opcode == OpTypeStruct) {
                auto cit = constants.find(spirv[chain_off + w]);
                if (cit == constants.end() || cit->second.second >= t.members.size()) break;
                current = t.members[cit->second.second];
                continue;
            } else if (t.opcode == OpTypeVector || t.opcode == OpTypeMatrix) {
                size = t.count;
                current = t.inner;
            } else if (t.opcode == OpTypeArray) {
                auto cit = constants.find(t.count);
                if (cit == constants.end()) break;
                size = cit->second.second;
                current = t.inner;
            } else {
                break;
            }
            if (size == 0) break;
            const uint32_t index_id = spirv[chain_off + w];
            uint32_t int_type = 0;
            bool is_signed = false;
            auto cit = constants.find(index_id);
            if (cit != constants.end()) {
                auto it_type = types.find(cit->second.first);
                if (it_type == types.end() || it_type->second.opcode != OpTypeInt) continue;
                is_signed = it_type->second.int_signed;
                const uint32_t v = cit->second.second;
                const bool oob = is_signed ? ((int32_t)v < 0 || v >= size) : v >= size;
                if (!oob) continue; // in-range constant: leave untouched
                int_type = cit->second.first;
            } else {
                auto vt = value_types.find(index_id);
                if (vt == value_types.end()) continue;
                auto it_type = types.find(vt->second);
                if (it_type == types.end() || it_type->second.opcode != OpTypeInt) continue;
                is_signed = it_type->second.int_signed;
                int_type = vt->second;
            }
            clamps.push_back({chain_off, w, index_id, int_type, is_signed, size - 1});
        }
    }
    if (clamps.empty()) return;

    // Allocate ids: one constant per (type, value), one result per clamp.
    uint32_t bound = spirv[3];
    std::map<std::pair<uint32_t, uint32_t>, uint32_t> const_ids; // (type, value) -> id
    for (auto& c : clamps) {
        for (uint32_t v : {0u, c.max_value}) {
            if (const_ids.find({c.int_type, v}) == const_ids.end())
                const_ids[{c.int_type, v}] = bound++;
        }
        c.result_id = bound++;
    }

    std::vector<unsigned int> out;
    out.reserve(spirv.size() + clamps.size() * 8 + const_ids.size() * 4);
    out.insert(out.end(), spirv.begin(), spirv.begin() + 5);
    out[3] = bound;
    off = 5;
    while (off < spirv.size()) {
        const uint32_t len = instr_at(off) >> 16;
        if (off == first_function) {
            // All types are declared by now: emit the clamp-bound constants.
            for (const auto& [key, id] : const_ids) {
                out.push_back((4u << 16) | OpConstant);
                out.push_back(key.first);
                out.push_back(id);
                out.push_back(key.second);
            }
        }
        bool patched = false;
        for (const auto& c : clamps) {
            if (c.instr_off != off) continue;
            if (!patched) {
                // Clamp instructions go right before the access chain.
                for (const auto& c2 : clamps) {
                    if (c2.instr_off != off) continue;
                    out.push_back((8u << 16) | OpExtInst);
                    out.push_back(c2.int_type);
                    out.push_back(c2.result_id);
                    out.push_back(glsl_set);
                    out.push_back(c2.int_signed ? GLSLstd450SClamp : GLSLstd450UClamp);
                    out.push_back(c2.index_id);
                    out.push_back(const_ids[{c2.int_type, 0u}]);
                    out.push_back(const_ids[{c2.int_type, c2.max_value}]);
                }
                patched = true;
            }
        }
        const size_t instr_start = out.size();
        out.insert(out.end(), spirv.begin() + off, spirv.begin() + off + len);
        for (const auto& c : clamps) {
            if (c.instr_off == off) out[instr_start + c.word] = c.result_id;
        }
        off += len;
    }
    spirv.swap(out);
}

// Identifier replacements shared by both stages. Struct-typed builtins
// (gl_LightSource, gl_Fog, materials) map onto identically-shaped fpe_*
// structs declared in the prelude, so member accesses survive verbatim.
const std::unordered_map<std::string, std::string>& commonReplacements() {
    static const std::unordered_map<std::string, std::string> map = {
        {"gl_ModelViewMatrix", "fpe_ModelViewMatrix"},
        {"gl_ProjectionMatrix", "fpe_ProjectionMatrix"},
        {"gl_ModelViewProjectionMatrix", "fpe_ModelViewProjectionMatrix"},
        {"gl_NormalMatrix", "fpe_NormalMatrix"},
        {"gl_ModelViewMatrixInverse", "fpe_ModelViewMatrixInverse"},
        {"gl_ProjectionMatrixInverse", "fpe_ProjectionMatrixInverse"},
        {"gl_TextureMatrix", "fpe_TextureMatrix"},
        {"gl_LightSource", "fpe_LightSource"},
        {"gl_LightModel", "fpe_LightModel"},
        {"gl_FrontMaterial", "fpe_FrontMaterial"},
        {"gl_BackMaterial", "fpe_BackMaterial"},
        {"gl_Fog", "fpe_Fog"},
        {"gl_ClipPlane", "fpe_ClipPlane"},
        {"gl_TexCoord", "fpe_TexCoord"},
        {"gl_FogFragCoord", "fpe_FogFragCoord"},
        {"gl_NormalScale", "fpe_NormalScale"},
        // The struct TYPE names are user-referencable too (e.g. as function
        // parameter types) and must follow their instances into the prelude.
        {"gl_LightSourceParameters", "fpe_LightSourceParameters"},
        {"gl_LightModelParameters", "fpe_LightModelParameters"},
        {"gl_MaterialParameters", "fpe_MaterialParameters"},
        {"gl_FogParameters", "fpe_FogParameters"},
        // Legacy sampler builtins vanished from core profiles; the modern
        // overload set accepts the same argument shapes.
        {"texture1D", "texture"},
        {"texture2D", "texture"},
        {"texture3D", "texture"},
        {"textureCube", "texture"},
        {"shadow1D", "fpe_shadow2D"}, // 1D lives as 2D height-1 here
        {"shadow2D", "fpe_shadow2D"},
        {"texture1DProj", "textureProj"},
        {"texture2DProj", "textureProj"},
        {"texture3DProj", "textureProj"},
        {"shadow1DProj", "fpe_shadow2DProj"},
        {"shadow2DProj", "fpe_shadow2DProj"},
        {"texture1DLod", "textureLod"},
        {"texture2DLod", "textureLod"},
        {"texture3DLod", "textureLod"},
        {"textureCubeLod", "textureLod"},
        {"texture1DProjLod", "textureProjLod"},
        {"texture2DProjLod", "textureProjLod"},
        {"texture3DProjLod", "textureProjLod"},
        // GL_EXT_gpu_shader4 spellings (ShadersMod-era packs).
        {"texelFetch1D", "texelFetch"},
        {"texelFetch2D", "texelFetch"},
        {"texelFetch3D", "texelFetch"},
        {"textureSize1D", "textureSize"},
        {"textureSize2D", "textureSize"},
        {"textureSize3D", "textureSize"},
    };
    return map;
}

const std::unordered_map<std::string, std::string>& vertexReplacements() {
    static const std::unordered_map<std::string, std::string> map = {
        {"gl_Vertex", "fpe_Vertex"},
        {"gl_Normal", "fpe_Normal"},
        {"gl_Color", "fpe_Color"},
        {"gl_SecondaryColor", "fpe_SecondaryColor"},
        {"gl_FogCoord", "fpe_FogCoord"},
        {"gl_MultiTexCoord0", "fpe_MultiTexCoord0"},
        {"gl_MultiTexCoord1", "fpe_MultiTexCoord1"},
        {"gl_MultiTexCoord2", "fpe_MultiTexCoord2"},
        {"gl_MultiTexCoord3", "fpe_MultiTexCoord3"},
        {"gl_MultiTexCoord4", "fpe_MultiTexCoord4"},
        {"gl_MultiTexCoord5", "fpe_MultiTexCoord5"},
        {"gl_MultiTexCoord6", "fpe_MultiTexCoord6"},
        {"gl_MultiTexCoord7", "fpe_MultiTexCoord7"},
        {"gl_FrontColor", "fpe_FrontColor"},
        {"gl_BackColor", "fpe_BackColor"},
        {"gl_FrontSecondaryColor", "fpe_FrontSecondaryColor"},
        {"gl_BackSecondaryColor", "fpe_BackSecondaryColor"},
        {"attribute", "in"},
        {"varying", "out"},
    };
    return map;
}

const std::unordered_map<std::string, std::string>& fragmentReplacements() {
    // In a fragment shader gl_Color/gl_SecondaryColor are the interpolated
    // varyings, not the vertex attributes: same names, different symbols.
    static const std::unordered_map<std::string, std::string> map = {
        {"gl_Color", "fpe_FrontColor"},
        {"gl_SecondaryColor", "fpe_FrontSecondaryColor"},
        // Writing gl_FragColor is not expressible in SPIR-V; route the
        // output through our own out variable.
        {"gl_FragColor", "fpe_FragColor"},
        {"gl_FragData", "fpe_FragData"},
        {"varying", "in"},
        // GLSL 1.20 allows `invariant varying` in the fragment stage;
        // modern GLSL restricts invariant to outputs. Dropping the
        // qualifier only weakens an optimization barrier.
        {"invariant", ""},
    };
    return map;
}

// In GLSL 1.10/1.20 these are ordinary identifiers (non-square matrix
// types arrived in 1.20, precision qualifiers in 1.30), but 450 treats
// them as keywords. Only applied as a RETRY when the plain parse fails:
// real-world sources freely mix versions (Mesa is permissive), so a
// shader claiming 110 may still use mat2x3 as a type.
const std::unordered_map<std::string, std::string>& legacyIdentifierReplacements() {
    static const std::unordered_map<std::string, std::string> map = {
        {"mat2x2", "fpe_id_mat2x2"}, {"mat2x3", "fpe_id_mat2x3"}, {"mat2x4", "fpe_id_mat2x4"},
        {"mat3x2", "fpe_id_mat3x2"}, {"mat3x3", "fpe_id_mat3x3"}, {"mat3x4", "fpe_id_mat3x4"},
        {"mat4x2", "fpe_id_mat4x2"}, {"mat4x3", "fpe_id_mat4x3"}, {"mat4x4", "fpe_id_mat4x4"},
        {"lowp", "fpe_id_lowp"},     {"mediump", "fpe_id_mediump"},
        {"highp", "fpe_id_highp"},   {"precision", "fpe_id_precision"},
        // Keywords GLSL grew after 1.20 that legacy sources use as plain
        // identifiers. `sample` (a 4.00 qualifier) appears as a variable
        // name in real shader packs - caught on device by the translation
        // failure "syntax error, unexpected SAMPLE".
        {"sample", "fpe_id_sample"},   {"patch", "fpe_id_patch"},
        {"subroutine", "fpe_id_subroutine"},
        {"smooth", "fpe_id_smooth_kw"}, {"flat", "fpe_id_flat_kw"},
        {"noperspective", "fpe_id_noperspective"},
    };
    return map;
}

// OptiFine shader packs of EVERY era declare `uniform sampler2D texture;`
// (real drivers let a variable shadow the builtin even in #version 400
// compatibility), which collides with the modern sampling function that
// texture2D() rewrites into. Applied as its own retry layer with no
// version gate: a shader that legitimately CALLS texture() simply fails
// this attempt and keeps the plain translation's diagnostics.
const std::unordered_map<std::string, std::string>& samplerShadowingReplacements() {
    static const std::unordered_map<std::string, std::string> map = {
        {"texture", "fpe_id_texture"},
        {"textureProj", "fpe_id_textureProj"},
        {"textureLod", "fpe_id_textureLod"},
        {"textureProjLod", "fpe_id_textureProjLod"},
    };
    return map;
}

constexpr char kSharedPrelude[] = R"(
struct fpe_LightSourceParameters {
    vec4 ambient; vec4 diffuse; vec4 specular; vec4 position;
    vec4 halfVector; vec3 spotDirection;
    float spotExponent; float spotCutoff; float spotCosCutoff;
    float constantAttenuation; float linearAttenuation; float quadraticAttenuation;
};
struct fpe_LightModelParameters { vec4 ambient; };
struct fpe_MaterialParameters {
    vec4 emission; vec4 ambient; vec4 diffuse; vec4 specular; float shininess;
};
struct fpe_FogParameters { vec4 color; float density; float start; float end; float scale; };
)";

// Compatibility state UNIFORMS, emitted only when a body references them.
// Unreferenced ones would be inactive anyway (location -1, nothing fed),
// but their mere declaration still takes part in cross-stage consistency
// checks at link: a shader declaring its own trimmed `fpe_Fog` in one
// stage must not collide with an unused full-size prelude declaration in
// the other (Mesa rejects that; NVIDIA happens to be lenient).
struct compat_uniform_t {
    const char* declaration;
    const char* name;
};
constexpr compat_uniform_t kSharedUniforms[] = {
    {"uniform mat4 fpe_ModelViewMatrix;\n", "fpe_ModelViewMatrix"},
    {"uniform mat4 fpe_ProjectionMatrix;\n", "fpe_ProjectionMatrix"},
    {"uniform mat4 fpe_ModelViewProjectionMatrix;\n", "fpe_ModelViewProjectionMatrix"},
    {"uniform mat3 fpe_NormalMatrix;\n", "fpe_NormalMatrix"},
    {"uniform mat4 fpe_ModelViewMatrixInverse;\n", "fpe_ModelViewMatrixInverse"},
    {"uniform mat4 fpe_ProjectionMatrixInverse;\n", "fpe_ProjectionMatrixInverse"},
    {"uniform mat4 fpe_TextureMatrix[8];\n", "fpe_TextureMatrix"},
    {"uniform fpe_LightSourceParameters fpe_LightSource[8];\n", "fpe_LightSource"},
    {"uniform fpe_LightModelParameters fpe_LightModel;\n", "fpe_LightModel"},
    {"uniform fpe_MaterialParameters fpe_FrontMaterial;\n", "fpe_FrontMaterial"},
    {"uniform fpe_MaterialParameters fpe_BackMaterial;\n", "fpe_BackMaterial"},
    {"uniform fpe_FogParameters fpe_Fog;\n", "fpe_Fog"},
    {"uniform vec4 fpe_ClipPlane[6];\n", "fpe_ClipPlane"},
    {"uniform float fpe_NormalScale;\n", "fpe_NormalScale"},
};

// Compatibility vertex ATTRIBUTES. Each one consumes a real attribute
// slot, so they are emitted only when the shader actually references them:
// a GL 3+ core shader that places its own inputs with layout(location = N)
// would otherwise collide with the auto-mapped locations of thirteen
// unused compat attributes ("overlapping location" at link time).
struct compat_attribute_t {
    const char* declaration;
    const char* name;
};
constexpr compat_attribute_t kVertexAttributes[] = {
    {"in vec4 fpe_Vertex;\n", "fpe_Vertex"},
    {"in vec3 fpe_Normal;\n", "fpe_Normal"},
    {"in vec4 fpe_Color;\n", "fpe_Color"},
    {"in vec4 fpe_SecondaryColor;\n", "fpe_SecondaryColor"},
    {"in float fpe_FogCoord;\n", "fpe_FogCoord"},
    {"in vec4 fpe_MultiTexCoord0;\n", "fpe_MultiTexCoord0"},
    {"in vec4 fpe_MultiTexCoord1;\n", "fpe_MultiTexCoord1"},
    {"in vec4 fpe_MultiTexCoord2;\n", "fpe_MultiTexCoord2"},
    {"in vec4 fpe_MultiTexCoord3;\n", "fpe_MultiTexCoord3"},
    {"in vec4 fpe_MultiTexCoord4;\n", "fpe_MultiTexCoord4"},
    {"in vec4 fpe_MultiTexCoord5;\n", "fpe_MultiTexCoord5"},
    {"in vec4 fpe_MultiTexCoord6;\n", "fpe_MultiTexCoord6"},
    {"in vec4 fpe_MultiTexCoord7;\n", "fpe_MultiTexCoord7"},
};

// Outputs cost a varying, not an attribute slot, and the fragment prelude
// declares the matching inputs unconditionally, so these stay whole.
constexpr char kVertexPrelude[] = R"(
out vec4 fpe_FrontColor;
out vec4 fpe_BackColor;
out vec4 fpe_FrontSecondaryColor;
out vec4 fpe_BackSecondaryColor;
out vec4 fpe_TexCoord[8];
out float fpe_FogFragCoord;
)";

// Only the first compilation unit of a stage carries function BODIES:
// further TUs see prototypes, and glslang's cross-TU link resolves them
// (duplicate bodies would be a redefinition).
constexpr char kVertexPreludeFuncs[] =
    "vec4 ftransform() { return fpe_ModelViewProjectionMatrix * fpe_Vertex; }\n";
constexpr char kVertexPreludeProtos[] = "vec4 ftransform();\n";

// Legacy shadow2D returns vec4 (the compare result splatted); the modern
// texture() overload returns float, so packs doing shadow2D(...).z need a
// widening wrapper rather than a rename.
constexpr char kSharedPreludeFuncs[] =
    "vec4 fpe_shadow2D(sampler2DShadow s, vec3 p) { return vec4(texture(s, p)); }\n"
    "vec4 fpe_shadow2DProj(sampler2DShadow s, vec4 p) { return vec4(textureProj(s, p)); }\n";
constexpr char kSharedPreludeProtos[] =
    "vec4 fpe_shadow2D(sampler2DShadow s, vec3 p);\n"
    "vec4 fpe_shadow2DProj(sampler2DShadow s, vec4 p);\n";

constexpr char kFragmentPrelude[] = R"(
in vec4 fpe_FrontColor;
in vec4 fpe_BackColor;
in vec4 fpe_FrontSecondaryColor;
in vec4 fpe_BackSecondaryColor;
in vec4 fpe_TexCoord[8];
in float fpe_FogFragCoord;
)";

constexpr char kFragColorOut[] = "out vec4 fpe_FragColor;\n";

// GL 2.1 alpha test is a per-fragment operation AFTER the fragment
// shader, so it applies to user programs too - and GLES dropped it
// entirely. The user's main() is renamed and called from a generated one
// that applies the test to the fragment's color-0 alpha. The func lives
// in a uniform (0 = disabled) so a state change never forces a
// retranslation; the branch is uniform-uniform and fully coherent.
// Legacy Minecraft leans on this for cutout foliage (grass, leaves).
constexpr char kAlphaTestPrelude[] = R"(
uniform int fpe_AlphaTestFunc;
uniform float fpe_AlphaTestRef;
void fpe_ApplyAlphaTest(float fpe_alpha) {
    int fpe_func = fpe_AlphaTestFunc;
    if (fpe_func == 0) return;
    bool fpe_pass;
    if (fpe_func == 512) fpe_pass = false;                          // GL_NEVER
    else if (fpe_func == 513) fpe_pass = fpe_alpha <  fpe_AlphaTestRef;  // LESS
    else if (fpe_func == 514) fpe_pass = fpe_alpha == fpe_AlphaTestRef;  // EQUAL
    else if (fpe_func == 515) fpe_pass = fpe_alpha <= fpe_AlphaTestRef;  // LEQUAL
    else if (fpe_func == 516) fpe_pass = fpe_alpha >  fpe_AlphaTestRef;  // GREATER
    else if (fpe_func == 517) fpe_pass = fpe_alpha != fpe_AlphaTestRef;  // NOTEQUAL
    else if (fpe_func == 518) fpe_pass = fpe_alpha >= fpe_AlphaTestRef;  // GEQUAL
    else fpe_pass = true;                                           // GL_ALWAYS
    if (!fpe_pass) discard;
}
)";
constexpr char kAlphaTestPrototypes[] =
    "uniform int fpe_AlphaTestFunc;\n"
    "uniform float fpe_AlphaTestRef;\n"
    "void fpe_ApplyAlphaTest(float fpe_alpha);\n";
// Sized from the backend's GL_MAX_DRAW_BUFFERS at translate time:
// OptiFine shader packs statically index gl_FragData up to [7], and a
// constant index beyond the declared size is a parse error.

bool identChar(char c) { return std::isalnum((unsigned char)c) || c == '_'; }

// Token-level identifier replacement; #define cannot touch reserved gl_*.
std::string replaceIdentifiers(const std::string& src,
                               const std::unordered_map<std::string, std::string>& primary,
                               const std::unordered_map<std::string, std::string>& stage) {
    std::string out;
    out.reserve(src.size() + src.size() / 8);
    size_t i = 0;
    while (i < src.size()) {
        const char c = src[i];
        if (c == '/' && i + 1 < src.size() && (src[i + 1] == '/' || src[i + 1] == '*')) {
            // Copy comments verbatim.
            if (src[i + 1] == '/') {
                while (i < src.size() && src[i] != '\n') out += src[i++];
            } else {
                out += src[i++];
                out += src[i++];
                while (i + 1 < src.size() && !(src[i] == '*' && src[i + 1] == '/')) out += src[i++];
                if (i + 1 < src.size()) { out += src[i++]; out += src[i++]; }
            }
            continue;
        }
        if (identChar(c) && !std::isdigit((unsigned char)c)) {
            size_t j = i;
            while (j < src.size() && identChar(src[j])) ++j;
            const std::string word = src.substr(i, j - i);
            if (auto sit = stage.find(word); sit != stage.end()) {
                out += sit->second;
            } else if (auto pit = primary.find(word); pit != primary.end()) {
                out += pit->second;
            } else {
                out += word;
            }
            i = j;
            continue;
        }
        out += c;
        ++i;
    }
    return out;
}

std::once_flag g_glslang_once;

} // namespace

namespace {

// Strip the caller's #version: glslang's OpenGL-SPIR-V environment only
// initializes its builtin tables for modern versions, so the toolchain
// input is always "450 core" - a superset in which every 1.10/1.20
// construct still parses once the preprocessor has rewritten the
// compatibility spellings.
std::string rewriteBody(bool vertex, const std::string& source, int rename_level) {
    std::string body = source;
    unsigned source_version = 110; // the GLSL default when #version is absent
    const size_t vpos = body.find("#version");
    if (vpos != std::string::npos) {
        source_version = (unsigned)std::atoi(body.c_str() + vpos + 8);
        const size_t eol = body.find('\n', vpos);
        body = body.substr(0, vpos) + body.substr(eol == std::string::npos ? body.size() : eol + 1);
    }
    if (rename_level >= 1) {
        body = replaceIdentifiers(body, samplerShadowingReplacements(), {});
    }
    if (rename_level >= 2 && source_version <= 120) {
        body = replaceIdentifiers(body, legacyIdentifierReplacements(), {});
    }
    body = replaceIdentifiers(body, commonReplacements(),
                              vertex ? vertexReplacements() : fragmentReplacements());
    // GLSL 1.10/1.20 allow redeclaring gl_TexCoord with an explicit size;
    // the prelude's fpe_TexCoord[8] is a superset, so user redeclarations
    // are dropped instead of colliding with it.
    for (const char* qual : {"out ", "in "}) {
        for (size_t pos = 0; (pos = body.find("fpe_TexCoord", pos)) != std::string::npos;) {
            const size_t semi = body.find(';', pos);
            size_t decl = body.rfind(qual, pos);
            // Only a declaration statement qualifies: qualifier, type and
            // array size with no other statement text in between.
            if (semi == std::string::npos || decl == std::string::npos ||
                (decl > 0 && identChar(body[decl - 1]))) {
                ++pos;
                continue;
            }
            const std::string between = body.substr(decl, pos - decl);
            if (between != std::string(qual) + "vec4 " && between != std::string(qual) + "vec4\t") {
                ++pos;
                continue;
            }
            const std::string tail = body.substr(pos + 12, semi - pos - 12);
            if (tail.find('[') == std::string::npos || tail.find_first_not_of("[]0123456789 \t") !=
                                                           std::string::npos) {
                ++pos;
                continue;
            }
            body.erase(decl, semi - decl + 1);
            pos = decl;
        }
    }
    return body;
}

// Word-boundary identifier search over already-rewritten source.
bool referencesIdentifier(const std::string& body, const char* name) {
    const size_t length = std::strlen(name);
    for (size_t pos = 0; (pos = body.find(name, pos)) != std::string::npos; pos += length) {
        const bool left = pos == 0 || !identChar(body[pos - 1]);
        const bool right = pos + length >= body.size() || !identChar(body[pos + length]);
        if (left && right) return true;
    }
    return false;
}

// Drop the prelude's own single-line `uniform`/`in`/`out` declaration of
// each suppressed name: the shader body declares that symbol itself (see
// the redefinition retry in translate()), and two declarations of one
// global in a single TU are an error.
std::string dropSuppressedDeclarations(const std::string& text,
                                       const std::unordered_set<std::string>& names) {
    std::string result;
    result.reserve(text.size());
    size_t start = 0;
    while (start < text.size()) {
        size_t end = text.find('\n', start);
        if (end == std::string::npos) end = text.size();
        const std::string line = text.substr(start, end - start);
        bool drop = false;
        if (line.rfind("uniform ", 0) == 0 || line.rfind("in ", 0) == 0 ||
            line.rfind("out ", 0) == 0) {
            for (const auto& name : names) {
                if (referencesIdentifier(line, name.c_str())) {
                    drop = true;
                    break;
                }
            }
        }
        if (!drop) {
            result += line;
            result += '\n';
        }
        start = end + 1;
    }
    return result;
}

std::string buildPrelude(bool vertex, bool uses_fragdata, bool with_bodies,
                         unsigned max_draw_buffers, const std::string& all_bodies,
                         const std::unordered_set<std::string>* suppressed = nullptr) {
    // ftransform() reads fpe_Vertex, so its use counts as a reference; its
    // helper (and the matrix it reads) can only exist when the fpe_Vertex
    // declaration itself is emitted rather than left to the shader body.
    const bool uses_ftransform = vertex && referencesIdentifier(all_bodies, "ftransform");
    const bool emit_vertex_attr =
        vertex && !(suppressed != nullptr && suppressed->count("fpe_Vertex") != 0) &&
        (referencesIdentifier(all_bodies, "fpe_Vertex") || uses_ftransform);

    std::string result = "#version 450\n"; // SPIR-V rejects compatibility
    result += kSharedPrelude;
    for (const auto& uniform : kSharedUniforms) {
        // The shader body declares this symbol itself; injecting it again
        // would be the very redefinition being suppressed.
        if (suppressed != nullptr && suppressed->count(uniform.name) != 0) continue;
        const bool forced_by_ftransform =
            emit_vertex_attr && std::strcmp(uniform.name, "fpe_ModelViewProjectionMatrix") == 0;
        if (!referencesIdentifier(all_bodies, uniform.name) && !forced_by_ftransform) continue;
        result += uniform.declaration;
    }
    result += with_bodies ? kSharedPreludeFuncs : kSharedPreludeProtos;
    result += vertex ? kVertexPrelude : kFragmentPrelude;
    if (vertex) {
        for (const auto& attribute : kVertexAttributes) {
            if (suppressed != nullptr && suppressed->count(attribute.name) != 0) continue;
            const bool is_vertex = std::strcmp(attribute.name, "fpe_Vertex") == 0;
            if (is_vertex ? !emit_vertex_attr : !referencesIdentifier(all_bodies, attribute.name))
                continue;
            result += attribute.declaration;
        }
        // ftransform()'s body reads fpe_Vertex; without that attribute the
        // helper cannot be declared at all (a modern shader never calls it).
        if (emit_vertex_attr) result += with_bodies ? kVertexPreludeFuncs : kVertexPreludeProtos;
    } else if (uses_fragdata) {
        // FragColor and FragData[0] would collide on one location; declare
        // only what the shader writes (GL forbids mixing them).
        result += "out vec4 fpe_FragData[" + std::to_string(max_draw_buffers) + "];\n";
        result += with_bodies ? kAlphaTestPrelude : kAlphaTestPrototypes;
    } else if (referencesIdentifier(all_bodies, "fpe_FragColor")) {
        result += kFragColorOut;
        result += with_bodies ? kAlphaTestPrelude : kAlphaTestPrototypes;
    }
    // A shader that writes neither gl_FragColor nor gl_FragData declares its
    // own output (GL 3+ core style). Adding fpe_FragColor next to it would
    // put two outputs on draw buffer 0 and the user's writes would land
    // nowhere; the alpha test is likewise a compatibility-only feature, so
    // both the declaration and the test wrapper are skipped.
    if (suppressed != nullptr && !suppressed->empty())
        result = dropSuppressedDeclarations(result, *suppressed);
    return result;
}

// True when the shader itself places its inputs with layout(location = N).
// Such a shader (GL 3+ core style) addresses those exact slots from
// glVertexAttribPointer, so the locations must survive translation; legacy
// compat shaders declare none and rely on glBindAttribLocation instead.
bool declaresInputLocation(const std::string& body) {
    for (size_t pos = 0; (pos = body.find("layout", pos)) != std::string::npos; pos += 6) {
        if (pos > 0 && identChar(body[pos - 1])) continue;
        const size_t close = body.find(')', pos);
        if (close == std::string::npos) break;
        if (body.compare(pos + 6, close - pos - 6, "") == 0) continue;
        const std::string qualifiers = body.substr(pos, close - pos);
        if (qualifiers.find("location") == std::string::npos) continue;
        // The declaration that follows must be an input.
        size_t decl = close + 1;
        while (decl < body.size() && (body[decl] == ' ' || body[decl] == '\t' || body[decl] == '\n' ||
                                      body[decl] == '\r'))
            ++decl;
        if (body.compare(decl, 3, "in ") == 0 || body.compare(decl, 3, "in\t") == 0) return true;
    }
    return false;
}

// Renames the user's entry point so a generated main() can run the alpha
// test on its result. Returns false when the shader has no plain `main`
// definition to wrap (nothing to do).
bool renameEntryPoint(std::string& body) {
    size_t pos = 0;
    while ((pos = body.find("main", pos)) != std::string::npos) {
        const bool word_start = pos == 0 || !identChar(body[pos - 1]);
        const bool word_end = pos + 4 >= body.size() || !identChar(body[pos + 4]);
        if (!word_start || !word_end) {
            pos += 4;
            continue;
        }
        // Must look like a definition/declaration: `main` then optional
        // spaces then '('.
        size_t paren = pos + 4;
        while (paren < body.size() && (body[paren] == ' ' || body[paren] == '\t')) ++paren;
        if (paren >= body.size() || body[paren] != '(') {
            pos += 4;
            continue;
        }
        body.replace(pos, 4, "fpe_user_main");
        pos += sizeof("fpe_user_main") - 1;
    }
    return body.find("fpe_user_main") != std::string::npos;
}

} // namespace

std::string preprocess(GLenum stage, const std::string& source) {
    return preprocess(stage, std::vector<std::string>{source});
}

// Multiple compilation units of one stage (GL 2.1 multi-TU programs, which
// GLES forbids) become one glslang TShader each; only the first TU's
// prelude carries function bodies. glslang's cross-stage-capable linker
// then merges globals, resolves prototypes and rejects real conflicts
// exactly like a desktop GLSL linker.
std::vector<std::string> preprocessUnits(GLenum stage, const std::vector<std::string>& sources,
                                         int rename_level = 0,
                                         unsigned max_draw_buffers = 4,
                                         const std::unordered_set<std::string>* suppressed = nullptr) {
    const bool vertex = stage == GL_VERTEX_SHADER;
    std::vector<std::string> bodies;
    bodies.reserve(sources.size());
    bool uses_fragdata = false;
    for (const auto& source : sources) {
        bodies.push_back(rewriteBody(vertex, source, rename_level));
        uses_fragdata = uses_fragdata || bodies.back().find("fpe_FragData") != std::string::npos;
    }
    // Prelude filtering must agree across the stage's TUs, so it looks at
    // every body: a helper TU may be the one touching a compat symbol.
    std::string all_bodies;
    for (const auto& body : bodies) all_bodies += body;

    // Wrap the fragment entry point so the emulated alpha test runs on the
    // shader's own output (see kAlphaTestPrelude). Only the TU that owns
    // main() is touched; the others keep their helper functions.
    std::string generated_main;
    // Only the compatibility outputs can carry the emulated alpha test: a
    // core-profile shader declares its own output (whose name we must not
    // assume) and cannot use alpha test in the first place.
    const bool compat_output = uses_fragdata || referencesIdentifier(all_bodies, "fpe_FragColor");
    if (!vertex && compat_output) {
        for (auto& body : bodies) {
            if (!renameEntryPoint(body)) continue;
            const char* alpha_source = uses_fragdata ? "fpe_FragData[0].a" : "fpe_FragColor.a";
            generated_main = std::string("\nvoid main() {\n"
                                         "    fpe_user_main();\n"
                                         "    fpe_ApplyAlphaTest(") +
                             alpha_source + ");\n}\n";
            break;
        }
    }

    std::vector<std::string> units;
    units.reserve(bodies.size());
    for (size_t i = 0; i < bodies.size(); ++i) {
        std::string unit =
            buildPrelude(vertex, uses_fragdata, i == 0, max_draw_buffers, all_bodies, suppressed);
        unit += "#line 1\n"; // keep glslang diagnostics on user line numbers
        unit += bodies[i];
        if (unit.back() != '\n') unit += '\n';
        // The generated main lives with the renamed entry point's TU.
        if (!generated_main.empty() && bodies[i].find("fpe_user_main") != std::string::npos)
            unit += generated_main;
        units.push_back(std::move(unit));
    }
    return units;
}

std::string preprocess(GLenum stage, const std::vector<std::string>& sources) {
    std::string joined;
    for (const auto& unit : preprocessUnits(stage, sources)) joined += unit;
    return joined;
}

namespace {

bool skipShaderPreamble(const std::string& source, size_t& pos) {
    if (pos == 0 && source.size() >= 3 &&
        (unsigned char)source[0] == 0xEF && (unsigned char)source[1] == 0xBB &&
        (unsigned char)source[2] == 0xBF) {
        pos = 3;
    }
    while (pos < source.size()) {
        const unsigned char c = (unsigned char)source[pos];
        if (std::isspace(c)) {
            ++pos;
            continue;
        }
        if (c == '/' && pos + 1 < source.size()) {
            if (source[pos + 1] == '/') {
                const size_t nl = source.find('\n', pos + 2);
                pos = nl == std::string::npos ? source.size() : nl + 1;
                continue;
            }
            if (source[pos + 1] == '*') {
                const size_t end = source.find("*/", pos + 2);
                if (end == std::string::npos) return false;
                pos = end + 2;
                continue;
            }
        }
        break;
    }
    return true;
}

} // namespace

shader_language_info_t detect_shader_language(const std::string& source) {
    shader_language_info_t info;
    size_t pos = 0;
    if (!skipShaderPreamble(source, pos)) {
        info.valid = false;
        return info;
    }
    if (pos >= source.size() || source[pos] != '#') {
        // A later #version directive would be malformed because the first
        // meaningful token is already shader code. A directive inside a
        // comment is harmless, so this conservative line scan only rejects
        // directives that begin a line.
        size_t line = pos;
        while (line < source.size()) {
            const size_t eol = source.find('\n', line);
            const size_t line_end = eol == std::string::npos ? source.size() : eol;
            size_t p = line;
            while (p < line_end &&
                   (source[p] == ' ' || source[p] == '\t' || source[p] == '\r'))
                ++p;
            if (p < line_end && source[p] == '#') {
                info.valid = false;
                break;
            }
            if (eol == std::string::npos) break;
            line = eol + 1;
        }
        return info; // otherwise GLSL 1.10
    }

    ++pos; // consume '#'
    while (pos < source.size() && (source[pos] == ' ' || source[pos] == '\t')) ++pos;
    if (source.compare(pos, 7, "version") != 0 ||
        (pos + 7 < source.size() && identChar(source[pos + 7]))) {
        info.valid = false;
        return info;
    }
    pos += 7;
    while (pos < source.size() && (source[pos] == ' ' || source[pos] == '\t')) ++pos;

    unsigned version = 0;
    while (pos < source.size() && std::isdigit((unsigned char)source[pos])) {
        version = version * 10u + (unsigned)(source[pos] - '0');
        ++pos;
    }
    if (version == 0) {
        info.valid = false;
        return info;
    }
    info.version = version;

    while (pos < source.size() && (source[pos] == ' ' || source[pos] == '\t')) ++pos;
    size_t line_end = source.find('\n', pos);
    if (line_end == std::string::npos) line_end = source.size();
    std::string tail = source.substr(pos, line_end - pos);
    while (!tail.empty() && (tail.back() == ' ' || tail.back() == '\t' || tail.back() == '\r'))
        tail.pop_back();

    size_t t = 0;
    while (t < tail.size() && (tail[t] == ' ' || tail[t] == '\t')) ++t;
    if (t < tail.size()) {
        size_t end = t;
        while (end < tail.size() && tail[end] != ' ' && tail[end] != '\t') ++end;
        const std::string token = tail.substr(t, end - t);
        if (token == "es") {
            info.dialect = shader_language_info_t::dialect_t::essl;
        } else if (token == "compatibility") {
            info.compatibility = true;
        } else if (token != "core") {
            info.valid = false;
            return info;
        }
        while (end < tail.size() && (tail[end] == ' ' || tail[end] == '\t')) ++end;
        if (end < tail.size()) {
            info.valid = false;
            return info;
        }
    }
    return info;
}

bool shader_can_passthrough(const std::string& source, const target_language_t& target) {
    const auto lang = detect_shader_language(source);
    if (!lang.valid || lang.version == 0) return false;
    // Desktop GLSL <= 1.40 is not a safe native form for the 3.2+ core
    // backend, so route those sources through the translator even when the
    // version number is within the backend's accepted range.
    // Compatibility-profile sources are likewise never passed through, so
    // the translator can rewrite their desktop-only builtins for the core
    // backend regardless of how new the #version is.
    if (lang.dialect == shader_language_info_t::dialect_t::desktop_glsl &&
        (lang.version <= 140 || lang.compatibility))
        return false;
    const bool dialect_matches =
        (lang.dialect == shader_language_info_t::dialect_t::essl) == target.es;
    return dialect_matches && lang.version <= target.accepted_version;
}

translation_result_t translate(GLenum stage, const std::string& source,
                               const target_language_t& target) {
    return translate(stage, std::vector<std::string>{source}, target);
}

namespace {
translation_result_t translateUnits(GLenum stage, const std::vector<std::string>& units,
                                    const target_language_t& target, bool explicit_input_locations);

// Scrape "'fpe_Xyz' : redefinition" out of a glslang parse log. Only fpe_
// names qualify: those are the prelude's own declarations, so a collision
// means the shader body declared the symbol itself.
void collectRedefinedFpeSymbols(const std::string& log, std::unordered_set<std::string>& names) {
    constexpr char kMarker[] = "' : redefinition";
    for (size_t pos = 0; (pos = log.find(kMarker, pos)) != std::string::npos;
         pos += sizeof(kMarker) - 1) {
        if (pos == 0) continue;
        const size_t open = log.rfind('\'', pos - 1);
        if (open == std::string::npos) continue;
        const std::string name = log.substr(open + 1, pos - open - 1);
        if (name.rfind("fpe_", 0) == 0) names.insert(name);
    }
}
} // namespace

translation_result_t translate(GLenum stage, const std::vector<std::string>& sources,
                               const target_language_t& target) {
    // A pure function of `sources`, so the cache key below (which spans every
    // source byte) already discriminates on it; it needs no key of its own.
    bool explicit_input_locations = false;
    for (const auto& source : sources)
        explicit_input_locations = explicit_input_locations || declaresInputLocation(source);

    // Source-hash memoization (plans/09): shader reloads and multi-context
    // recompiles re-translate byte-identical sources, and one glslang ->
    // SPIR-V -> SPIRV-Cross round trip costs ~1ms. Failures are cached too -
    // identical input reproduces identical diagnostics. Process-global and
    // mutex-guarded (translation is cold); bounded by total bytes, cleared
    // wholesale on overflow (pathological churn only re-translates).
    static std::mutex cache_mutex;
    static std::unordered_map<std::string, translation_result_t> cache;
    static size_t cache_bytes = 0;
    constexpr size_t kCacheByteLimit = 16u * 1024u * 1024u;

    std::string key;
    {
        size_t total = 32;
        for (const auto& source : sources) total += source.size() + 16;
        key.reserve(total);
        key += std::to_string(stage);
        key += '\x1f';
        key += std::to_string(target.version);
        key += target.es ? 'e' : 'd';
        key += std::to_string(target.max_draw_buffers);
        for (const auto& source : sources) {
            key += '\x1f';
            key += std::to_string(source.size());
            key += ':';
            key += source;
        }
    }
    {
        std::lock_guard<std::mutex> lock(cache_mutex);
        auto hit = cache.find(key);
        if (hit != cache.end()) return hit->second;
    }

    auto attempt = [&](int level, const std::unordered_set<std::string>* suppressed) {
        return translateUnits(
            stage, preprocessUnits(stage, sources, level, target.max_draw_buffers, suppressed),
            target, explicit_input_locations);
    };

    auto result = attempt(0, nullptr);
    // Escalating rename retries, keeping the PLAIN attempt's diagnostics
    // when everything fails: level 1 un-shadows sampler names (`uniform
    // sampler2D texture;` exists in packs of every #version), level 2 also
    // renames identifiers that were plain in <= 1.20 (mat2x3, lowp, ...).
    for (int level = 1; level <= 2 && !result.ok && !result.parse_ok; ++level) {
        auto retry = attempt(level, nullptr);
        if (retry.ok) {
            result = std::move(retry);
            break;
        }
    }
    // A modern-style shader may declare the wrapper's fpe_* interface
    // itself (`in vec4 fpe_Vertex;`, `uniform ... fpe_Fog;`) to reach the
    // fixed-function feeds from a user program; the injected prelude then
    // collides with it as a redefinition. Yield those prelude declarations
    // and retry. Iterated because glslang reports errors TU by TU, so one
    // pass may surface only part of the set; the plain attempt's
    // diagnostics are kept if suppression never reaches a clean parse.
    if (!result.ok) {
        std::unordered_set<std::string> suppressed;
        std::string log = result.log;
        for (int round = 0; round < 8 && !result.ok; ++round) {
            const size_t known = suppressed.size();
            collectRedefinedFpeSymbols(log, suppressed);
            if (suppressed.size() == known) break;
            auto retry = attempt(0, &suppressed);
            if (retry.ok) {
                result = std::move(retry);
                break;
            }
            log = std::move(retry.log);
        }
    }

    {
        std::lock_guard<std::mutex> lock(cache_mutex);
        size_t entry_bytes = key.size() + result.essl.size() + result.log.size() +
                             result.preprocessed.size() + 256;
        for (const auto& initializer : result.uniform_initializers)
            entry_bytes += sizeof(initializer) + initializer.name.size();
        if (cache_bytes + entry_bytes > kCacheByteLimit) {
            cache.clear();
            cache_bytes = 0;
        }
        // Concurrent misses on the same key both translate; only the thread
        // whose emplace actually inserts may account the bytes.
        if (cache.emplace(std::move(key), result).second) cache_bytes += entry_bytes;
    }
    return result;
}

namespace {
translation_result_t translateUnits(GLenum stage, const std::vector<std::string>& units,
                                    const target_language_t& target,
                                    bool explicit_input_locations) {
    translation_result_t result;
    for (const auto& unit : units) result.preprocessed += unit;

    std::call_once(g_glslang_once, [] { glslang::InitializeProcess(); });

    const EShLanguage lang = stage == GL_VERTEX_SHADER ? EShLangVertex : EShLangFragment;
    std::vector<std::unique_ptr<glslang::TShader>> shaders;
    const EShMessages messages = (EShMessages)(EShMsgSpvRules | EShMsgKeepUncalled);
    for (const auto& unit : units) {
        auto shader = std::make_unique<glslang::TShader>(lang);
        const char* text = unit.c_str();
        shader->setStrings(&text, 1);
        shader->setEnvInput(glslang::EShSourceGlsl, lang, glslang::EShClientOpenGL, 450);
        shader->setEnvClient(glslang::EShClientOpenGL, glslang::EShTargetOpenGL_450);
        shader->setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_0);
        // OpenGL SPIR-V requires explicit locations/bindings; auto-map them
        // and let the linker resolve attributes by name from the ESSL.
        shader->setAutoMapLocations(true);
        shader->setAutoMapBindings(true);
        if (!shader->parse(GetDefaultResources(), 450, ECoreProfile, false, false, messages)) {
            result.log = std::string("glslang parse:\n") + shader->getInfoLog();
            return result;
        }
        shaders.push_back(std::move(shader));
    }
    result.parse_ok = true;

    glslang::TProgram program;
    for (auto& shader : shaders) program.addShader(shader.get());
    if (!program.link(messages) || !program.mapIO()) {
        result.log = std::string("glslang link:\n") + program.getInfoLog();
        return result;
    }

    std::vector<unsigned int> spirv;
    glslang::SpvOptions options;
    options.disableOptimizer = true;
    options.validate = false;
    glslang::GlslangToSpv(*program.getIntermediate(lang), spirv, &options);
    if (spirv.empty()) {
        result.log = "glslang produced no SPIR-V";
        return result;
    }
    clampAccessChainIndices(spirv);

    try {
        EsslCompiler compiler(std::move(spirv));
        spirv_cross::CompilerGLSL::Options opts;
        opts.version = target.version;
        opts.es = target.es;
        opts.vulkan_semantics = false;
        opts.enable_420pack_extension = false;
        // Desktop GLSL 1.20 computes at (at least) single precision;
        // mediump would visibly degrade transcendentals (tan, exp2, ...).
        opts.fragment.default_float_precision =
            spirv_cross::CompilerGLSL::Options::Precision::Highp;
        compiler.set_common_options(opts);
        // The wrapper links everything by NAME (glGetUniformLocation /
        // glGetAttribLocation / varying name matching): the auto-mapped
        // bindings and locations from the per-stage glslang runs are not
        // coherent across stages, and ESSL 310+ would otherwise emit
        // layout(binding=N) on plain default-block uniforms, which no GLSL
        // dialect accepts. Strip them; only fragment outputs keep their
        // locations (gl_FragData[i] must stay routed to draw buffer i).
        const auto resources = compiler.get_shader_resources();
        auto strip = [&compiler](const spirv_cross::Resource& r) {
            compiler.unset_decoration(r.id, spv::DecorationLocation);
            compiler.unset_decoration(r.id, spv::DecorationBinding);
        };
        for (const auto& r : resources.gl_plain_uniforms) strip(r);
        for (const auto& r : resources.sampled_images) strip(r);
        for (const auto& r : resources.separate_images) strip(r);
        for (const auto& r : resources.separate_samplers) strip(r);
        if (lang == EShLangVertex) {
            for (const auto& r : resources.stage_outputs) strip(r);
            // VS input locations are load-bearing in opposite directions
            // depending on the shader's era, so only the AUTO-MAPPED ones
            // are dropped:
            //  - legacy compat shaders declare no locations at all and let
            //    the app place attributes with glBindAttribLocation
            //    (OptiFine pins mc_Entity/mc_midTexCoord that way), which a
            //    location baked in by glslang's auto-mapper would override;
            //  - GL 3+ core shaders declare layout(location = N) themselves
            //    and address those exact slots with glVertexAttribPointer,
            //    never asking the linker where anything went.
            if (!explicit_input_locations) {
                for (const auto& r : resources.stage_inputs) strip(r);
            }
        } else {
            for (const auto& r : resources.stage_inputs) strip(r);
        }
        compiler.nameAnonymousStructs();
        result.uniform_initializers = compiler.scrapeUniformInitializers();
        result.essl = compiler.compile();
        result.ok = true;
    } catch (const std::exception& e) {
        result.log = std::string("SPIRV-Cross: ") + e.what();
    }
    return result;
}
} // namespace

} // namespace SFPEW::Shader

namespace SFPEW::Shader {

namespace {

unsigned parseShadingLanguageVersionString(const char* text) {
    if (text == nullptr) return 0;
    const char* p = text;
    while (*p != '\0' && !std::isdigit((unsigned char)*p)) ++p;
    unsigned major = 0;
    while (*p != '\0' && std::isdigit((unsigned char)*p)) {
        major = major * 10u + (unsigned)(*p - '0');
        ++p;
    }
    while (*p != '\0' && *p != '.') ++p;
    if (*p != '.') return major;
    ++p;
    unsigned minor = 0;
    while (*p != '\0' && std::isdigit((unsigned char)*p)) {
        minor = minor * 10u + (unsigned)(*p - '0');
        ++p;
    }
    return major * 100u + minor * 10u;
}

} // namespace

target_language_t detect_backend_target() {
    // The backend tables must be resolved first or every probe below reads
    // null function pointers and the detection silently degrades to the
    // ESSL 300 default (translate can run before any other GL call).
    sfpewEnsureBackend();
    // Cached per context like the other logical shadows.
    static thread_local struct {
        EGLContext context = (EGLContext)(intptr_t)-1;
        target_language_t target{};
    } cache;
    const EGLContext current =
        sfpewCurrentContext();
    if (cache.context == current) return cache.target;

    target_language_t target; // safe default: ESSL 300
    if (current != EGL_NO_CONTEXT && g_glFuncs.glGetString != nullptr &&
        g_glFuncs.glGetIntegerv != nullptr) {
        const char* version = (const char*)g_glFuncs.glGetString(GL_VERSION);
        const char* shading_version =
            (const char*)g_glFuncs.glGetString(GL_SHADING_LANGUAGE_VERSION);
        target.accepted_version = parseShadingLanguageVersionString(shading_version);
        GLint major = 3, minor = 0;
        g_glFuncs.glGetIntegerv(GL_MAJOR_VERSION, &major);
        g_glFuncs.glGetIntegerv(GL_MINOR_VERSION, &minor);
        if (version != nullptr && std::strstr(version, "OpenGL ES") != nullptr) {
            target.es = true;
            target.version = major >= 3 ? (unsigned)(300 + minor * 10) : 300;
            if (target.version > 320) target.version = 320;
        } else if (version != nullptr) {
            target.es = false;
            target.version = (unsigned)(major * 100 + minor * 10); // 420, 450, ...
            if (target.version < 330) target.version = 330;
        }
        GLint max_draw_buffers = 0;
        g_glFuncs.glGetIntegerv(0x8824 /* GL_MAX_DRAW_BUFFERS */, &max_draw_buffers);
        if (max_draw_buffers >= 1)
            target.max_draw_buffers = (unsigned)std::min(max_draw_buffers, 8);
    }
    if (target.accepted_version == 0) target.accepted_version = target.version;
    cache.context = current;
    cache.target = target;
    return target;
}

} // namespace SFPEW::Shader

// C hook so the CTest suite can exercise the pipeline through dlopen.
extern "C" __attribute__((visibility("default"))) int
sfpewTranslateGlslForTest(unsigned int stage, const char* source, char* out, int out_size) {
    if (source == nullptr || out == nullptr || out_size <= 0) return -1;
    // The test hook targets the backend when one is current, else ESSL 300.
    const auto result = SFPEW::Shader::translate(stage, source, SFPEW::Shader::detect_backend_target());
    // SFPEW_DEBUG_PRE=1: return the preprocessed toolchain input instead
    // of the diagnostics on failure (translator debugging).
    const bool debug_pre = std::getenv("SFPEW_DEBUG_PRE") != nullptr && !result.ok;
    const std::string& payload = result.ok ? result.essl : (debug_pre ? result.preprocessed : result.log);
    const int n = (int)std::min((size_t)out_size - 1, payload.size());
    std::memcpy(out, payload.data(), (size_t)n);
    out[n] = '\0';
    return result.ok ? 0 : 1;
}

extern "C" __attribute__((visibility("default"))) int
sfpewShaderCanPassthroughForTest(unsigned int stage, const char* source, int backend_es,
                                 unsigned int backend_version) {
    (void)stage;
    if (source == nullptr) return -1;
    SFPEW::Shader::target_language_t target;
    target.es = backend_es != 0;
    target.version = backend_version;
    target.accepted_version = backend_version;
    return SFPEW::Shader::shader_can_passthrough(source, target) ? 1 : 0;
}
