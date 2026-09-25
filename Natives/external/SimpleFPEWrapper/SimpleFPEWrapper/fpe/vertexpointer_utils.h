// SimpleFPEWrapper - SimpleFPEWrapper/fpe/vertexpointer_utils.h
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#pragma once

#include <GL/gl.h>

int vp2idx(GLenum vp);
uint32_t vp_mask(GLenum vp);
GLenum idx2vp(int idx);
