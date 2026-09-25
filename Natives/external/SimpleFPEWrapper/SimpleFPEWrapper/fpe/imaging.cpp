// SimpleFPEWrapper - SimpleFPEWrapper/fpe/imaging.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "imaging.h"

#include "drawing1x.h"
#include "fpe.hpp"
#include "list.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <new>
#include <type_traits>
#include <vector>

namespace {

thread_local unsigned imaging_bypass_depth = 0;

struct pixel_format_t {
    int components = 0;
};

bool pixelFormat(GLenum format, pixel_format_t* out) {
    switch (format) {
    case GL_RED:
    case GL_GREEN:
    case GL_BLUE:
    case GL_ALPHA:
    case GL_LUMINANCE:
        out->components = 1;
        return true;
    case GL_RG:
    case GL_LUMINANCE_ALPHA:
        out->components = 2;
        return true;
    case GL_RGB:
    case GL_BGR:
        out->components = 3;
        return true;
    case GL_RGBA:
    case GL_BGRA:
        out->components = 4;
        return true;
    default: return false;
    }
}

bool scalarType(GLenum type, size_t* bytes) {
    switch (type) {
    case GL_BYTE:
    case GL_UNSIGNED_BYTE: *bytes = 1; return true;
    case GL_SHORT:
    case GL_UNSIGNED_SHORT:
    case GL_HALF_FLOAT: *bytes = 2; return true;
    case GL_INT:
    case GL_UNSIGNED_INT:
    case GL_FLOAT: *bytes = 4; return true;
    default: return false;
    }
}

bool packedType(GLenum type, int widths[4], int* components, size_t* bytes,
                bool* reversed) {
    *reversed = false;
    switch (type) {
    case GL_UNSIGNED_BYTE_3_3_2:
        widths[0] = 3; widths[1] = 3; widths[2] = 2; *components = 3; *bytes = 1; return true;
    case GL_UNSIGNED_BYTE_2_3_3_REV:
        widths[0] = 3; widths[1] = 3; widths[2] = 2; *components = 3; *bytes = 1;
        *reversed = true; return true;
    case GL_UNSIGNED_SHORT_5_6_5:
        widths[0] = 5; widths[1] = 6; widths[2] = 5; *components = 3; *bytes = 2; return true;
    case GL_UNSIGNED_SHORT_5_6_5_REV:
        widths[0] = 5; widths[1] = 6; widths[2] = 5; *components = 3; *bytes = 2;
        *reversed = true; return true;
    case GL_UNSIGNED_SHORT_4_4_4_4:
        widths[0] = 4; widths[1] = 4; widths[2] = 4; widths[3] = 4;
        *components = 4; *bytes = 2; return true;
    case GL_UNSIGNED_SHORT_4_4_4_4_REV:
        widths[0] = 4; widths[1] = 4; widths[2] = 4; widths[3] = 4;
        *components = 4; *bytes = 2; *reversed = true; return true;
    case GL_UNSIGNED_SHORT_5_5_5_1:
        widths[0] = 5; widths[1] = 5; widths[2] = 5; widths[3] = 1;
        *components = 4; *bytes = 2; return true;
    case GL_UNSIGNED_SHORT_1_5_5_5_REV:
        widths[0] = 5; widths[1] = 5; widths[2] = 5; widths[3] = 1;
        *components = 4; *bytes = 2; *reversed = true; return true;
    case GL_UNSIGNED_INT_8_8_8_8:
        widths[0] = widths[1] = widths[2] = widths[3] = 8;
        *components = 4; *bytes = 4; return true;
    case GL_UNSIGNED_INT_8_8_8_8_REV:
        widths[0] = widths[1] = widths[2] = widths[3] = 8;
        *components = 4; *bytes = 4; *reversed = true; return true;
    case GL_UNSIGNED_INT_10_10_10_2:
        widths[0] = widths[1] = widths[2] = 10; widths[3] = 2;
        *components = 4; *bytes = 4; return true;
    case GL_UNSIGNED_INT_2_10_10_10_REV:
        widths[0] = widths[1] = widths[2] = 10; widths[3] = 2;
        *components = 4; *bytes = 4; *reversed = true; return true;
    default: return false;
    }
}

bool pixelSize(GLenum format, GLenum type, size_t* bytes) {
    pixel_format_t info;
    if (!pixelFormat(format, &info)) return false;
    size_t scalar = 0;
    if (scalarType(type, &scalar)) {
        *bytes = scalar * static_cast<size_t>(info.components);
        return true;
    }
    int widths[4] = {}, components = 0;
    bool reversed = false;
    if (!packedType(type, widths, &components, bytes, &reversed)) return false;
    // GL 2.1 3.6.4: a packed type names its fields after exactly one format -
    // GL_RGB for the three-field types (GL_BGR is NOT among them; only the
    // four-field types have a reversed spelling), GL_RGBA or GL_BGRA for the
    // four-field ones. Anything else is GL_INVALID_OPERATION, which the
    // callers' own GL_INVALID_ENUM cannot overwrite once latched.
    if ((components == 3 && format != GL_RGB) ||
        (components == 4 && format != GL_RGBA && format != GL_BGRA)) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }
    return true;
}

template <typename T>
T loadScalar(const uint8_t* source, bool swap) {
    T value{};
    if (swap && sizeof(T) > 1) {
        uint8_t bytes[sizeof(T)];
        std::memcpy(bytes, source, sizeof(T));
        std::reverse(bytes, bytes + sizeof(T));
        std::memcpy(&value, bytes, sizeof(T));
    } else {
        std::memcpy(&value, source, sizeof(T));
    }
    return value;
}

template <typename T>
void storeScalar(uint8_t* destination, T value, bool swap) {
    std::memcpy(destination, &value, sizeof(T));
    if (swap && sizeof(T) > 1) std::reverse(destination, destination + sizeof(T));
}

float halfToFloat(uint16_t bits) {
    const bool negative = (bits & 0x8000u) != 0;
    const uint16_t exponent = (bits >> 10u) & 0x1fu;
    const uint16_t mantissa = bits & 0x3ffu;
    float value = 0.0f;
    if (exponent == 0)
        value = std::ldexp(static_cast<float>(mantissa), -24);
    else if (exponent == 0x1fu)
        value = mantissa == 0 ? std::numeric_limits<float>::infinity()
                              : std::numeric_limits<float>::quiet_NaN();
    else
        value = std::ldexp(1.0f + static_cast<float>(mantissa) / 1024.0f,
                           static_cast<int>(exponent) - 15);
    return negative ? -value : value;
}

uint16_t floatToHalf(float value) {
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    const uint32_t sign = (bits >> 16u) & 0x8000u;
    int exponent = static_cast<int>((bits >> 23u) & 0xffu) - 127 + 15;
    uint32_t mantissa = bits & 0x7fffffu;
    if (exponent <= 0) {
        if (exponent < -10) return static_cast<uint16_t>(sign);
        mantissa = (mantissa | 0x800000u) >> static_cast<unsigned>(1 - exponent);
        return static_cast<uint16_t>(sign | ((mantissa + 0x1000u) >> 13u));
    }
    if (exponent >= 31)
        return static_cast<uint16_t>(sign | 0x7c00u | (mantissa != 0 ? 0x200u : 0));
    return static_cast<uint16_t>(sign | (static_cast<uint32_t>(exponent) << 10u) |
                                 ((mantissa + 0x1000u) >> 13u));
}

float readComponent(const uint8_t* source, GLenum type, bool swap) {
    switch (type) {
    case GL_BYTE: return sfpewNormalizeColorComponent(loadScalar<GLbyte>(source, false));
    case GL_UNSIGNED_BYTE: return sfpewNormalizeColorComponent(loadScalar<GLubyte>(source, false));
    case GL_SHORT: return sfpewNormalizeColorComponent(loadScalar<GLshort>(source, swap));
    case GL_UNSIGNED_SHORT: return sfpewNormalizeColorComponent(loadScalar<GLushort>(source, swap));
    case GL_INT: return sfpewNormalizeColorComponent(loadScalar<GLint>(source, swap));
    case GL_UNSIGNED_INT: return sfpewNormalizeColorComponent(loadScalar<GLuint>(source, swap));
    case GL_FLOAT: return loadScalar<GLfloat>(source, swap);
    case GL_HALF_FLOAT: return halfToFloat(loadScalar<uint16_t>(source, swap));
    default: return 0.0f;
    }
}

glm::vec4 expandPixel(GLenum format, const float values[4]) {
    switch (format) {
    case GL_RED: return {values[0], 0, 0, 1};
    case GL_GREEN: return {0, values[0], 0, 1};
    case GL_BLUE: return {0, 0, values[0], 1};
    case GL_ALPHA: return {0, 0, 0, values[0]};
    case GL_RG: return {values[0], values[1], 0, 1};
    case GL_RGB: return {values[0], values[1], values[2], 1};
    case GL_BGR: return {values[2], values[1], values[0], 1};
    case GL_RGBA: return {values[0], values[1], values[2], values[3]};
    case GL_BGRA: return {values[2], values[1], values[0], values[3]};
    case GL_LUMINANCE: return {values[0], values[0], values[0], 1};
    case GL_LUMINANCE_ALPHA: return {values[0], values[0], values[0], values[1]};
    default: return {0, 0, 0, 1};
    }
}

glm::vec4 decodePixel(const uint8_t* source, GLenum format, GLenum type, bool swap) {
    pixel_format_t info;
    pixelFormat(format, &info);
    float values[4] = {};
    size_t scalar = 0;
    if (scalarType(type, &scalar)) {
        for (int i = 0; i < info.components; ++i)
            values[i] = readComponent(source + static_cast<size_t>(i) * scalar, type, swap);
    } else {
        int widths[4] = {}, components = 0;
        size_t bytes = 0;
        bool reversed = false;
        packedType(type, widths, &components, &bytes, &reversed);
        uint32_t word = bytes == 1 ? loadScalar<uint8_t>(source, false)
                                  : bytes == 2 ? loadScalar<uint16_t>(source, swap)
                                               : loadScalar<uint32_t>(source, swap);
        int shift = reversed ? 0 : static_cast<int>(bytes * 8u);
        for (int i = 0; i < components; ++i) {
            if (reversed)
                shift += i == 0 ? 0 : widths[i - 1];
            else
                shift -= widths[i];
            const uint32_t mask = (1u << widths[i]) - 1u;
            values[i] = static_cast<float>((word >> shift) & mask) / static_cast<float>(mask);
        }
    }
    return expandPixel(format, values);
}

bool checkedAdd(size_t a, size_t b, size_t* out) {
    if (b > std::numeric_limits<size_t>::max() - a) return false;
    *out = a + b;
    return true;
}

bool checkedMultiply(size_t a, size_t b, size_t* out) {
    if (a != 0 && b > std::numeric_limits<size_t>::max() / a) return false;
    *out = a * b;
    return true;
}

struct pixel_layout_t {
    size_t start = 0;
    size_t stride = 0;
    size_t needed = 0;
};

