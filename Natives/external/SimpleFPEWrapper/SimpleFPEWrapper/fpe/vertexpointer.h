// SimpleFPEWrapper - SimpleFPEWrapper/fpe/vertexpointer.h
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#pragma once

#include "GL/gl.h"
#include "types.h"
#include "vertexpointer_utils.h"

#ifdef __cplusplus
extern "C"
{
#endif

    GLAPI GLAPIENTRY void glVertexPointer(GLint size, GLenum type, GLsizei stride, const void* pointer);
    GLAPI GLAPIENTRY void glNormalPointer(GLenum type, GLsizei stride, const GLvoid* pointer);
    GLAPI GLAPIENTRY void glColorPointer(GLint size, GLenum type, GLsizei stride, const GLvoid* pointer);
    GLAPI GLAPIENTRY void glTexCoordPointer(GLint size, GLenum type, GLsizei stride, const GLvoid* pointer);
    GLAPI GLAPIENTRY void glIndexPointer(GLenum type, GLsizei stride, const GLvoid* ptr);

    GLAPI GLAPIENTRY void glEnableClientState(GLenum cap);
    GLAPI GLAPIENTRY void glDisableClientState(GLenum cap);

#ifdef __cplusplus
}

// The array-buffer binding is part of each legacy client-array pointer's
// state. Keep it alongside the existing pointer metadata without expanding
// vertex_pointer_array_t, which is shared with shader-generation work.
GLuint getClientArrayBufferBinding(int index);
#endif
