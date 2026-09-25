#!/usr/bin/env python3
# SimpleFPEWrapper —— iOS 构建适配补丁
#
# 与 Natives/patch_mobilegl_ios.py 同款约定：
#   * 幂等   —— 先 grep 判据，已修补则整条跳过；重复运行不叠加、不报错
#   * 校验   —— 锚点缺失 / 多处命中都响亮失败，绝不静默打歪
#   * 自愈   —— 上游若自行修复（判据命中新形态）则自动跳过
#
# 下面几处都是 AppleClang 15（Xcode 15.4 / iPhoneOS17.5.sdk）在
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
# 2) fpe/fpe_shadergen.cpp —— std::format 的浮点格式化（运行期保险）
#
#   libc++ 的 __formatter_floating_point 内部调 std::to_chars(float)，而该重载
#   在 SDK 里标了 availability(introduced=iOS 16.3)。全树唯一的浮点格式化是
#   `{:.1f}`（env.rgb_scale / env.alpha_scale），先用 snprintf 预转字符串再交给
#   `{}`。<cstdio> 已在文件里 include，且 %.1f 与原 `{:.1f}` 的输出逐字符一致。
#
# ---------------------------------------------------------------------------
# 3) std::format 整体替换（编译期根治，本补丁的关键改动）
#
#   光做 2) 是不够的：std::format 的模板展开**无条件**拉进
#   formatter_floating_point.h —— 实测 fpe_shadergen.cpp 里一句
#   std::format<unsigned, string, string>（整数+字符串，毫无浮点）照样触发
#     error: 'to_chars' is unavailable: introduced in iOS 16.3
#   且 -Wno-unguarded-availability{,-new} 压不住它（那两个旗标只管 warn 级，
#   availability "unavailable" 是 err 级）—— CI 实测已证伪。
#
#   所以这里把 std::format 整个换成自研的 fpefmt::format（写入
#   fpe/fpe_format_compat.h，纯 ostringstream 实现，不碰 <format> / to_chars）。
#   覆盖实测用到的全部占位符：{} {0} {1} {2} {:x} {:.1f}。
#
#   注意：不要改走"把 deployment target 抬到 16.3"那条路 —— 那会让 to_chars
#   变成**强**引用，iOS 14~16.2 真机 dyld 找不到符号直接启动崩。保持 14.0 且
#   彻底不引用该符号，才两头都安全。

import sys
from pathlib import Path

MARKER = "Amethyst iOS"

# std::format 兼容层（详见文件头注释第 3 节）
FORMAT_COMPAT_H = r'''#pragma once
// ---------------------------------------------------------------------------
// Amethyst iOS —— std::format 兼容层（由 Natives/patch_sfpew_ios.py 生成）
//
// 背景：libc++ 的 std::format 在模板展开时**无条件**实例化
// __format/formatter_floating_point.h，后者调用 std::to_chars(float) /
// std::to_chars(double)。这两个重载在 iPhoneOS SDK 里标了
// availability(introduced=iOS 16.3)，而本工程 deployment target = 14.0，于是
// AppleClang 直接报 hard error：
//     error: 'to_chars' is unavailable: introduced in iOS 16.3
// 实测即便实参全是整数/字符串（std::format<unsigned, string, string>）也照样
// 触发 —— 所以改掉浮点格式说明符、或 -Wno-unguarded-availability{,-new}
// 都压不住（后者只管 warn 级，这条是 err 级）。
//
// 对策：本工程用到的占位符子集极小（实测全树只有 {}、{0}、{1}、{2}、{:x}、
// {:.1f}），这里给出不依赖 <format> / to_chars 的最小实现，把 std::format
// 整体替换掉。保持 deployment target 14.0，iOS 14~16.2 不会有任何弱引用可踩。
//
// 每个实参单独开一个 ostringstream 并只在其上设格式旗标，因此旗标不会串到
// 后续实参上。
// ---------------------------------------------------------------------------
#include <cstdlib>
#include <iomanip>
#include <sstream>
#include <string>
#include <tuple>
#include <type_traits>
#include <utility>

namespace fpefmt {
namespace detail {

inline void apply_spec(std::ostringstream& os, const std::string& spec) {
    if (spec.empty()) return;
    const std::size_t dot = spec.find('.');
    if (dot != std::string::npos) {
        std::size_t p = 0;
        for (std::size_t k = dot + 1; k < spec.size() && spec[k] >= '0' && spec[k] <= '9'; ++k)
            p = p * 10u + static_cast<std::size_t>(spec[k] - '0');
        os << std::setprecision(static_cast<std::streamsize>(p));
        if (spec.find_first_of("fF") != std::string::npos)
            os << std::fixed;
        else if (spec.find_first_of("eE") != std::string::npos)
            os << std::scientific;
    }
    if (spec.find_first_of("xX") != std::string::npos) {
        os << std::hex;
        if (spec.find('X') != std::string::npos) os << std::uppercase;
    }
}

template <typename T>
inline void put(std::ostringstream& os, const T& v, const std::string& spec) {
    std::ostringstream one;
    apply_spec(one, spec);
    using U = typename std::decay<T>::type;
    if constexpr (std::is_same<U, bool>::value)
        one << (v ? "true" : "false");
    else
        one << v;
    os << one.str();
}

template <std::size_t I, typename Tuple>
inline void emit_at(std::size_t n, std::ostringstream& os, const std::string& spec, const Tuple& t) {
    if constexpr (I < std::tuple_size<Tuple>::value) {
        if (n == I) {
            put(os, std::get<I>(t), spec);
            return;
        }
        emit_at<I + 1>(n, os, spec, t);
    } else {
        // 实参不足（上游改了格式串）—— 保留占位符而不是越界
        os << "{}";
    }
}

}  // namespace detail

template <typename... Ts>
inline std::string format(const std::string& fmt, Ts&&... args) {
    auto t = std::forward_as_tuple(std::forward<Ts>(args)...);
    std::ostringstream os;
    std::size_t i = 0;
    std::size_t n = 0;
    while (i < fmt.size()) {
        const char c = fmt[i];
        if (c == '{') {
            if (i + 1 < fmt.size() && fmt[i + 1] == '{') {
                os << '{';
                i += 2;
                continue;
            }
            const std::size_t close = fmt.find('}', i);
            if (close == std::string::npos) {
                os << c;
                ++i;
                continue;
            }
            const std::string body = fmt.substr(i + 1, close - i - 1);
            const std::size_t colon = body.find(':');
            const std::string idx_s = (colon == std::string::npos) ? body : body.substr(0, colon);
            const std::string spec = (colon == std::string::npos) ? std::string() : body.substr(colon + 1);
            std::size_t idx = n;
            if (idx_s.empty()) {
                ++n;  // 自动编号
            } else {
                const char* s = idx_s.c_str();
                char* endp = nullptr;
                const unsigned long v = std::strtoul(s, &endp, 10);
                if (endp != nullptr && *endp == '\0') idx = static_cast<std::size_t>(v);
            }
            detail::emit_at<0>(idx, os, spec, t);
            i = close + 1;
            continue;
        }
        if (c == '}' && i + 1 < fmt.size() && fmt[i + 1] == '}') {
            os << '}';
            i += 2;
            continue;
        }
        os << c;
        ++i;
    }
    return os.str();
}

}  // namespace fpefmt
'''


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


