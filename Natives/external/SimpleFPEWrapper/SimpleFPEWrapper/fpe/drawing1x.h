// SimpleFPEWrapper - SimpleFPEWrapper/fpe/drawing1x.h
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#pragma once

#include "types.h"
#include "fpe.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <type_traits>
#include <vector>

void flushPendingImmediateDraws();

// Puts the app's program/VAO/buffers back if a fixed-function draw left the
// wrapper's own bound (plans/12). One branch when nothing is held.
void sfpewFlushDeferredDrawState();

// What every glDrawArrays-shaped draw funnels through, whether from the
// glDrawArrays entry point itself or a captured display-list command's
// replay (fpe/list_capture.cpp). `arrayBufferOverride` >= 0 supplies the
// attribute source buffer directly, skipping the synchronous binding query.
void drawArraysNow(GLenum mode, GLint first, GLsizei count, bool forceFixedFunction,
                   GLint arrayBufferOverride = -1);

// Indexed counterpart of drawArraysNow (fpe/draw_now.cpp). External linkage
// because multidraw.cpp's glMultiDrawElements falls back to it per sub-draw
// when the backend has no native multi-draw or a sub-draw needs individual
// fixed-function/user-program handling, and because a captured display-list
// draw replays through it (fpe/list_capture.cpp).
//
// `elementBufferOverride` >= 0 names the buffer `indices` is an offset into
// instead of resolving the caller's binding, with 0 meaning `indices` is a
// client-memory pointer. A replay MUST supply it: the binding this function
// would otherwise resolve describes the APP's element source, which has
// nothing to do with the buffer the list's own indices live in.
void drawElementsNow(GLenum mode, GLsizei count, GLenum type, const GLvoid* indices,
                     bool forceFixedFunction = false, GLint elementBufferOverride = -1);

// Four corners into the two triangles that cover them, as GL_UNSIGNED_INT
// indices. Shared so the immediate GL_QUADS path and the display-list capture
// that expands its quads once at compile time cannot disagree about winding.
template <typename T>
void expandQuadIndices(const T* src, size_t quadCount, std::vector<uint32_t>& out) {
    out.resize(quadCount * 6u);
    for (size_t q = 0; q < quadCount; ++q) {
        const uint32_t i0 = src[q * 4 + 0], i1 = src[q * 4 + 1];
        const uint32_t i2 = src[q * 4 + 2], i3 = src[q * 4 + 3];
        out[q * 6 + 0] = i0;
        out[q * 6 + 1] = i1;
        out[q * 6 + 2] = i2;
        out[q * 6 + 3] = i2;
        out[q * 6 + 4] = i3;
        out[q * 6 + 5] = i0;
    }
}

// What every exported entry point OUTSIDE the immediate-mode vertex family
// calls first: drains the pending glyph batch and hands the app its draw state
// back. Only glBegin/glEnd and the glVertex/glColor/glNormal/glTexCoord/
// glMultiTexCoord/glFogCoord/glSecondaryColor/glEdgeFlag/glArrayElement
// families use the bare flushPendingImmediateDraws(), because keeping the
// wrapper's bindings across those is the entire point.
//
// Erring toward calling this is safe: an unnecessary call costs the restore
// it was going to pay anyway. Omitting one where the app can observe those
// bindings is what corrupts state, so new entry points should use this unless
// they are demonstrably part of the vertex family.
inline void sfpewEntryBarrier() {
    flushPendingImmediateDraws();
    sfpewFlushDeferredDrawState();
}

// For entry points that CANNOT observe the program, VAO or buffer bindings -
// texture state being the case that matters in practice. The pending batch
// still has to drain, because it was collected under the state this call is
// about to change; but handing the app back bindings it cannot look at only
// forces the next fixed-function draw to re-establish ours. A texture switch
// between draws paid a full save/restore cycle for nothing (plans/12).
//
// The bar for using this instead of sfpewEntryBarrier is high: the entry must
// neither read nor write GL_CURRENT_PROGRAM, GL_VERTEX_ARRAY_BINDING,
// GL_ARRAY_BUFFER_BINDING or GL_ELEMENT_ARRAY_BUFFER_BINDING, and must not
// hand control to anything that could. When in doubt use the full barrier: the
// cost of an unnecessary restore is speed, the cost of a missing one is the app
// drawing with the wrapper's state.
inline void sfpewTextureStateBarrier() { flushPendingImmediateDraws(); }

