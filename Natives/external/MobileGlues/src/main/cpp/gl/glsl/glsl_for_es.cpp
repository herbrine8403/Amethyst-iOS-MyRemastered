// MobileGlues - gl/glsl/glsl_for_es.cpp
// Copyright (c) 2025-2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v2.1:
//   https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt
// SPDX-License-Identifier: LGPL-2.1-only
// End of Source File Header
#include "glsl_for_es.h"

#include <glslang/Public/ShaderLang.h>
#include <glslang/Include/Types.h>
#include <glslang/Public/ShaderLang.h>
#include <spirv_cross/spirv_cross_c.h>
#include <iostream>
#include <fstream>
#include <cstring>
#include "../log.h"
#include "glslang/SPIRV/GlslangToSpv.h"
#include <string>
#include <regex>
#include <strstream>
#include <algorithm>
#include <sstream>
// Amethyst Task 32: explicit headers for fix_dynamic_output_indexing() and the
// token-guarded process_uniform_declarations() (snprintf/atoi/isalnum/vector);
// these used to arrive transitively via the toolchain headers above.
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "cache.h"
#include "../../version.h"

#if defined(__APPLE__)
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <mutex>
// NB: <sys/ucontext.h>, NOT <ucontext.h> -- the latter errors out on the
// iOS SDK without _XOPEN_SOURCE. sys/ucontext.h defines ucontext_t with
// uc_mcontext (mcontext_t, a pointer to _STRUCT_MCONTEXT64) and uc_mcsize.
#include <sys/ucontext.h>
#include <dlfcn.h>
#endif

#define DEBUG 0

static TBuiltInResource InitResources() {
    TBuiltInResource Resources{};

    Resources.maxLights = 32;
    Resources.maxClipPlanes = 6;
    Resources.maxTextureUnits = 32;
    Resources.maxTextureCoords = 32;
    Resources.maxVertexAttribs = 64;
    Resources.maxVertexUniformComponents = 4096;
    Resources.maxVaryingFloats = 64;
    Resources.maxVertexTextureImageUnits = 32;
    Resources.maxCombinedTextureImageUnits = 80;
    Resources.maxTextureImageUnits = 32;
    Resources.maxFragmentUniformComponents = 4096;
    Resources.maxDrawBuffers = 32;
    Resources.maxVertexUniformVectors = 128;
    Resources.maxVaryingVectors = 8;
    Resources.maxFragmentUniformVectors = 16;
    Resources.maxVertexOutputVectors = 16;
    Resources.maxFragmentInputVectors = 15;
    Resources.minProgramTexelOffset = -8;
    Resources.maxProgramTexelOffset = 7;
    Resources.maxClipDistances = 8;
    Resources.maxComputeWorkGroupCountX = 65535;
    Resources.maxComputeWorkGroupCountY = 65535;
    Resources.maxComputeWorkGroupCountZ = 65535;
    Resources.maxComputeWorkGroupSizeX = 1024;
    Resources.maxComputeWorkGroupSizeY = 1024;
    Resources.maxComputeWorkGroupSizeZ = 64;
    Resources.maxComputeUniformComponents = 1024;
    Resources.maxComputeTextureImageUnits = 16;
    Resources.maxComputeImageUniforms = 8;
    Resources.maxComputeAtomicCounters = 8;
    Resources.maxComputeAtomicCounterBuffers = 1;
    Resources.maxVaryingComponents = 60;
    Resources.maxVertexOutputComponents = 64;
    Resources.maxGeometryInputComponents = 64;
    Resources.maxGeometryOutputComponents = 128;
    Resources.maxFragmentInputComponents = 128;
    Resources.maxImageUnits = 8;
    Resources.maxCombinedImageUnitsAndFragmentOutputs = 8;
    Resources.maxCombinedShaderOutputResources = 8;
    Resources.maxImageSamples = 0;
    Resources.maxVertexImageUniforms = 0;
    Resources.maxTessControlImageUniforms = 0;
    Resources.maxTessEvaluationImageUniforms = 0;
    Resources.maxGeometryImageUniforms = 0;
    Resources.maxFragmentImageUniforms = 8;
    Resources.maxCombinedImageUniforms = 8;
    Resources.maxGeometryTextureImageUnits = 16;
    Resources.maxGeometryOutputVertices = 256;
    Resources.maxGeometryTotalOutputComponents = 1024;
    Resources.maxGeometryUniformComponents = 1024;
    Resources.maxGeometryVaryingComponents = 64;
    Resources.maxTessControlInputComponents = 128;
    Resources.maxTessControlOutputComponents = 128;
    Resources.maxTessControlTextureImageUnits = 16;
    Resources.maxTessControlUniformComponents = 1024;
    Resources.maxTessControlTotalOutputComponents = 4096;
    Resources.maxTessEvaluationInputComponents = 128;
    Resources.maxTessEvaluationOutputComponents = 128;
    Resources.maxTessEvaluationTextureImageUnits = 16;
    Resources.maxTessEvaluationUniformComponents = 1024;
    Resources.maxTessPatchComponents = 120;
    Resources.maxPatchVertices = 32;
    Resources.maxTessGenLevel = 64;
    Resources.maxViewports = 16;
    Resources.maxVertexAtomicCounters = 0;
    Resources.maxTessControlAtomicCounters = 0;
    Resources.maxTessEvaluationAtomicCounters = 0;
    Resources.maxGeometryAtomicCounters = 0;
    Resources.maxFragmentAtomicCounters = 8;
    Resources.maxCombinedAtomicCounters = 8;
    Resources.maxAtomicCounterBindings = 1;
    Resources.maxVertexAtomicCounterBuffers = 0;
    Resources.maxTessControlAtomicCounterBuffers = 0;
    Resources.maxTessEvaluationAtomicCounterBuffers = 0;
    Resources.maxGeometryAtomicCounterBuffers = 0;
    Resources.maxFragmentAtomicCounterBuffers = 1;
    Resources.maxCombinedAtomicCounterBuffers = 1;
    Resources.maxAtomicCounterBufferSize = 16384;
    Resources.maxTransformFeedbackBuffers = 4;
    Resources.maxTransformFeedbackInterleavedComponents = 64;
    Resources.maxCullDistances = 8;
    Resources.maxCombinedClipAndCullDistances = 8;
    Resources.maxSamples = 4;
    Resources.maxMeshOutputVerticesNV = 256;
    Resources.maxMeshOutputPrimitivesNV = 512;
    Resources.maxMeshWorkGroupSizeX_NV = 32;
    Resources.maxMeshWorkGroupSizeY_NV = 1;
    Resources.maxMeshWorkGroupSizeZ_NV = 1;
    Resources.maxTaskWorkGroupSizeX_NV = 32;
    Resources.maxTaskWorkGroupSizeY_NV = 1;
    Resources.maxTaskWorkGroupSizeZ_NV = 1;
    Resources.maxMeshViewCountNV = 4;

    Resources.limits.nonInductiveForLoops = true;
    Resources.limits.whileLoops = true;
    Resources.limits.doWhileLoops = true;
    Resources.limits.generalUniformIndexing = true;
    Resources.limits.generalAttributeMatrixVectorIndexing = true;
    Resources.limits.generalVaryingIndexing = true;
    Resources.limits.generalSamplerIndexing = true;
    Resources.limits.generalVariableIndexing = true;
    Resources.limits.generalConstantMatrixVectorIndexing = true;

    // Ten fields this table never set, left at 0 by the value-initialisation
    // above. Nine are mesh-shader limits that glslang only reads when a shader
    // asks for them, so 0 was harmless. maxDualSourceDrawBuffersEXT was not:
    // glslang emits
    //     mediump vec4 gl_SecondaryFragDataEXT[gl_MaxDualSourceDrawBuffersEXT];
    // into the ESSL built-in block, and an array sized 0 fails to parse -- which
    // fails the whole built-in table, so every shader routed through glslang was
    // rejected with "unsupported shader version". It only showed on a context
    // whose ESSL version is below the shader's, since a shader the driver can
    // take is passed straight through; ANGLE presents ES 3.1, so turning ANGLE on
    // meant nothing using #version 320 es could compile at all.
    //
    // The values are glslang's own defaults (glslang/ResourceLimits.cpp).
    Resources.maxDualSourceDrawBuffersEXT = 1;
    Resources.maxMeshOutputVerticesEXT = 256;
    Resources.maxMeshOutputPrimitivesEXT = 256;
    Resources.maxMeshWorkGroupSizeX_EXT = 128;
    Resources.maxMeshWorkGroupSizeY_EXT = 128;
    Resources.maxMeshWorkGroupSizeZ_EXT = 128;
    Resources.maxTaskWorkGroupSizeX_EXT = 128;
    Resources.maxTaskWorkGroupSizeY_EXT = 128;
    Resources.maxTaskWorkGroupSizeZ_EXT = 128;
    Resources.maxMeshViewCountEXT = 4;

    return Resources;
}

