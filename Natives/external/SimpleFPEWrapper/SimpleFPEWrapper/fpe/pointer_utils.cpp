// SimpleFPEWrapper - SimpleFPEWrapper/fpe/pointer_utils.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "pointer_utils.h"
#include <GL/gl.h>

#define DEBUG 0

int PointerUtils::type_to_bytes(GLenum type) {
    switch (type) {
    case GL_BYTE:
    case GL_UNSIGNED_BYTE:
        return 1;
    case GL_SHORT:
    case GL_UNSIGNED_SHORT:
    case GL_2_BYTES:
    case GL_HALF_FLOAT:
        return 2;
    case GL_3_BYTES:
        return 3;
    case GL_INT:
    case GL_UNSIGNED_INT:
    case GL_FLOAT:
    case GL_4_BYTES:
    case GL_FIXED:
        return 4;
    case GL_DOUBLE:
    case GL_INT64_NV:
    case GL_UNSIGNED_INT64_NV:
        return 8;
    default:
        // LOG_E("Unsupported OpenGL type: %s", glEnumToString(type))
        return 0;
    }
}

int PointerUtils::pname_to_count(GLenum pname) {
    switch (pname) {
    case GL_FOG_MODE: // fog
    case GL_FOG_INDEX:
    case GL_FOG_COORD_SRC:
    case GL_FOG_DENSITY:
    case GL_FOG_START:
    case GL_FOG_END:
    case GL_SPOT_CUTOFF: // light
    case GL_SPOT_EXPONENT:
    case GL_CONSTANT_ATTENUATION:
    case GL_LINEAR_ATTENUATION:
    case GL_QUADRATIC_ATTENUATION:
    case GL_LIGHT_MODEL_COLOR_CONTROL: // lightModel
    case GL_LIGHT_MODEL_LOCAL_VIEWER:
    case GL_LIGHT_MODEL_TWO_SIDE:
        return 1;
    case GL_SPOT_DIRECTION: // light
        return 3;
    case GL_FOG_COLOR: // fog
    case GL_AMBIENT:   // light
    case GL_DIFFUSE:
    case GL_SPECULAR:
    case GL_POSITION:
    case GL_LIGHT_MODEL_AMBIENT: // lightModel
        return 4;
    default:
        // LOG_E("unsupported OpenGL pname: %s", glEnumToString(pname))
        return 0;
    }
}