// Same flush-only contract for entries that mutate only the wrapper's own
// CPU-side state: the matrix-stack family (glMatrixMode, glPush/PopMatrix,
// glTranslate/Rotate/Scale, glLoad/MultMatrix, glOrtho, glFrustum and their
// display-list replay commands) and the client-array family (gl*Pointer,
// glEnable/DisableClientState, glClientActiveTexture). Both meet the bar
// above: no read or write of the program, VAO or buffer bindings, and no
// control handed elsewhere. Using the full barrier here made every draw that
// sits between glPushMatrix/glPopMatrix or a pointer respecification (the
// Minecraft chunk and entity shapes) pay a glUseProgram(0) ->
// glUseProgram(fpe) round trip per draw.
inline void sfpewClientStateBarrier() { flushPendingImmediateDraws(); }

// Stream-upload into the persistent-coherent immediate ring (GL_ARRAY_BUFFER
// must already be bound to fpe_immediate_vbo). Returns the byte offset of the
// uploaded range inside the ring (0 on the glBufferData fallback). Shared by
// the glBegin/glEnd path and the client-array draw commit.
GLintptr sfpewUploadImmediateVertexData(const void* data, size_t size);

// Same ring mechanism for CPU-side index data (client-memory indices and
// rewritten GL_QUADS). GL_ELEMENT_ARRAY_BUFFER must already be bound to
// fpe_element_ring. Returns the byte offset to pass to glDrawElements.
GLintptr sfpewUploadElementData(const void* data, size_t size);

// Missing components take their GL defaults (0, 0, 0, 1) in the SAME store as
// the supplied ones. Writing the default vector first and then overwriting it
// costs a second 16-byte store per attribute on the hottest path there is -
// three of these run for every immediate-mode vertex.
template <GLint N, typename Type>
inline glm::vec4 mglDefaultedVec4(const std::array<Type, N>& v) {
    if constexpr (N >= 4)
        return glm::vec4((GLfloat)v[0], (GLfloat)v[1], (GLfloat)v[2], (GLfloat)v[3]);
    else if constexpr (N == 3)
        return glm::vec4((GLfloat)v[0], (GLfloat)v[1], (GLfloat)v[2], 1.0f);
    else if constexpr (N == 2)
        return glm::vec4((GLfloat)v[0], (GLfloat)v[1], 0.0f, 1.0f);
    else
        return glm::vec4((GLfloat)v[0], 0.0f, 0.0f, 1.0f);
}

// GL 2.1 Table 2.6 conversion shared by primary colors, secondary colors,
// normals and the integer fixed-function parameter spellings. Signed minima
// have one extra magnitude value, so clamp -128/127 (and equivalents) to -1.
template <typename T>
inline GLfloat sfpewNormalizeColorComponent(T value) {
    if constexpr (std::is_floating_point_v<T>) {
        return static_cast<GLfloat>(value);
    } else if constexpr (std::is_signed_v<T>) {
        const GLfloat converted = static_cast<GLfloat>(value) /
                                  static_cast<GLfloat>(std::numeric_limits<T>::max());
        return std::max(converted, -1.0f);
    } else {
        return static_cast<GLfloat>(value) /
               static_cast<GLfloat>(std::numeric_limits<T>::max());
    }
}

// Vertex-data entries ride the Begin/End context pin: zero strict resolves
// while a batch is collecting, one strict resolve otherwise (types.h).
template <typename Type, GLint N>
void mglNormal(std::array<Type, N> normal) {
    auto& state = sfpewVertexDataState().fpe_state.fpe_draw;
    state.set_attribute_size(1, N); // before overwriting the current value
    auto& cur = state.current_data.normal;
    // let's hope this vectorizes well...
    for (auto i = 0; i < N; ++i) {
        glm::value_ptr(cur)[i] = (GLfloat)normal[i];
    }
}

