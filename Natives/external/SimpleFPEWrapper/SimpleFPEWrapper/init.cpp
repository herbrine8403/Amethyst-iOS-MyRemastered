// SimpleFPEWrapper - SimpleFPEWrapper/init.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "init.h"
#include "fpe/fpe.hpp"
#include "log.h"
#include "version.h"

#include <cstdlib>

SFPEW::External::EGLFunctionsTable g_eglFuncs;
SFPEW::External::BackendGLFunctionsTable g_glFuncs;

namespace {

// Loading the backend at dlopen time ran inside a static constructor; a
// missing libEGL threw from it and terminated the host process before it
// could even report an error. Resolve the tables on first use instead and
// keep every failure inside the library boundary.
bool InitBackend() noexcept {
    try {
        std::string eglLibName;
        const char* envEglLib = std::getenv("SFPEW_EGL");
        eglLibName = envEglLib ? envEglLib : "libEGL.so";

        if (!SFPEW::Utils::BackendLoader::AcquireEGLFunctions(g_eglFuncs, eglLibName) ||
            g_eglFuncs.eglGetProcAddress == nullptr) {
            SFPEW_LOGE("failed to acquire EGL functions from '%s'", eglLibName.c_str());
            return false;
        }

        if (!SFPEW::Utils::BackendLoader::AcquireBackendGLFunctions(g_glFuncs, g_eglFuncs.eglGetProcAddress) ||
            g_glFuncs.glGetString == nullptr) {
            SFPEW_LOGE("failed to acquire backend GL functions");
            return false;
        } // FIXME: actually we should acquire gl functions after egl initialization

        // One line identifying the build, at the moment the wrapper first
        // becomes operational: every on-device report starts with "which
        // commit is this", and the version alone cannot answer that.
        SFPEW_LOGI("%s %s (%s build) initialized, commit %s, built %s", kSfpewProjectFullName,
                   sfpewVersionString(), sfpewVersionTypeName(kSfpewVersion.type),
                   SFPEW_GIT_COMMIT, __DATE__ " " __TIME__);

        return true;
    } catch (...) {
        // Never let an exception cross the extern "C" surface above us.
        SFPEW_LOGE("backend initialization threw; wrapper disabled");
        return false;
    }
}

} // namespace

bool sfpewEnsureBackend() noexcept {
    // Magic-static: thread-safe, runs once; a failed attempt stays failed
    // and every caller degrades to a no-op instead of terminating.
    static const bool ok = InitBackend();
    return ok;
}
