#!/usr/bin/env python3
# SimpleFPEWrapper —— iOS 构建适配补丁
#
# 与 Natives/patch_mobilegl_ios.py 同款约定：
#   * 幂等   —— 先 grep 判据，已修补则整条跳过；重复运行不叠加、不报错
#   * 校验   —— 锚点缺失 / 多处命中都响亮失败，绝不静默打歪
#   * 自愈   —— 上游若自行修复（判据命中新形态）则自动跳过
#
# 下面两处都是 AppleClang 15（Xcode 15.4 / iPhoneOS17.5.sdk）在
# CMAKE_OSX_DEPLOYMENT_TARGET=14.0 下才暴露的问题，Linux/GCC 与 Android NDK
# 都不触发，所以上游源码里没有对应处理。
#
# ---------------------------------------------------------------------------
# 1) fpe/types.h —— glstate_t 的默认构造函数被隐式删除
#
#   fpe.cpp:114  `static glstate_t no_context_state;`
#   fpe.cpp:152  `slot = std::make_unique<glstate_t>();`
#
#   fixed_function_draw_size_t 里的匿名 union 含一个带 NSDMI 的匿名 struct
#   （vertex_size = 0 … texcoord_size[MAX_TEX] = {0}），[class.default.ctor]/2
#   规定：非 union 类若含"默认构造函数非平凡"的 variant member，且该匿名 union
#   内没有任何 variant member 带默认成员初始化器，则默认构造函数被删除。
#   clang 原文：
#     "default constructor of 'fixed_function_draw_size_t' is implicitly
#      deleted because variant field '' has a non-trivial default constructor"
#
#   修法：给 fixed_function_draw_size_t 一个显式默认构造函数，逐一初始化匿名
#   struct 的各字段（匿名 union 的成员即外围类的成员，可直接进 mem-initializer
#   列表）。默认构造函数由用户显式提供后，"隐式删除"不再适用；且活跃成员仍是
#   那个匿名 struct，与上游各字段 NSDMI(= 0) 的原意完全一致。
#
#   注：不要改用"给 data[] 加 = {}"这种看起来更小的改法 —— 那会触发
#   "at most one variant member may have a default member initializer"
#   （GCC 实测报 "multiple fields in union initialized"，因为带 NSDMI 的匿名
#   struct 也被算作已初始化）。显式构造函数不依赖这条晦涩规则，两个编译器都过。
#
# ---------------------------------------------------------------------------
# 2) fpe/fpe_shadergen.cpp —— std::format 的浮点格式化
#
#   libc++ 的 __formatter_floating_point 内部调 std::to_chars(float)，而该重载
#   在 SDK 里标了 availability(introduced=iOS 16.3)，deployment target 14.0 下
#   "unavailable"：
#     "error: 'to_chars' is unavailable: introduced in iOS 16.3"
#
#   重要：光把浮点格式说明符换掉**不够**。std::format 的模板展开无条件拉进
#   formatter_floating_point.h —— 实测 fpe_shadergen.cpp 里一句
#   std::format<unsigned, string, string>（整数+字符串，毫无浮点）照样触发
#   同一个 error。所以编译期必须靠 CMakeLists 里的
#   -Wno-unguarded-availability{,-new} 压诊断（见该文件注释）。
#
#   本补丁做的是**运行期保险**：全树唯一的浮点格式化是 `{:.1f}`（env.rgb_scale
#   / env.alpha_scale），改成 snprintf 预转字符串再交给 `{}`。这样即使某个
#   编译器把弱引用解析成了真调用，也绝不会落进 to_chars 浮点路径 —— 而弱
#   引用（deployment target 保持 14.0 的自然结果）在 iOS 14~16.2 上解析为
#   NULL，一旦被调用就是 NULL 解引用。两层保险缺一不可。
#   <cstdio> 已在文件里 include，且 %.1f 与原 `{:.1f}` 的输出逐字符一致。

import sys
from pathlib import Path