// glFogCoord* feeds attribute slot 5. It only reaches the shader when
// glFogi(GL_FOG_COORD_SRC, GL_FOG_COORD) selects it as the fog distance.
template <typename Type>
void mglFogCoord(Type coord) {
    auto& state = g_glstate.fpe_state.fpe_draw;
    state.set_attribute_size(5, 1);
    state.current_data.fog_coord = (GLfloat)coord;
}

// GL 1.4 / EXT_secondary_color feeds fixed-function attribute slot 6. The
// alpha component is not supplied by this API and is always one.
template <typename Type, GLint N>
void mglSecondaryColor(std::array<Type, N> color) {
    auto& state = sfpewVertexDataState().fpe_state.fpe_draw;
    state.set_attribute_size(6, 3);
    auto& current = state.current_data.secondary_color;
    for (GLint i = 0; i < N; ++i)
        glm::value_ptr(current)[i] = sfpewNormalizeColorComponent(color[i]);
    glm::value_ptr(current)[3] = 1.0f;
}

template <typename Type, GLint N>
void mglTexCoord(std::array<Type, N> uv, GLint texid) {
    auto& state = sfpewVertexDataState().fpe_state.fpe_draw;
    state.set_attribute_size(7 + texid, N);
    state.current_data.texcoord[texid] = mglDefaultedVec4<N>(uv);
}

// Color material is a per-vertex side effect that mutates uniform material
// state, so it has to stay ordered with the batch - but it is off for almost
// every draw. Kept out of line so glColor4f can inline the part that always
// runs: with the whole thing in one function the compiler declined to inline
// it, and every immediate-mode vertex paid a call.
void sfpewApplyColorMaterial(glstate_t& gs, const glm::vec4& color);

template <typename Type, GLint N>
__attribute__((always_inline)) inline void mglColor(std::array<Type, N> color) {
    auto& gs = sfpewVertexDataState();
    auto& state = gs.fpe_state.fpe_draw;
    state.set_attribute_size(2, N);
    // Desktop GL defines alpha=1 for every glColor3* entry point.
    auto& cur = state.current_data.color;
    cur = mglDefaultedVec4<N>(color);
    if (__builtin_expect(gs.fpe_state.fpe_bools.color_material_enable, 0))
        sfpewApplyColorMaterial(gs, cur);
}

template <typename Type, GLint N>
void mglVertex(std::array<Type, N> vertex) {
    auto& state = sfpewVertexDataState().fpe_state.fpe_draw;
    // Release builds define NDEBUG, so this must be a real check: a glVertex*
    // outside glBegin/glEnd would otherwise append stray data that leaks into
    // the next primitive's vertex stream.
    if (state.primitive == kNoPrimitive) return;
    state.set_attribute_size(0, N);
    auto& cur = state.current_data.vertex;
    // Missing components are (0, 0, 0, 1), rather than values left over
    // from the previous immediate-mode vertex.
    cur = mglDefaultedVec4<N>(vertex);
    // let's collect one vertex here!
    state.advance();
}

GLAPI void GLAPIENTRY glBegin(GLenum mode);

GLAPI void GLAPIENTRY glEnd(void);

GLAPI void GLAPIENTRY glVertex2d(GLdouble x, GLdouble y);
GLAPI void GLAPIENTRY glVertex2f(GLfloat x, GLfloat y);
GLAPI void GLAPIENTRY glVertex2i(GLint x, GLint y);
GLAPI void GLAPIENTRY glVertex2s(GLshort x, GLshort y);

GLAPI void GLAPIENTRY glVertex3d(GLdouble x, GLdouble y, GLdouble z);
GLAPI void GLAPIENTRY glVertex3f(GLfloat x, GLfloat y, GLfloat z);
GLAPI void GLAPIENTRY glVertex3i(GLint x, GLint y, GLint z);
GLAPI void GLAPIENTRY glVertex3s(GLshort x, GLshort y, GLshort z);