int getGLSLVersion(const char* glsl_code) {
    std::string code(glsl_code);
    static std::regex version_pattern(R"(#version\s+(\d{3}))");
    std::smatch match;
    if (std::regex_search(code, match, version_pattern)) {
        return std::stoi(match[1].str());
    }

    return -1;
}

std::string forceSupporterOutput(const std::string& glslCode) {
    bool hasPrecisionFloat =
        glslCode.find("precision ") != std::string::npos && glslCode.find("float;") != std::string::npos;
    bool hasPrecisionInt =
        glslCode.find("precision ") != std::string::npos && glslCode.find("int;") != std::string::npos;

    std::string result = glslCode;
    std::string precisionFloat;
    std::string precisionInt;

    if (hasPrecisionFloat && hasPrecisionInt) {
        std::istringstream iss(result);
        std::vector<std::string> lines;
        std::string line;
        while (std::getline(iss, line)) {
            bool isPrecisionLine = (line.find("precision ") != std::string::npos) &&
                                   (line.find("float;") != std::string::npos || line.find("int;") != std::string::npos);
            if (!isPrecisionLine) {
                lines.push_back(line);
            }
        }
        result.clear();
        for (size_t i = 0; i < lines.size(); ++i) {
            if (i != 0) result += '\n';
            result += lines[i];
        }
        precisionFloat = "precision highp float;\n";
        precisionInt = "precision highp int;\n";
    } else {
        precisionFloat = hasPrecisionFloat ? "" : "precision highp float;\n";
        precisionInt = hasPrecisionInt ? "" : "precision highp int;\n";
    }

    size_t lastExtensionPos = result.rfind("#extension");
    size_t insertionPos = 0;

    if (lastExtensionPos != std::string::npos) {
        size_t nextNewline = result.find('\n', lastExtensionPos);
        if (nextNewline != std::string::npos) {
            insertionPos = nextNewline + 1;
        } else {
            insertionPos = result.length();
        }
    } else {
        size_t firstNewline = result.find('\n');
        if (firstNewline != std::string::npos) {
            insertionPos = firstNewline + 1;
        } else {
            result = precisionFloat + precisionInt + result;
            return result;
        }
    }

    result.insert(insertionPos, precisionFloat + precisionInt);
    return result;
}

std::string removeLayoutBinding(const std::string& glslCode) {
    static std::regex bindingRegex(R"(layout\s*\(\s*binding\s*=\s*\d+\s*\)\s*)");
    std::string result = std::regex_replace(glslCode, bindingRegex, "");
    static std::regex bindingRegex2(R"(layout\s*\(\s*binding\s*=\s*\d+\s*,)");
    result = std::regex_replace(result, bindingRegex2, "layout(");
    return result;
}

void trim(std::string& str) {
    str.erase(str.begin(), std::find_if(str.begin(), str.end(), [](int ch) { return !std::isspace(ch); }));
    str.erase(std::find_if(str.rbegin(), str.rend(), [](int ch) { return !std::isspace(ch); }).base(), str.end());
}

// Process all uniform declarations into `uniform <precision> <type> <name>;` form
std::string process_uniform_declarations(const std::string& glslCode) {
    std::string result;
    size_t scan_pos = 0;
    size_t chunk_start = 0;
    const size_t length = glslCode.length();
    const std::vector<std::string> precision_kws = {"highp", "lowp", "mediump"};

    result.reserve(glslCode.length());

    while (scan_pos < length) {
        // Amethyst Task 32 (2026-09, latestlog of build a09e020): "uniform" must
        // match as a standalone token. Minecraft 26.3's RenderPearl pipeline
        // feeds this layer GLSL whose uniform-block instance variables are named
        // _uniform_instance_00_XX; the raw substring match below fired at the
        // "u" inside that identifier, mis-parsed the rest of the statement as a
        // uniform declaration, and -- because the following member access
        // contained a '=' (e.g. "if (_uniform_instance_00_00.UseRgss == 1)") --
        // took the has_initializer rewrite path, which replaced the whole
        // statement with "uniform _instance_00_00 ;" and skipped ahead to the
        // next ';'. Every core pipeline's fragment shader then died in ANGLE
        // with "'_uniform' : undeclared identifier" /
        // "'_instance_00_XX' : syntax error". Guard both sides of the token.
        const bool prev_is_token_char =
            scan_pos > 0 && (std::isalnum(static_cast<unsigned char>(glslCode[scan_pos - 1])) ||
                             glslCode[scan_pos - 1] == '_');
        const bool next_is_token_char =
            scan_pos + 7 < length &&
            (std::isalnum(static_cast<unsigned char>(glslCode[scan_pos + 7])) ||
             glslCode[scan_pos + 7] == '_');
        if (!prev_is_token_char && !next_is_token_char &&
            glslCode.compare(scan_pos, 7, "uniform") == 0) {
            if (scan_pos > chunk_start) {
                result.append(glslCode, chunk_start, scan_pos - chunk_start);
            }

            const size_t decl_start = scan_pos;
            scan_pos += 7; // Skip "uniform"

            std::string precision, type;
            bool found_precision = false;

            while (scan_pos < length) {
                while (scan_pos < length && std::isspace(glslCode[scan_pos]))
                    ++scan_pos;

                for (const auto& kw : precision_kws) {
                    if (glslCode.compare(scan_pos, kw.length(), kw) == 0) {
                        precision = " " + kw;
                        scan_pos += kw.length();
                        found_precision = true;
                        break;
                    }
                }
                if (found_precision) break;

                const size_t type_start = scan_pos;
                while (scan_pos < length && (std::isalnum(glslCode[scan_pos]) || glslCode[scan_pos] == '_')) {
                    ++scan_pos;
                }
                type = glslCode.substr(type_start, scan_pos - type_start);
                break;
            }

            while (scan_pos < length) {
                while (scan_pos < length && std::isspace(glslCode[scan_pos]))
                    ++scan_pos;

                bool found = false;
                for (const auto& kw : precision_kws) {
                    if (glslCode.compare(scan_pos, kw.length(), kw) == 0) {
                        if (precision.empty()) precision = " " + kw;
                        scan_pos += kw.length();
                        found = true;
                        break;
                    }
                }
                if (!found) break;
            }

            if (type.empty()) {
                const size_t type_start = scan_pos;
                while (scan_pos < length && (std::isalnum(glslCode[scan_pos]) || glslCode[scan_pos] == '_')) {
                    ++scan_pos;
                }
                type = glslCode.substr(type_start, scan_pos - type_start);
            }

            while (scan_pos < length && std::isspace(glslCode[scan_pos]))
                ++scan_pos;
            const size_t name_start = scan_pos;
            while (scan_pos < length && (std::isalnum(glslCode[scan_pos]) || glslCode[scan_pos] == '_')) {
                ++scan_pos;
            }
            const std::string name = glslCode.substr(name_start, scan_pos - name_start);

            size_t decl_end = glslCode.find(';', scan_pos);
            if (decl_end == std::string::npos)
                decl_end = length;
            else
                ++decl_end;
            const bool has_initializer = (glslCode.find('=', scan_pos) < decl_end);
            if (has_initializer) {
                result.append("uniform").append(precision).append(" ").append(type).append(" ").append(name).append(
                    ";");
            } else {
                result.append(glslCode, decl_start, decl_end - decl_start);
            }

            scan_pos = chunk_start = decl_end;
        } else {
            ++scan_pos;
        }
    }

    if (chunk_start < length) {
        result.append(glslCode, chunk_start, length - chunk_start);
    }

    return result;
}

