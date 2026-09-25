// SimpleFPEWrapper - SimpleFPEWrapper/fpe/transformation.h
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#pragma once

#include "GL/gl.h"
#include <glm/glm.hpp>

int matrix_idx(GLenum matrix_mode);

void print_matrix(const glm::mat4& mat);

#ifdef __cplusplus
extern "C"
{
#endif

    GLAPI GLAPIENTRY void glMatrixMode(GLenum mode);
    GLAPI GLAPIENTRY void glLoadIdentity();
    GLAPI GLAPIENTRY void glOrtho(GLdouble left, GLdouble right, GLdouble bottom, GLdouble top, GLdouble near_val,
                                  GLdouble far_val);
    GLAPI GLAPIENTRY void glOrthof(GLfloat left, GLfloat right, GLfloat bottom, GLfloat top, GLfloat near_val,
                                   GLfloat far_val);
    GLAPI GLAPIENTRY void glFrustum(GLdouble left, GLdouble right, GLdouble bottom, GLdouble top, GLdouble near_val,
                                    GLdouble far_val);
    GLAPI GLAPIENTRY void glFrustumf(GLfloat left, GLfloat right, GLfloat bottom, GLfloat top, GLfloat near_val,
                                     GLfloat far_val);
    GLAPI GLAPIENTRY void glScalef(GLfloat x, GLfloat y, GLfloat z);
    GLAPI GLAPIENTRY void glTranslatef(GLfloat x, GLfloat y, GLfloat z);
    GLAPI GLAPIENTRY void glRotatef(GLfloat angle, GLfloat x, GLfloat y, GLfloat z);

    GLAPI GLAPIENTRY void glLoadMatrixd(const GLdouble* m);
    GLAPI GLAPIENTRY void glLoadMatrixf(const GLfloat* m);
    GLAPI GLAPIENTRY void glMultMatrixd(const GLdouble* m);
    GLAPI GLAPIENTRY void glMultMatrixf(const GLfloat* m);
    GLAPI GLAPIENTRY void glLoadTransposeMatrixd(const GLdouble* m);
    GLAPI GLAPIENTRY void glLoadTransposeMatrixf(const GLfloat* m);
    GLAPI GLAPIENTRY void glMultTransposeMatrixd(const GLdouble* m);
    GLAPI GLAPIENTRY void glMultTransposeMatrixf(const GLfloat* m);

    GLAPI GLAPIENTRY void glRotated(GLdouble angle, GLdouble x, GLdouble y, GLdouble z);
    GLAPI GLAPIENTRY void glScaled(GLdouble x, GLdouble y, GLdouble z);
    GLAPI GLAPIENTRY void glTranslated(GLdouble x, GLdouble y, GLdouble z);

    GLAPI GLAPIENTRY void glPushMatrix(void);
    GLAPI GLAPIENTRY void glPopMatrix(void);

#ifdef __cplusplus
}
#endif
