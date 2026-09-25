#!/usr/bin/env python3
"""Task 135: libSDL3.dylib 事件过滤器守卫 —— SDL_SetEventFilter / SDL_AddEventWatch
入口机器码补丁（26.1.2 整合包 controlify/JNA closure SIGBUS 的源头根治）。

背景（df10f70/3756a05/63178f8/6235baf 四份装机日志定案）
--------------------------------------------------------
controlify 3.0.1（26.1 整合包）经 libsdl4j -> JNA NativeLibrary 加载 SDL3：
mod 自带的 macOS 版 SDL3 解包 dlopen 必败（链接 Cocoa/AppKit/Carbon/
ForceFeedback，iOS 上不存在），按名字回退 dlopen("libSDL3.dylib") 命中本
启动器 Frameworks 里的 iOS 版 —— 所有 SDL 调用最终都在【本二进制】里执行。
SDLControllerManager 构造时调 SDL_SetEventFilter(JNA closure, NULL)：JNA
把 Java 回调包装成 libffi closure，其 trampoline 页在无 JIT 权限的 iOS 进程
里只能 RW 不可执行；SDL_SetEventFilter 注册即对 pending 队列逐事件同步调用
filter -> 跳进 RW trampoline 页 -> ARM64 Darwin 对"执行不可执行页"投递
SIGBUS（多会话 PC 形如 0x...010，均在非镜像内存）。

Task131 已在 dlsym 解析层拦这两个入口（hooked_dlsym 按名分发 no-op 守卫），
LWJGL 路径与 26.2 会话（FFM loaderLookup）实证有效；但 26.1.2 会话 JNA 的
符号解析仍能绕过 hook 直接拿到真函数（全会话零 Task131 守卫日志、零
"hooked SDL_SetEventFilter" 解析日志 —— 具体绕行机制未定案，jnilib 的
__la_symbol_ptr[8] _dlsym 槽静态分析确认存在且可重绑）。本补丁把守卫下沉到
【SDL 二进制自身】：无论调用方经哪条路径解析符号，函数入口一律把非空回调
指针置空（SetEventFilter）/ 直接返回不注册（AddEventWatch）。

策略依据：启动器自身与 MC/LWJGL 均不使用 SDL 事件过滤器（全仓 grep 验证，
Task131 注释同结论"零误伤"）；唯一的注册者就是 controlify 的 JNA closure。
与 Task131 的"全部拦截"策略保持一致 —— 本补丁是它的链路无关兜底。

补丁布局（arm64；__TEXT 段 vmaddr==fileoff）
----------------------------------------------
_SDL_SetEventFilter @ 0x27cbc:
  入口第 1 条 (stp x22,x21,[sp,#-0x30]!  f6 57 bd a9) -> b 0x1e1c80
  cave1 @ 0x1e1c80:
      cbz  x0, +12          ; filter==NULL（移除过滤器）→ 原语义
      mov  x0, xzr          ; 非空 → 置空（JNA closure 守卫）
      stp  x22, x21, [sp, #-0x30]!   ; 重定位的原第 1 条指令
      b    0x27cc0          ; 回到原第 2 条指令
_SDL_AddEventWatch @ 0x27db4:
  入口第 1 条 (mov x2, x1  e2 03 01 aa) -> b 0x1e1cb0
  cave2 @ 0x1e1cb0:
      cbz  x0, +16          ; watch==NULL → 原语义
      mov  w0, #1           ; 非空 → 返回 true（假装注册成功）
      ret
      mov  x2, x1           ; 重定位的原第 1 条指令
      b    0x27db8          ; 回到原第 2 条指令
cave 选址：__TEXT 尾部全零 padding（0x1e1c78..0x1e4000，9096 字节，Task 34
同款技巧）。全部指令经 keystone 生成 + capstone 往返验证。

代码签名：本补丁改写源文件后签名哈希失效 —— 与 dep_angle_freeze（Task 57）
同情况：打包时 `ldid -S Payload/AngelAuraAmethyst.app` 递归重签全 app，无需
额外步骤。

用法
----
  python3 patch_sdl3_eventfilter_guard.py <libSDL3.dylib> [--verify]
  --verify : 只检查补丁状态，不写文件。
  幂等：对已打补丁的二进制重复运行 = 校验后退出 0。
  原始字节不匹配（SDL3 版本漂移）时响亮失败退出 1。
"""
import sys

# ---- 常量（对应本二进制的符号布局，见脚本头注释） ----
SET_EVENT_FILTER = 0x27CBC
ADD_EVENT_WATCH = 0x27DB4
CAVE1 = 0x1E1C80
CAVE2 = 0x1E1CB0

# 原始（pristine）入口字节 —— 版本漂移哨兵
PRISTINE_SET_EVENT_FILTER = bytes([0xf6, 0x57, 0xbd, 0xa9])  # stp x22,x21,[sp,#-0x30]!
PRISTINE_ADD_EVENT_WATCH = bytes([0xe2, 0x03, 0x01, 0xaa])   # mov x2, x1

# 入口 trampoline（b caveN）
TRAMP_SET_EVENT_FILTER = bytes([0xf1, 0xe7, 0x06, 0x14])     # b 0x1e1c80
TRAMP_ADD_EVENT_WATCH = bytes([0xbf, 0xe7, 0x06, 0x14])      # b 0x1e1cb0