std::string processOutColorLocations(const std::string& glslCode) {
    const static std::regex pattern(R"(\n(out highp vec4 outColor)(\d+);)");
    const std::string replacement = "\nlayout(location=$2) $1$2;";
    return std::regex_replace(glslCode, pattern, replacement);
}

// Amethyst Task 32 (2026-09): ESSL 300 only allows CONSTANT integral
// expressions when indexing fragment-output arrays ("array indexes for
// fragment outputs must be constant integral expressions" -- the ANGLE
// rejection that killed every minecraft:oit_transmittance_* pipeline).
// Minecraft 26.x's OIT passes write
//     layout(location = 0) out vec4 coeff[ATTACHMENTS];
//     ... coeff[attachmentIndex][i] = ...   // loop variables -- dynamic
// which desktop GLSL accepts and this converter used to pass through
// verbatim. Rewrite every access through a global scratch array (dynamic
// indexing of a plain global is legal ES 3.00) and copy out with constant
// indices at the end of main(). Reads of the output array are redirected the
// same way; outputs are write-only by convention so a read-before-write only
// ever observes the zero-initialized scratch, never a previous frame.
//
// Runs AFTER removeLayoutBinding (declarations have no binding qualifier
// left) and AFTER forceSupporterOutput (global precision is in place).
std::string fix_dynamic_output_indexing(const std::string& essl) {
    static std::regex out_arr(
        R"((layout\s*\(\s*location\s*=\s*\d+\s*\)\s*)?out\s+(?:(highp|mediump|lowp)\s+)?(\w+)\s+(\w+)\s*\[\s*(\d+)\s*\]\s*;)");
    struct ArrInfo {
        std::string name, prec, type;
        int n;
    };
    std::vector<ArrInfo> arrs;
    std::vector<std::string> decls;  // protected declaration + scratch decl
    std::string cur = essl;

    // (a) Collect output-array declarations, replace each with a plain marker
    // so the access rewrite in (b) cannot touch the declaration itself.
    for (int idx = 0;; ++idx) {
        std::smatch m;
        if (!std::regex_search(cur, m, out_arr)) break;
        ArrInfo a;
        a.prec = m[2].str();
        a.type = m[3].str();
        a.name = m[4].str();
        a.n = atoi(m[5].str().c_str());
        if (a.n <= 0 || a.n > 64) break;  // defensive: absurd size, bail out
        arrs.push_back(a);
        char marker[48];
        snprintf(marker, sizeof marker, "@@MGOUTARR%d@@", idx);
        decls.push_back(m[0].str() + "\n" + (a.prec.empty() ? "" : a.prec + " ") + a.type + " " +
                        a.name + "_mgio[" + std::to_string(a.n) + "];");
        cur.replace(m.position(), m.length(), marker);
    }
    if (arrs.empty()) return essl;

    // (b) Rewrite every  <name>[  access to the scratch array (word boundary).
    for (const auto& a : arrs) {
        cur = std::regex_replace(cur, std::regex("\\b" + a.name + "\\["), a.name + "_mgio[");
    }

    // (c) Restore declarations, each followed by its scratch declaration.
    // Plain string replacement -- the marker must never be treated as a regex.
    for (size_t i = 0; i < decls.size(); ++i) {
        char marker[48];
        snprintf(marker, sizeof marker, "@@MGOUTARR%d@@", (int)i);
        const std::string mk(marker);
        size_t p = cur.find(mk);
        while (p != std::string::npos) {
            cur.replace(p, mk.length(), decls[i]);
            p = cur.find(mk, p);
        }
    }

    // (d) Insert constant-index copies just before main()'s closing brace.
    static std::regex main_re(R"(void\s+main\s*\(\s*\)\s*\{)");
    std::smatch mm;
    if (std::regex_search(cur, mm, main_re)) {
        const size_t body_start = mm.position() + mm.length();
        int depth = 1;
        size_t i = body_start;
        for (; i < cur.length() && depth > 0; ++i) {
            if (cur[i] == '{') depth++;
            else if (cur[i] == '}') depth--;
        }
        if (depth == 0 && i > 0) {
            const size_t close = i - 1;
            std::string copies = "\n    // mg: constant-index fragment-output copies (ESSL 300)\n";
            for (const auto& a : arrs) {
                for (int k = 0; k < a.n; ++k) {
                    copies += "    " + a.name + "[" + std::to_string(k) + "] = " + a.name +
                              "_mgio[" + std::to_string(k) + "];\n";
                }
            }
            cur.insert(close, copies);
        }
    }
    return cur;
}

std::string GLSLtoGLSLES(const char* glsl_code, GLenum glsl_type, uint essl_version, uint glsl_version,
                         int& return_code) {
    std::string sha256_string(glsl_code);
    sha256_string += "\n//" + std::to_string(MAJOR) + "." + std::to_string(MINOR) + "." + std::to_string(REVISION) +
                     "|" + std::to_string(essl_version);
    const char* cachedESSL = Cache::get_instance().get(sha256_string.c_str());
    // SPIRV-Cross output always starts with "#version". A cached entry that
    // does not is corrupt — e.g. written by a build whose glslang/SPIRV-Cross
    // were not at the pinned commits, which on iOS surfaced as ANGLE failing
    // every shader with "ERROR: 1:1: '' : syntax error". Fall through to a
    // fresh conversion instead; the put() below then overwrites the bad
    // entry, so the cache self-heals on the first miss.
    if (cachedESSL && strncmp(cachedESSL, "#version", 8) == 0) {
        LOG_D("GLSL Hit Cache:\n%s\n-->\n%s", glsl_code, cachedESSL)
        return_code = 0;
        return (char*)cachedESSL;
    }
    if (cachedESSL) {
        LOG_W_FORCE("[MG] Cached ESSL is corrupt (head='%.64s') — ignoring cache and re-translating.", cachedESSL)
    }

    return_code = -1;
    // std::string converted = glsl_version<140? GLSLtoGLSLES_1(glsl_code, glsl_type, essl_version,
    // return_code):GLSLtoGLSLES_2(glsl_code, glsl_type, essl_version, return_code);
    std::string converted = GLSLtoGLSLES_2(glsl_code, glsl_type, essl_version, return_code);
    if (return_code >= 0 && !converted.empty()) {
        converted = process_uniform_declarations(converted);
        Cache::get_instance().put(sha256_string.c_str(), converted.c_str());
    }

    return (return_code >= 0) ? converted : glsl_code;
}

std::string replace_line_starting_with(const std::string& glslCode, const std::string& starting,
                                       const std::string& substitution = "") {
    std::string result;
    size_t length = glslCode.size();
    size_t start = 0;
    size_t current = 0;

    auto append_chunk = [&](size_t end) {
        if (end > start) {
            result.append(glslCode, start, end - start);
        }
    };

    while (current < length) {
        // Skip whitespace at line begin
        size_t lineStart = current;
        while (current < length && (glslCode[current] == ' ' || glslCode[current] == '\t')) {
            current++;
        }

        // Check whether #line directive
        bool isLineDirective = false;
        if (current + 5 <= length && glslCode.compare(current, 5, "#line") == 0) {
            isLineDirective = true;
        }

        // Move to line end
        while (current < length && glslCode[current] != '\r' && glslCode[current] != '\n') {
            current++;
        }

        // Handle carriage return
        size_t newlineLength = 0;
        if (current < length) {
            if (glslCode[current] == '\r') {
                newlineLength = (current + 1 < length && glslCode[current + 1] == '\n') ? 2 : 1;
            } else {
                newlineLength = 1;
            }
        }

        if (isLineDirective) {
            // Find #line directive ->
            //  1. Append chunk
            append_chunk(lineStart); // from chunk_begin to before `#line`
            // 2. Skip this line (incl. \n)
            current += newlineLength;
            start = current; // 3. Starting from next line

            result += substitution;
        } else {
            // move to a new line
            current += newlineLength;
        }
    }

    // append last block
    append_chunk(current);
    return result;
}

