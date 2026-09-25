# SimpleFPEWrapper —— iOS 构建（Amethyst-iOS）
#
# 上游：https://github.com/MobileGL-Dev/SimpleFPEWrapper（LGPL-3.0）
# 本文件基于上游 CMakeLists.txt 裁剪，差异如下：
#   1. glslang / SPIRV-Cross / glm 复用本仓库已 vendored 的 MobileGlues 3rdparty
#      树（避免再复制一份 ~9000 个文件），路径由 SFPEW_MG_3RDPARTY 指定。
#   2. 去掉 googletest 与全部测试目标：iOS 交叉编译无法构建并运行可执行文件。
#   3. 去掉 tools/generate_git_commit.cmake：vendored 副本不在 git 工作树中，
#      version.h 的 __has_include 会走 "unknown" 兜底。
#   4. 不启用 LTO（上游默认 ON）：iOS 交叉编译下 LTO 需要匹配的 archiver，
#      且收益远小于多出的构建时间与失败面。
#   5. -Wl,--no-undefined 是 GNU-only，Apple 侧本来就不启用（与上游一致）。
cmake_minimum_required(VERSION 3.22.1)

project(SimpleFPEWrapper CXX)

find_package(Threads REQUIRED)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# ---------------------------------------------------------------------------
# 依赖树位置：默认指向 MobileGlues vendored 3rdparty
# ---------------------------------------------------------------------------
set(SFPEW_MG_3RDPARTY "" CACHE PATH "MobileGlues vendored 3rdparty directory")
if(NOT SFPEW_MG_3RDPARTY)
    set(SFPEW_MG_3RDPARTY "${CMAKE_CURRENT_SOURCE_DIR}/../MobileGlues/src/main/cpp/3rdparty")
endif()
set(SFPEW_GLSLANG_DIR    "${SFPEW_MG_3RDPARTY}/glslang"     CACHE PATH "glslang source tree")
set(SFPEW_SPIRVCROSS_DIR "${SFPEW_MG_3RDPARTY}/SPIRV-Cross" CACHE PATH "SPIRV-Cross source tree")
set(SFPEW_GLM_DIR        "${SFPEW_MG_3RDPARTY}/glm"         CACHE PATH "glm source tree")

foreach(_d "${SFPEW_GLSLANG_DIR}" "${SFPEW_SPIRVCROSS_DIR}" "${SFPEW_GLM_DIR}")
    if(NOT IS_DIRECTORY "${_d}")
        message(FATAL_ERROR "SFPEW: dependency tree missing: ${_d}")
    endif()
endforeach()

# ---------------------------------------------------------------------------
# Apple 编译旗标（沿用上游 APPLE 分支）
#
# -Wno-unguarded-availability{,-new}：deployment target 14.0 下 std::format 的
# 编译期拦路虎。libc++ 的 std::format 无论实参是不是浮点，模板展开都会拉进
# __format/formatter_floating_point.h，而该头的实现调 std::to_chars(float) ——
# 这个重载在新版 SDK 里标了 availability(introduced=iOS 16.3)，低于该版本即
# "unavailable"，clang 默认按 error 报：
#   error: 'to_chars' is unavailable: introduced in iOS 16.3
#   （fpe_shadergen.cpp 哪怕是 std::format<unsigned, string, string> 也照样炸）
#
# 为什么是"压诊断"而不是"把 deployment target 抬到 16.3"：
#   * 抬 target 会让 clang 生成对 to_chars 的**强**引用，iOS 14~16.2 真机上
#     dyld 找不到该符号 → 启动即崩（libc++ 是系统 dylib，随 OS 更新才有）。
#   * 保持 14.0 时，availability 机制让该引用成为**弱**引用，旧系统上解析为
#     NULL；而 SFPEW 全树唯一的浮点格式化（{:.1f}）已由
#     scripts/patch_sfpew_ios.py 改成 snprintf，运行期根本不会走到该路径。
#   两者叠加：编译得过 + 旧机不崩。
# ---------------------------------------------------------------------------
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fvisibility=default -funwind-tables -g -D_THREAD_SAFE -fPIC -stdlib=libc++ -Wno-unguarded-availability -Wno-unguarded-availability-new")
set(CMAKE_C_FLAGS   "${CMAKE_C_FLAGS}   -g -std=gnu99 -funwind-tables -O3 -fvisibility=hidden")