def patch_types_h(root: Path) -> None:
    types_h = root / "SimpleFPEWrapper" / "fpe" / "types.h"
    if not types_h.is_file():
        fail(f"missing {types_h}")
    t = types_h.read_text(encoding="utf-8")
    if "fixed_function_draw_size_t()\n" in t:
        print("patch_sfpew_ios: glstate_t default ctor: already patched -- skip")
        return
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


def patch_float_call_site(root: Path) -> None:
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


def patch_format_to_compat(root: Path) -> None:
    """把 std::format 整体换成自研的 fpefmt::format（不碰 <format>/to_chars）。"""
    fpe_dir = root / "SimpleFPEWrapper" / "fpe"
    if not fpe_dir.is_dir():
        fail(f"missing {fpe_dir}")

    # 兼容层头文件：每次都重写（幂等由内容决定，不追加）
    compat = fpe_dir / "fpe_format_compat.h"
    compat.write_text(FORMAT_COMPAT_H, encoding="utf-8")
    print(f"patch_sfpew_ios: fpe_format_compat.h: written ({compat})")

    targets = [fpe_dir / "fpe_shadergen.cpp", fpe_dir / "glstate.cpp"]
    changed = False
    for src in targets:
        if not src.is_file():
            fail(f"missing {src}")
        text = src.read_text(encoding="utf-8")
        if "fpefmt::format(" in text:
            print(f"patch_sfpew_ios: std::format -> fpefmt::format: already patched -- skip ({src.name})")
            continue
        if "std::format(" not in text:
            print(f"patch_sfpew_ios: no std::format in {src.name} -- skip")
            continue
        if "#include <format>" not in text:
            fail(f"{src}: uses std::format but no '#include <format>' -- layout changed?")
        text = text.replace("#include <format>", '#include "fpe_format_compat.h"', 1)
        text = text.replace("std::format(", "fpefmt::format(")
        src.write_text(text, encoding="utf-8")
        changed = True
        print(f"patch_sfpew_ios: std::format -> fpefmt::format: PATCHED ({src.name})")

    # 收尾校验：全树不得再出现 std::format（否则下一个 TU 还会撞同一个 error）
    leftovers = []
    for p in root.rglob("*.cpp"):
        if "std::format(" in p.read_text(encoding="utf-8", errors="ignore"):
            leftovers.append(str(p.relative_to(root)))
    if leftovers:
        fail("residual std::format after patching: " + ", ".join(leftovers))
    if changed:
        print("patch_sfpew_ios: verified -- no std::format left in tree")


def main() -> None:
    if len(sys.argv) != 2:
        fail(f"usage: {sys.argv[0]} <SimpleFPEWrapper source dir>")
    root = Path(sys.argv[1])
    if not root.is_dir():
        fail(f"SFPEW source dir not found: {root}")

    patch_types_h(root)
    patch_float_call_site(root)
    patch_format_to_compat(root)


if __name__ == "__main__":
    main()
