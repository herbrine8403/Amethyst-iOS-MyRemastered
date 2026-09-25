#!/usr/bin/env python3
"""patch_angle_surface_freeze.py — Task 57 二进制补丁（画面分裂根治）

目标: Natives/resources/Frameworks/libGLESv2.framework/libGLESv2（自带 ANGLE
Metal 后端，经 libEGL 垫片动态加载，surface 创建/查询/呈现全在此镜像内）。

== 根因（bbe6d63 日志 + 反汇编铁证链）==

rx::WindowSurfaceMtl::checkIfLayerResized()（每帧 obtainNextDrawable 都会执行）
是一个"几何执法者"：

    expected = [mLayer bounds].size * [mLayer contentsScale]   ; 期望尺寸
    if (drawableSize == expected && mWidth == expected.w && mHeight == expected.h)
        return false                       ; 一致，无事发生
    mWidth, mHeight = expected             ; 【表面尺寸 ← bounds×scale】
    [mLayer setDrawableSize: expected]     ; 反向强制 layer
    return true → onBackbufferResized      ; 重建 swapchain

设备事实（两轮日志、两代数值，622166a 与 bbe6d63）：
  * 创建时（initialize）读 bounds 干净 → query=1180x820 正确；
  * 加载盲窗期（无 swap、shaderc 风暴约 8s）SDL/UIKit 从【后台线程】把
    窗口模式（Code=101 证明 scene 处于 iPadOS 26 windowed）的竖屏几何写入
    渲染层 → CA 渲染服务器侧被污染（drawable 实际 820x1180），主线程模型
    读仍横屏（心跳 drawable=1180x820）——CALayer 跨线程 split-brain，本项目
    两次实测（622166a: 心跳 2360x1640 vs 卫兵读 1640x2360）；
  * 渲染线程的 bounds 读从此被毒化 → checkIfLayerResized 每帧把
    expected=820x1180 灌进 mWidth/mHeight → 转置锁死 1200+ 帧不恢复；
  * 主线程写 drawableSize（Task50/51/52 全部补偿）无效——执法者只读
    bounds（Task55 stepA/C 实验吻合：写 drawableSize 后 query 纹丝不动）；
  * 销毁重建（Task53/55 stepB）同层同毒 → 新表面照样 820x1180。

== 补丁（2 条指令、8 字节，无 cave）==

把 expected 的来源从"被毒化的 bounds×scale"改为"表面自己已锁定的值"：

    0x1aaca0: fmul d0, d10, d0   →  ldr d0, [x19, #0x430]   ; expected.w = mWidth
    0x1aaca4: fmul d1, d11, d1   →  ldr d1, [x19, #0x438]   ; expected.h = mHeight

x19 = this（WindowSurfaceMtl*），[+0x430]/[+0x438] = mWidth/mHeight（本函数
resized 分支 str d0/d1 的同一对槽位，编码模板直接取自函数体内既有指令）。

效果（三态封闭）：
  1) 一致态: drawableSize == mWidth/mHeight → return false，与原逻辑同；
  2) 漂移态: drawableSize != 冻结值 → resized 分支把 mWidth/mHeight 写回
     【自身旧值】（不变）+ setDrawableSize(冻结值) → ANGLE 主动把 layer 的
     drawableSize 拉回横屏 → nextDrawable 恢复横屏 drawable → swapchain
     在正确尺寸上重建。surface 尺寸在物理上不可能被 layer 读数改变；
  3) 转置毒化: bounds 读成 820x1180 也无济于事——expected 根本不看 bounds。

代价（有意为之）：表面尺寸冻结在创建时几何（创建读一直干净，所有日志
证据）。合法 resize（iPadOS 26 窗口拖拽）退化为 CA 拉伸（无分裂，仅纵横
比变化）；方向已锁横屏（supportedInterfaceOrientations=Landscape），旋转
不发生。当前窗口模式下"必分裂"相比是严格改进。

== 鲁棒性 ==
  * 符号表定位函数（不硬编码地址），函数体内搜指令模式；
  * 原字节不符 → 响亮失败（ANGLE 版本漂移保护）；
  * 已打补丁 → 幂等跳过（--verify 只校验）；
  * capstone 反汇编往返验证（若可用）。
"""
import struct
import sys

FUNC_SYMBOL = "__ZN2rx16WindowSurfaceMtl19checkIfLayerResizedEPKN2gl7ContextE"

# 指令编码（已用二进制内模板交叉验证）
ORIG_WORDS = (0x1E600940, 0x1E610961)   # fmul d0, d10, d0 ; fmul d1, d11, d1
PATCH_WORDS = (0xFD421A60, 0xFD421E61)  # ldr d0,[x19,#0x430] ; ldr d1,[x19,#0x438]

# 上下文锚点（resized 分支的写回指令，必须出现在补丁点之后 ≤0x40 字节）
STORE_ANCHOR = (0xFD021A60, 0xFD021E61)  # str d0,[x19,#0x430] ; str d1,[x19,#0x438]


def parse_symbols(data):
    """返回 {value: name} 与 {name: value}（仅 defined 符号）。"""
    ncmds = struct.unpack("<I", data[16:20])[0]
    off = 32
    symoff = symcount = stroff = strsize = 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[off:off + 8])
        if cmd == 0x2:  # LC_SYMTAB
            symoff, symcount, stroff, strsize = struct.unpack("<IIII", data[off + 8:off + 24])
            break
        off += cmdsize
    strtab = data[stroff:stroff + strsize]
    byname = {}
    for i in range(symcount):
        e = data[symoff + i * 16: symoff + i * 16 + 16]
        n_strx, n_type, n_sect, n_desc, n_value = struct.unpack("<IBBHQ", e)
        if not (n_type & 0x0E) or n_value == 0:
            continue
        end = strtab.index(b"\0", n_strx)
        nm = strtab[n_strx:end].decode(errors="replace")
        if nm:
            byname.setdefault(nm, n_value)
    return byname