static inline void replace_all(std::string& str, const std::string& from, const std::string& to) {
    size_t start_pos = 0;
    while ((start_pos = str.find(from, start_pos)) != std::string::npos) {
        str.replace(start_pos, from.length(), to);
        start_pos += to.length(); // Handles case where 'to' is a substring of 'from'
    }
}

static size_t find_insertion_point(const std::string& glsl) {
    size_t pos = 0;
    size_t insertion_point = 0;

    size_t version_pos = glsl.find("#version");
    if (version_pos != std::string::npos) {
        size_t version_end = glsl.find('\n', version_pos);
        if (version_end == std::string::npos) {
            version_end = glsl.length();
        } else {
            version_end++;
        }
        insertion_point = version_end;
        pos = version_end;
    } else {
        insertion_point = 0;
        pos = 0;
    }

    while (pos < glsl.length()) {
        size_t line_begin = pos;
        while (pos < glsl.length() && std::isspace(glsl[pos])) {
            pos++;
        }
        if (pos >= glsl.length()) break;

        if (glsl[pos] == '#') {
            pos++;
            while (pos < glsl.length() && std::isspace(glsl[pos])) {
                pos++;
            }
            if (glsl.compare(pos, 9, "extension") == 0) {
                size_t ext_end = glsl.find('\n', pos);
                if (ext_end == std::string::npos) {
                    ext_end = glsl.length();
                } else {
                    ext_end++;
                }
                insertion_point = ext_end;
                pos = ext_end;
            } else {
                break;
            }
        } else {
            break;
        }
    }

    return insertion_point;
}

// ----------------------------------------------------------------------------
// Buffer-texture (samplerBuffer) emulation for ES 3.0 backends.
//
// The previous implementation rewrote texelFetch argument lists with
//     std::regex(R"(texelFetch\s*\(\s*(\w+)\s*,\s*([^)]+?)\s*\))")
// whose [^)]+? stops at the FIRST ')' -- so any coordinate expression with a
// nested call was shredded mid-way. Sodium 0.9.x's
//     texelFetch(u_SectionTimeInfo, int((u_RegionID * 256u) + uint(chunkId)))
// came out as
//     ivec2((int((u_RegionID * 256u) % u_BufferTexWidth, ...)
// which (a) makes 'temp uint % uniform int' out of u_RegionID * 256u -- a
// guaranteed glslang parse error at desktop 330 ("0:%d '%' : wrong operand
// types", plus the bogus "missing #endif" cascade) and (b) unbalances the
// parens for everything after it. Every Sodium terrain pipeline compiles that
// one vertex shader, so the whole world went unrendered. The scanner below
// tracks real paren depth instead; a text-level regex cannot do this job.
// ----------------------------------------------------------------------------

namespace {

// ')' matching the '(' at 'open'; npos when unbalanced (callers leave the
// source untouched instead of corrupting it).
size_t find_matching_paren(const std::string& source, size_t open) {
    if (open >= source.size() || source[open] != '(') return std::string::npos;
    int depth = 0;
    for (size_t i = open; i < source.size(); ++i) {
        if (source[i] == '(') {
            depth++;
        } else if (source[i] == ')') {
            if (--depth == 0) return i;
        }
    }
    return std::string::npos;
}

size_t skip_ws(const std::string& s, size_t p) {
    while (p < s.size() && std::isspace((unsigned char)s[p])) ++p;
    return p;
}

std::string trim_ws(const std::string& s) {
    size_t b = 0, e = s.size();
    while (b < e && std::isspace((unsigned char)s[b])) ++b;
    while (e > b && std::isspace((unsigned char)s[e - 1])) --e;
    return s.substr(b, e - b);
}

// Split [begin, end) on top-level commas (paren depth 0 relative to begin).
std::vector<std::string> split_top_level_args(const std::string& source, size_t begin, size_t end) {
    std::vector<std::string> args;
    int depth = 0;
    size_t start = begin;
    for (size_t i = begin; i < end; ++i) {
        char c = source[i];
        if (c == '(') {
            depth++;
        } else if (c == ')') {
            depth--;
        } else if (c == ',' && depth == 0) {
            args.push_back(source.substr(start, i - start));
            start = i + 1;
        }
    }
    args.push_back(source.substr(start, end - start));
    return args;
}

// "ivec2 ( EXPR )" with EXPR containing no top-level comma (i.e. a linear
// index, not a 2D coordinate) -> true, EXPR in 'inner'.
bool parse_single_component_ivec2(const std::string& arg, std::string& inner) {
    const std::string head = "ivec2";
    if (arg.compare(0, head.size(), head) != 0) return false;
    size_t p = skip_ws(arg, head.size());
    if (p >= arg.size() || arg[p] != '(') return false;
    size_t close = find_matching_paren(arg, p);
    if (close == std::string::npos) return false;
    if (trim_ws(arg.substr(close + 1)).size() != 0) return false;
    size_t begin = p + 1, end = close;
    for (size_t i = begin; i < end; ++i) {
        if (arg[i] == '(') {
            // only track depth; commas inside nested parens are not top-level
        } else if (arg[i] == ',') {
            // any top-level comma means 2+ components -> a real 2D coordinate
            return false;
        }
    }
    inner = trim_ws(arg.substr(begin, end - begin));
    return !inner.empty();
}

} // namespace

void process_sampler_buffer(std::string& source) {
    // The check matches isamplerBuffer/usamplerBuffer too (substring), and the
    // swap below keeps those single-letter prefixes intact.
    if (source.find("samplerBuffer") == std::string::npos) {
        return;
    }

    // samplerBuffer / isamplerBuffer / usamplerBuffer -> (i/u)sampler2D
    size_t pos = 0;
    while ((pos = source.find("samplerBuffer", pos)) != std::string::npos) {
        source.replace(pos, 13, "sampler2D");
        pos += 9;
    }

    // texelFetch rewriting with paren-aware argument parsing:
    //   texelFetch(SAMP, COORD)                     (buffer-texture form)
    //     -> texelFetch(SAMP, ivec2((int(COORD)) % u_BufferTexWidth,
    //                               (int(COORD)) / u_BufferTexWidth), 0)
    //   texelFetch(SAMP, ivec2(INDEX), 0)           (pre-flattened linear form)
    //     -> texelFetch(SAMP, bufferCoords(int(INDEX)), 0)
    // COORD/INDEX go through int(...): the coordinate of a buffer fetch is an
    // int in valid GLSL, but drivers accept uint expressions there and the
    // emulation's '% u_BufferTexWidth' would then mix uint with a uniform int
    // -- illegal at desktop GLSL 330 and an instant parse error. int() is an
    // identity for the already-int case, so this only ever repairs.
    // Genuine 2D fetches -- texelFetch(SAMP, ivec2(X, Y), 0) -- are left alone;
    // the old regex pass turned those into bufferCoords(X, Y), a call whose
    // arity never matched the helper.
    static const std::string kFetch = "texelFetch";
    std::string out;
    out.reserve(source.size() + 128);
    size_t copy_from = 0;
    size_t scan = 0;
    bool rewrote_any = false;
    while ((scan = source.find(kFetch, scan)) != std::string::npos) {
        if (scan > 0 && (std::isalnum((unsigned char)source[scan - 1]) || source[scan - 1] == '_')) {
            scan += kFetch.size();
            continue;
        }
        size_t p = skip_ws(source, scan + kFetch.size());
        if (p >= source.size() || source[p] != '(') {
            scan += kFetch.size();
            continue;
        }
        size_t close = find_matching_paren(source, p);
        if (close == std::string::npos) break; // unbalanced overall: bail out untouched

        std::vector<std::string> args = split_top_level_args(source, p + 1, close);
        for (std::string& a : args) a = trim_ws(std::move(a));

        std::string replacement;
        if (args.size() == 2 && !args[0].empty() && !args[1].empty()) {
            const std::string& coord = args[1];
            replacement = "texelFetch(" + args[0] + ", ivec2((int(" + coord + ")) % u_BufferTexWidth, (int(" +
                          coord + ")) / u_BufferTexWidth), 0)";
        } else if (args.size() == 3 && args[2] == "0") {
            std::string inner;
            if (parse_single_component_ivec2(args[1], inner)) {
                replacement = "texelFetch(" + args[0] + ", bufferCoords(int(" + inner + ")), 0)";
            }
        }

        if (replacement.empty()) {
            // Not a buffer-style fetch (or malformed): keep as-is and keep
            // scanning inside it for further calls.
            scan += kFetch.size();
            continue;
        }
        out.append(source, copy_from, scan - copy_from);
        out.append(replacement);
        rewrote_any = true;
        scan = close + 1;
        copy_from = scan;
    }
    if (rewrote_any) {
        out.append(source, copy_from, source.size() - copy_from);
        source = std::move(out);
    }

    const char* boundaryProtection = R"(
ivec2 bufferCoords(int index) {
    int width = u_BufferTexWidth;
    int x = index % width;
    int y = index / width;
    if (y >= u_BufferTexHeight) {
        y = u_BufferTexHeight - 1;
        x = width - 1;
    }
    return ivec2(x, y);
}
)";

    size_t insertion_point = find_insertion_point(source);
    if (insertion_point != std::string::npos) {
        source.insert(insertion_point, boundaryProtection);
    }

    const char* uniformDecl = R"(
