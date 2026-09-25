// SimpleFPEWrapper - SimpleFPEWrapper/fpe/state.h
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#pragma once

#include <GL/gl.h>

#include "types.h"

#ifdef __cplusplus
extern "C"
{
#endif

    GLAPI GLAPIENTRY void glEnable(GLenum cap);
    GLAPI GLAPIENTRY void glDisable(GLenum cap);
    GLAPI GLAPIENTRY void glClientActiveTexture(GLenum texture);
    GLAPI void GLAPIENTRY glAlphaFunc(GLenum func, GLclampf ref);
    GLAPI void GLAPIENTRY glLogicOp(GLenum opcode);
    GLAPI void GLAPIENTRY glFogf(GLenum pname, GLfloat param);
    GLAPI void GLAPIENTRY glFogi(GLenum pname, GLint param);
    GLAPI void GLAPIENTRY glFogfv(GLenum pname, const GLfloat* params);
    GLAPI void GLAPIENTRY glFogiv(GLenum pname, const GLint* params);

    GLAPI void GLAPIENTRY glShadeModel(GLenum mode);
    GLAPI void GLAPIENTRY glLightf(GLenum light, GLenum pname, GLfloat param);
    GLAPI void GLAPIENTRY glLighti(GLenum light, GLenum pname, GLint param);
    GLAPI void GLAPIENTRY glLightfv(GLenum light, GLenum pname, const GLfloat* params);
    GLAPI void GLAPIENTRY glLightiv(GLenum light, GLenum pname, const GLint* params);
    GLAPI void GLAPIENTRY glLightModelf(GLenum pname, GLfloat param);
    GLAPI void GLAPIENTRY glLightModeli(GLenum pname, GLint param);
    GLAPI void GLAPIENTRY glLightModelfv(GLenum pname, const GLfloat* params);
    GLAPI void GLAPIENTRY glLightModeliv(GLenum pname, const GLint* params);
    GLAPI void GLAPIENTRY glColorMaterial(GLenum face, GLenum mode);
    GLAPI void GLAPIENTRY glMaterialf(GLenum face, GLenum pname, GLfloat param);
    GLAPI void GLAPIENTRY glMateriali(GLenum face, GLenum pname, GLint param);
    GLAPI void GLAPIENTRY glMaterialfv(GLenum face, GLenum pname, const GLfloat* params);
    GLAPI void GLAPIENTRY glMaterialiv(GLenum face, GLenum pname, const GLint* params);
    GLAPI void GLAPIENTRY glTexEnvf(GLenum target, GLenum pname, GLfloat param);
    GLAPI void GLAPIENTRY glTexEnvi(GLenum target, GLenum pname, GLint param);
    GLAPI void GLAPIENTRY glTexEnvfv(GLenum target, GLenum pname, const GLfloat* params);
    GLAPI void GLAPIENTRY glTexEnviv(GLenum target, GLenum pname, const GLint* params);
    GLAPI void GLAPIENTRY glColor4f(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha);

#ifdef __cplusplus
}

// GL_POINT_SIZE_MAX starts at the implementation's supported maximum. It is
// queried lazily because glstate_t can be constructed before a context exists.
void sfpewInitializePointSizeMax(glstate_t& state);
#endif
