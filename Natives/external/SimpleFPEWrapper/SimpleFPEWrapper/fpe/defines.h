// SimpleFPEWrapper - SimpleFPEWrapper/fpe/defines.h
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#pragma once

#define MAX_TEX 16
#define MAX_LIGHTS 8

// Matrix stack depth caps (GL 2.1 spec minimums: modelview >= 32, others
// >= 2; we advertise these via glGet in plans/03 task 3.2). The stacks are
// std::vector, so the caps exist to produce GL_STACK_OVERFLOW instead of
// unbounded growth when push/pop pairs are unbalanced.
#define MAX_MODELVIEW_STACK_DEPTH 64
#define MAX_PROJECTION_STACK_DEPTH 16
#define MAX_TEXTURE_STACK_DEPTH 16
#define MAX_COLOR_STACK_DEPTH 16
