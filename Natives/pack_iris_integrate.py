#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ★ [IRIS-INTEGRATE] pack_iris_integrate.py
#   让 26.2-iris 路线吃到 **91 符号** 的 libmetallum（＝ r10 那一代的 native），
#   同时不动类集、不动 26.3/26.1 共用的 Frameworks/libmetallum.dylib。
#
#   ★ 为什么**不是**"把 r10 的类集搬进来"（本仓库 agent 的 classes262iris 比 r10 更新）：
#     逐类 `javap -p` / `javap -p -c` 对比（agent classes262iris vs r10，本机可复算）：
#       · 21 个类不同，其中 9 个的**字节码完全相同**（差异只在 LocalVariableTable/LineNumberTable
#         —— agent 是带调试信息的开发构建，r10 是 strip 过的发布构建）；
#       · 另外 12 个是**真差异，且差异全部是 agent 侧更大/更多**，没有任何成员是 r10 有、agent 没有：
#           - GlStateManagerMixin     : agent 有 GL_EXTENSIONS / METALLUM_GL_EXTENSIONS /
#                                       metallum$metalExtensionString（SHADER-CAP）— r10 没有；
#                                       真机 `[metallum:gl] reporting 6 GL extension(s)` 只可能由
#                                       agent 这份打出（9-24 的 r10 日志里没有这行）
#           - IrisMetalWorldResources : agent 有 shadowColorFormatsFrom(ProgramSet) — r10 没有
#           - IrisMetalCompiledPrograms: agent 的 sodium/compile/colorTargets 多一个 GpuFormat[]
#                                       参数 ⇒ shadow 颜色附件格式打通（正是 shadow pass
#                                       "pipeline=[RG11B10Float] vs renderPass=[RGBA8Unorm]" 的正解）
#           - MetalNativeBridge       : 唯一代码差异 = 解包路径 agent `/natives/ir1/`（91 符号）
#                                       vs r10 `/natives/ios/`（75 符号）
#       · 其余 IrisMetalExecutionGraph / IrisMetalRenderTargets / IrisMetalShadowPass /
#         IrisMetalShadowTargets / IrisMetalTerrainBridge 均为 agent 侧更大（含同一套
#         `[metallum-iris-pass]` §12 探针 + shadow 格式打通）。
#     ⇒ 把 r10 类集覆盖进来 = **功能回退**。所以本脚本**默认不回退类集**；
#       确要 r10 那份时用 `--r10 <jar>`（显式、带警告、可回退）。
#
#   默认只做一件事（幂等）：
#     · agent jar classes262iris/…/MetalNativeBridge.class 与 mod jar com/…/MetalNativeBridge.class
#       内 `System.loadLibrary("metallum")` → `"metallum_iris"`
#     ⇒ 同一包里：
#         26.2-iris  → <app>/Frameworks/libmetallum_iris.dylib（91 符号，缺 0；随包签名）
#         26.3/26.1  → <app>/Frameworks/libmetallum.dylib（75 符号，含 getError/getStatus/get_last_error）
#       §6.7「两条路线共用一个文件名」用**改名接线**解决：不需要打包期覆盖，也不需要重编 native。
#       ★ 前提：Natives/resources/Frameworks/libmetallum_iris.dylib 必须存在
#         （md5 f83b1b3b…，91 符号）—— 否则拒绝改写，避免"loadLibrary 失败 → 退回 jar 解包
#          未签名副本"的 SIGBUS 形态（与 glslang 同款教训）。
#
#   保留今天的成果：26.4 路由 / SHADER-CAP / marker / blaze3d 三处镜像 / jar 内其它前缀全不动。
#   用法:  python Natives/pack_iris_integrate.py           # 接线（幂等）
#          python Natives/pack_iris_integrate.py --check   # 只检查/报状态
#          python Natives/pack_iris_integrate.py --r10 <metallum-1.0.4-irisuniform-r10.jar>
#                                                          # ★ 显式回退到 r10 类集（有警告）
import os, sys, zipfile, hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
TREE = os.path.dirname(HERE)
AGENT = os.path.join(TREE, "JavaApp", "libs", "others", "metallum_agent.jar")
MOD = os.path.join(HERE, "resources", "mods_preload", "MetalUniversal-1.0.4.jar")
IRIS_DYLIB = os.path.join(HERE, "resources", "Frameworks", "libmetallum_iris.dylib")

PREFIX = "classes262iris/"
MNB = "com/metallum/client/metal/render/bridge/MetalNativeBridge.class"
NEEDLE = b"\x01\x00\x08metallum"          # UTF8 常量池条目: tag=01, len=8, "metallum"
REPL = b"\x01\x00\x0dmetallum_iris"       # tag=01, len=13
IRIS_DYLIB_MD5 = "f83b1b3b8e521b57c482e0dddec06df4"
IR1 = b"/natives/ir1/libmetallum.dylib"


