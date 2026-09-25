// SimpleFPEWrapper - SimpleFPEWrapper/fpe/pointer_utils.h
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#pragma once

#include <GL/gl.h>

#define DEBUG 0

class PointerUtils {
public:
    static int type_to_bytes(GLenum type);
    static int pname_to_count(GLenum pname);
};