GLAPI void GLAPIENTRY glVertex4d(GLdouble x, GLdouble y, GLdouble z, GLdouble w);
GLAPI void GLAPIENTRY glVertex4f(GLfloat x, GLfloat y, GLfloat z, GLfloat w);
GLAPI void GLAPIENTRY glVertex4i(GLint x, GLint y, GLint z, GLint w);
GLAPI void GLAPIENTRY glVertex4s(GLshort x, GLshort y, GLshort z, GLshort w);

GLAPI void GLAPIENTRY glVertex2dv(const GLdouble* v);
GLAPI void GLAPIENTRY glVertex2fv(const GLfloat* v);
GLAPI void GLAPIENTRY glVertex2iv(const GLint* v);
GLAPI void GLAPIENTRY glVertex2sv(const GLshort* v);

GLAPI void GLAPIENTRY glVertex3dv(const GLdouble* v);
GLAPI void GLAPIENTRY glVertex3fv(const GLfloat* v);
GLAPI void GLAPIENTRY glVertex3iv(const GLint* v);
GLAPI void GLAPIENTRY glVertex3sv(const GLshort* v);

GLAPI void GLAPIENTRY glVertex4dv(const GLdouble* v);
GLAPI void GLAPIENTRY glVertex4fv(const GLfloat* v);
GLAPI void GLAPIENTRY glVertex4iv(const GLint* v);
GLAPI void GLAPIENTRY glVertex4sv(const GLshort* v);

GLAPI void GLAPIENTRY glNormal3b(GLbyte nx, GLbyte ny, GLbyte nz);
GLAPI void GLAPIENTRY glNormal3d(GLdouble nx, GLdouble ny, GLdouble nz);
GLAPI void GLAPIENTRY glNormal3f(GLfloat nx, GLfloat ny, GLfloat nz);
GLAPI void GLAPIENTRY glNormal3i(GLint nx, GLint ny, GLint nz);
GLAPI void GLAPIENTRY glNormal3s(GLshort nx, GLshort ny, GLshort nz);

GLAPI void GLAPIENTRY glNormal3bv(const GLbyte* v);
GLAPI void GLAPIENTRY glNormal3dv(const GLdouble* v);
GLAPI void GLAPIENTRY glNormal3fv(const GLfloat* v);
GLAPI void GLAPIENTRY glNormal3iv(const GLint* v);
GLAPI void GLAPIENTRY glNormal3sv(const GLshort* v);

// GLAPI void GLAPIENTRY glIndexd( GLdouble c );
// GLAPI void GLAPIENTRY glIndexf( GLfloat c );
// GLAPI void GLAPIENTRY glIndexi( GLint c );
// GLAPI void GLAPIENTRY glIndexs( GLshort c );
// GLAPI void GLAPIENTRY glIndexub( GLubyte c );  /* 1.1 */
//
// GLAPI void GLAPIENTRY glIndexdv( const GLdouble *c );
// GLAPI void GLAPIENTRY glIndexfv( const GLfloat *c );
// GLAPI void GLAPIENTRY glIndexiv( const GLint *c );
// GLAPI void GLAPIENTRY glIndexsv( const GLshort *c );
// GLAPI void GLAPIENTRY glIndexubv( const GLubyte *c );  /* 1.1 */

GLAPI void GLAPIENTRY glColor3b(GLbyte red, GLbyte green, GLbyte blue);
GLAPI void GLAPIENTRY glColor3d(GLdouble red, GLdouble green, GLdouble blue);
GLAPI void GLAPIENTRY glColor3f(GLfloat red, GLfloat green, GLfloat blue);
GLAPI void GLAPIENTRY glColor3i(GLint red, GLint green, GLint blue);
GLAPI void GLAPIENTRY glColor3s(GLshort red, GLshort green, GLshort blue);
GLAPI void GLAPIENTRY glColor3ub(GLubyte red, GLubyte green, GLubyte blue);
GLAPI void GLAPIENTRY glColor3ui(GLuint red, GLuint green, GLuint blue);
GLAPI void GLAPIENTRY glColor3us(GLushort red, GLushort green, GLushort blue);