# cave 代码（keystone 生成，capstone 往返验证；开发脚本
# /home/z/my-project/scripts/task135_gen_sdl3_patch.py）
CAVE1_BYTES = bytes([
    0x40, 0x00, 0x00, 0xb4,             # cbz x0, +8 (NULL 回调跳到重定位的 stp)
    0xe0, 0x03, 0x1f, 0xaa,             # mov x0, xzr
    0xf6, 0x57, 0xbd, 0xa9,             # stp x22, x21, [sp, #-0x30]!
    0x0d, 0x18, 0xf9, 0x17,             # b 0x27cc0
])
CAVE2_BYTES = bytes([
    0x60, 0x00, 0x00, 0xb4,             # cbz x0, +12 (NULL 回调跳到重定位的 mov)
    0x20, 0x00, 0x80, 0x52,             # mov w0, #1
    0xc0, 0x03, 0x5f, 0xd6,             # ret
    0xe2, 0x03, 0x01, 0xaa,             # mov x2, x1
    0x3e, 0x18, 0xf9, 0x17,             # b 0x27db8
])

CAVE_ZERO_SENTINEL_LEN = 0x100  # cave 周边必须是全零（首次打补丁时校验）


def check(data):
    """返回 (已打补丁, 原始模式匹配, 错误说明列表)。"""
    errs = []
    if len(data) < CAVE2 + len(CAVE2_BYTES):
        return False, False, ["file too small (%d bytes)" % len(data)]

    t1 = data[SET_EVENT_FILTER:SET_EVENT_FILTER + 4]
    t2 = data[ADD_EVENT_WATCH:ADD_EVENT_WATCH + 4]
    c1 = data[CAVE1:CAVE1 + len(CAVE1_BYTES)]
    c2 = data[CAVE2:CAVE2 + len(CAVE2_BYTES)]

    patched = (t1 == TRAMP_SET_EVENT_FILTER and t2 == TRAMP_ADD_EVENT_WATCH
               and c1 == CAVE1_BYTES and c2 == CAVE2_BYTES)
    pristine = (t1 == PRISTINE_SET_EVENT_FILTER and t2 == PRISTINE_ADD_EVENT_WATCH)
    if patched:
        return True, True, []
    if pristine:
        # 首次打补丁：校验 cave 区全零（防布局漂移踩到真实数据）
        if any(b != 0 for b in data[CAVE1:CAVE1 + CAVE_ZERO_SENTINEL_LEN]):
            errs.append("cave region 0x%x..0x%x not zero-filled -- layout drift"
                        % (CAVE1, CAVE1 + CAVE_ZERO_SENTINEL_LEN))
        if any(b != 0 for b in data[CAVE2:CAVE2 + CAVE_ZERO_SENTINEL_LEN]):
            errs.append("cave region 0x%x..0x%x not zero-filled -- layout drift"
                        % (CAVE2, CAVE2 + CAVE_ZERO_SENTINEL_LEN))
        if errs:
            return False, False, errs
        return False, True, []
    return False, False, [
        "SDL_SetEventFilter @0x%x: expected %s (pristine) or %s (patched), got %s"
        % (SET_EVENT_FILTER, PRISTINE_SET_EVENT_FILTER.hex(),
           TRAMP_SET_EVENT_FILTER.hex(), t1.hex()),
        "SDL_AddEventWatch @0x%x: expected %s (pristine) or %s (patched), got %s"
        % (ADD_EVENT_WATCH, PRISTINE_ADD_EVENT_WATCH.hex(),
           TRAMP_ADD_EVENT_WATCH.hex(), t2.hex()),
    ]


def main():
    args = [a for a in sys.argv[1:] if a != "--verify"]
    verify_only = "--verify" in sys.argv[1:]
    if len(args) != 1:
        print("usage: patch_sdl3_eventfilter_guard.py <libSDL3.dylib> [--verify]")
        return 1
    path = args[0]
    with open(path, "rb") as f:
        data = f.read()

    patched, ok, errs = check(data)
    if patched:
        print("[Task135] SDL3 event-filter guard: already patched (verified OK)")
        return 0
    if not ok:
        print("[Task135] ERROR: %s does not match the expected pristine/patched "
              "pattern -- SDL3 version drift? Re-derive the patch "
              "(scripts/task135_gen_sdl3_patch.py)." % path)
        for e in errs:
            print("  - " + e)
        return 1
    if verify_only:
        print("[Task135] SDL3 event-filter guard: NOT patched (pristine) -- "
              "verify-only mode, no write")
        return 1

    buf = bytearray(data)
    buf[SET_EVENT_FILTER:SET_EVENT_FILTER + 4] = TRAMP_SET_EVENT_FILTER
    buf[ADD_EVENT_WATCH:ADD_EVENT_WATCH + 4] = TRAMP_ADD_EVENT_WATCH
    buf[CAVE1:CAVE1 + len(CAVE1_BYTES)] = CAVE1_BYTES
    buf[CAVE2:CAVE2 + len(CAVE2_BYTES)] = CAVE2_BYTES
    with open(path, "wb") as f:
        f.write(buf)

    # 写后读回验证
    with open(path, "rb") as f:
        recheck = f.read()
    patched2, ok2, errs2 = check(recheck)
    if not patched2:
        print("[Task135] ERROR: post-write verification failed:")
        for e in errs2:
            print("  - " + e)
        return 1
    print("[Task135] SDL3 event-filter guard applied: "
          "SDL_SetEventFilter/SDL_AddEventWatch non-NULL callbacks now "
          "nullified/rejected at the SDL binary itself (JNA/libffi closure "
          "SIGBUS source-level defense, chain-independent)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
