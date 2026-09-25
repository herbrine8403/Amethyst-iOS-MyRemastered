// SimpleFPEWrapper - SimpleFPEWrapper/egl_dispatch.h
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#pragma once

#include <EGL/egl.h>

#include <vector>

enum class SfpewContextDispatchMode {
    Wrapped,
    BackendDirect,
};

enum class SfpewEglContextRequest {
    Wrapped,
    CoreOnly,
    Compatibility,
};

struct SfpewEglContextAttributes {
    SfpewEglContextRequest request = SfpewEglContextRequest::Wrapped;
    std::vector<EGLint> core_fallback;
};

SfpewEglContextAttributes sfpewClassifyEglContextAttributes(const EGLint* attribs, bool desktop_api);
bool sfpewCanCreateNativeCompatibilityContext(EGLDisplay dpy, EGLConfig config, const EGLint* attribs);

void sfpewRegisterContextDispatch(EGLContext context, SfpewContextDispatchMode mode);
void sfpewNoteDispatchCurrentContext(EGLContext context);
void sfpewForgetContextDispatch(EGLContext context);
SfpewContextDispatchMode sfpewCurrentContextDispatch();