bool pixelLayout(bool pack, GLsizei width, GLsizei height, size_t pixel_bytes,
                 pixel_layout_t* out) {
    GLint alignment = 4, row_length = 0, skip_rows = 0, skip_pixels = 0;
    if (sfpewEnsureBackend() && g_glFuncs.glGetIntegerv != nullptr) {
        g_glFuncs.glGetIntegerv(pack ? GL_PACK_ALIGNMENT : GL_UNPACK_ALIGNMENT, &alignment);
        g_glFuncs.glGetIntegerv(pack ? GL_PACK_ROW_LENGTH : GL_UNPACK_ROW_LENGTH, &row_length);
        g_glFuncs.glGetIntegerv(pack ? GL_PACK_SKIP_ROWS : GL_UNPACK_SKIP_ROWS, &skip_rows);
        g_glFuncs.glGetIntegerv(pack ? GL_PACK_SKIP_PIXELS : GL_UNPACK_SKIP_PIXELS, &skip_pixels);
    }
    if ((alignment != 1 && alignment != 2 && alignment != 4 && alignment != 8) ||
        row_length < 0 || skip_rows < 0 || skip_pixels < 0) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }
    const size_t row_pixels = row_length > 0 ? static_cast<size_t>(row_length)
                                             : static_cast<size_t>(width);
    size_t row_bytes = 0, padded = 0, skip_row_bytes = 0, skip_pixel_bytes = 0;
    if (!checkedMultiply(row_pixels, pixel_bytes, &row_bytes) ||
        !checkedAdd(row_bytes, static_cast<size_t>(alignment - 1), &padded) ||
        !checkedMultiply(static_cast<size_t>(skip_rows),
                         padded & ~static_cast<size_t>(alignment - 1), &skip_row_bytes) ||
        !checkedMultiply(static_cast<size_t>(skip_pixels), pixel_bytes, &skip_pixel_bytes) ||
        !checkedAdd(skip_row_bytes, skip_pixel_bytes, &out->start)) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return false;
    }
    out->stride = padded & ~static_cast<size_t>(alignment - 1);
    size_t last_row = 0, final_bytes = 0;
    if (!checkedMultiply(static_cast<size_t>(height - 1), out->stride, &last_row) ||
        !checkedMultiply(static_cast<size_t>(width), pixel_bytes, &final_bytes) ||
        !checkedAdd(out->start, last_row, &out->needed) ||
        !checkedAdd(out->needed, final_bytes, &out->needed)) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

void drainBackendErrors() {
    if (g_glFuncs.glGetError == nullptr) return;
    while (g_glFuncs.glGetError() != GL_NO_ERROR) {}
}

struct mapped_pixels_t {
    GLenum target = GL_NONE;
    void* pointer = nullptr;
    ~mapped_pixels_t() {
        if (target != GL_NONE && g_glFuncs.glUnmapBuffer != nullptr)
            g_glFuncs.glUnmapBuffer(target);
    }
};

bool mapPixelBuffer(bool pack, const void* pointer, const pixel_layout_t& layout,
                    mapped_pixels_t* mapped, uint8_t** base) {
    const GLenum binding_name = pack ? GL_PIXEL_PACK_BUFFER_BINDING
                                     : GL_PIXEL_UNPACK_BUFFER_BINDING;
    const GLenum target = pack ? GL_PIXEL_PACK_BUFFER : GL_PIXEL_UNPACK_BUFFER;
    GLint binding = 0;
    if (!DisplayListManager::isCalling() && sfpewEnsureBackend() &&
        g_glFuncs.glGetIntegerv != nullptr)
        g_glFuncs.glGetIntegerv(binding_name, &binding);
    if (binding == 0) {
        if (pointer == nullptr) return false;
        *base = const_cast<uint8_t*>(static_cast<const uint8_t*>(pointer));
        return true;
    }
    if (g_glFuncs.glGetBufferParameteriv == nullptr || g_glFuncs.glMapBufferRange == nullptr ||
        g_glFuncs.glUnmapBuffer == nullptr) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }
    const size_t offset = reinterpret_cast<uintptr_t>(pointer);
    GLint size = 0, is_mapped = GL_FALSE;
    g_glFuncs.glGetBufferParameteriv(target, GL_BUFFER_SIZE, &size);
    g_glFuncs.glGetBufferParameteriv(target, GL_BUFFER_MAPPED, &is_mapped);
    if (size < 0 || is_mapped == GL_TRUE || offset > static_cast<size_t>(size) ||
        layout.needed > static_cast<size_t>(size) - offset ||
        offset > static_cast<size_t>(std::numeric_limits<GLintptr>::max()) ||
        layout.needed > static_cast<size_t>(std::numeric_limits<GLsizeiptr>::max())) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }
    mapped->pointer = g_glFuncs.glMapBufferRange(
        target, static_cast<GLintptr>(offset), static_cast<GLsizeiptr>(layout.needed),
        pack ? GL_MAP_WRITE_BIT : GL_MAP_READ_BIT);
    if (mapped->pointer == nullptr) {
        drainBackendErrors();
        g_glstate.set_error(GL_INVALID_OPERATION);
        return false;
    }
    mapped->target = target;
    *base = static_cast<uint8_t*>(mapped->pointer);
    return true;
}

bool decodePixels(GLsizei width, GLsizei height, GLenum format, GLenum type,
                  const void* data, std::vector<glm::vec4>* out) {
    if (width < 0 || height < 0) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return false;
    }
    if (width == 0 || height == 0) {
        out->clear();
        return true;
    }
    size_t pixel_bytes = 0;
    if (!pixelSize(format, type, &pixel_bytes)) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return false;
    }
    pixel_layout_t layout;
    if (DisplayListManager::isCalling()) {
        layout.start = 0;
        layout.stride = static_cast<size_t>(width) * pixel_bytes;
        layout.needed = layout.stride * static_cast<size_t>(height);
    } else if (!pixelLayout(false, width, height, pixel_bytes, &layout)) {
        return false;
    }
    mapped_pixels_t mapped;
    uint8_t* base = nullptr;
    if (!mapPixelBuffer(false, data, layout, &mapped, &base)) return false;
    try {
        out->resize(static_cast<size_t>(width) * static_cast<size_t>(height));
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return false;
    }
    // Imaging uploads captured by a display list are canonical, tightly
    // packed RGBA floats. They must not inherit unpack byte swapping from the
    // state at replay time.
    const bool swap = !DisplayListManager::isCalling() && g_glstate.pixel_store_unpack_swap_bytes;
    const uint8_t* first = base + layout.start;
    for (GLsizei y = 0; y < height; ++y) {
        const uint8_t* row = first + static_cast<size_t>(y) * layout.stride;
        for (GLsizei x = 0; x < width; ++x)
            (*out)[static_cast<size_t>(y) * width + x] =
                decodePixel(row + static_cast<size_t>(x) * pixel_bytes, format, type, swap);
    }
    return true;
}

void pixelComponents(GLenum format, const glm::vec4& value, float out[4]) {
    switch (format) {
    case GL_RED: out[0] = value.r; break;
    case GL_GREEN: out[0] = value.g; break;
    case GL_BLUE: out[0] = value.b; break;
    case GL_ALPHA: out[0] = value.a; break;
    case GL_RG: out[0] = value.r; out[1] = value.g; break;
    case GL_RGB: out[0] = value.r; out[1] = value.g; out[2] = value.b; break;
    case GL_BGR: out[0] = value.b; out[1] = value.g; out[2] = value.r; break;
    case GL_RGBA:
        out[0] = value.r; out[1] = value.g; out[2] = value.b; out[3] = value.a; break;
    case GL_BGRA:
        out[0] = value.b; out[1] = value.g; out[2] = value.r; out[3] = value.a; break;
    case GL_LUMINANCE: out[0] = value.r; break;
    case GL_LUMINANCE_ALPHA: out[0] = value.r; out[1] = value.a; break;
    default: break;
    }
}

template <typename T>
T normalizedResult(float value) {
    if constexpr (std::is_floating_point_v<T>) {
        return static_cast<T>(value);
    } else if constexpr (std::is_signed_v<T>) {
        const long double scaled = std::clamp(static_cast<long double>(value), -1.0L, 1.0L) *
                                   static_cast<long double>(std::numeric_limits<T>::max());
        return static_cast<T>(std::llround(scaled));
    } else {
        const long double scaled = std::clamp(static_cast<long double>(value), 0.0L, 1.0L) *
                                   static_cast<long double>(std::numeric_limits<T>::max());
        return static_cast<T>(std::llround(scaled));
    }
}

template <typename T>
T numericResult(float value) {
    if (std::isnan(value)) return 0;
    const long double bounded = std::clamp(
        static_cast<long double>(value), static_cast<long double>(std::numeric_limits<T>::lowest()),
        static_cast<long double>(std::numeric_limits<T>::max()));
    return static_cast<T>(std::llround(bounded));
}

void encodeScalar(uint8_t* destination, GLenum type, float value, bool swap, bool numeric) {
    switch (type) {
    case GL_BYTE: storeScalar(destination, numeric ? numericResult<GLbyte>(value)
                                                   : normalizedResult<GLbyte>(value), false); break;
    case GL_UNSIGNED_BYTE:
        storeScalar(destination, numeric ? numericResult<GLubyte>(value)
                                         : normalizedResult<GLubyte>(value), false); break;
    case GL_SHORT: storeScalar(destination, numeric ? numericResult<GLshort>(value)
                                                    : normalizedResult<GLshort>(value), swap); break;
    case GL_UNSIGNED_SHORT:
        storeScalar(destination, numeric ? numericResult<GLushort>(value)
                                         : normalizedResult<GLushort>(value), swap); break;
    case GL_INT: storeScalar(destination, numeric ? numericResult<GLint>(value)
                                                  : normalizedResult<GLint>(value), swap); break;
    case GL_UNSIGNED_INT:
        storeScalar(destination, numeric ? numericResult<GLuint>(value)
                                         : normalizedResult<GLuint>(value), swap); break;
    case GL_FLOAT: storeScalar(destination, value, swap); break;
    case GL_HALF_FLOAT: storeScalar(destination, floatToHalf(value), swap); break;
    default: break;
    }
}

void encodePixel(uint8_t* destination, GLenum format, GLenum type, const glm::vec4& value,
                 bool swap, bool numeric) {
    pixel_format_t info;
    pixelFormat(format, &info);
    float components[4] = {};
    pixelComponents(format, value, components);
    size_t scalar = 0;
    if (scalarType(type, &scalar)) {
        for (int i = 0; i < info.components; ++i)
            encodeScalar(destination + static_cast<size_t>(i) * scalar, type, components[i], swap,
                         numeric);
        return;
    }
    int widths[4] = {}, count = 0;
    size_t bytes = 0;
    bool reversed = false;
    packedType(type, widths, &count, &bytes, &reversed);
    uint32_t word = 0;
    int shift = reversed ? 0 : static_cast<int>(bytes * 8u);
    for (int i = 0; i < count; ++i) {
        if (reversed)
            shift += i == 0 ? 0 : widths[i - 1];
        else
            shift -= widths[i];
        const uint32_t mask = (1u << widths[i]) - 1u;
        const uint32_t encoded = static_cast<uint32_t>(std::llround(
            std::clamp(components[i], 0.0f, 1.0f) * static_cast<float>(mask)));
        word |= (encoded & mask) << shift;
    }
    if (bytes == 1) storeScalar(destination, static_cast<uint8_t>(word), false);
    else if (bytes == 2) storeScalar(destination, static_cast<uint16_t>(word), swap);
    else storeScalar(destination, word, swap);
}

