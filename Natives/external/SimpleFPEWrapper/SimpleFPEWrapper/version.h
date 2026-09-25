// SimpleFPEWrapper - SimpleFPEWrapper/version.h
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#pragma once
#include <string>

// The wrapper's own version, following what MobileGL does: calendar
// versioning, where the major is the year past 2000 and the minor is the
// month, so the number says when a build was made rather than how many
// features it accumulated. That suits a compatibility layer, which is dated
// by the drivers and games it was last matched against, not by a feature
// roadmap.
//
// The version alone cannot identify a build - several are made in the same
// month, and the interesting ones are usually a day apart - so everywhere it
// is reported the git commit goes with it. That pairing is the whole point:
// the version tells a user which release they are on, the commit tells a
// maintainer which code that was.

// Generated at build time (tools/generate_git_commit.cmake), not baked in
// only at cmake-configure time, so an ordinary rebuild picks up a commit
// made since the last configure. __has_include rather than a hard #include:
// this header still needs to compile standalone outside CMake's generated
// include path (a tarball build, an IDE indexer that never ran the custom
// target).
#if __has_include("sfpew_git_commit.h")
#include "sfpew_git_commit.h"
#endif
#ifndef SFPEW_GIT_COMMIT
// Only a build outside git (or before the generating custom target has run
// once) lands here.
#define SFPEW_GIT_COMMIT "unknown"
#endif

// What the suffix means, kept separate from the suffix text so a "-rc1" and
// a "-dev" can be told apart without parsing it.
enum class sfpew_version_type_t {
    Release,
    Unstable,
    Development,
};

// Zero-padding widths for each part, so a month prints as "08" rather than
// "8". A width of 0 prints the number as it is; autoPatch leaves the patch
// part out entirely while it is still 0.
struct sfpew_version_format_t {
    int majorWidth = 0;
    int minorWidth = 0;
    int patchWidth = 0;
    bool useSuffix = true;
    bool autoPatch = false;
};

struct sfpew_version_t {
    int major;
    int minor;
    int patch;
    const char* suffix; // nullptr when there is none
    sfpew_version_type_t type;

    std::string format(const sfpew_version_format_t& fmt) const {
        const auto pad = [](int value, int width) {
            std::string digits = std::to_string(value);
            if (width <= 0 || (int)digits.size() == width) return digits;
            // A number wider than its field keeps its low digits: the year
            // rolls (2100 -> "00") rather than widening every version string
            // that was formatted to line up.
            if ((int)digits.size() > width) return digits.substr(digits.size() - (size_t)width);
            return std::string((size_t)(width - (int)digits.size()), '0') + digits;
        };

        std::string out = pad(major, fmt.majorWidth) + "." + pad(minor, fmt.minorWidth);
        if (!fmt.autoPatch || patch != 0) out += "." + pad(patch, fmt.patchWidth);
        if (fmt.useSuffix && suffix != nullptr) out += suffix;
        return out;
    }
};

inline constexpr const char* kSfpewProjectName = "SFPEW";
inline constexpr const char* kSfpewProjectFullName = "Simple FPE Wrapper";
inline constexpr sfpew_version_t kSfpewVersion = {26, 8, 0, "-dev",
                                                  sfpew_version_type_t::Development};
// "26.08-dev": both parts padded to two digits, the patch hidden while it is
// 0, the suffix kept.
inline constexpr sfpew_version_format_t kSfpewVersionFormat = {2, 2, 0, true, true};

inline const char* sfpewVersionTypeName(sfpew_version_type_t type) {
    switch (type) {
    case sfpew_version_type_t::Release: return "release";
    case sfpew_version_type_t::Unstable: return "unstable";
    case sfpew_version_type_t::Development: return "development";
    }
    return "unknown";
}

// "26.08-dev". Formatted once; the pointer stays valid for the process.
inline const char* sfpewVersionString() {
    static const std::string cached = kSfpewVersion.format(kSfpewVersionFormat);
    return cached.c_str();
}

// "26.08-dev, GIT@<commit>" - what goes into GL_VERSION, where a user
// reading a crash report needs both halves.
inline const char* sfpewVersionAndCommit() {
    static const std::string cached =
        std::string(sfpewVersionString()) + ", GIT@" + SFPEW_GIT_COMMIT;
    return cached.c_str();
}
