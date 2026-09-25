// SimpleFPEWrapper - SimpleFPEWrapper/egl_dispatch.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "egl_dispatch.h"

#include "init.h"

#include <mutex>
#include <thread>
#include <unordered_map>

namespace {

constexpr size_t kMaxContextAttributes = 256;

struct ParsedAttributes {
    bool valid = false;
    bool has_major_version = false;
    EGLint major_version = 1;
    bool has_minor_version = false;
    EGLint minor_version = 0;
    bool has_profile_mask = false;
    EGLint profile_mask = 0;
    bool has_forward_compatible = false;
    EGLint forward_compatible = EGL_FALSE;
    bool has_context_flags = false;
    EGLint context_flags = 0;
    std::vector<EGLint> values;
};

ParsedAttributes parseAttributes(const EGLint* attribs) {
    ParsedAttributes parsed;
    if (attribs == nullptr) {
        parsed.valid = true;
        return parsed;
    }

    for (size_t i = 0; i < kMaxContextAttributes; ++i) {
        const EGLint key = attribs[i];
        if (key == EGL_NONE) {
            parsed.values.push_back(EGL_NONE);
            parsed.valid = true;
            return parsed;
        }
        if (++i == kMaxContextAttributes) return parsed;

        const EGLint value = attribs[i];
        parsed.values.push_back(key);
        parsed.values.push_back(value);
        switch (key) {
        case EGL_CONTEXT_MAJOR_VERSION:
            if (parsed.has_major_version) return parsed;
            parsed.has_major_version = true;
            parsed.major_version = value;
            break;
        case EGL_CONTEXT_MINOR_VERSION:
            if (parsed.has_minor_version) return parsed;
            parsed.has_minor_version = true;
            parsed.minor_version = value;
            break;
        case EGL_CONTEXT_OPENGL_PROFILE_MASK:
            if (parsed.has_profile_mask) return parsed;
            parsed.has_profile_mask = true;
            parsed.profile_mask = value;
            break;
        case EGL_CONTEXT_OPENGL_FORWARD_COMPATIBLE:
            if (parsed.has_forward_compatible) return parsed;
            parsed.has_forward_compatible = true;
            parsed.forward_compatible = value;
            break;
        case EGL_CONTEXT_FLAGS_KHR:
            if (parsed.has_context_flags) return parsed;
            parsed.has_context_flags = true;
            parsed.context_flags = value;
            break;
        default:
            break;
        }
    }
    return parsed;
}

bool isForwardCompatible(const ParsedAttributes& parsed) {
    return (parsed.has_forward_compatible && parsed.forward_compatible != EGL_FALSE) ||
           (parsed.has_context_flags &&
            (parsed.context_flags & EGL_CONTEXT_OPENGL_FORWARD_COMPATIBLE_BIT_KHR) != 0);
}

bool profileCapable(const ParsedAttributes& parsed) {
    return parsed.major_version > 3 ||
           (parsed.major_version == 3 && parsed.minor_version >= 2);
}

std::vector<EGLint> coreFallback(const ParsedAttributes& parsed) {
    const bool needs_profile_mask = !parsed.has_profile_mask;
    const bool needs_profile_version = !profileCapable(parsed);
    std::vector<EGLint> result;
    result.reserve(parsed.values.size() + 6);
    for (size_t i = 0; i + 1 < parsed.values.size(); i += 2) {
        const EGLint key = parsed.values[i];
        if (key == EGL_NONE) break;
        EGLint value = parsed.values[i + 1];
        if (key == EGL_CONTEXT_MAJOR_VERSION && needs_profile_version) {
            value = 3;
        } else if (key == EGL_CONTEXT_MINOR_VERSION && needs_profile_version) {
            value = 2;
        } else if (key == EGL_CONTEXT_OPENGL_PROFILE_MASK) {
            value = EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT;
        } else if (key == EGL_CONTEXT_OPENGL_FORWARD_COMPATIBLE) {
            value = EGL_FALSE;
        } else if (key == EGL_CONTEXT_FLAGS_KHR) {
            value &= ~EGL_CONTEXT_OPENGL_FORWARD_COMPATIBLE_BIT_KHR;
        }
        result.push_back(key);
        result.push_back(value);
    }
    if (needs_profile_version && !parsed.has_major_version) {
        result.push_back(EGL_CONTEXT_MAJOR_VERSION);
        result.push_back(3);
    }
    if (needs_profile_version && !parsed.has_minor_version) {
        result.push_back(EGL_CONTEXT_MINOR_VERSION);
        result.push_back(2);
    }
    if (needs_profile_mask) {
        result.push_back(EGL_CONTEXT_OPENGL_PROFILE_MASK);
        result.push_back(EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT);
    }
    result.push_back(EGL_NONE);
    return result;
}

struct ContextEntry {
    SfpewContextDispatchMode mode = SfpewContextDispatchMode::Wrapped;
    bool destroy_pending = false;
};

std::mutex g_context_dispatch_mutex;
std::unordered_map<EGLContext, ContextEntry> g_context_dispatch;
thread_local EGLContext g_current_context = EGL_NO_CONTEXT;

struct EglThreadRelease {
    ~EglThreadRelease() {
        if (g_eglFuncs.eglReleaseThread != nullptr) g_eglFuncs.eglReleaseThread();
    }
};

void noteCurrentContext(EGLContext context) {
    const EGLContext previous = g_current_context;
    g_current_context = context;
    if (previous == context) return;

    std::lock_guard lock(g_context_dispatch_mutex);
    const auto found = g_context_dispatch.find(previous);
    if (found != g_context_dispatch.end() && found->second.destroy_pending)
        g_context_dispatch.erase(found);
}

} // namespace