bool encodePixels(GLsizei width, GLsizei height, GLenum format, GLenum type,
                  const glm::vec4* source, void* data, bool numeric = false) {
    if (width < 0 || height < 0) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return false;
    }
    if (width == 0 || height == 0) return true;
    size_t pixel_bytes = 0;
    if (!pixelSize(format, type, &pixel_bytes)) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return false;
    }
    pixel_layout_t layout;
    if (!pixelLayout(true, width, height, pixel_bytes, &layout)) return false;
    mapped_pixels_t mapped;
    uint8_t* base = nullptr;
    if (!mapPixelBuffer(true, data, layout, &mapped, &base)) return false;
    const bool swap = g_glstate.pixel_store_pack_swap_bytes;
    uint8_t* first = base + layout.start;
    for (GLsizei y = 0; y < height; ++y) {
        uint8_t* row = first + static_cast<size_t>(y) * layout.stride;
        for (GLsizei x = 0; x < width; ++x)
            encodePixel(row + static_cast<size_t>(x) * pixel_bytes, format, type,
                        source[static_cast<size_t>(y) * width + x], swap, numeric);
    }
    return true;
}

struct internal_format_t {
    GLenum base = GL_NONE;
    GLint bits[4] = {};
};

bool internalFormat(GLenum format, internal_format_t* out) {
    auto set = [&](GLenum base, GLint r, GLint g, GLint b, GLint a) {
        out->base = base;
        out->bits[0] = r; out->bits[1] = g; out->bits[2] = b; out->bits[3] = a;
        return true;
    };
    switch (format) {
    case GL_ALPHA: return set(GL_ALPHA, 0, 0, 0, 8);
    case GL_ALPHA4: return set(GL_ALPHA, 0, 0, 0, 4);
    case GL_ALPHA8: return set(GL_ALPHA, 0, 0, 0, 8);
    case GL_ALPHA12: return set(GL_ALPHA, 0, 0, 0, 12);
    case GL_ALPHA16: return set(GL_ALPHA, 0, 0, 0, 16);
    case GL_LUMINANCE: return set(GL_LUMINANCE, 8, 8, 8, 0);
    case GL_LUMINANCE4: return set(GL_LUMINANCE, 4, 4, 4, 0);
    case GL_LUMINANCE8: return set(GL_LUMINANCE, 8, 8, 8, 0);
    case GL_LUMINANCE12: return set(GL_LUMINANCE, 12, 12, 12, 0);
    case GL_LUMINANCE16: return set(GL_LUMINANCE, 16, 16, 16, 0);
    case GL_LUMINANCE_ALPHA: return set(GL_LUMINANCE_ALPHA, 8, 8, 8, 8);
    case GL_LUMINANCE4_ALPHA4: return set(GL_LUMINANCE_ALPHA, 4, 4, 4, 4);
    case GL_LUMINANCE6_ALPHA2: return set(GL_LUMINANCE_ALPHA, 6, 6, 6, 2);
    case GL_LUMINANCE8_ALPHA8: return set(GL_LUMINANCE_ALPHA, 8, 8, 8, 8);
    case GL_LUMINANCE12_ALPHA4: return set(GL_LUMINANCE_ALPHA, 12, 12, 12, 4);
    case GL_LUMINANCE12_ALPHA12: return set(GL_LUMINANCE_ALPHA, 12, 12, 12, 12);
    case GL_LUMINANCE16_ALPHA16: return set(GL_LUMINANCE_ALPHA, 16, 16, 16, 16);
    case GL_INTENSITY: return set(GL_INTENSITY, 8, 8, 8, 8);
    case GL_INTENSITY4: return set(GL_INTENSITY, 4, 4, 4, 4);
    case GL_INTENSITY8: return set(GL_INTENSITY, 8, 8, 8, 8);
    case GL_INTENSITY12: return set(GL_INTENSITY, 12, 12, 12, 12);
    case GL_INTENSITY16: return set(GL_INTENSITY, 16, 16, 16, 16);
    case GL_RGB: return set(GL_RGB, 8, 8, 8, 0);
    case GL_R3_G3_B2: return set(GL_RGB, 3, 3, 2, 0);
    case GL_RGB4: return set(GL_RGB, 4, 4, 4, 0);
    case GL_RGB5: return set(GL_RGB, 5, 5, 5, 0);
    case GL_RGB8: return set(GL_RGB, 8, 8, 8, 0);
    case GL_RGB10: return set(GL_RGB, 10, 10, 10, 0);
    case GL_RGB12: return set(GL_RGB, 12, 12, 12, 0);
    case GL_RGB16: return set(GL_RGB, 16, 16, 16, 0);
    case GL_RGBA: return set(GL_RGBA, 8, 8, 8, 8);
    case GL_RGBA2: return set(GL_RGBA, 2, 2, 2, 2);
    case GL_RGBA4: return set(GL_RGBA, 4, 4, 4, 4);
    case GL_RGB5_A1: return set(GL_RGBA, 5, 5, 5, 1);
    case GL_RGBA8: return set(GL_RGBA, 8, 8, 8, 8);
    case GL_RGB10_A2: return set(GL_RGBA, 10, 10, 10, 2);
    case GL_RGBA12: return set(GL_RGBA, 12, 12, 12, 12);
    case GL_RGBA16: return set(GL_RGBA, 16, 16, 16, 16);
#ifdef GL_RGBA32F_ARB
    case GL_RGBA32F_ARB: return set(GL_RGBA, 32, 32, 32, 32);
    case GL_RGB32F_ARB: return set(GL_RGB, 32, 32, 32, 0);
    case GL_ALPHA32F_ARB: return set(GL_ALPHA, 0, 0, 0, 32);
    case GL_LUMINANCE32F_ARB: return set(GL_LUMINANCE, 32, 32, 32, 0);
    case GL_LUMINANCE_ALPHA32F_ARB: return set(GL_LUMINANCE_ALPHA, 32, 32, 32, 32);
    case GL_INTENSITY32F_ARB: return set(GL_INTENSITY, 32, 32, 32, 32);
#endif
    default: return false;
    }
}

glm::vec4 applyInternalFormat(const glm::vec4& value, GLenum format) {
    internal_format_t info;
    internalFormat(format, &info);
    switch (info.base) {
    case GL_ALPHA: return {0, 0, 0, value.a};
    case GL_LUMINANCE: return {value.r, value.r, value.r, 1};
    case GL_LUMINANCE_ALPHA: return {value.r, value.r, value.r, value.a};
    case GL_INTENSITY: return {value.r, value.r, value.r, value.r};
    case GL_RGB: return {value.r, value.g, value.b, 1};
    default: return value;
    }
}

// Which of R,G,B,A a color table or convolution filter of this internal
// format actually carries, as a bit per channel. Everything else is
// applyInternalFormat's 0/1 filler, which is the right thing to STORE -
// glGetColorTable/glGetConvolutionFilter must hand those defaults back -
// but must never reach a pixel group: GL 2.1 3.6.3's resulting-component
// tables pass undefined channels through the stage untouched (an ALPHA
// table yields (R, G, B, A[a]), a LUMINANCE filter leaves alpha alone).
unsigned definedChannels(GLenum internalformat) {
    internal_format_t info;
    internalFormat(internalformat, &info);
    switch (info.base) {
    case GL_ALPHA: return 0x8u;
    case GL_LUMINANCE:
    case GL_RGB: return 0x7u;
    default: return 0xfu;
    }
}

glm::vec4 clampColor(const glm::vec4& value) {
    return glm::clamp(value, glm::vec4(0.0f), glm::vec4(1.0f));
}

int colorTableIndex(GLenum target, bool* proxy = nullptr) {
    bool is_proxy = target >= GL_PROXY_COLOR_TABLE &&
                    target <= GL_PROXY_POST_COLOR_MATRIX_COLOR_TABLE;
    GLenum base = is_proxy ? target - (GL_PROXY_COLOR_TABLE - GL_COLOR_TABLE) : target;
    if (base < GL_COLOR_TABLE || base > GL_POST_COLOR_MATRIX_COLOR_TABLE) return -1;
    if (proxy != nullptr) *proxy = is_proxy;
    return static_cast<int>(base - GL_COLOR_TABLE);
}

color_table_t* colorTableState(GLenum target) {
    bool proxy = false;
    const int index = colorTableIndex(target, &proxy);
    if (index < 0) return nullptr;
    return proxy ? &g_glstate.color_table_proxies[index] : &g_glstate.color_tables[index];
}

bool powerOfTwo(GLsizei value) { return value > 0 && (value & (value - 1)) == 0; }

void loadColorEntries(color_table_t& state, const std::vector<glm::vec4>& decoded,
                      size_t destination) {
    const glm::vec4 scale(state.scale[0], state.scale[1], state.scale[2], state.scale[3]);
    const glm::vec4 bias(state.bias[0], state.bias[1], state.bias[2], state.bias[3]);
    for (size_t i = 0; i < decoded.size(); ++i)
        state.entries[destination + i] =
            applyInternalFormat(clampColor(decoded[i] * scale + bias), state.internalformat);
}

bool readFramebuffer(GLint x, GLint y, GLsizei width, GLsizei height,
                     std::vector<glm::vec4>* out) {
    if (width < 0 || height < 0) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return false;
    }
    if (!sfpewEnsureBackend() || g_glFuncs.glReadPixels == nullptr ||
        g_glFuncs.glGetIntegerv == nullptr || g_glFuncs.glPixelStorei == nullptr ||
        g_glFuncs.glBindBuffer == nullptr) {
        return false;
    }
    GLint alignment = 4, row_length = 0, skip_rows = 0, skip_pixels = 0, pbo = 0;
    g_glFuncs.glGetIntegerv(GL_PACK_ALIGNMENT, &alignment);
    g_glFuncs.glGetIntegerv(GL_PACK_ROW_LENGTH, &row_length);
    g_glFuncs.glGetIntegerv(GL_PACK_SKIP_ROWS, &skip_rows);
    g_glFuncs.glGetIntegerv(GL_PACK_SKIP_PIXELS, &skip_pixels);
    g_glFuncs.glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &pbo);
    std::vector<GLubyte> bytes;
    try {
        bytes.resize(static_cast<size_t>(width) * static_cast<size_t>(height) * 4u);
        out->resize(static_cast<size_t>(width) * static_cast<size_t>(height));
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return false;
    }
    if (pbo != 0) g_glFuncs.glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    g_glFuncs.glPixelStorei(GL_PACK_ALIGNMENT, 1);
    g_glFuncs.glPixelStorei(GL_PACK_ROW_LENGTH, 0);
    g_glFuncs.glPixelStorei(GL_PACK_SKIP_ROWS, 0);
    g_glFuncs.glPixelStorei(GL_PACK_SKIP_PIXELS, 0);
    g_glFuncs.glReadPixels(x, y, width, height, GL_RGBA, GL_UNSIGNED_BYTE, bytes.data());
    g_glFuncs.glPixelStorei(GL_PACK_ALIGNMENT, alignment);
    g_glFuncs.glPixelStorei(GL_PACK_ROW_LENGTH, row_length);
    g_glFuncs.glPixelStorei(GL_PACK_SKIP_ROWS, skip_rows);
    g_glFuncs.glPixelStorei(GL_PACK_SKIP_PIXELS, skip_pixels);
    if (pbo != 0) g_glFuncs.glBindBuffer(GL_PIXEL_PACK_BUFFER, static_cast<GLuint>(pbo));
    for (size_t i = 0; i < out->size(); ++i) {
        (*out)[i] = glm::vec4(bytes[i * 4u + 0], bytes[i * 4u + 1], bytes[i * 4u + 2],
                              bytes[i * 4u + 3]) /
                    255.0f;
    }
    return true;
}

