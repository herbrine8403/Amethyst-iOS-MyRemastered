// SimpleFPEWrapper - SimpleFPEWrapper/log.h
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#pragma once

// Unified diagnostics sink: logcat on Android, stderr elsewhere. Messages
// pass printf-style format strings WITHOUT a trailing newline.

#if defined(__ANDROID__)
#include <android/log.h>
#define SFPEW_LOG_TAG "SFPEW"
#define SFPEW_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, SFPEW_LOG_TAG, __VA_ARGS__)
#define SFPEW_LOGW(...) __android_log_print(ANDROID_LOG_WARN, SFPEW_LOG_TAG, __VA_ARGS__)
#define SFPEW_LOGI(...) __android_log_print(ANDROID_LOG_INFO, SFPEW_LOG_TAG, __VA_ARGS__)
#else
#include <cstdio>
#define SFPEW_LOG_IMPL(level, ...)                                                                                     \
    do {                                                                                                               \
        std::fprintf(stderr, "SFPEW/" level ": ");                                                                     \
        std::fprintf(stderr, __VA_ARGS__);                                                                             \
        std::fputc('\n', stderr);                                                                                      \
    } while (0)
#define SFPEW_LOGE(...) SFPEW_LOG_IMPL("E", __VA_ARGS__)
#define SFPEW_LOGW(...) SFPEW_LOG_IMPL("W", __VA_ARGS__)
#define SFPEW_LOGI(...) SFPEW_LOG_IMPL("I", __VA_ARGS__)
#endif