uniform int u_BufferTexWidth;
uniform int u_BufferTexHeight;
)";

    insertion_point = find_insertion_point(source);
    if (insertion_point != std::string::npos) {
        insertion_point = source.find('\n', insertion_point);
        if (insertion_point != std::string::npos) {
            source.insert(insertion_point + 1, uniformDecl);
        }
    }
}

static void inject_textureQueryLod(std::string& glsl) {
    const std::regex defRegex(R"(vec2\s+mg_textureQueryLod\s*\()", std::regex::ECMAScript);

    if (glsl.find("textureQueryLod") == std::string::npos) {
        return;
    }
    if (std::regex_search(glsl, defRegex)) {
        return;
    }

    const std::string textureQueryLodImpl = R"(
#define textureQueryLod mg_textureQueryLod

vec2 mg_textureQueryLod(sampler2D tex, vec2 uv) {
    vec2 texSizeF = vec2(textureSize(tex, 0));
    vec2 dFdx_uv = dFdx(uv * texSizeF);
    vec2 dFdy_uv = dFdy(uv * texSizeF);
    float maxDerivative = max(length(dFdx_uv), length(dFdy_uv));
    float lod = log2(maxDerivative);
    return vec2(lod);
}
)";

    size_t insertPos = find_insertion_point(glsl);
    glsl.insert(insertPos, "\n" + textureQueryLodImpl + "\n");
}

static inline void inject_temporal_filter(std::string& glsl) {
    const std::regex defRegex(R"(vec4\s+GI_TemporalFilter\s*\()", std::regex::ECMAScript);

    if (glsl.find("GI_TemporalFilter") == std::string::npos) {
        return;
    }
    if (std::regex_search(glsl, defRegex)) {
        return;
    }

    const std::regex uniformRegex(
        R"(^\s*(?:layout\s*\([^)]*\)\s*)?uniform\s+\w+(?:\s*\[\s*\d+\s*\])?\s+\w+(?:\s*\[\s*\d+\s*\])?\s*;.*$)",
        std::regex::ECMAScript | std::regex::multiline);
    std::sregex_iterator it(glsl.begin(), glsl.end(), uniformRegex);
    std::sregex_iterator end;
    size_t insertPos = 0;
    for (; it != end; ++it) {
        insertPos = it->position() + it->length();
    }

    const std::string GI_TemporalFilterImpl = R"(
vec4 GI_TemporalFilter() {
    vec2 uv = gl_FragCoord.xy / screenSize;
    uv += taaJitter * pixelSize;
    vec4 currentGI = texture(colortex0, uv);
    float depth = texture(depthtex0, uv).r;
    vec4 clipPos = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 viewPos = gbufferProjectionInverse * clipPos;
    viewPos /= viewPos.w;
    vec4 worldPos = gbufferModelViewInverse * viewPos;
    vec4 prevClipPos = gbufferPreviousProjection * (gbufferPreviousModelView * worldPos);
    prevClipPos /= prevClipPos.w;
    vec2 prevUV = prevClipPos.xy * 0.5 + 0.5;
    vec4 historyGI = texture(colortex1, prevUV);
    float difference = length(currentGI.rgb - historyGI.rgb);
    float thresholdValue = 0.1;
    float adaptiveBlend = mix(0.9, 0.0, smoothstep(thresholdValue, thresholdValue * 2.0, difference));
    vec4 filteredGI = mix(currentGI, historyGI, adaptiveBlend);
    if (difference > thresholdValue * 2.0) {
        filteredGI = currentGI;
    }
    return filteredGI;
}
)";
    glsl.insert(insertPos, "\n" + GI_TemporalFilterImpl + "\n");
}
#define xstr(s) str(s)
#define str(s) #s

void inject_mg_macro_definition(std::string& glslCode) {
    std::string macro_definitions =
        "\n#define MG_MOBILEGLUES\n"
        "#define MG_MOBILEGLUES_VERSION " xstr(MAJOR) xstr(MINOR) xstr(REVISION) xstr(PATCH) "\n";

    size_t versionPos = glslCode.rfind("#version");
    size_t insertionPos = 0;

    if (versionPos != std::string::npos) {
        size_t nextNewline = glslCode.find('\n', versionPos);
        insertionPos = (nextNewline != std::string::npos) ? nextNewline + 1 : glslCode.length();
    } else {
        size_t firstNewline = glslCode.find('\n');
        insertionPos = (firstNewline != std::string::npos) ? firstNewline + 1 : 0;
    }

    glslCode.insert(insertionPos, macro_definitions);
}

std::string preprocess_glsl(const std::string& glsl, GLenum shaderType) {
    std::string ret = glsl;
    // Remove lines beginning with `#line`
    ret = replace_line_starting_with(ret, "#line");
    // Act as if disable_GL_ARB_derivative_control is false
    replace_all(ret, "#ifdef GL_ARB_derivative_control", "#if 0");
    replace_all(ret, "#ifndef GL_ARB_derivative_control", "#if 1");

    // Polyfill transpose()
    replace_all(ret, "const mat3 rotInverse = transpose(rot);",
                "const mat3 rotInverse = mat3(rot[0][0], rot[1][0], rot[2][0], rot[0][1], rot[1][1], rot[2][1], "
                "rot[0][2], rot[1][2], rot[2][2]);");

    // GI_TemporalFilter injection
    inject_temporal_filter(ret);

    // textureQueryLod injection
    if (!g_gles_caps.GL_EXT_texture_query_lod) {
        inject_textureQueryLod(ret);
    }

    // MobileGlues macros injection
    inject_mg_macro_definition(ret);

    if (hardware->emulate_texture_buffer) {
        // Sampler buffer processing
        process_sampler_buffer(ret);
    }

    return ret;
}

int get_or_add_glsl_version(std::string& glsl) {
    int glsl_version = getGLSLVersion(glsl.c_str());
    if (glsl_version == -1) {
        glsl_version = 150;
        glsl.insert(0, "#version 150\n");
    } else if (glsl_version < 140) {
        // force upgrade glsl version
        glsl = replace_line_starting_with(glsl, "#version", "#version 150 compatibility\n");
        glsl_version = 150;
    }

    LOG_D("GLSL version: %d", glsl_version)
    return glsl_version;
}