template <typename T>
void copyValues(T* destination, const GLfloat* source, int count) {
    if (destination == nullptr) return;
    for (int i = 0; i < count; ++i) destination[i] = static_cast<T>(source[i]);
}

} // namespace

void glColorTable(GLenum target, GLenum requested_internalformat, GLsizei width, GLenum format,
                  GLenum type, const GLvoid* table) {
    sfpewEntryBarrier();
    bool proxy = false;
    const int index = colorTableIndex(target, &proxy);
    if (index < 0) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    internal_format_t info;
    if (!internalFormat(requested_internalformat, &info)) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    if (!powerOfTwo(width)) {
        g_glstate.set_error(GL_INVALID_VALUE);
        if (proxy) g_glstate.color_table_proxies[index].width = 0;
        return;
    }
    if (width > SFPEW_MAX_COLOR_TABLE_SIZE) {
        color_table_t& proxy_state = g_glstate.color_table_proxies[index];
        if (proxy) {
            LIST_RECORD(glColorTable, {}, target, requested_internalformat, width, format, type,
                        static_cast<const GLvoid*>(nullptr))
            proxy_state = {};
            proxy_state.internalformat = GL_NONE;
            return;
        }
        g_glstate.set_error(GL_TABLE_TOO_LARGE);
        return;
    }
    size_t ignored_pixel_bytes = 0;
    if (!pixelSize(format, type, &ignored_pixel_bytes)) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    color_table_t& state = proxy ? g_glstate.color_table_proxies[index]
                                 : g_glstate.color_tables[index];
    if (proxy) {
        // Proxy uploads still compile, but their data pointer is never read.
        LIST_RECORD(glColorTable, {}, target, requested_internalformat, width, format, type,
                    static_cast<const GLvoid*>(nullptr))
        state.internalformat = requested_internalformat;
        state.width = width;
        state.entries.clear();
        return;
    }
    std::vector<glm::vec4> decoded;
    if (!decodePixels(width, 1, format, type, table, &decoded)) return;
    LIST_RECORD(glColorTable, {{5, decoded.size() * sizeof(glm::vec4)}}, target,
                requested_internalformat, width, GL_RGBA, GL_FLOAT,
                static_cast<const GLvoid*>(decoded.data()))
    state.internalformat = requested_internalformat;
    state.width = width;
    try {
        state.entries.resize(static_cast<size_t>(width));
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        state.width = 0;
        return;
    }
    loadColorEntries(state, decoded, 0);
}

void glColorSubTable(GLenum target, GLsizei start, GLsizei count, GLenum format, GLenum type,
                     const GLvoid* data) {
    sfpewEntryBarrier();
    bool proxy = false;
    const int index = colorTableIndex(target, &proxy);
    if (index < 0 || proxy) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    color_table_t& state = g_glstate.color_tables[index];
    if (start < 0 || count < 0 || state.width == 0 || start > state.width - count) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    if (count == 0) return;
    std::vector<glm::vec4> decoded;
    if (!decodePixels(count, 1, format, type, data, &decoded)) return;
    LIST_RECORD(glColorSubTable, {{5, decoded.size() * sizeof(glm::vec4)}}, target, start,
                count, GL_RGBA, GL_FLOAT, static_cast<const GLvoid*>(decoded.data()))
    loadColorEntries(state, decoded, static_cast<size_t>(start));
}

void glColorTableParameterfv(GLenum target, GLenum pname, const GLfloat* params) {
    sfpewEntryBarrier();
    color_table_t* state = colorTableState(target);
    if (state == nullptr) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    if (params == nullptr) return;
    if (pname != GL_COLOR_TABLE_SCALE && pname != GL_COLOR_TABLE_BIAS) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    LIST_RECORD(glColorTableParameterfv, {{2, sizeof(GLfloat) * 4u}}, target, pname, params)
    std::copy_n(params, 4, pname == GL_COLOR_TABLE_SCALE ? state->scale : state->bias);
}

void glColorTableParameteriv(GLenum target, GLenum pname, const GLint* params) {
    sfpewEntryBarrier();
    if (params == nullptr) return;
    GLfloat converted[4];
    for (int i = 0; i < 4; ++i) converted[i] = static_cast<GLfloat>(params[i]);
    LIST_RECORD(glColorTableParameteriv, {{2, sizeof(GLint) * 4u}}, target, pname, params)
    SELF_CALL(glColorTableParameterfv, target, pname, converted)
}

void glCopyColorTable(GLenum target, GLenum internalformat, GLint x, GLint y, GLsizei width) {
    sfpewEntryBarrier();
    LIST_RECORD(glCopyColorTable, {}, target, internalformat, x, y, width)
    std::vector<glm::vec4> pixels;
    if (!readFramebuffer(x, y, width, 1, &pixels)) return;
    sfpew_imaging_upload_t tight;
    if (!sfpewBeginTightImagingUpload(&tight)) return;
    SELF_CALL(glColorTable, target, internalformat, width, GL_RGBA, GL_FLOAT, pixels.data())
    sfpewFinishImagingUpload(tight);
}

void glCopyColorSubTable(GLenum target, GLsizei start, GLint x, GLint y, GLsizei width) {
    sfpewEntryBarrier();
    LIST_RECORD(glCopyColorSubTable, {}, target, start, x, y, width)
    std::vector<glm::vec4> pixels;
    if (!readFramebuffer(x, y, width, 1, &pixels)) return;
    sfpew_imaging_upload_t tight;
    if (!sfpewBeginTightImagingUpload(&tight)) return;
    SELF_CALL(glColorSubTable, target, start, width, GL_RGBA, GL_FLOAT, pixels.data())
    sfpewFinishImagingUpload(tight);
}

void glGetColorTable(GLenum target, GLenum format, GLenum type, GLvoid* table) {
    sfpewEntryBarrier();
    bool proxy = false;
    const int index = colorTableIndex(target, &proxy);
    if (index < 0 || proxy) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    const color_table_t& state = g_glstate.color_tables[index];
    if (state.width == 0) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return;
    }
    encodePixels(state.width, 1, format, type, state.entries.data(), table);
}

namespace {

bool colorTableParameter(GLenum target, GLenum pname, GLfloat values[4], int* count) {
    color_table_t* state = colorTableState(target);
    if (state == nullptr) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return false;
    }
    internal_format_t info;
    internalFormat(state->internalformat, &info);
    switch (pname) {
    case GL_COLOR_TABLE_SCALE: std::copy_n(state->scale, 4, values); *count = 4; return true;
    case GL_COLOR_TABLE_BIAS: std::copy_n(state->bias, 4, values); *count = 4; return true;
    case GL_COLOR_TABLE_FORMAT: values[0] = static_cast<GLfloat>(state->internalformat); break;
    case GL_COLOR_TABLE_WIDTH: values[0] = static_cast<GLfloat>(state->width); break;
    case GL_COLOR_TABLE_RED_SIZE: values[0] = static_cast<GLfloat>(info.bits[0]); break;
    case GL_COLOR_TABLE_GREEN_SIZE: values[0] = static_cast<GLfloat>(info.bits[1]); break;
    case GL_COLOR_TABLE_BLUE_SIZE: values[0] = static_cast<GLfloat>(info.bits[2]); break;
    case GL_COLOR_TABLE_ALPHA_SIZE: values[0] = static_cast<GLfloat>(info.bits[3]); break;
    case GL_COLOR_TABLE_LUMINANCE_SIZE:
        values[0] = info.base == GL_LUMINANCE || info.base == GL_LUMINANCE_ALPHA
                        ? static_cast<GLfloat>(info.bits[0])
                        : 0.0f;
        break;
    case GL_COLOR_TABLE_INTENSITY_SIZE:
        values[0] = info.base == GL_INTENSITY ? static_cast<GLfloat>(info.bits[0]) : 0.0f;
        break;
    default: g_glstate.set_error(GL_INVALID_ENUM); return false;
    }
    *count = 1;
    return true;
}

} // namespace

void glGetColorTableParameterfv(GLenum target, GLenum pname, GLfloat* params) {
    sfpewEntryBarrier();
    if (params == nullptr) return;
    GLfloat values[4] = {};
    int count = 0;
    if (colorTableParameter(target, pname, values, &count)) std::copy_n(values, count, params);
}

void glGetColorTableParameteriv(GLenum target, GLenum pname, GLint* params) {
    sfpewEntryBarrier();
    if (params == nullptr) return;
    GLfloat values[4] = {};
    int count = 0;
    if (colorTableParameter(target, pname, values, &count)) copyValues(params, values, count);
}

namespace {

int convolutionIndex(GLenum target) {
    return target >= GL_CONVOLUTION_1D && target <= GL_SEPARABLE_2D
               ? static_cast<int>(target - GL_CONVOLUTION_1D)
               : -1;
}

convolution_t* convolutionState(GLenum target) {
    const int index = convolutionIndex(target);
    return index < 0 ? nullptr : &g_glstate.convolutions[index];
}

void loadConvolutionEntries(convolution_t& state, const std::vector<glm::vec4>& decoded,
                            std::vector<glm::vec4>* destination) {
    const glm::vec4 scale(state.filter_scale[0], state.filter_scale[1], state.filter_scale[2],
                          state.filter_scale[3]);
    const glm::vec4 bias(state.filter_bias[0], state.filter_bias[1], state.filter_bias[2],
                         state.filter_bias[3]);
    destination->resize(decoded.size());
    for (size_t i = 0; i < decoded.size(); ++i)
        (*destination)[i] = applyInternalFormat(decoded[i] * scale + bias, state.internalformat);
}

bool validateConvolutionUpload(GLenum target, GLenum expected, GLenum requested_internalformat,
                               GLsizei width, GLsizei height) {
    if (target != expected) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return false;
    }
    internal_format_t info;
    if (!internalFormat(requested_internalformat, &info)) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return false;
    }
    if (width < 1 || height < 1 || width > SFPEW_MAX_CONVOLUTION_SIZE ||
        height > SFPEW_MAX_CONVOLUTION_SIZE) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return false;
    }
    return true;
}

void installConvolution(convolution_t& state, GLenum requested_internalformat, GLsizei width,
                        GLsizei height, const std::vector<glm::vec4>& decoded) {
    state.internalformat = requested_internalformat;
    state.width = width;
    state.height = height;
    try {
        loadConvolutionEntries(state, decoded, &state.entries);
    } catch (const std::bad_alloc&) {
        state.entries.clear();
        state.width = state.height = 0;
        g_glstate.set_error(GL_OUT_OF_MEMORY);
    }
}

} // namespace

void glConvolutionFilter1D(GLenum target, GLenum requested_internalformat, GLsizei width,
                           GLenum format, GLenum type, const GLvoid* image) {
    sfpewEntryBarrier();
    if (!validateConvolutionUpload(target, GL_CONVOLUTION_1D, requested_internalformat, width, 1))
        return;
    std::vector<glm::vec4> decoded;
    if (!decodePixels(width, 1, format, type, image, &decoded)) return;
    LIST_RECORD(glConvolutionFilter1D, {{5, decoded.size() * sizeof(glm::vec4)}}, target,
                requested_internalformat, width, GL_RGBA, GL_FLOAT,
                static_cast<const GLvoid*>(decoded.data()))
    installConvolution(g_glstate.convolutions[0], requested_internalformat, width, 1, decoded);
}

