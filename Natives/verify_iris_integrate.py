#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ★ [IRIS-INTEGRATE] verify_iris_integrate.py — 只读自检（任何一条不满足即 exit 2）
#
#   校验「26.2-iris 走 91 符号 libmetallum_iris.dylib，26.3/26.1 继续吃 libmetallum.dylib」
#   这件事在产物里确实成立，并且**没有**把 iris 类集回退成 r10（r10 比当前构建旧）。
#
#   为什么类集不能回退到 r10（硬证据，脚本可复算 `javap -p -c`）：
#     agent classes262iris vs r10 = 21 类不同；9 类字节码完全相同（只差调试信息），
#     12 类真差异且**全部是 agent 侧更大/更多**：
#       GlStateManagerMixin(SHADER-CAP GL_EXTENSIONS) / IrisMetalWorldResources.shadowColorFormatsFrom /
#       IrisMetalCompiledPrograms.*(多 GpuFormat[] 参数=shadow 格式打通) /
#       MetalNativeBridge(解包路径 /natives/ir1 vs r10 /natives/ios) …
#     ⇒ 回退 r10 = 丢 SHADER-CAP 上报 + 丢 shadow 格式对齐 + iris native 退回 75 符号那份。
#
#   用法:  python Natives/verify_iris_integrate.py
import os, sys, zipfile, hashlib, struct, json

HERE = os.path.dirname(os.path.abspath(__file__))
TREE = os.path.dirname(HERE)
AGENT = os.path.join(TREE, "JavaApp", "libs", "others", "metallum_agent.jar")
MOD = os.path.join(HERE, "resources", "mods_preload", "MetalUniversal-1.0.4.jar")
FW = os.path.join(HERE, "resources", "Frameworks")
IRIS_DYLIB = os.path.join(FW, "libmetallum_iris.dylib")
T510_DYLIB = os.path.join(FW, "libmetallum.dylib")

PREFIX = "classes262iris/"
MNB = "com/metallum/client/metal/render/bridge/MetalNativeBridge.class"
IFACES = ["GpuSurfaceBackend", "CommandEncoderBackend", "TransientMemory"]
IFACE_PREFIXES = ["classes262iris/", "classes262/", ""]
IRIS_DYLIB_MD5 = "f83b1b3b8e521b57c482e0dddec06df4"      # 91 符号（r10 世代 native）
T510_DYLIB_MD5 = "edadd02ab39a1dde269aa77a93f68531"      # 75 符号（26.3/26.1 用，须原样）
FEATURES = {
    "SHADER-CAP GL_EXTENSIONS (GlStateManagerMixin)":
        (PREFIX + "com/metallum/mixin/iris/GlStateManagerMixin.class", b"GL_EXTENSIONS"),
    "shadowColorFormats (IrisMetalWorldResources)":
        (PREFIX + "com/metallum/client/metal/render/IrisMetalWorldResources.class", b"shadowColorFormats"),
    "iris native path /natives/ir1 (MetalNativeBridge)":
        (PREFIX + MNB, b"/natives/ir1/libmetallum.dylib"),
}