# ---------------------------------------------------------------------------
# glslang（裁剪构建：no HLSL、no CLI、no tests）
# ---------------------------------------------------------------------------
set(GLSLANG_TESTS OFF CACHE BOOL "" FORCE)
set(ENABLE_GLSLANG_BINARIES OFF CACHE BOOL "" FORCE)
set(ENABLE_HLSL OFF CACHE BOOL "" FORCE)
set(ENABLE_OPT OFF CACHE BOOL "" FORCE)
set(BUILD_EXTERNAL OFF CACHE BOOL "" FORCE)
# SFPEW 自身带 RTTI（display-list / matrix 路径有 dynamic_cast），并构造
# glslang::TShader 这类多态类型；glslang 默认关 RTTI 时不会发射相应 typeinfo，
# 最终 dylib 在 dlopen 时缺符号。强制打开以匹配我们的 ABI。
set(ENABLE_RTTI ON CACHE BOOL "" FORCE)
add_subdirectory("${SFPEW_GLSLANG_DIR}" "${CMAKE_BINARY_DIR}/glslang" EXCLUDE_FROM_ALL)

set(SPIRV_CROSS_CLI OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_HLSL OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_MSL OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_CPP OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_REFLECT OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_C_API OFF CACHE BOOL "" FORCE)
add_subdirectory("${SFPEW_SPIRVCROSS_DIR}" "${CMAKE_BINARY_DIR}/spirv-cross" EXCLUDE_FROM_ALL)

add_library(${CMAKE_PROJECT_NAME} SHARED
        SimpleFPEWrapper/init.cpp
        SimpleFPEWrapper/multidraw.cpp
        SimpleFPEWrapper/getter_version_strings.cpp
        SimpleFPEWrapper/fbo.cpp
        SimpleFPEWrapper/texture_binding.cpp
        SimpleFPEWrapper/texture_image.cpp
        SimpleFPEWrapper/egl_dispatch.cpp
        SimpleFPEWrapper/lookup.cpp
        SimpleFPEWrapper/ordered_passthrough.cpp

        SimpleFPEWrapper/backend/loader.cpp
        SimpleFPEWrapper/backend/capabilities.cpp

        SimpleFPEWrapper/fpe/fpe.cpp
        SimpleFPEWrapper/fpe/fpe_shadergen.cpp
        SimpleFPEWrapper/fpe/state.cpp
        SimpleFPEWrapper/fpe/ffp_state_query.cpp
        SimpleFPEWrapper/fpe/transformation.cpp
        SimpleFPEWrapper/fpe/vertexpointer.cpp
        SimpleFPEWrapper/fpe/list.cpp
        SimpleFPEWrapper/fpe/list_diagnostics.cpp
        SimpleFPEWrapper/fpe/list_capture.cpp
        SimpleFPEWrapper/fpe/draw_now.cpp
        SimpleFPEWrapper/fpe/attribstack.cpp
        SimpleFPEWrapper/fpe/pixelops.cpp
        SimpleFPEWrapper/fpe/linestipple.cpp
        SimpleFPEWrapper/fpe/imaging.cpp
        SimpleFPEWrapper/fpe/selection.cpp
        SimpleFPEWrapper/fpe/evaluators.cpp
        SimpleFPEWrapper/shader/translator.cpp
        SimpleFPEWrapper/shader/shaderobjects.cpp
        SimpleFPEWrapper/shader/userprogram.cpp
        SimpleFPEWrapper/shader/vertexattrib.cpp
        SimpleFPEWrapper/fpe/pointer_utils.cpp
        SimpleFPEWrapper/fpe/drawing1x.cpp
        SimpleFPEWrapper/fpe/vertexpointer_utils.cpp
        SimpleFPEWrapper/fpe/drawstate1x.cpp
        SimpleFPEWrapper/fpe/glstate.cpp
        SimpleFPEWrapper/fpe/vertexpointerarray.cpp
)

target_include_directories(${CMAKE_PROJECT_NAME} PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_include_directories(${CMAKE_PROJECT_NAME} SYSTEM PUBLIC
        ${SFPEW_GLM_DIR}
        ${CMAKE_CURRENT_SOURCE_DIR}/3rdparty/xxhash)
target_include_directories(${CMAKE_PROJECT_NAME} SYSTEM PRIVATE
        "${SFPEW_GLSLANG_DIR}"
        "${SFPEW_SPIRVCROSS_DIR}")

target_link_libraries(${CMAKE_PROJECT_NAME} PRIVATE
        Threads::Threads
        glslang glslang-default-resource-limits SPIRV spirv-cross-glsl spirv-cross-core)