void glConvolutionFilter2D(GLenum target, GLenum requested_internalformat, GLsizei width,
                           GLsizei height, GLenum format, GLenum type, const GLvoid* image) {
    sfpewEntryBarrier();
    if (!validateConvolutionUpload(target, GL_CONVOLUTION_2D, requested_internalformat, width,
                                   height))
        return;
    std::vector<glm::vec4> decoded;
    if (!decodePixels(width, height, format, type, image, &decoded)) return;
    LIST_RECORD(glConvolutionFilter2D, {{6, decoded.size() * sizeof(glm::vec4)}}, target,
                requested_internalformat, width, height, GL_RGBA, GL_FLOAT,
                static_cast<const GLvoid*>(decoded.data()))
    installConvolution(g_glstate.convolutions[1], requested_internalformat, width, height,
                       decoded);
}

void glConvolutionParameterfv(GLenum target, GLenum pname, const GLfloat* params) {
    sfpewEntryBarrier();
    convolution_t* state = convolutionState(target);
    if (state == nullptr) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    if (params == nullptr) return;
    const size_t count = pname == GL_CONVOLUTION_BORDER_COLOR ||
                                 pname == GL_CONVOLUTION_FILTER_SCALE ||
                                 pname == GL_CONVOLUTION_FILTER_BIAS
                             ? 4u
                             : 1u;
    LIST_RECORD(glConvolutionParameterfv, {{2, count * sizeof(GLfloat)}}, target, pname, params)
    switch (pname) {
    case GL_CONVOLUTION_BORDER_MODE: {
        const GLenum mode = static_cast<GLenum>(params[0]);
        if (mode != GL_REDUCE && mode != GL_CONSTANT_BORDER && mode != GL_REPLICATE_BORDER) {
            g_glstate.set_error(GL_INVALID_ENUM);
            return;
        }
        state->border_mode = mode;
        break;
    }
    case GL_CONVOLUTION_BORDER_COLOR:
        for (int i = 0; i < 4; ++i) state->border_color[i] = std::clamp(params[i], 0.0f, 1.0f);
        break;
    case GL_CONVOLUTION_FILTER_SCALE: std::copy_n(params, 4, state->filter_scale); break;
    case GL_CONVOLUTION_FILTER_BIAS: std::copy_n(params, 4, state->filter_bias); break;
    default: g_glstate.set_error(GL_INVALID_ENUM); break;
    }
}

void glConvolutionParameterf(GLenum target, GLenum pname, GLfloat param) {
    sfpewEntryBarrier();
    if (pname != GL_CONVOLUTION_BORDER_MODE) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    LIST_RECORD(glConvolutionParameterf, {}, target, pname, param)
    SELF_CALL(glConvolutionParameterfv, target, pname, &param)
}

void glConvolutionParameteriv(GLenum target, GLenum pname, const GLint* params) {
    sfpewEntryBarrier();
    if (params == nullptr) return;
    const int count = pname == GL_CONVOLUTION_BORDER_COLOR ||
                              pname == GL_CONVOLUTION_FILTER_SCALE ||
                              pname == GL_CONVOLUTION_FILTER_BIAS
                          ? 4
                          : 1;
    GLfloat converted[4] = {};
    for (int i = 0; i < count; ++i) {
        converted[i] = pname == GL_CONVOLUTION_BORDER_COLOR
                           ? sfpewNormalizeColorComponent(params[i])
                           : static_cast<GLfloat>(params[i]);
    }
    LIST_RECORD(glConvolutionParameteriv, {{2, static_cast<size_t>(count) * sizeof(GLint)}},
                target, pname, params)
    SELF_CALL(glConvolutionParameterfv, target, pname, converted)
}

void glConvolutionParameteri(GLenum target, GLenum pname, GLint param) {
    sfpewEntryBarrier();
    if (pname != GL_CONVOLUTION_BORDER_MODE) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    LIST_RECORD(glConvolutionParameteri, {}, target, pname, param)
    SELF_CALL(glConvolutionParameterf, target, pname, static_cast<GLfloat>(param))
}

void glCopyConvolutionFilter1D(GLenum target, GLenum internalformat, GLint x, GLint y,
                               GLsizei width) {
    sfpewEntryBarrier();
    LIST_RECORD(glCopyConvolutionFilter1D, {}, target, internalformat, x, y, width)
    if (!validateConvolutionUpload(target, GL_CONVOLUTION_1D, internalformat, width, 1)) return;
    std::vector<glm::vec4> pixels;
    if (!readFramebuffer(x, y, width, 1, &pixels)) return;
    installConvolution(g_glstate.convolutions[0], internalformat, width, 1, pixels);
}

void glCopyConvolutionFilter2D(GLenum target, GLenum internalformat, GLint x, GLint y,
                               GLsizei width, GLsizei height) {
    sfpewEntryBarrier();
    LIST_RECORD(glCopyConvolutionFilter2D, {}, target, internalformat, x, y, width, height)
    if (!validateConvolutionUpload(target, GL_CONVOLUTION_2D, internalformat, width, height)) return;
    std::vector<glm::vec4> pixels;
    if (!readFramebuffer(x, y, width, height, &pixels)) return;
    installConvolution(g_glstate.convolutions[1], internalformat, width, height, pixels);
}

void glGetConvolutionFilter(GLenum target, GLenum format, GLenum type, GLvoid* image) {
    sfpewEntryBarrier();
    convolution_t* state = convolutionState(target);
    if (state == nullptr || target == GL_SEPARABLE_2D) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    if (state->width == 0 || state->height == 0) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return;
    }
    encodePixels(state->width, state->height, format, type, state->entries.data(), image);
}

namespace {

bool convolutionParameter(GLenum target, GLenum pname, GLfloat values[4], int* count,
                          bool* color) {
    convolution_t* state = convolutionState(target);
    if (state == nullptr) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return false;
    }
    *color = false;
    switch (pname) {
    case GL_CONVOLUTION_BORDER_MODE: values[0] = static_cast<GLfloat>(state->border_mode); break;
    case GL_CONVOLUTION_BORDER_COLOR:
        std::copy_n(state->border_color, 4, values); *count = 4; *color = true; return true;
    case GL_CONVOLUTION_FILTER_SCALE:
        std::copy_n(state->filter_scale, 4, values); *count = 4; return true;
    case GL_CONVOLUTION_FILTER_BIAS:
        std::copy_n(state->filter_bias, 4, values); *count = 4; return true;
    case GL_CONVOLUTION_FORMAT: values[0] = static_cast<GLfloat>(state->internalformat); break;
    case GL_CONVOLUTION_WIDTH: values[0] = static_cast<GLfloat>(state->width); break;
    case GL_CONVOLUTION_HEIGHT: values[0] = static_cast<GLfloat>(state->height); break;
    case GL_MAX_CONVOLUTION_WIDTH:
    case GL_MAX_CONVOLUTION_HEIGHT:
        values[0] = static_cast<GLfloat>(SFPEW_MAX_CONVOLUTION_SIZE);
        break;
    default: g_glstate.set_error(GL_INVALID_ENUM); return false;
    }
    *count = 1;
    return true;
}

} // namespace

void glGetConvolutionParameterfv(GLenum target, GLenum pname, GLfloat* params) {
    sfpewEntryBarrier();
    if (params == nullptr) return;
    GLfloat values[4] = {};
    int count = 0;
    bool color = false;
    if (convolutionParameter(target, pname, values, &count, &color))
        std::copy_n(values, count, params);
}

void glGetConvolutionParameteriv(GLenum target, GLenum pname, GLint* params) {
    sfpewEntryBarrier();
    if (params == nullptr) return;
    GLfloat values[4] = {};
    int count = 0;
    bool color = false;
    if (!convolutionParameter(target, pname, values, &count, &color)) return;
    for (int i = 0; i < count; ++i)
        params[i] = color ? normalizedResult<GLint>(values[i])
                          : static_cast<GLint>(std::lround(values[i]));
}

void glSeparableFilter2D(GLenum target, GLenum requested_internalformat, GLsizei width,
                         GLsizei height, GLenum format, GLenum type, const GLvoid* row,
                         const GLvoid* column) {
    sfpewEntryBarrier();
    if (!validateConvolutionUpload(target, GL_SEPARABLE_2D, requested_internalformat, width,
                                   height))
        return;
    std::vector<glm::vec4> decoded_row, decoded_column;
    if (!decodePixels(width, 1, format, type, row, &decoded_row) ||
        !decodePixels(height, 1, format, type, column, &decoded_column))
        return;
    LIST_RECORD(glSeparableFilter2D,
                {{6, decoded_row.size() * sizeof(glm::vec4)},
                  {7, decoded_column.size() * sizeof(glm::vec4)}},
                target, requested_internalformat, width, height, GL_RGBA, GL_FLOAT,
                static_cast<const GLvoid*>(decoded_row.data()),
                static_cast<const GLvoid*>(decoded_column.data()))
    convolution_t& state = g_glstate.convolutions[2];
    state.internalformat = requested_internalformat;
    state.width = width;
    state.height = height;
    try {
        loadConvolutionEntries(state, decoded_row, &state.separable_row);
        loadConvolutionEntries(state, decoded_column, &state.separable_column);
        state.entries.clear();
    } catch (const std::bad_alloc&) {
        state.width = state.height = 0;
        state.separable_row.clear();
        state.separable_column.clear();
        g_glstate.set_error(GL_OUT_OF_MEMORY);
    }
}

void glGetSeparableFilter(GLenum target, GLenum format, GLenum type, GLvoid* row,
                          GLvoid* column, GLvoid* span) {
    sfpewEntryBarrier();
    (void)span;
    if (target != GL_SEPARABLE_2D) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    const convolution_t& state = g_glstate.convolutions[2];
    if (state.width == 0 || state.height == 0) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return;
    }
    if (!encodePixels(state.width, 1, format, type, state.separable_row.data(), row)) return;
    encodePixels(state.height, 1, format, type, state.separable_column.data(), column);
}

void glHistogram(GLenum target, GLsizei width, GLenum requested_internalformat, GLboolean sink) {
    sfpewEntryBarrier();
    const bool proxy = target == GL_PROXY_HISTOGRAM;
    if (target != GL_HISTOGRAM && !proxy) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    internal_format_t info;
    if (!internalFormat(requested_internalformat, &info)) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    histogram_t& state = proxy ? g_glstate.histogram_proxy : g_glstate.histogram;
    if (!powerOfTwo(width)) {
        state.width = 0;
        state.counts.clear();
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    if (width > SFPEW_MAX_HISTOGRAM_SIZE) {
        if (proxy) {
            LIST_RECORD(glHistogram, {}, target, width, requested_internalformat, sink)
            state = {};
            state.internalformat = GL_NONE;
        } else {
            g_glstate.set_error(GL_TABLE_TOO_LARGE);
        }
        return;
    }
    LIST_RECORD(glHistogram, {}, target, width, requested_internalformat, sink)
    state.internalformat = requested_internalformat;
    state.width = width;
    state.sink = sink != GL_FALSE;
    if (proxy) {
        state.counts.clear();
        return;
    }
    try {
        state.counts.assign(static_cast<size_t>(width), glm::uvec4(0));
    } catch (const std::bad_alloc&) {
        state.width = 0;
        g_glstate.set_error(GL_OUT_OF_MEMORY);
    }
}

void glResetHistogram(GLenum target) {
    sfpewEntryBarrier();
    if (target != GL_HISTOGRAM) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    LIST_RECORD(glResetHistogram, {}, target)
    if (g_glstate.histogram.width == 0) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return;
    }
    std::fill(g_glstate.histogram.counts.begin(), g_glstate.histogram.counts.end(), glm::uvec4(0));
}