GLAPI void GLAPIENTRY glColor4b(GLbyte red, GLbyte green, GLbyte blue, GLbyte alpha);
GLAPI void GLAPIENTRY glColor4d(GLdouble red, GLdouble green, GLdouble blue, GLdouble alpha);
GLAPI void GLAPIENTRY glColor4f(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha);
GLAPI void GLAPIENTRY glColor4i(GLint red, GLint green, GLint blue, GLint alpha);
GLAPI void GLAPIENTRY glColor4s(GLshort red, GLshort green, GLshort blue, GLshort alpha);
GLAPI void GLAPIENTRY glColor4ub(GLubyte red, GLubyte green, GLubyte blue, GLubyte alpha);
GLAPI void GLAPIENTRY glColor4ui(GLuint red, GLuint green, GLuint blue, GLuint alpha);
GLAPI void GLAPIENTRY glColor4us(GLushort red, GLushort green, GLushort blue, GLushort alpha);

GLAPI void GLAPIENTRY glColor3bv(const GLbyte* v);
GLAPI void GLAPIENTRY glColor3dv(const GLdouble* v);
GLAPI void GLAPIENTRY glColor3fv(const GLfloat* v);
GLAPI void GLAPIENTRY glColor3iv(const GLint* v);
GLAPI void GLAPIENTRY glColor3sv(const GLshort* v);
GLAPI void GLAPIENTRY glColor3ubv(const GLubyte* v);
GLAPI void GLAPIENTRY glColor3uiv(const GLuint* v);
GLAPI void GLAPIENTRY glColor3usv(const GLushort* v);

GLAPI void GLAPIENTRY glColor4bv(const GLbyte* v);
GLAPI void GLAPIENTRY glColor4dv(const GLdouble* v);
GLAPI void GLAPIENTRY glColor4fv(const GLfloat* v);
GLAPI void GLAPIENTRY glColor4iv(const GLint* v);
GLAPI void GLAPIENTRY glColor4sv(const GLshort* v);
GLAPI void GLAPIENTRY glColor4ubv(const GLubyte* v);
GLAPI void GLAPIENTRY glColor4uiv(const GLuint* v);
GLAPI void GLAPIENTRY glColor4usv(const GLushort* v);

GLAPI void GLAPIENTRY glTexCoord1d(GLdouble s);
GLAPI void GLAPIENTRY glTexCoord1f(GLfloat s);
GLAPI void GLAPIENTRY glTexCoord1i(GLint s);
GLAPI void GLAPIENTRY glTexCoord1s(GLshort s);

GLAPI void GLAPIENTRY glTexCoord2d(GLdouble s, GLdouble t);
GLAPI void GLAPIENTRY glTexCoord2f(GLfloat s, GLfloat t);
GLAPI void GLAPIENTRY glTexCoord2i(GLint s, GLint t);
GLAPI void GLAPIENTRY glTexCoord2s(GLshort s, GLshort t);

GLAPI void GLAPIENTRY glTexCoord3d(GLdouble s, GLdouble t, GLdouble r);
GLAPI void GLAPIENTRY glTexCoord3f(GLfloat s, GLfloat t, GLfloat r);
GLAPI void GLAPIENTRY glTexCoord3i(GLint s, GLint t, GLint r);
GLAPI void GLAPIENTRY glTexCoord3s(GLshort s, GLshort t, GLshort r);

GLAPI void GLAPIENTRY glTexCoord4d(GLdouble s, GLdouble t, GLdouble r, GLdouble q);
GLAPI void GLAPIENTRY glTexCoord4f(GLfloat s, GLfloat t, GLfloat r, GLfloat q);
GLAPI void GLAPIENTRY glTexCoord4i(GLint s, GLint t, GLint r, GLint q);
GLAPI void GLAPIENTRY glTexCoord4s(GLshort s, GLshort t, GLshort r, GLshort q);

GLAPI void GLAPIENTRY glTexCoord1dv(const GLdouble* v);
GLAPI void GLAPIENTRY glTexCoord1fv(const GLfloat* v);
GLAPI void GLAPIENTRY glTexCoord1iv(const GLint* v);
GLAPI void GLAPIENTRY glTexCoord1sv(const GLshort* v);