std::vector<unsigned int> glsl_to_spirv(GLenum shader_type, int glsl_version, const char* const* shader_src,
                                        int& errc, bool safe_mode = false) {
    EShLanguage shader_language;
    switch (shader_type) {
    case GL_VERTEX_SHADER:
        shader_language = EShLanguage::EShLangVertex;
        break;
    case GL_FRAGMENT_SHADER:
        shader_language = EShLanguage::EShLangFragment;
        break;
    case GL_COMPUTE_SHADER:
        shader_language = EShLanguage::EShLangCompute;
        break;
    case GL_TESS_CONTROL_SHADER:
        shader_language = EShLanguage::EShLangTessControl;
        break;
    case GL_TESS_EVALUATION_SHADER:
        shader_language = EShLanguage::EShLangTessEvaluation;
        break;
    case GL_GEOMETRY_SHADER:
        shader_language = EShLanguage::EShLangGeometry;
        break;
    default:
        LOG_D("GLSL type not supported!")
        errc = -1;
        return {};
    }

    glslang::TShader shader(shader_language);
    shader.setStrings(shader_src, 1);

    using namespace glslang;
    shader.setEnvInput(EShSourceGlsl, shader_language, EShClientVulkan, glsl_version);
    shader.setEnvClient(EShClientOpenGL, EShTargetOpenGL_450);
    shader.setEnvTarget(EShTargetSpv, EShTargetSpv_1_5);
    shader.setAutoMapLocations(true);
    shader.setPreamble("#undef VULKAN\n");
    shader.setAutoMapBindings(true);

    TBuiltInResource TBuiltInResource_resources = InitResources();

    if (!shader.parse(&TBuiltInResource_resources, glsl_version, true, EShMsgDefault)) {
        // Always report parse failures: on iOS this is the only way to see
        // WHY the desktop-GLSL -> SPIR-V stage failed (it is currently broken
        // there and silently falls back to raw desktop GLSL, which the host
        // driver then rejects with a misleading "1:1: '' : syntax error").
        LOG_W_FORCE("GLSL Compiling ERROR (parse, glslver=%d): \n%s", glsl_version, shader.getInfoLog())
        LOG_D("GLSL Compiling ERROR: \n%s", shader.getInfoLog())
        errc = -1;
        return {};
    }
    LOG_W_FORCE("GLSL parse OK (glslver=%d)", glsl_version)
    LOG_D("GLSL Compiled.")

    glslang::TProgram program;
    program.addShader(&shader);

    if (!program.link(EShMsgDefault)) {
        LOG_W_FORCE("Shader Linking ERROR (glslver=%d): %s", glsl_version, program.getInfoLog())
        LOG_D("Shader Linking ERROR: %s", program.getInfoLog())
        errc = -1;
        return {};
    }
    LOG_D("Shader Linked.")
    std::vector<unsigned int> spirv_code;
    glslang::SpvOptions spvOptions;
    // safe_mode (set by the SIGSEGV-retry path) skips the optional SPIR-V
    // optimizer pass: if the arm64 fault lives inside it, the unoptimized
    // SPIR-V still cross-compiles to a valid, working ESSL shader.
    spvOptions.disableOptimizer = safe_mode;
    glslang::GlslangToSpv(*program.getIntermediate(shader_language), spirv_code, &spvOptions);
    errc = 0;
    return spirv_code;
}

// The context owns the ParsedIR, the compiler and every string they hand back, and the only
// destroy used to sit past the early return. A shader the ES backend rejects is a normal
// outcome and failed translations are not cached, so that leaked the lot again on every
// resource-pack reload. Scoped so no exit can skip it.
namespace {
struct spvc_context_guard_t {
    spvc_context context = nullptr;
    spvc_context_guard_t() = default;
    ~spvc_context_guard_t() {
        if (context) spvc_context_destroy(context);
    }
    spvc_context_guard_t(const spvc_context_guard_t&) = delete;
    spvc_context_guard_t& operator=(const spvc_context_guard_t&) = delete;
};
} // namespace

// SPIRV-Cross throws internally and turns that into a result code at its C boundary; on failure
// it leaves the out-parameter untouched. Dropping the code therefore hands the next call a
// handle that was never written, which crashes rather than reporting anything.
static bool spvc_ok(spvc_context context, spvc_result res, const char* what) {
    if (res == SPVC_SUCCESS) {
        return true;
    }
    LOG_W_FORCE("Error: %s failed in spirv-cross: %s", what, spvc_context_get_last_error_string(context))
    LOG_E("Error: %s failed in spirv-cross: %s", what, spvc_context_get_last_error_string(context))
    return false;
}

std::string spirv_to_essl(std::vector<unsigned int> spirv, uint essl_version, int& errc) {
    spvc_parsed_ir ir = nullptr;
    spvc_compiler compiler_glsl = nullptr;
    spvc_compiler_options options = nullptr;
    const char* result = nullptr;

    const SpvId* p_spirv = spirv.data();
    size_t word_count = spirv.size();

    LOG_D("spirv_code.size(): %d", spirv.size())

    // Declared before 'essl': the compiled source lives in context-owned memory and is only
    // copied out when the std::string is constructed, so the guard has to outlive it.
    spvc_context_guard_t guard;
    if (spvc_context_create(&guard.context) != SPVC_SUCCESS || !guard.context) {
        LOG_E("Error: could not create a spirv-cross context.")
        errc = -1;
        return "";
    }
    spvc_context context = guard.context;

    if (!spvc_ok(context, spvc_context_parse_spirv(context, p_spirv, word_count, &ir), "spvc_context_parse_spirv") ||
        !ir) {
        errc = -1;
        return "";
    }
    if (!spvc_ok(context,
                 spvc_context_create_compiler(context, SPVC_BACKEND_GLSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP,
                                              &compiler_glsl),
                 "spvc_context_create_compiler") ||
        !compiler_glsl) {
        errc = -1;
        return "";
    }
    if (!spvc_ok(context, spvc_compiler_create_compiler_options(compiler_glsl, &options),
                 "spvc_compiler_create_compiler_options") ||
        !options) {
        errc = -1;
        return "";
    }
    // A silently dropped GLSL_ES option would emit desktop GLSL and hand it straight to the
    // driver, so these are checked too.
    if (!spvc_ok(context,
                 spvc_compiler_options_set_uint(options, SPVC_COMPILER_OPTION_GLSL_VERSION,
                                                essl_version >= 300 ? essl_version : 300),
                 "spvc_compiler_options_set_uint") ||
        !spvc_ok(context, spvc_compiler_options_set_bool(options, SPVC_COMPILER_OPTION_GLSL_ES, SPVC_TRUE),
                 "spvc_compiler_options_set_bool") ||
        !spvc_ok(context, spvc_compiler_install_compiler_options(compiler_glsl, options),
                 "spvc_compiler_install_compiler_options")) {
        errc = -1;
        return "";
    }
    if (!spvc_ok(context, spvc_compiler_compile(compiler_glsl, &result), "spvc_compiler_compile") || !result) {
        errc = -1;
        return "";
    }

    std::string essl = result;

    errc = 0;
    return essl;
}

static bool glslang_inited = false;

// Coarse pipeline-stage marker, updated before each conversion sub-step. A
// recovered SIGSEGV reports it so one device log says WHICH stage died
// (parse / link / SPIR-V codegen+optimizer / SPIRV-Cross / ESSL post).
// Declared outside the Apple-only guard block because the conversion impl
// (shared with the desktop harness) updates it unconditionally.
static thread_local const char* t_conv_stage = "idle";