def md5(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def macho_exported_metallum(path):
    b = open(path, "rb").read()
    if len(b) < 32 or b[:4] != b"\xcf\xfa\xed\xfe":
        return None, "not 64-bit Mach-O"
    ncmds = struct.unpack("<I", b[16:20])[0]
    off = 32; symoff = nsyms = stroff = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", b[off:off + 8])
        if cmd == 0x2:
            symoff, nsyms, stroff, strsize = struct.unpack("<IIII", b[off + 8:off + 24])
        off += cmdsize
        if off > len(b):
            return None, "walk past EOF"
    if symoff is None:
        return None, "no LC_SYMTAB"
    names = set()
    for i in range(nsyms):
        p = symoff + i * 16
        n_strx, n_type, n_sect, n_desc, n_value = struct.unpack("<IBBHQ", b[p:p + 16])
        if n_strx == 0 or (n_type & 0x0E) != 0x0E:
            continue
        end = b.find(b"\x00", stroff + n_strx)
        names.add(b[stroff + n_strx:end].decode("utf-8", "replace"))
    return len([n for n in names if n.startswith("_metallum_")]), None


def main():
    bad = []
    za = zipfile.ZipFile(AGENT); zm = zipfile.ZipFile(MOD)
    an = set(za.namelist()); mn = set(zm.namelist())

    # 1. mod jar 身份（信息项；不强制 r10）
    try:
        ver = json.loads(zm.read("fabric.mod.json").decode("utf-8")).get("version", "")
    except Exception as e:
        ver = "?"; bad.append("mod fabric.mod.json unreadable: %s" % e)
    print("[1] mod jar version                : %s   (r10 = 1.0.4-irisuniform-r10；当前应保持更新那份)" % ver)

    # 2. 两条通道都接线
    wire_a = b"metallum_iris" in za.read(PREFIX + MNB)
    wire_m = b"metallum_iris" in zm.read(MNB)
    print("[2] loadLibrary(\"metallum_iris\")     : agent=%s mod=%s" % (wire_a, wire_m))
    if not (wire_a and wire_m):
        bad.append("metallum_iris wiring missing (agent=%s mod=%s)" % (wire_a, wire_m))

    # 3. 91 符号 native 在 Frameworks（接线目标必须存在）
    if not os.path.isfile(IRIS_DYLIB):
        bad.append("Frameworks/libmetallum_iris.dylib MISSING (wire-in target)")
    else:
        m = md5(IRIS_DYLIB); cnt, why = macho_exported_metallum(IRIS_DYLIB)
        print("[3] Frameworks/libmetallum_iris.dylib : %d B md5 %s exported_metallum=%s%s"
              % (os.path.getsize(IRIS_DYLIB), m, cnt, "" if why is None else " (%s)" % why))
        if m != IRIS_DYLIB_MD5:
            bad.append("libmetallum_iris.dylib md5 %s != %s" % (m, IRIS_DYLIB_MD5))
        if cnt is not None and cnt < 91:
            bad.append("libmetallum_iris.dylib exports only %d _metallum_* (want >=91)" % cnt)

    # 4. 26.3/26.1 那份共用文件必须原样（否则 26.3 掉 3 个符号）
    if os.path.isfile(T510_DYLIB):
        m = md5(T510_DYLIB); cnt, why = macho_exported_metallum(T510_DYLIB)
        ok = (m == T510_DYLIB_MD5)
        print("[4] Frameworks/libmetallum.dylib     : %d B md5 %s exported_metallum=%s  %s"
              % (os.path.getsize(T510_DYLIB), m, cnt, "OK (26.3/26.1 用)" if ok else "≠ 基线 %s" % T510_DYLIB_MD5))
        if not ok:
            bad.append("libmetallum.dylib 不再是 26.3 基线（26.3/26.1 可能掉 getError/getStatus/get_last_error）")

    # 5. blaze3d 三处镜像 + marker
    grid = [sum(1 for c in IFACES if "%scom/mojang/blaze3d/systems/%s.class" % (p, c) in an) for p in IFACE_PREFIXES]
    marker = "metallum_iris.mode" in an
    print("[5] blaze3d-ifaces @ 3 prefixes      : %s   marker=%s" % (grid, marker))
    if grid != [3, 3, 3]:
        bad.append("blaze3d iface mirrors incomplete: %s" % grid)
    if not marker:
        bad.append("metallum_iris.mode marker missing")

    # 6. glslang 不变量
    gl = [n for n in (an | mn) if "glslang" in n]
    print("[6] glslang entries inside jars      : %s" % (gl or "NONE ✓"))
    if gl:
        bad.append("glslang present in jar: %s" % gl)

    # 7. 类集未被回退到 r10（特征必须都在）
    feats = {}
    for label, (name, needle) in FEATURES.items():
        feats[label] = (name in an) and (needle in za.read(name))
    print("[7] iris 类集特征（必须全 True，证明没回退 r10）:")
    for k, v in feats.items():
        print("      %-52s %s" % (k, v))
    if not all(feats.values()):
        bad.append("iris class set looks REGRESSED (r10-era); missing: %s"
                   % [k for k, v in feats.items() if not v])

    if bad:
        print("\nRESULT: FAIL")
        for x in bad:
            print("  - " + x)
        return 2
    print("\nRESULT: ALL OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