void glGetHistogram(GLenum target, GLboolean reset, GLenum format, GLenum type, GLvoid* values) {
    sfpewEntryBarrier();
    if (target != GL_HISTOGRAM) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    histogram_t& state = g_glstate.histogram;
    if (state.width == 0) {
        g_glstate.set_error(GL_INVALID_OPERATION);
        return;
    }
    std::vector<glm::vec4> converted;
    try {
        converted.resize(state.counts.size());
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return;
    }
    for (size_t i = 0; i < state.counts.size(); ++i)
        converted[i] = glm::vec4(state.counts[i]);
    if (!encodePixels(state.width, 1, format, type, converted.data(), values, true)) return;
    if (reset != GL_FALSE)
        std::fill(state.counts.begin(), state.counts.end(), glm::uvec4(0));
}

namespace {

histogram_t* histogramState(GLenum target) {
    if (target == GL_HISTOGRAM) return &g_glstate.histogram;
    if (target == GL_PROXY_HISTOGRAM) return &g_glstate.histogram_proxy;
    return nullptr;
}

bool histogramParameter(GLenum target, GLenum pname, GLfloat* value) {
    histogram_t* state = histogramState(target);
    if (state == nullptr) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return false;
    }
    internal_format_t info;
    internalFormat(state->internalformat, &info);
    switch (pname) {
    case GL_HISTOGRAM_WIDTH: *value = static_cast<GLfloat>(state->width); break;
    case GL_HISTOGRAM_FORMAT: *value = static_cast<GLfloat>(state->internalformat); break;
    case GL_HISTOGRAM_RED_SIZE: *value = static_cast<GLfloat>(info.bits[0]); break;
    case GL_HISTOGRAM_GREEN_SIZE: *value = static_cast<GLfloat>(info.bits[1]); break;
    case GL_HISTOGRAM_BLUE_SIZE: *value = static_cast<GLfloat>(info.bits[2]); break;
    case GL_HISTOGRAM_ALPHA_SIZE: *value = static_cast<GLfloat>(info.bits[3]); break;
    case GL_HISTOGRAM_LUMINANCE_SIZE:
        *value = info.base == GL_LUMINANCE || info.base == GL_LUMINANCE_ALPHA
                     ? static_cast<GLfloat>(info.bits[0])
                     : 0.0f;
        break;
    case GL_HISTOGRAM_SINK: *value = state->sink ? 1.0f : 0.0f; break;
    default: g_glstate.set_error(GL_INVALID_ENUM); return false;
    }
    return true;
}

} // namespace

void glGetHistogramParameterfv(GLenum target, GLenum pname, GLfloat* params) {
    sfpewEntryBarrier();
    if (params != nullptr) histogramParameter(target, pname, params);
}

void glGetHistogramParameteriv(GLenum target, GLenum pname, GLint* params) {
    sfpewEntryBarrier();
    if (params == nullptr) return;
    GLfloat value = 0.0f;
    if (histogramParameter(target, pname, &value)) *params = static_cast<GLint>(value);
}

void glMinmax(GLenum target, GLenum requested_internalformat, GLboolean sink) {
    sfpewEntryBarrier();
    if (target != GL_MINMAX) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    internal_format_t info;
    if (!internalFormat(requested_internalformat, &info)) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    LIST_RECORD(glMinmax, {}, target, requested_internalformat, sink)
    auto& state = g_glstate.minmax;
    state.internalformat = requested_internalformat;
    state.sink = sink != GL_FALSE;
    state.minimum = glm::vec4(1.0f);
    state.maximum = glm::vec4(0.0f);
}

void glResetMinmax(GLenum target) {
    sfpewEntryBarrier();
    if (target != GL_MINMAX) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    LIST_RECORD(glResetMinmax, {}, target)
    g_glstate.minmax.minimum = glm::vec4(1.0f);
    g_glstate.minmax.maximum = glm::vec4(0.0f);
}

void glGetMinmax(GLenum target, GLboolean reset, GLenum format, GLenum type, GLvoid* values) {
    sfpewEntryBarrier();
    if (target != GL_MINMAX) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    auto& state = g_glstate.minmax;
    const glm::vec4 result[2] = {applyInternalFormat(state.minimum, state.internalformat),
                                 applyInternalFormat(state.maximum, state.internalformat)};
    if (!encodePixels(2, 1, format, type, result, values)) return;
    if (reset != GL_FALSE) {
        state.minimum = glm::vec4(1.0f);
        state.maximum = glm::vec4(0.0f);
    }
}

namespace {

bool minmaxParameter(GLenum target, GLenum pname, GLfloat* value) {
    if (target != GL_MINMAX) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return false;
    }
    switch (pname) {
    case GL_MINMAX_FORMAT: *value = static_cast<GLfloat>(g_glstate.minmax.internalformat); return true;
    case GL_MINMAX_SINK: *value = g_glstate.minmax.sink ? 1.0f : 0.0f; return true;
    default: g_glstate.set_error(GL_INVALID_ENUM); return false;
    }
}

glm::vec4 tableLookup(const color_table_t& table, const glm::vec4& value) {
    if (!table.enabled || table.entries.empty()) return value;
    const unsigned defined = definedChannels(table.internalformat);
    glm::vec4 result = value;
    for (int channel = 0; channel < 4; ++channel) {
        if ((defined & (1u << channel)) == 0) continue;
        const float component = std::clamp(value[channel], 0.0f, 1.0f);
        const size_t index = std::min(static_cast<size_t>(std::floor(component * table.entries.size())),
                                      table.entries.size() - 1u);
        result[channel] = table.entries[index][channel];
    }
    return result;
}

glm::vec4 convolutionSample(const std::vector<glm::vec4>& image, GLsizei width,
                            GLsizei height, GLint x, GLint y, const convolution_t& state) {
    if (x >= 0 && y >= 0 && x < width && y < height)
        return image[static_cast<size_t>(y) * width + x];
    if (state.border_mode == GL_CONSTANT_BORDER)
        return {state.border_color[0], state.border_color[1], state.border_color[2],
                state.border_color[3]};
    x = std::clamp<GLint>(x, 0, width - 1);
    y = std::clamp<GLint>(y, 0, height - 1);
    return image[static_cast<size_t>(y) * width + x];
}

void convolve2D(std::vector<glm::vec4>* image, GLsizei* width, GLsizei* height,
                const convolution_t& state) {
    const GLsizei kw = state.width;
    const GLsizei kh = state.height;
    if (kw <= 0 || kh <= 0 || state.entries.empty()) return;
    const bool reduce = state.border_mode == GL_REDUCE;
    const unsigned defined = definedChannels(state.internalformat);
    const GLsizei output_width = reduce ? std::max<GLsizei>(*width - kw + 1, 0) : *width;
    const GLsizei output_height = reduce ? std::max<GLsizei>(*height - kh + 1, 0) : *height;
    std::vector<glm::vec4> output(static_cast<size_t>(output_width) * output_height,
                                  glm::vec4(0.0f));
    for (GLsizei y = 0; y < output_height; ++y) {
        for (GLsizei x = 0; x < output_width; ++x) {
            glm::vec4 sum(0.0f);
            const GLint origin_x = reduce ? x : x - kw / 2;
            const GLint origin_y = reduce ? y : y - kh / 2;
            for (GLsizei ky = 0; ky < kh; ++ky) {
                for (GLsizei kx = 0; kx < kw; ++kx) {
                    sum += convolutionSample(*image, *width, *height, origin_x + kx,
                                             origin_y + ky, state) *
                           state.entries[static_cast<size_t>(ky) * kw + kx];
                }
            }
            if (defined != 0xfu) {
                // The channels this filter's base internal format does not
                // carry come from source pixel (x, y) - the ORIGIN of the
                // footprint, which under GL_REDUCE is not its centre.
                // Measured against the desktop driver: a 3-wide LUMINANCE
                // filter reducing a 3-wide source to one pixel passes the
                // leftmost source alpha through, not the middle one.
                const glm::vec4 unfiltered =
                    convolutionSample(*image, *width, *height, x, y, state);
                for (int channel = 0; channel < 4; ++channel)
                    if ((defined & (1u << channel)) == 0) sum[channel] = unfiltered[channel];
            }
            output[static_cast<size_t>(y) * output_width + x] = sum;
        }
    }
    *image = std::move(output);
    *width = output_width;
    *height = output_height;
}

void convolveSeparable(std::vector<glm::vec4>* image, GLsizei* width, GLsizei* height,
                       const convolution_t& state) {
    if (state.width <= 0 || state.height <= 0 || state.separable_row.empty() ||
        state.separable_column.empty())
        return;
    const bool reduce = state.border_mode == GL_REDUCE;
    const unsigned defined = definedChannels(state.internalformat);
    const GLsizei row_width = reduce ? std::max<GLsizei>(*width - state.width + 1, 0) : *width;
    std::vector<glm::vec4> horizontal(static_cast<size_t>(row_width) * *height,
                                      glm::vec4(0.0f));
    for (GLsizei y = 0; y < *height; ++y) {
        for (GLsizei x = 0; x < row_width; ++x) {
            glm::vec4 sum(0.0f);
            const GLint origin = reduce ? x : x - state.width / 2;
            for (GLsizei k = 0; k < state.width; ++k)
                sum += convolutionSample(*image, *width, *height, origin + k, y, state) *
                       state.separable_row[k];
            horizontal[static_cast<size_t>(y) * row_width + x] = sum;
        }
    }
    const GLsizei output_height =
        reduce ? std::max<GLsizei>(*height - state.height + 1, 0) : *height;
    glm::vec4 horizontal_border(state.border_color[0], state.border_color[1],
                                state.border_color[2], state.border_color[3]);
    if (state.border_mode == GL_CONSTANT_BORDER) {
        glm::vec4 row_sum(0.0f);
        for (const glm::vec4& coefficient : state.separable_row) row_sum += coefficient;
        horizontal_border *= row_sum;
    }
    std::vector<glm::vec4> output(static_cast<size_t>(row_width) * output_height,
                                  glm::vec4(0.0f));
    for (GLsizei y = 0; y < output_height; ++y) {
        for (GLsizei x = 0; x < row_width; ++x) {
            glm::vec4 sum(0.0f);
            const GLint origin = reduce ? y : y - state.height / 2;
            for (GLsizei k = 0; k < state.height; ++k) {
                GLint sample_y = origin + k;
                glm::vec4 sample;
                if (sample_y >= 0 && sample_y < *height)
                    sample = horizontal[static_cast<size_t>(sample_y) * row_width + x];
                else if (state.border_mode == GL_CONSTANT_BORDER)
                    sample = horizontal_border;
                else {
                    sample_y = std::clamp<GLint>(sample_y, 0, *height - 1);
                    sample = horizontal[static_cast<size_t>(sample_y) * row_width + x];
                }
                sum += sample * state.separable_column[k];
            }
            // Same pass-through rule as convolve2D, against the source this
            // two-pass form still holds untouched until the move below.
            if (defined != 0xfu) {
                const glm::vec4 unfiltered =
                    convolutionSample(*image, *width, *height, x, y, state);
                for (int channel = 0; channel < 4; ++channel)
                    if ((defined & (1u << channel)) == 0) sum[channel] = unfiltered[channel];
            }
            output[static_cast<size_t>(y) * row_width + x] = sum;
        }
    }
    *image = std::move(output);
    *width = row_width;
    *height = output_height;
}