#if defined(__APPLE__)
namespace {
// glslang's recursive-descent parser and its semantic analysis recurse through
// the whole expression/declaration tree. iOS threads created by pthread_create
// default to a 512 KB stack and JVM threads get 1-2 MB, while the harness runs
// with the 8 MB main-thread stack -- which is why complex shaders (Sodium etc.)
// SIGSEGV'd inside glslang::TParseContext::lValueErrorCheck on-device but never
// locally. When the calling thread's stack is smaller than 8 MB, run the whole
// conversion on a dedicated 32 MB-stack thread; results are copied back
// synchronously. One pthread_create per compiled shader is negligible next to
// the conversion itself.
struct BigStackJob {
    void (*fn)(void*);
    void* arg;
};

// ---------------------------------------------------------------------------
// SIGSEGV safety net for the conversion thread.
//
// History: three device builds in a row (2.0.1 .. 2.0.3) died with SIGSEGV at
// glslang::TParseContext::lValueErrorCheck+0x264 while parsing Minecraft
// 26.x's position_color vertex shader on iOS/arm64 -- an input that parses
// fine under x86_64 with the same pinned glslang and is clean under ASan.
// The fatal fault turned a per-shader GLSL problem into a whole-process kill
// during startup.
//
// The guard below confines that blast radius: while a conversion runs on the
// dedicated big-stack thread, a SIGSEGV in it unwinds back to the conversion
// entry via siglongjmp, the failure is logged, and the shader simply fails to
// convert (a per-shader GLSL error -- Minecraft 26.x can cope with that).
// Faults on any other thread (or outside a conversion) are forwarded to
// whatever handler was installed before us (HotSpot, PLCrashReporter, ...).
// ---------------------------------------------------------------------------
static thread_local sigjmp_buf t_conv_jmp;
static thread_local bool t_in_conversion = false;
static sigjmp_buf dummy_jmp;
static struct sigaction g_prev_sigsegv{};
static bool g_prev_sigsegv_valid = false;

// Best-effort crash-site report from inside the signal handler. We are
// already past the point of caring about strict async-signal-safety (the
// longjmp below aborts a corrupted computation anyway); what matters is
// that the offsets land in the log so the arm64 fault can be symbolicated
// offline against the exact CI dylib, the way lValueErrorCheck+0x264 was.
static void report_crash_site(siginfo_t* info, void* uctx) {
    uint64_t pc = 0, lr = 0, far_addr = 0;
#if defined(__APPLE__) && defined(__aarch64__)
    ucontext_t* uc = (ucontext_t*)uctx;
    mcontext_t mc = uc ? uc->uc_mcontext : nullptr;
    if (uc && mc && uc->uc_mcsize >= sizeof(*mc)) {
        pc = mc->__ss.__pc;
        lr = mc->__ss.__lr;
        far_addr = mc->__es.__far;
    }
#elif defined(__APPLE__) && defined(__x86_64__)
    ucontext_t* uc = (ucontext_t*)uctx;
    mcontext_t mc = uc ? uc->uc_mcontext : nullptr;
    if (uc && mc && uc->uc_mcsize >= sizeof(*mc)) {
        pc = mc->__ss.__rip;
        lr = mc->__ss.__rip;
        far_addr = mc->__es.__faultvaddr;
    }
#else
    (void)uctx;
#endif
    if (pc != 0) {
        Dl_info dli{};
        if (dladdr((void*)pc, &dli) && dli.dli_fbase) {
            uint64_t base = (uint64_t)dli.dli_fbase;
            const char* img = dli.dli_fname ? strrchr(dli.dli_fname, '/') : nullptr;
            img = img ? img + 1 : dli.dli_fname;
            LOG_W_FORCE("[MG] crash site: stage='%s' pc=0x%llx (pc-%s+0x%llx) lr=0x%llx far=0x%llx si_addr=0x%p",
                        t_conv_stage, (unsigned long long)pc, img ? img : "?",
                        (unsigned long long)(pc - base), (unsigned long long)lr,
                        (unsigned long long)far_addr, info ? info->si_addr : nullptr)
        } else {
            LOG_W_FORCE("[MG] crash site: stage='%s' pc=0x%llx lr=0x%llx far=0x%llx si_addr=0x%p (module unknown)",
                        t_conv_stage, (unsigned long long)pc, (unsigned long long)lr,
                        (unsigned long long)far_addr, info ? info->si_addr : nullptr)
        }
    } else {
        LOG_W_FORCE("[MG] crash site: stage='%s' si_addr=0x%p (pc unavailable)",
                    t_conv_stage, info ? info->si_addr : nullptr)
    }
}

static void conversion_sigsegv_handler(int sig, siginfo_t* info, void* uctx) {
    if (t_in_conversion) {
        t_in_conversion = false;
        report_crash_site(info, uctx);
        siglongjmp(t_conv_jmp, 1);
    }
    // Not ours: forward to the previous handler chain (JVM, PLCrash, ...).
    if (g_prev_sigsegv_valid && (g_prev_sigsegv.sa_flags & SA_SIGINFO) && g_prev_sigsegv.sa_sigaction) {
        g_prev_sigsegv.sa_sigaction(sig, info, uctx);
        return;
    }
    if (g_prev_sigsegv_valid && g_prev_sigsegv.sa_handler &&
        g_prev_sigsegv.sa_handler != SIG_DFL && g_prev_sigsegv.sa_handler != SIG_IGN) {
        g_prev_sigsegv.sa_handler(sig);
        return;
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

// Called once per process, at the first conversion. By that time the JVM and
// PLCrashReporter have already installed their handlers, which we chain to.
static void install_conversion_sigsegv_guard() {
    static std::once_flag once;
    std::call_once(once, [] {
        struct sigaction sa{};
        sa.sa_sigaction = conversion_sigsegv_handler;
        sa.sa_flags = SA_SIGINFO;
        sigemptyset(&sa.sa_mask);
        g_prev_sigsegv_valid = (sigaction(SIGSEGV, &sa, &g_prev_sigsegv) == 0);
    });
}

static void* big_stack_trampoline(void* p) {
    BigStackJob* job = (BigStackJob*)p;
    job->fn(job->arg);
    return nullptr;
}

static bool run_on_big_stack_if_needed(void (*fn)(void*), void* arg) {
    // ALWAYS run on the dedicated 32 MB-stack thread.  pthread_get_stacksize_np()
    // is authoritative for pthread-created threads, but the JVM may hand out
    // large stacks (>= 8 MB) to some of its threads while the glslang recursive
    // descent still overflows inside them on complex shaders -- and a
    // mis-detected "plenty of headroom" case crashes the whole game.  The old
    // ">= 8 MB -> inline" fast path made the behaviour depend on the caller's
    // stack report; determinism beats the negligible cost of one pthread per
    // shader compile.
    pthread_attr_t attr;
    if (pthread_attr_init(&attr) != 0) return false;
    if (pthread_attr_setstacksize(&attr, 32u << 20) != 0) {
        pthread_attr_destroy(&attr);
        return false;
    }
    BigStackJob job{fn, arg};
    pthread_t tid;
    int rc = pthread_create(&tid, &attr, big_stack_trampoline, &job);
    pthread_attr_destroy(&attr);
    if (rc != 0) return false;
    pthread_join(tid, nullptr);
    return true;
}
} // namespace
#endif

struct GLSLtoGLSLES_2_Args {
    const char* glsl_code;
    GLenum glsl_type;
    uint essl_version;
    int* return_code;
    std::string* out;
    // safe_mode: run the SPIR-V pipeline with the optimizer disabled. Used
    // for the one-shot retry after a recovered SIGSEGV -- the optimizer is an
    // optional transform, so if a crash lives in it, the retry converts the
    // shader for real instead of falling back to unusable raw desktop GLSL.
    bool safe_mode = false;
};

static void GLSLtoGLSLES_2_impl(const char* glsl_code, GLenum glsl_type, uint essl_version,
                                int& return_code, std::string& out, bool safe_mode = false);

static void GLSLtoGLSLES_2_entry(void* p) {
    GLSLtoGLSLES_2_Args* a = (GLSLtoGLSLES_2_Args*)p;
#if defined(__APPLE__)
    if (sigsetjmp(t_conv_jmp, 1) != 0) {
        // SIGSEGV inside glslang/SPIRV-Cross on this dedicated thread (see
        // the guard notes above). Report a clean per-shader failure instead
        // of dying: -999 marks "conversion crashed" for the caller's log.
        LOG_W_FORCE("[MG] shader conversion CRASHED (SIGSEGV recovered on 32MB-stack thread, stage='%s', len=%zu, head='%.96s') -- reporting conversion failure",
                    t_conv_stage, strlen(a->glsl_code), a->glsl_code)
        *a->return_code = -999;
        a->out->clear();
        return;
    }
    t_in_conversion = true;
    GLSLtoGLSLES_2_impl(a->glsl_code, a->glsl_type, a->essl_version, *a->return_code, *a->out, a->safe_mode);
    t_in_conversion = false;
#else
    GLSLtoGLSLES_2_impl(a->glsl_code, a->glsl_type, a->essl_version, *a->return_code, *a->out);
#endif
}

std::string GLSLtoGLSLES_2(const char* glsl_code, GLenum glsl_type, uint essl_version, int& return_code) {
#if defined(__APPLE__)
    // Process-wide serialization of the whole GLSL->ESSL conversion (Amethyst
    // Task 30, 2026-09, hs_err_pid27946). glslang's parse/link/codegen share
    // process-global state (built-in symbol table, pools); Minecraft 26.x
    // issues glShaderSource from multiple Java threads (RenderThread +
    // Worker-Main during resource reload), so two conversions could parse
    // concurrently and corrupt each other's AST -- the on-device
    // "l-value of swizzle / selector read garbage" family that has killed
    // this process since MobileGlues 2.0.1 (x86_64 + ASan clean, arm64
    // device only). The lock lives on the CALLING thread around the hop:
    // the dedicated conversion thread always runs to completion (siglongjmp
    // lands inside the entry function, which then returns), so the join
    // returns and the lock releases even after a recovered SIGSEGV.
    // Recursive so any future re-entrant conversion path degrades to
    // sequential instead of deadlocking.
    static std::recursive_mutex g_conv_serial;
    std::lock_guard<std::recursive_mutex> conv_guard(g_conv_serial);

    // ---- Amethyst Task 37: cross-engine master compile lock ----
    // On-device evidence (latestlog 2026-09-06 18:42, GL renderer path):
    // while this converter ran, RenderPearl's shaderc compiles of complex
    // shaders (terrain/entity/clouds) crashed deterministically in the
    // SAME time window -- four shader engines were running concurrently
    // (this converter's embedded glslang+SPIRV-Cross vs shaderc/spvc shims,
    // with three independent locks). Negotiate the master lock exported by
    // libshaderc.dylib (the shaderc_shim forwarder, RTLD-safe dlopen of an
    // already-loaded image -> same instance) and hold it across the whole
    // conversion hop so shaderc compiles, spvc cross-compiles and MG
    // conversions are fully serialized. Lock order is one-way
    // (g_conv_serial -> master; the shims never take g_conv_serial), no
    // cycles. Failure to negotiate (shim absent, standalone MG build)
    // degrades to the Task-30 behavior above -- a no-op guard.
    struct MasterLockGuard {
        pthread_mutex_t* m;
        explicit MasterLockGuard(pthread_mutex_t* mm) : m(mm) {
            if (m) pthread_mutex_lock(m);
        }
        ~MasterLockGuard() { if (m) pthread_mutex_unlock(m); }
    };
    static pthread_mutex_t* ame_master = (pthread_mutex_t*)1; // 1 = not yet negotiated
    if (ame_master == (pthread_mutex_t*)1) {
        ame_master = nullptr;
        // dlopen an already-loaded image only bumps its refcount and returns
        // the same handle, so this never creates a second shaderc instance.
        // "ame_master_compile_lock" is not in the launcher's fishhook prefix
        // list, so dlsym resolves it unhooked.
        void* h = dlopen("libshaderc.dylib", RTLD_LAZY);
        if (h) {
            if (auto fn = (pthread_mutex_t* (*)())dlsym(h, "ame_master_compile_lock"))
                ame_master = fn();
        }
        LOG_I("[MG] amethyst master compile lock %s (shaderc/spvc/MG full serialization)",
              ame_master ? "negotiated" : "unavailable -- conversion serialized within MG only")
    }
    MasterLockGuard master_guard(ame_master);
    std::string out;
    int rc = 0;
    GLSLtoGLSLES_2_Args args{glsl_code, glsl_type, essl_version, &rc, &out};
    // Log BEFORE the conversion so a crash inside glslang is attributable:
    // if the next log shows this line but no completion, the SEGV happened on
    // the dedicated 32 MB stack (=> a real glslang bug, not a stack overflow).
#if defined(__APPLE__)
    install_conversion_sigsegv_guard();
#endif
    LOG_V("[MG] shader conversion dispatched to dedicated 32MB-stack thread (len=%zu, head='%.96s')",
          strlen(glsl_code), glsl_code)
    if (run_on_big_stack_if_needed(&GLSLtoGLSLES_2_entry, &args)) {
        if (rc == -999) {
            // One recovery shot in safe mode: the SPIR-V optimizer is an
            // optional pass, and if the arm64 fault lives inside it, running
            // without it turns a dead pipeline back into a working shader.
            // Each run_on_big_stack_if_needed() call spawns a fresh pthread,
            // so the retry also starts from clean glslang state.
            int rc2 = 0;
            std::string out2;
            GLSLtoGLSLES_2_Args args2{glsl_code, glsl_type, essl_version, &rc2, &out2, true};
            LOG_W_FORCE("[MG] conversion crashed -- retrying once with SPIR-V optimizer disabled (len=%zu, head='%.96s')",
                        strlen(glsl_code), glsl_code)
            if (run_on_big_stack_if_needed(&GLSLtoGLSLES_2_entry, &args2) && rc2 == 0 && !out2.empty()) {
                LOG_W_FORCE("[MG] conversion SUCCEEDED on optimizer-disabled retry (len=%zu) -- the SPIR-V optimizer path is the crasher",
                            strlen(glsl_code))
                return_code = rc2;
                return out2;
            }
            LOG_W_FORCE("[MG] optimizer-disabled retry did not produce a usable shader (rc=%d) -- reporting conversion failure", rc2)
        }
        return_code = rc;
        return out;
    }
    LOG_W_FORCE("[MG] shader conversion falling back to inline execution (big-stack thread unavailable)")
#endif
    std::string out2;
    GLSLtoGLSLES_2_impl(glsl_code, glsl_type, essl_version, return_code, out2);
    return out2;
}

static void GLSLtoGLSLES_2_impl(const char* glsl_code, GLenum glsl_type, uint essl_version,
                                int& return_code, std::string& out, bool safe_mode) {
    t_conv_stage = "preprocess";
    std::string correct_glsl_str = preprocess_glsl(glsl_code, glsl_type);
    LOG_D("Firstly converted GLSL:\n%s", correct_glsl_str.c_str())
    int glsl_version = get_or_add_glsl_version(correct_glsl_str);

    if (!glslang_inited) {
        glslang::InitializeProcess();
        glslang_inited = true;
    }
    const char* s[] = {correct_glsl_str.c_str()};
    int errc = 0;
    t_conv_stage = "glslang-parse+link+spv";
    std::vector<unsigned int> spirv_code = glsl_to_spirv(glsl_type, glsl_version, s, errc, safe_mode);
    if (errc != 0) {
        return_code = -1;
        out.clear();
        return;
    }
    errc = 0;
    t_conv_stage = "spirv-cross";
    std::string essl = spirv_to_essl(spirv_code, essl_version, errc);
    if (errc != 0) {
        return_code = -2;
        out.clear();
        return;
    }

    // Post-processing ESSL
    t_conv_stage = "essl-postprocess";

    if (glsl_type != GL_COMPUTE_SHADER) {
        essl = removeLayoutBinding(essl);
    }
    essl = processOutColorLocations(essl);
    essl = forceSupporterOutput(essl);
    // Amethyst Task 32: OIT fragment-output arrays are written with loop
    // variables, which ESSL 300 rejects. No-op when the shader has no
    // output arrays (all non-OIT shaders).
    essl = fix_dynamic_output_indexing(essl);

    t_conv_stage = "done";
    LOG_D("Originally GLSL to GLSL ES Complete: \n%s", essl.c_str())
    return_code = errc;
    out = std::move(essl);
}

std::string GLSLtoGLSLES_1(const char* glsl_code, GLenum glsl_type, uint esversion, int& return_code) { // useless now
    /*
#if !defined(__APPLE__)
    LOG_W("Warning: use glsl optimizer to convert shader.")
    if (esversion < 300) esversion = 300;
    std::string result = MesaConvertShader(glsl_code, glsl_type == GL_VERTEX_SHADER ? GL_VERTEX_SHADER :
GL_FRAGMENT_SHADER, 460LL, esversion);

    return_code = 0;
    return result;
#else
    LOG_W_FORCE("Cannot convert glsl with version %d in MacOS/iOS", esversion);
    return std::string(glsl_code);
#endif
    */
}
