// SimpleFPEWrapper - SimpleFPEWrapper/shader/vertexattrib.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "../init.h"
#include "../fpe/drawing1x.h"
#include "../fpe/list.h"

#include <array>
#include <cstddef>

namespace {

GLint maxVertexAttribs() {
    static thread_local GLint cached = 0;
    if (cached == 0 && sfpewEnsureBackend() && g_glFuncs.glGetIntegerv != nullptr)
        g_glFuncs.glGetIntegerv(GL_MAX_VERTEX_ATTRIBS, &cached);
    return cached > 0 ? cached : 16; // GL 2.1 minimum
}

bool validVertexAttribIndex(glstate_t& state, GLuint index) {
    if (index < static_cast<GLuint>(maxVertexAttribs())) return true;
    state.set_error(GL_INVALID_VALUE);
    return false;
}

// GL 2.0 generic attribute variants all define the same four-component
// current value. Plain integer forms are numeric casts; only the explicitly
// N-prefixed forms normalize.
template <bool Normalized, typename Type, size_t N>
void mglVertexAttrib(GLuint index, const std::array<Type, N>& value) {
    auto& state = g_glstate;
    if (!validVertexAttribIndex(state, index)) return;
    if (!sfpewEnsureBackend() || g_glFuncs.glVertexAttrib4fv == nullptr) return;

    // A current value is NOT immediate-mode vertex data the wrapper collects,
    // so a run already sitting in the merge batch would be redrawn with this
    // one instead of the value it was described under (plans/16 M6).
    sfpewEntryBarrier();

    GLfloat expanded[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    for (size_t i = 0; i < N; ++i) {
        if constexpr (Normalized)
            expanded[i] = sfpewNormalizeColorComponent(value[i]);
        else
            expanded[i] = static_cast<GLfloat>(value[i]);
    }
    g_glFuncs.glVertexAttrib4fv(index, expanded);
}

} // namespace

#define SFPEW_DEFINE_ATTRIB_1(SUFFIX, TYPE)                                                       \
    void glVertexAttrib1##SUFFIX(GLuint index, TYPE x) {                                          \
        LIST_RECORD(glVertexAttrib1##SUFFIX, {}, index, x)                                        \
        mglVertexAttrib<false>(index, std::array<TYPE, 1>{x});                                    \
    }                                                                                             \
    void glVertexAttrib1##SUFFIX##v(GLuint index, const TYPE* value) {                             \
        if (value == nullptr) return;                                                              \
        LIST_RECORD(glVertexAttrib1##SUFFIX##v, {{1, sizeof(TYPE)}}, index, value)                 \
        mglVertexAttrib<false>(index, std::array<TYPE, 1>{value[0]});                              \
    }

#define SFPEW_DEFINE_ATTRIB_2(SUFFIX, TYPE)                                                       \
    void glVertexAttrib2##SUFFIX(GLuint index, TYPE x, TYPE y) {                                  \
        LIST_RECORD(glVertexAttrib2##SUFFIX, {}, index, x, y)                                     \
        mglVertexAttrib<false>(index, std::array<TYPE, 2>{x, y});                                 \
    }                                                                                             \
    void glVertexAttrib2##SUFFIX##v(GLuint index, const TYPE* value) {                             \
        if (value == nullptr) return;                                                              \
        LIST_RECORD(glVertexAttrib2##SUFFIX##v, {{1, 2 * sizeof(TYPE)}}, index, value)             \
        mglVertexAttrib<false>(index, std::array<TYPE, 2>{value[0], value[1]});                    \
    }

#define SFPEW_DEFINE_ATTRIB_3(SUFFIX, TYPE)                                                       \
    void glVertexAttrib3##SUFFIX(GLuint index, TYPE x, TYPE y, TYPE z) {                           \
        LIST_RECORD(glVertexAttrib3##SUFFIX, {}, index, x, y, z)                                  \
        mglVertexAttrib<false>(index, std::array<TYPE, 3>{x, y, z});                              \
    }                                                                                             \
    void glVertexAttrib3##SUFFIX##v(GLuint index, const TYPE* value) {                             \
        if (value == nullptr) return;                                                              \
        LIST_RECORD(glVertexAttrib3##SUFFIX##v, {{1, 3 * sizeof(TYPE)}}, index, value)             \
        mglVertexAttrib<false>(index, std::array<TYPE, 3>{value[0], value[1], value[2]});          \
    }

#define SFPEW_DEFINE_ATTRIB_4(SUFFIX, TYPE)                                                       \
    void glVertexAttrib4##SUFFIX(GLuint index, TYPE x, TYPE y, TYPE z, TYPE w) {                   \
        LIST_RECORD(glVertexAttrib4##SUFFIX, {}, index, x, y, z, w)                               \
        mglVertexAttrib<false>(index, std::array<TYPE, 4>{x, y, z, w});                           \
    }                                                                                             \
    void glVertexAttrib4##SUFFIX##v(GLuint index, const TYPE* value) {                             \
        if (value == nullptr) return;                                                              \
        LIST_RECORD(glVertexAttrib4##SUFFIX##v, {{1, 4 * sizeof(TYPE)}}, index, value)             \
        mglVertexAttrib<false>(                                                                   \
            index, std::array<TYPE, 4>{value[0], value[1], value[2], value[3]});                  \
    }

#define SFPEW_DEFINE_ATTRIB_FAMILY(SUFFIX, TYPE)                                                  \
    SFPEW_DEFINE_ATTRIB_1(SUFFIX, TYPE)                                                           \
    SFPEW_DEFINE_ATTRIB_2(SUFFIX, TYPE)                                                           \
    SFPEW_DEFINE_ATTRIB_3(SUFFIX, TYPE)                                                           \
    SFPEW_DEFINE_ATTRIB_4(SUFFIX, TYPE)

// The float family reaches the backend unchanged; it is wrapped only for the
// barrier and the display-list record, both of which the backend's own symbol
// would skip.
SFPEW_DEFINE_ATTRIB_FAMILY(f, GLfloat)
SFPEW_DEFINE_ATTRIB_FAMILY(d, GLdouble)
SFPEW_DEFINE_ATTRIB_FAMILY(s, GLshort)

#define SFPEW_DEFINE_ATTRIB4_VECTOR(SUFFIX, TYPE, NORMALIZED)                                     \
    void glVertexAttrib4##SUFFIX(GLuint index, const TYPE* value) {                               \
        if (value == nullptr) return;                                                              \
        LIST_RECORD(glVertexAttrib4##SUFFIX, {{1, 4 * sizeof(TYPE)}}, index, value)                \
        mglVertexAttrib<NORMALIZED>(                                                              \
            index, std::array<TYPE, 4>{value[0], value[1], value[2], value[3]});                  \
    }

SFPEW_DEFINE_ATTRIB4_VECTOR(Nbv, GLbyte, true)
SFPEW_DEFINE_ATTRIB4_VECTOR(Nsv, GLshort, true)
SFPEW_DEFINE_ATTRIB4_VECTOR(Niv, GLint, true)

void glVertexAttrib4Nub(GLuint index, GLubyte x, GLubyte y, GLubyte z, GLubyte w) {
    LIST_RECORD(glVertexAttrib4Nub, {}, index, x, y, z, w)
    mglVertexAttrib<true>(index, std::array<GLubyte, 4>{x, y, z, w});
}

SFPEW_DEFINE_ATTRIB4_VECTOR(Nubv, GLubyte, true)
SFPEW_DEFINE_ATTRIB4_VECTOR(Nusv, GLushort, true)
SFPEW_DEFINE_ATTRIB4_VECTOR(Nuiv, GLuint, true)

SFPEW_DEFINE_ATTRIB4_VECTOR(bv, GLbyte, false)
SFPEW_DEFINE_ATTRIB4_VECTOR(iv, GLint, false)
SFPEW_DEFINE_ATTRIB4_VECTOR(ubv, GLubyte, false)
SFPEW_DEFINE_ATTRIB4_VECTOR(uiv, GLuint, false)
SFPEW_DEFINE_ATTRIB4_VECTOR(usv, GLushort, false)

#undef SFPEW_DEFINE_ATTRIB4_VECTOR
#undef SFPEW_DEFINE_ATTRIB_FAMILY
#undef SFPEW_DEFINE_ATTRIB_4
#undef SFPEW_DEFINE_ATTRIB_3
#undef SFPEW_DEFINE_ATTRIB_2
#undef SFPEW_DEFINE_ATTRIB_1

void glGetVertexAttribdv(GLuint index, GLenum pname, GLdouble* params) {
    sfpewEntryBarrier();
    auto& state = g_glstate;
    if (params == nullptr || !validVertexAttribIndex(state, index)) return;
    if (!sfpewEnsureBackend() || g_glFuncs.glGetVertexAttribfv == nullptr) return;

    GLfloat values[4] = {};
    g_glFuncs.glGetVertexAttribfv(index, pname, values);
    const int count = pname == GL_CURRENT_VERTEX_ATTRIB ? 4 : 1;
    for (int i = 0; i < count; ++i) params[i] = static_cast<GLdouble>(values[i]);
}