def vm_to_file(data, addr):
    """段映射 vmaddr→file offset（本镜像 __TEXT vm==file，但按段表算以防万一）。"""
    ncmds = struct.unpack("<I", data[16:20])[0]
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[off:off + 8])
        if cmd == 0x19:  # LC_SEGMENT_64
            vmaddr, vmsize, fileoff, filesize = struct.unpack("<QQQQ", data[off + 24:off + 56])
            if vmaddr is not None and vmaddr <= addr < vmaddr + filesize:
                return fileoff + (addr - vmaddr)
        off += cmdsize
    return None


def find_pattern(data, start, end, words):
    """在 [start,end) 内查找连续 word 序列，返回偏移或 None。"""
    needle = b"".join(struct.pack("<I", w) for w in words)
    idx = data.find(needle, start, end)
    return idx if idx != -1 else None


def capstone_check(off, words, expect):
    try:
        from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
    except ImportError:
        print("patch_angle_surface_freeze: capstone 不可用，跳过反汇编往返验证")
        return True
    md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
    code = b"".join(struct.pack("<I", w) for w in words)
    got = [(i.mnemonic, i.op_str) for i in md.disasm(code, off)]
    ok = got == expect
    if not ok:
        print(f"patch_angle_surface_freeze: 反汇编不匹配: {got} != {expect}", file=sys.stderr)
    return ok


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    verify_only = "--verify" in sys.argv[1:]
    if not args:
        print("用法: patch_angle_surface_freeze.py <libGLESv2> [--verify]", file=sys.stderr)
        return 2
    path = args[0]
    data = bytearray(open(path, "rb").read())

    byname = parse_symbols(bytes(data))
    if FUNC_SYMBOL not in byname:
        print(f"patch_angle_surface_freeze: FAIL: 符号 {FUNC_SYMBOL} 不存在（ANGLE 版本漂移？）", file=sys.stderr)
        return 1
    fn_vm = byname[FUNC_SYMBOL]
    fn_off = vm_to_file(bytes(data), fn_vm)
    if fn_off is None:
        print(f"patch_angle_surface_freeze: FAIL: 函数地址 {fn_vm:#x} 无文件偏移映射", file=sys.stderr)
        return 1
    fn_end = fn_off + 0x200  # 函数体 < 0x100，取宽松上界

    # 幂等：已打补丁？
    patched_at = find_pattern(bytes(data), fn_off, fn_end, PATCH_WORDS)
    orig_at = find_pattern(bytes(data), fn_off, fn_end, ORIG_WORDS)
    if patched_at is not None and orig_at is None:
        # 校验锚点仍在
        anchor_at = find_pattern(bytes(data), patched_at, patched_at + 0x40, STORE_ANCHOR)
        if anchor_at is None:
            print("patch_angle_surface_freeze: FAIL: 补丁存在但 resized 分支锚点缺失", file=sys.stderr)
            return 1
        ok = capstone_check(patched_at, PATCH_WORDS, [
            ("ldr", "d0, [x19, #0x430]"), ("ldr", "d1, [x19, #0x438]")])
        if not ok:
            return 1
        print("patch_angle_surface_freeze: PATCH PRESENT ✓ (surface size frozen at creation geometry)")
        return 0

    if verify_only:
        if orig_at is not None:
            print("patch_angle_surface_freeze: NOT PATCHED (pristine pattern present) — verify-only 拒绝放行",
                  file=sys.stderr)
            return 1
        print("patch_angle_surface_freeze: FAIL: 既非原始也非补丁状态，无法识别", file=sys.stderr)
        return 1

    if orig_at is None:
        print(f"patch_angle_surface_freeze: FAIL: 函数内找不到原始指令模式 fmul d0,d10,d0 / fmul d1,d11,d1"
              f"（@{fn_off:#x}..{fn_end:#x}，ANGLE 版本漂移？）", file=sys.stderr)
        return 1

    # 锚点校验：resized 分支写回指令必须紧随其后（≤0x40 字节）
    anchor_at = find_pattern(bytes(data), orig_at, orig_at + 0x40, STORE_ANCHOR)
    if anchor_at is None:
        print("patch_angle_surface_freeze: FAIL: resized 分支 str d0/d1 锚点缺失，布局与预期不符", file=sys.stderr)
        return 1

    # 打补丁
    for k, w in enumerate(PATCH_WORDS):
        struct.pack_into("<I", data, orig_at + k * 4, w)

    # 落盘前反汇编往返
    if not capstone_check(orig_at, PATCH_WORDS, [
            ("ldr", "d0, [x19, #0x430]"), ("ldr", "d1, [x19, #0x438]")]):
        return 1

    with open(path, "wb") as f:
        f.write(bytes(data))
    print(f"patch_angle_surface_freeze: PATCHED ✓ checkIfLayerResized @{orig_at:#x}:"
          f" expected <- bounds×scale 改为 <- 冻结的 mWidth/mHeight [x19,#0x430/0x438]"
          f"（转置毒化物理隔离）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