def read_entries(p):
    z = zipfile.ZipFile(p)
    o = [i.filename for i in z.infolist()]
    d = {i.filename: z.read(i.filename) for i in z.infolist()}
    z.close()
    return o, d


def write_entries(p, o, d):
    t = p + ".tmp"
    with zipfile.ZipFile(t, "w", zipfile.ZIP_DEFLATED) as z:
        for n in o:
            z.writestr(n, d[n])
    zz = zipfile.ZipFile(t)
    assert zz.testzip() is None, "zip integrity fail: " + p
    zz.close()
    os.replace(t, p)


def wire(blob):
    """唯一 UTF8 "metallum" → "metallum_iris"（长度前缀已把它与 "metallum_native" 区分开）。"""
    if b"\x00\x0dmetallum_iris" in blob:
        return blob, False
    n = blob.count(NEEDLE)
    if n != 1:
        raise AssertionError("expected exactly 1 UTF8 'metallum' constant, got %d" % n)
    i = blob.find(NEEDLE)
    j = i + len(NEEDLE)
    if blob[j:j + 1] == b"_":
        raise AssertionError("the 'metallum' utf8 is a prefix of a longer name")
    return blob[:i] + REPL + blob[j:], True


def main():
    argv = sys.argv[1:]
    check_only = "--check" in argv
    r10 = argv[argv.index("--r10") + 1] if "--r10" in argv else None

    if not os.path.isfile(IRIS_DYLIB):
        print("[iris-integrate] FATAL: %s missing (91 符号 native 是接线目标)" % IRIS_DYLIB)
        return 2
    m = hashlib.md5(open(IRIS_DYLIB, "rb").read()).hexdigest()
    if m != IRIS_DYLIB_MD5:
        print("[iris-integrate] FATAL: libmetallum_iris.dylib md5 %s != %s" % (m, IRIS_DYLIB_MD5))
        return 2
    print("[iris-integrate] Frameworks/libmetallum_iris.dylib  %d B  md5 %s  OK"
          % (os.path.getsize(IRIS_DYLIB), m))

    a_order, a_data = read_entries(AGENT)
    m_order, m_data = read_entries(MOD)

    if r10:
        print("=" * 78)
        print("!! WARNING: --r10 会把 classes262iris 的 21 个类**回退**到 r10（比当前构建旧）。")
        print("!!          会丢: SHADER-CAP GL 扩展上报 / shadowColorFormats 打通 / /natives/ir1 路径。")
        print("=" * 78)
        zr = zipfile.ZipFile(r10)
        rcls = {n: zr.read(n) for n in zr.namelist() if n.endswith(".class")}
        ch = ad = 0
        for rel, blob in rcls.items():
            k = PREFIX + rel
            if k in a_data:
                if a_data[k] != blob:
                    a_data[k] = blob; ch += 1
            else:
                a_data[k] = blob; a_order.append(k); ad += 1
        m_data.update(rcls)
        print("[iris-integrate] r10 fallback applied: changed=%d added=%d (both channels)" % (ch, ad))

    if check_only:
        print("[iris-integrate] wiring already correct: agent_wired=%s mod_wired=%s"
              % (b"\x00\x0dmetallum_iris" in a_data[PREFIX + MNB],
                 b"\x00\x0dmetallum_iris" in m_data[MNB]))
    a_data[PREFIX + MNB], w1 = wire(a_data[PREFIX + MNB])
    m_data[MNB], w2 = wire(m_data[MNB])
    print("[iris-integrate] loadLibrary(\"metallum\") -> \"metallum_iris\": changed(agent=%s mod=%s)" % (w1, w2))

    ev = {
        "SHADER-CAP GL_EXTENSIONS": b"GL_EXTENSIONS" in a_data[PREFIX + "com/metallum/mixin/iris/GlStateManagerMixin.class"],
        "shadowColorFormats": b"shadowColorFormats" in a_data[PREFIX + "com/metallum/client/metal/render/IrisMetalWorldResources.class"],
        "iris native path /natives/ir1": IR1 in a_data[PREFIX + MNB],
    }
    print("[iris-integrate] iris 类集特征: %s" % ev)
    if not r10 and not all(ev.values()):
        print("[iris-integrate] NOTE: 有 False ⇒ 类集可能不是『比 r10 新』的那份（或已被改），请复核。")

    if check_only:
        return 0
    write_entries(AGENT, a_order, a_data)
    write_entries(MOD, m_order, m_data)
    print("[iris-integrate] written: agent entries=%d  mod entries=%d" % (len(a_order), len(m_order)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