MARKER = "Amethyst iOS"


def fail(msg: str) -> "NoReturn":  # type: ignore[valid-type]
    print(f"patch_sfpew_ios: ERROR: {msg}", file=sys.stderr)
    raise SystemExit(1)


def replace_once(path: Path, old: str, new: str, what: str) -> None:
    text = path.read_text(encoding="utf-8")
    n = text.count(old)
    if n == 0:
        fail(f"{what}: anchor not found in {path} -- SFPEW source layout changed?")
    if n > 1:
        fail(f"{what}: anchor matched {n} times in {path} -- refusing to patch blindly")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"patch_sfpew_ios: {what}: PATCHED ({path.name})")


def main() -> None:
    if len(sys.argv) != 2:
        fail(f"usage: {sys.argv[0]} <SimpleFPEWrapper source dir>")
    root = Path(sys.argv[1])
    if not root.is_dir():
        fail(f"SFPEW source dir not found: {root}")

    # ---------------------------------------------------------------- 1) types.h
    types_h = root / "SimpleFPEWrapper" / "fpe" / "types.h"
    if not types_h.is_file():
        fail(f"missing {types_h}")
    t = types_h.read_text(encoding="utf-8")
    if "fixed_function_draw_size_t()\n" in t:
        print("patch_sfpew_ios: glstate_t default ctor: already patched -- skip")
    else:
        replace_once(
            types_h,
            "        GLint data[VERTEX_POINTER_COUNT];\n    };\n};",
            "        GLint data[VERTEX_POINTER_COUNT];\n    };\n"
            "    // " + MARKER + ": 见 Natives/patch_sfpew_ios.py —— 匿名 union 内含\n"
            "    // 带 NSDMI 的匿名 struct，AppleClang 按 [class.default.ctor]/2 把默认\n"
            "    // 构造函数判为 deleted（fpe.cpp 的 no_context_state / make_unique 会炸）。\n"
            "    fixed_function_draw_size_t()\n"
            "        : vertex_size(0), normal_size(0), color_size(0), index_size(0), edge_size(0),\n"
            "          fog_size(0), secondary_color_size(0), texcoord_size{} {}\n};",
            "glstate_t default ctor",
        )

    # ------------------------------------------------------- 2) fpe_shadergen.cpp
    shadergen = root / "SimpleFPEWrapper" / "fpe" / "fpe_shadergen.cpp"
    if not shadergen.is_file():
        fail(f"missing {shadergen}")
    s = shadergen.read_text(encoding="utf-8")
    if "sfpew_ios_format_glfloat" in s:
        print("patch_sfpew_ios: std::format float: already patched -- skip")
        return

    helper = '''
// {marker}: std::format 的浮点格式化在 libc++ 内部依赖 std::to_chars(float)，
// 而该重载在 SDK 里标了 introduced=iOS 16.3，deployment target 14.0 下不可用。
// 这里先用 snprintf 把 GLfloat 转成字符串，避免实例化那个 formatter。
static std::string sfpew_ios_format_glfloat(GLfloat v) {{
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%.1f", static_cast<double>(v));
    return std::string(buf);
}}
'''.format(marker=MARKER)

    replace_once(
        shadergen,
        '#include "../init.h"\n',
        '#include "../init.h"\n' + helper,
        "std::format float (helper insertion)",
    )

    replace_once(
        shadergen,
        '            fs += std::format("    color = clamp(vec4(({}) * {:.1f}, ({}) * {:.1f}), 0.0, 1.0);\\n",\n'
        "                              rgb, env.rgb_scale, alpha, env.alpha_scale);",
        '            fs += std::format("    color = clamp(vec4(({}) * {}, ({}) * {}), 0.0, 1.0);\\n",\n'
        "                              rgb, sfpew_ios_format_glfloat(env.rgb_scale), alpha,\n"
        "                              sfpew_ios_format_glfloat(env.alpha_scale));",
        "std::format float (call site)",
    )


if __name__ == "__main__":
    main()