void collectHistogram(const std::vector<glm::vec4>& image, histogram_t& state) {
    if (!state.enabled || state.width <= 0 || state.counts.empty()) return;
    for (const glm::vec4& pixel : image) {
        for (int channel = 0; channel < 4; ++channel) {
            const GLint bin = std::clamp(
                static_cast<GLint>(std::clamp(pixel[channel], 0.0f, 1.0f) * (state.width - 1) +
                                   0.5f),
                0, state.width - 1);
            GLuint& count = state.counts[bin][channel];
            // Long-running captures must saturate rather than silently wrap.
            if (count != std::numeric_limits<GLuint>::max()) ++count;
        }
    }
}

// The color matrix and the post-color-matrix scale/bias are the one part of
// 3.6.3 with no glEnable of their own - the stage runs unconditionally - so
// a non-default value is the only "enabled" they have, and sfpewImagingActive
// cannot be a pure OR of the eight enable flags without dropping them.
bool colorMatrixStageActive() {
    const auto& un = g_glstate.fpe_uniform;
    for (int channel = 0; channel < 4; ++channel) {
        if (un.post_color_matrix_scale[channel] != 1.0f ||
            un.post_color_matrix_bias[channel] != 0.0f)
            return true;
    }
    return un.transformation.matrices[matrix_idx(GL_COLOR)] != glm::mat4(1.0f);
}

void collectMinmax(const std::vector<glm::vec4>& image, minmax_t& state) {
    if (!state.enabled) return;
    for (const glm::vec4& pixel : image) {
        const glm::vec4 bounded = clampColor(pixel);
        state.minimum = glm::min(state.minimum, bounded);
        state.maximum = glm::max(state.maximum, bounded);
    }
}

} // namespace

void glGetMinmaxParameterfv(GLenum target, GLenum pname, GLfloat* params) {
    sfpewEntryBarrier();
    if (params != nullptr) minmaxParameter(target, pname, params);
}

void glGetMinmaxParameteriv(GLenum target, GLenum pname, GLint* params) {
    sfpewEntryBarrier();
    if (params == nullptr) return;
    GLfloat value = 0.0f;
    if (minmaxParameter(target, pname, &value)) *params = static_cast<GLint>(value);
}

bool sfpewImagingActive() {
    if (imaging_bypass_depth != 0) return false;
    const auto& gs = g_glstate;
    return gs.color_tables[0].enabled || gs.color_tables[1].enabled ||
           gs.color_tables[2].enabled || gs.convolutions[0].enabled ||
           gs.convolutions[1].enabled || gs.convolutions[2].enabled ||
           gs.histogram.enabled || gs.minmax.enabled || colorMatrixStageActive();
}

bool sfpewImagingSink() {
    return (g_glstate.histogram.enabled && g_glstate.histogram.sink) ||
           (g_glstate.minmax.enabled && g_glstate.minmax.sink);
}

bool sfpewImagingTransfer(GLfloat* rgba, GLsizei* width, GLsizei* height) {
    if (!sfpewImagingActive()) return false;
    if (rgba == nullptr || width == nullptr || height == nullptr || *width < 0 || *height < 0)
        return true;
    std::vector<glm::vec4> image;
    try {
        image.resize(static_cast<size_t>(*width) * *height);
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return true;
    }
    std::memcpy(image.data(), rgba, image.size() * sizeof(glm::vec4));
    auto& gs = g_glstate;
    for (glm::vec4& pixel : image) pixel = tableLookup(gs.color_tables[0], pixel);

    // Everything reaching this transfer is a 2D image, and 3.6.3 chooses
    // between CONVOLUTION_2D (winning) and SEPARABLE_2D for those.
    // CONVOLUTION_1D filters one-dimensional images only, so it never
    // competes here however it is enabled.
    const int convolution_index = gs.convolutions[1].enabled   ? 1
                                  : gs.convolutions[2].enabled ? 2
                                                               : -1;
    try {
        if (convolution_index >= 0) {
            const convolution_t& convolution = gs.convolutions[convolution_index];
            if (convolution_index == 2)
                convolveSeparable(&image, width, height, convolution);
            else
                convolve2D(&image, width, height, convolution);
            const auto& un = gs.fpe_uniform;
            const glm::vec4 scale(un.post_convolution_scale[0], un.post_convolution_scale[1],
                                  un.post_convolution_scale[2], un.post_convolution_scale[3]);
            const glm::vec4 bias(un.post_convolution_bias[0], un.post_convolution_bias[1],
                                 un.post_convolution_bias[2], un.post_convolution_bias[3]);
            for (glm::vec4& pixel : image) pixel = clampColor(pixel * scale + bias);
        }
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return true;
    }
    for (glm::vec4& pixel : image) pixel = tableLookup(gs.color_tables[1], pixel);

    const glm::mat4& color_matrix =
        gs.fpe_uniform.transformation.matrices[matrix_idx(GL_COLOR)];
    const auto& un = gs.fpe_uniform;
    const glm::vec4 color_scale(un.post_color_matrix_scale[0], un.post_color_matrix_scale[1],
                                un.post_color_matrix_scale[2], un.post_color_matrix_scale[3]);
    const glm::vec4 color_bias(un.post_color_matrix_bias[0], un.post_color_matrix_bias[1],
                               un.post_color_matrix_bias[2], un.post_color_matrix_bias[3]);
    for (glm::vec4& pixel : image)
        pixel = tableLookup(gs.color_tables[2], clampColor((color_matrix * pixel) * color_scale +
                                                           color_bias));

    collectHistogram(image, gs.histogram);
    collectMinmax(image, gs.minmax);
    std::memcpy(rgba, image.data(), image.size() * sizeof(glm::vec4));
    return true;
}

bool sfpewImagingDecodePixels(GLsizei width, GLsizei height, GLenum format, GLenum type,
                              const GLvoid* pixels, std::vector<GLfloat>* rgba,
                              GLsizei* output_width, GLsizei* output_height) {
    if (!sfpewImagingActive()) return false;
    std::vector<glm::vec4> decoded;
    if (!decodePixels(width, height, format, type, pixels, &decoded)) return true;
    try {
        rgba->resize(decoded.size() * 4u);
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return true;
    }
    std::memcpy(rgba->data(), decoded.data(), rgba->size() * sizeof(GLfloat));
    *output_width = width;
    *output_height = height;
    sfpewImagingTransfer(rgba->data(), output_width, output_height);
    rgba->resize(static_cast<size_t>(*output_width) * *output_height * 4u);
    return true;
}

bool sfpewImagingReadRgba(GLint x, GLint y, GLsizei width, GLsizei height,
                          std::vector<GLfloat>* rgba, GLsizei* output_width,
                          GLsizei* output_height) {
    if (!sfpewImagingActive()) return false;
    std::vector<glm::vec4> readback;
    if (!readFramebuffer(x, y, width, height, &readback)) return true;
    try {
        rgba->resize(readback.size() * 4u);
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return true;
    }
    std::memcpy(rgba->data(), readback.data(), rgba->size() * sizeof(GLfloat));
    *output_width = width;
    *output_height = height;
    sfpewImagingTransfer(rgba->data(), output_width, output_height);
    rgba->resize(static_cast<size_t>(*output_width) * *output_height * 4u);
    return true;
}

bool sfpewImagingReadPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format,
                            GLenum type, GLvoid* pixels) {
    std::vector<GLfloat> rgba;
    GLsizei output_width = width, output_height = height;
    if (!sfpewImagingReadRgba(x, y, width, height, &rgba, &output_width, &output_height))
        return false;
    if (sfpewImagingSink() || rgba.empty()) return true;
    encodePixels(output_width, output_height, format, type,
                 reinterpret_cast<const glm::vec4*>(rgba.data()), pixels);
    return true;
}

// defects-plan-3.md: GL 2.1 3.6.3's basic pixel transfer - RGBA scale/bias,
// then GL_MAP_COLOR's per-channel table lookup - applied before any
// ARB_imaging stage, exactly the formula glDrawPixels' own decode loop
// already uses on the write side (pixelops.cpp).
bool sfpewBasicColorTransferActive() {
    const auto& un = g_glstate.fpe_uniform;
    return un.pixel_scale[0] != 1.0f || un.pixel_scale[1] != 1.0f || un.pixel_scale[2] != 1.0f ||
           un.pixel_scale[3] != 1.0f || un.pixel_bias[0] != 0.0f || un.pixel_bias[1] != 0.0f ||
           un.pixel_bias[2] != 0.0f || un.pixel_bias[3] != 0.0f || un.pixel_map_color;
}

void applyBasicColorTransfer(glm::vec4* pixel) {
    const auto& un = g_glstate.fpe_uniform;
    for (int channel = 0; channel < 4; ++channel) {
        float transferred =
            std::clamp((*pixel)[channel] * un.pixel_scale[channel] + un.pixel_bias[channel], 0.0f, 1.0f);
        if (un.pixel_map_color) {
            const auto& map = g_glstate.pixel_maps[
                static_cast<size_t>(GL_PIXEL_MAP_R_TO_R - GL_PIXEL_MAP_I_TO_I) +
                static_cast<size_t>(channel)];
            const size_t map_index =
                std::min(static_cast<size_t>(std::floor(transferred * map.size())), map.size() - 1u);
            transferred = map[map_index];
        }
        (*pixel)[channel] = transferred;
    }
}

// Supersedes sfpewImagingReadRgba above for glReadPixels/glCopyPixels
// specifically: runs the basic transfer THEN (unchanged) whatever
// ARB_imaging stages are active, the full GL 2.1 pipeline in spec order.
// sfpewImagingReadRgba/ReadPixels themselves stay untouched - they still
// back glCopyTexImage2D/glCopyTexSubImage2D's own imaging hook
// (texture_image.cpp), which this fix does not extend to (out of scope: the
// user asked to fix glCopyPixels and glReadPixels specifically).
bool sfpewFullColorReadRgba(GLint x, GLint y, GLsizei width, GLsizei height,
                            std::vector<GLfloat>* rgba, GLsizei* output_width,
                            GLsizei* output_height, bool force) {
    if (!force && !sfpewBasicColorTransferActive() && !sfpewImagingActive()) return false;
    std::vector<glm::vec4> readback;
    if (!readFramebuffer(x, y, width, height, &readback)) return true;
    for (auto& pixel : readback) applyBasicColorTransfer(&pixel);
    try {
        rgba->resize(readback.size() * 4u);
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return true;
    }
    std::memcpy(rgba->data(), readback.data(), rgba->size() * sizeof(GLfloat));
    *output_width = width;
    *output_height = height;
    sfpewImagingTransfer(rgba->data(), output_width, output_height);
    rgba->resize(static_cast<size_t>(*output_width) * *output_height * 4u);
    return true;
}