GLAPI void GLAPIENTRY glTexCoord2dv(const GLdouble* v);
GLAPI void GLAPIENTRY glTexCoord2fv(const GLfloat* v);
GLAPI void GLAPIENTRY glTexCoord2iv(const GLint* v);
GLAPI void GLAPIENTRY glTexCoord2sv(const GLshort* v);

GLAPI void GLAPIENTRY glTexCoord3dv(const GLdouble* v);
GLAPI void GLAPIENTRY glTexCoord3fv(const GLfloat* v);
GLAPI void GLAPIENTRY glTexCoord3iv(const GLint* v);
GLAPI void GLAPIENTRY glTexCoord3sv(const GLshort* v);

GLAPI void GLAPIENTRY glTexCoord4dv(const GLdouble* v);
GLAPI void GLAPIENTRY glTexCoord4fv(const GLfloat* v);
GLAPI void GLAPIENTRY glTexCoord4iv(const GLint* v);
GLAPI void GLAPIENTRY glTexCoord4sv(const GLshort* v);

GLAPI void GLAPIENTRY glMultiTexCoord1d(GLenum target, GLdouble s);
GLAPI void GLAPIENTRY glMultiTexCoord1f(GLenum target, GLfloat s);
GLAPI void GLAPIENTRY glMultiTexCoord1i(GLenum target, GLint s);
GLAPI void GLAPIENTRY glMultiTexCoord1s(GLenum target, GLshort s);

GLAPI void GLAPIENTRY glMultiTexCoord2d(GLenum target, GLdouble s, GLdouble t);
GLAPI void GLAPIENTRY glMultiTexCoord2f(GLenum target, GLfloat s, GLfloat t);
GLAPI void GLAPIENTRY glMultiTexCoord2i(GLenum target, GLint s, GLint t);
GLAPI void GLAPIENTRY glMultiTexCoord2s(GLenum target, GLshort s, GLshort t);

GLAPI void GLAPIENTRY glMultiTexCoord3d(GLenum target, GLdouble s, GLdouble t, GLdouble r);
GLAPI void GLAPIENTRY glMultiTexCoord3f(GLenum target, GLfloat s, GLfloat t, GLfloat r);
GLAPI void GLAPIENTRY glMultiTexCoord3i(GLenum target, GLint s, GLint t, GLint r);
GLAPI void GLAPIENTRY glMultiTexCoord3s(GLenum target, GLshort s, GLshort t, GLshort r);

GLAPI void GLAPIENTRY glMultiTexCoord4d(GLenum target, GLdouble s, GLdouble t, GLdouble r, GLdouble q);
GLAPI void GLAPIENTRY glMultiTexCoord4f(GLenum target, GLfloat s, GLfloat t, GLfloat r, GLfloat q);
GLAPI void GLAPIENTRY glMultiTexCoord4i(GLenum target, GLint s, GLint t, GLint r, GLint q);
GLAPI void GLAPIENTRY glMultiTexCoord4s(GLenum target, GLshort s, GLshort t, GLshort r, GLshort q);

GLAPI void GLAPIENTRY glMultiTexCoord1dv(GLenum target, const GLdouble* v);
GLAPI void GLAPIENTRY glMultiTexCoord1fv(GLenum target, const GLfloat* v);
GLAPI void GLAPIENTRY glMultiTexCoord1iv(GLenum target, const GLint* v);
GLAPI void GLAPIENTRY glMultiTexCoord1sv(GLenum target, const GLshort* v);

GLAPI void GLAPIENTRY glMultiTexCoord2dv(GLenum target, const GLdouble* v);
GLAPI void GLAPIENTRY glMultiTexCoord2fv(GLenum target, const GLfloat* v);
GLAPI void GLAPIENTRY glMultiTexCoord2iv(GLenum target, const GLint* v);
GLAPI void GLAPIENTRY glMultiTexCoord2sv(GLenum target, const GLshort* v);