SfpewEglContextAttributes sfpewClassifyEglContextAttributes(const EGLint* attribs, bool desktop_api) {
    SfpewEglContextAttributes result;
    const ParsedAttributes parsed = parseAttributes(attribs);
    if (!desktop_api || !parsed.valid || isForwardCompatible(parsed)) return result;

    if (!parsed.has_profile_mask) {
        if (profileCapable(parsed)) {
            result.request = SfpewEglContextRequest::CoreOnly;
        } else {
            result.request = SfpewEglContextRequest::Compatibility;
            result.core_fallback = coreFallback(parsed);
        }
        return result;
    }

    if (parsed.profile_mask == EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT) {
        result.request = SfpewEglContextRequest::CoreOnly;
    } else if (parsed.profile_mask == EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT) {
        result.request = SfpewEglContextRequest::Compatibility;
        result.core_fallback = coreFallback(parsed);
    }
    return result;
}

bool sfpewCanCreateNativeCompatibilityContext(EGLDisplay dpy, EGLConfig config, const EGLint* attribs) {
    if (g_eglFuncs.eglBindAPI == nullptr || g_eglFuncs.eglCreateContext == nullptr ||
        g_eglFuncs.eglDestroyContext == nullptr) {
        return false;
    }

    bool supported = false;
    try {
        std::thread probe([&] {
            EglThreadRelease release;
            if (g_eglFuncs.eglBindAPI(EGL_OPENGL_API) != EGL_TRUE) return;
            EGLContext context = g_eglFuncs.eglCreateContext(dpy, config, EGL_NO_CONTEXT, attribs);
            if (context == EGL_NO_CONTEXT) return;
            supported = g_eglFuncs.eglDestroyContext(dpy, context) == EGL_TRUE;
        });
        probe.join();
    } catch (...) {
        return false;
    }
    return supported;
}

void sfpewRegisterContextDispatch(EGLContext context, SfpewContextDispatchMode mode) {
    if (context == EGL_NO_CONTEXT) return;
    std::lock_guard lock(g_context_dispatch_mutex);
    g_context_dispatch[context] = {mode, false};
}

void sfpewNoteDispatchCurrentContext(EGLContext context) {
    noteCurrentContext(context);
}

void sfpewForgetContextDispatch(EGLContext context) {
    if (context == EGL_NO_CONTEXT) return;

    EGLContext current = g_current_context;
    if (g_eglFuncs.eglGetCurrentContext != nullptr) current = g_eglFuncs.eglGetCurrentContext();
    g_current_context = current;

    std::lock_guard lock(g_context_dispatch_mutex);
    const auto found = g_context_dispatch.find(context);
    if (found == g_context_dispatch.end()) return;
    if (current == context)
        found->second.destroy_pending = true;
    else
        g_context_dispatch.erase(found);
}

SfpewContextDispatchMode sfpewCurrentContextDispatch() {
    EGLContext current = g_current_context;
    if (g_eglFuncs.eglGetCurrentContext != nullptr) current = g_eglFuncs.eglGetCurrentContext();
    noteCurrentContext(current);
    if (current == EGL_NO_CONTEXT) return SfpewContextDispatchMode::Wrapped;

    std::lock_guard lock(g_context_dispatch_mutex);
    const auto found = g_context_dispatch.find(current);
    if (found == g_context_dispatch.end()) return SfpewContextDispatchMode::Wrapped;
    return found->second.mode;
}