bool sfpewFullColorReadPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format,
                              GLenum type, GLvoid* pixels, bool force) {
    pixel_format_t info; // GL_DEPTH_COMPONENT/GL_STENCIL_INDEX are not
                         // color formats - not this function's concern.
    if (!pixelFormat(format, &info)) return false;
    std::vector<GLfloat> rgba;
    GLsizei output_width = width, output_height = height;
    if (!sfpewFullColorReadRgba(x, y, width, height, &rgba, &output_width, &output_height, force))
        return false;
    if (sfpewImagingSink() || rgba.empty()) return true;
    encodePixels(output_width, output_height, format, type,
                reinterpret_cast<const glm::vec4*>(rgba.data()), pixels);
    return true;
}

// GL_DEPTH_SCALE/BIAS (GL 2.1 3.6.3), applied to a tightly packed float
// depth buffer already read from the backend.
bool sfpewDepthPixelTransferActive() {
    const auto& un = g_glstate.fpe_uniform;
    return un.pixel_scale[4] != 1.0f || un.pixel_bias[4] != 0.0f;
}

bool sfpewReadTransformedDepth(GLint x, GLint y, GLsizei width, GLsizei height,
                               std::vector<GLfloat>* out) {
    if (!sfpewEnsureBackend() || g_glFuncs.glReadPixels == nullptr ||
        g_glFuncs.glGetIntegerv == nullptr || g_glFuncs.glPixelStorei == nullptr ||
        g_glFuncs.glBindBuffer == nullptr || width <= 0 || height <= 0) {
        return false;
    }
    try {
        out->resize(static_cast<size_t>(width) * static_cast<size_t>(height));
    } catch (const std::bad_alloc&) {
        g_glstate.set_error(GL_OUT_OF_MEMORY);
        return false;
    }
    // Matches readFramebuffer above: `out` is our own tightly packed buffer,
    // not the caller's, so the caller's GL_PACK_* layout and any bound pack
    // PBO must be neutralized around the backend call (else it either pads
    // rows the tight width*height loop below doesn't expect, or - with a
    // PBO bound - treats out->data() as a byte offset instead of a client
    // pointer) and then restored.
    GLint alignment = 4, row_length = 0, skip_rows = 0, skip_pixels = 0, pbo = 0;
    g_glFuncs.glGetIntegerv(GL_PACK_ALIGNMENT, &alignment);
    g_glFuncs.glGetIntegerv(GL_PACK_ROW_LENGTH, &row_length);
    g_glFuncs.glGetIntegerv(GL_PACK_SKIP_ROWS, &skip_rows);
    g_glFuncs.glGetIntegerv(GL_PACK_SKIP_PIXELS, &skip_pixels);
    g_glFuncs.glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &pbo);
    if (pbo != 0) g_glFuncs.glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    g_glFuncs.glPixelStorei(GL_PACK_ALIGNMENT, 1);
    g_glFuncs.glPixelStorei(GL_PACK_ROW_LENGTH, 0);
    g_glFuncs.glPixelStorei(GL_PACK_SKIP_ROWS, 0);
    g_glFuncs.glPixelStorei(GL_PACK_SKIP_PIXELS, 0);
    g_glFuncs.glReadPixels(x, y, width, height, GL_DEPTH_COMPONENT, GL_FLOAT, out->data());
    // Some backends reject a raw GL_DEPTH_COMPONENT read outright regardless
    // of the framebuffer (observed on this project's own dev/test driver -
    // see gtest_copypixels_depth.cc's DepthAt() comment). That is the
    // backend's own error, not this call's - drain it here so it cannot
    // leak into the caller's next glGetError() as if the caller had done
    // something wrong.
    drainBackendErrors();
    g_glFuncs.glPixelStorei(GL_PACK_ALIGNMENT, alignment);
    g_glFuncs.glPixelStorei(GL_PACK_ROW_LENGTH, row_length);
    g_glFuncs.glPixelStorei(GL_PACK_SKIP_ROWS, skip_rows);
    g_glFuncs.glPixelStorei(GL_PACK_SKIP_PIXELS, skip_pixels);
    if (pbo != 0) g_glFuncs.glBindBuffer(GL_PIXEL_PACK_BUFFER, static_cast<GLuint>(pbo));
    const auto& un = g_glstate.fpe_uniform;
    for (auto& value : *out) value = std::clamp(value * un.pixel_scale[4] + un.pixel_bias[4], 0.0f, 1.0f);
    return true;
}

namespace {
size_t depthScalarBytes(GLenum type) {
    switch (type) {
    case GL_UNSIGNED_BYTE: return 1;
    case GL_UNSIGNED_SHORT: return 2;
    case GL_UNSIGNED_INT:
    case GL_FLOAT: return 4;
    default: return 0;
    }
}

// GL 2.1 table 3.7's DEPTH_COMPONENT encodings: float stays exact, the
// unsigned integer types normalize [0,1] -> their full range like every
// other normalized color channel already does elsewhere in this file.
void encodeDepthScalar(uint8_t* dest, GLenum type, float value, bool swap) {
    switch (type) {
    case GL_FLOAT: {
        GLfloat v = value;
        if (swap) {
            uint8_t bytes[4];
            std::memcpy(bytes, &v, 4);
            std::reverse(bytes, bytes + 4);
            std::memcpy(dest, bytes, 4);
        } else {
            std::memcpy(dest, &v, 4);
        }
        return;
    }
    case GL_UNSIGNED_BYTE:
        *dest = static_cast<GLubyte>(value * 255.0f + 0.5f);
        return;
    case GL_UNSIGNED_SHORT: {
        GLushort v = static_cast<GLushort>(value * 65535.0f + 0.5f);
        if (swap) {
            uint8_t bytes[2];
            std::memcpy(bytes, &v, 2);
            std::reverse(bytes, bytes + 2);
            std::memcpy(dest, bytes, 2);
        } else {
            std::memcpy(dest, &v, 2);
        }
        return;
    }
    case GL_UNSIGNED_INT: {
        GLuint v = static_cast<GLuint>(static_cast<double>(value) * 4294967295.0 + 0.5);
        if (swap) {
            uint8_t bytes[4];
            std::memcpy(bytes, &v, 4);
            std::reverse(bytes, bytes + 4);
            std::memcpy(dest, bytes, 4);
        } else {
            std::memcpy(dest, &v, 4);
        }
        return;
    }
    default:
        return;
    }
}
} // namespace

bool sfpewDepthPixelTransferReadPixels(GLint x, GLint y, GLsizei width, GLsizei height,
                                       GLenum format, GLenum type, GLvoid* pixels) {
    // format must be checked here, not left to the caller: `type` alone
    // (GL_UNSIGNED_BYTE etc.) is also a legal type for plenty of color
    // formats, so without this a glReadPixels(GL_RGBA, GL_UNSIGNED_BYTE)
    // done while some unrelated earlier call had set GL_DEPTH_SCALE/BIAS
    // would otherwise get silently hijacked into writing reinterpreted
    // depth data over the caller's requested color output.
    if (format != GL_DEPTH_COMPONENT || !sfpewDepthPixelTransferActive()) return false;
    const size_t scalar_bytes = depthScalarBytes(type);
    if (scalar_bytes == 0 || pixels == nullptr) return false;

    std::vector<GLfloat> depth;
    if (!sfpewReadTransformedDepth(x, y, width, height, &depth)) return true;

    pixel_layout_t layout;
    if (!pixelLayout(/*pack=*/true, width, height, scalar_bytes, &layout)) return true;
    mapped_pixels_t mapped;
    uint8_t* base = nullptr;
    if (!mapPixelBuffer(/*pack=*/true, pixels, layout, &mapped, &base)) return true;
    const bool swap = g_glstate.pixel_store_pack_swap_bytes;
    uint8_t* first = base + layout.start;
    for (GLsizei row = 0; row < height; ++row) {
        uint8_t* dest_row = first + static_cast<size_t>(row) * layout.stride;
        for (GLsizei column = 0; column < width; ++column) {
            encodeDepthScalar(dest_row + static_cast<size_t>(column) * scalar_bytes, type,
                              depth[static_cast<size_t>(row) * width + column], swap);
        }
    }
    return true;
}

bool sfpewPrepareImagingUpload(GLsizei width, GLsizei height, GLenum format, GLenum type,
                               const GLvoid* pixels, sfpew_imaging_upload_t* upload) {
    *upload = {};
    if (!sfpewImagingActive()) return false;
    upload->width = width;
    upload->height = height;
    if (!sfpewImagingDecodePixels(width, height, format, type, pixels, &upload->rgba,
                                  &upload->width, &upload->height))
        return false;
    upload->sink = sfpewImagingSink();
    upload->valid = upload->sink || width == 0 || height == 0 || !upload->rgba.empty();
    if (!upload->valid || width == 0 || height == 0) return true;
    if (!sfpewBeginTightImagingUpload(upload)) upload->valid = false;
    return true;
}

bool sfpewBeginTightImagingUpload(sfpew_imaging_upload_t* upload) {
    if (!sfpewEnsureBackend() || g_glFuncs.glGetIntegerv == nullptr ||
        g_glFuncs.glPixelStorei == nullptr || g_glFuncs.glBindBuffer == nullptr)
        return false;
    g_glFuncs.glGetIntegerv(GL_UNPACK_ALIGNMENT, &upload->alignment);
    g_glFuncs.glGetIntegerv(GL_UNPACK_ROW_LENGTH, &upload->row_length);
    g_glFuncs.glGetIntegerv(GL_UNPACK_SKIP_ROWS, &upload->skip_rows);
    g_glFuncs.glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &upload->skip_pixels);
    g_glFuncs.glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &upload->unpack_pbo);
    upload->unpack_swap_bytes = g_glstate.pixel_store_unpack_swap_bytes;
    if (upload->unpack_pbo != 0) g_glFuncs.glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    g_glFuncs.glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    g_glFuncs.glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    g_glFuncs.glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
    g_glFuncs.glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
    g_glstate.pixel_store_unpack_swap_bytes = false;
    upload->neutralized = true;
    return true;
}

void sfpewFinishImagingUpload(const sfpew_imaging_upload_t& upload) {
    if (!upload.neutralized || g_glFuncs.glPixelStorei == nullptr ||
        g_glFuncs.glBindBuffer == nullptr)
        return;
    g_glFuncs.glPixelStorei(GL_UNPACK_ALIGNMENT, upload.alignment);
    g_glFuncs.glPixelStorei(GL_UNPACK_ROW_LENGTH, upload.row_length);
    g_glFuncs.glPixelStorei(GL_UNPACK_SKIP_ROWS, upload.skip_rows);
    g_glFuncs.glPixelStorei(GL_UNPACK_SKIP_PIXELS, upload.skip_pixels);
    g_glstate.pixel_store_unpack_swap_bytes = upload.unpack_swap_bytes;
    if (upload.unpack_pbo != 0)
        g_glFuncs.glBindBuffer(GL_PIXEL_UNPACK_BUFFER, static_cast<GLuint>(upload.unpack_pbo));
}

void sfpewPushImagingBypass() { ++imaging_bypass_depth; }

void sfpewPopImagingBypass() {
    if (imaging_bypass_depth != 0) --imaging_bypass_depth;
}