GLAPI void GLAPIENTRY glMultiTexCoord3dv(GLenum target, const GLdouble* v);
GLAPI void GLAPIENTRY glMultiTexCoord3fv(GLenum target, const GLfloat* v);
GLAPI void GLAPIENTRY glMultiTexCoord3iv(GLenum target, const GLint* v);
GLAPI void GLAPIENTRY glMultiTexCoord3sv(GLenum target, const GLshort* v);

GLAPI void GLAPIENTRY glMultiTexCoord4dv(GLenum target, const GLdouble* v);
GLAPI void GLAPIENTRY glMultiTexCoord4fv(GLenum target, const GLfloat* v);
GLAPI void GLAPIENTRY glMultiTexCoord4iv(GLenum target, const GLint* v);
GLAPI void GLAPIENTRY glMultiTexCoord4sv(GLenum target, const GLshort* v);

GLAPI void GLAPIENTRY glRasterPos2d(GLdouble x, GLdouble y);
GLAPI void GLAPIENTRY glRasterPos2f(GLfloat x, GLfloat y);
GLAPI void GLAPIENTRY glRasterPos2i(GLint x, GLint y);
GLAPI void GLAPIENTRY glRasterPos2s(GLshort x, GLshort y);

GLAPI void GLAPIENTRY glRasterPos3d(GLdouble x, GLdouble y, GLdouble z);
GLAPI void GLAPIENTRY glRasterPos3f(GLfloat x, GLfloat y, GLfloat z);
GLAPI void GLAPIENTRY glRasterPos3i(GLint x, GLint y, GLint z);
GLAPI void GLAPIENTRY glRasterPos3s(GLshort x, GLshort y, GLshort z);

GLAPI void GLAPIENTRY glRasterPos4d(GLdouble x, GLdouble y, GLdouble z, GLdouble w);
GLAPI void GLAPIENTRY glRasterPos4f(GLfloat x, GLfloat y, GLfloat z, GLfloat w);
GLAPI void GLAPIENTRY glRasterPos4i(GLint x, GLint y, GLint z, GLint w);
GLAPI void GLAPIENTRY glRasterPos4s(GLshort x, GLshort y, GLshort z, GLshort w);

GLAPI void GLAPIENTRY glRasterPos2dv(const GLdouble* v);
GLAPI void GLAPIENTRY glRasterPos2fv(const GLfloat* v);
GLAPI void GLAPIENTRY glRasterPos2iv(const GLint* v);
GLAPI void GLAPIENTRY glRasterPos2sv(const GLshort* v);

GLAPI void GLAPIENTRY glRasterPos3dv(const GLdouble* v);
GLAPI void GLAPIENTRY glRasterPos3fv(const GLfloat* v);
GLAPI void GLAPIENTRY glRasterPos3iv(const GLint* v);
GLAPI void GLAPIENTRY glRasterPos3sv(const GLshort* v);

GLAPI void GLAPIENTRY glRasterPos4dv(const GLdouble* v);
GLAPI void GLAPIENTRY glRasterPos4fv(const GLfloat* v);
GLAPI void GLAPIENTRY glRasterPos4iv(const GLint* v);
GLAPI void GLAPIENTRY glRasterPos4sv(const GLshort* v);

GLAPI void GLAPIENTRY glRectd(GLdouble x1, GLdouble y1, GLdouble x2, GLdouble y2);
GLAPI void GLAPIENTRY glRectf(GLfloat x1, GLfloat y1, GLfloat x2, GLfloat y2);
GLAPI void GLAPIENTRY glRecti(GLint x1, GLint y1, GLint x2, GLint y2);
GLAPI void GLAPIENTRY glRects(GLshort x1, GLshort y1, GLshort x2, GLshort y2);

GLAPI void GLAPIENTRY glRectdv(const GLdouble* v1, const GLdouble* v2);
GLAPI void GLAPIENTRY glRectfv(const GLfloat* v1, const GLfloat* v2);
GLAPI void GLAPIENTRY glRectiv(const GLint* v1, const GLint* v2);
GLAPI void GLAPIENTRY glRectsv(const GLshort* v1, const GLshort* v2);
