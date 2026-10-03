#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ★ [SHADER-BLAZE3D-GROUP] extract_blaze3d_group.py
#   「整组镜像」的【取源/建清单】工具（只在有 client-26.2.jar + agent jar 的机器跑，
#   即本 Windows 工作机；Mac 出包线【不跑】它，只消费已提交的 Natives/shader_glslang/blaze3d/**）。
#
#   背景：上一轮 pack_shader_glslang.py 把 blaze3d 镜像硬编码成 3 个固定名字
#   (GpuSurfaceBackend / CommandEncoderBackend / TransientMemory)，真机
#   latestlog-40.txt 立刻在下一层炸：
#       FLOW=ERR:java.lang.NoClassDefFoundError:
#                com/mojang/blaze3d/systems/GpuSurface$PresentMode      ← 内部类($)
#   ⇒ 要镜像的是一【整组】(引用闭包)，不是一个一个固定名字。
#
#   本工具：从 client-26.2.jar 取源，算出「agent jar 三个镜像根(classes262iris/ +
#   classes262/ + jar 根)下的 com/metallum/** 类 + 三个接口所直接/传递引用到的
#   com/mojang/blaze3d/**」闭包（= 出包下界，闭包保证「镜像里不会再出 blaze3d NCDFE」），
#   逐字节落到 Natives/shader_glslang/blaze3d/**，并写清单 Natives/shader_glslang/blaze3d_group.txt。
#
# ★★★ [BLAZE3D-ONDEMAND] 本工具算出的「组」只是【镜像源/清单】(体积不大, 保留)；
#   真正决定"define 与否"的是运行时 agent 侧的新规则 —— 「目标加载器能解析的就不定义,
#   只补真缺」(见 MetallumAgent.blaze3dResolvable / collectBlaze3dMissing)。
#   为什么: 真机 latestlog-41 (MC 26.2 + Fabric + Sodium + Iris) 证明 agent 把 129 个
#   镜像【无差别】define 进 knot 会:
#     (a) 对 knot 已加载的类抛 LinkageError:
#         "loader 'knot' attempted duplicate abstract class definition for ..."
#         (GpuSampler/GpuTexture/GpuTextureView/buffers/GpuFence/opengl/*/pipeline/
#          RenderTarget/shaders/ShaderSource/systems/GpuDeviceBackend/vulkan/* 等几十条);
#     (b) 对尚未加载的 mixin 靶子(VertexFormat)抢先裸定义 ⇒ 绕过 Sodium mixin ⇒ 启动崩:
#         java.lang.ClassCastException: class com.mojang.blaze3d.vertex.VertexFormat
#           cannot be cast to class ...sodium...VertexFormatExtensions
#   ⇒ agent 现在对每个候选类先 Class.forName(name,false,targetLoader) 探测:
#       能解析 ⇒ 跳过, 绝不 define;  CNFE/NCDFE ⇒ 才 define 镜像那份。
#   本机可用 --resolvable 生成"两个清单"静态证据(见下方 RESOLVABLE_OUT)。
#
#   用法（本机）:
#     python Natives/extract_blaze3d_group.py \
#         --client D:/CTF/client-26.2.jar \
#         --agent  D:/CTF/_510src/tree510/JavaApp/libs/others/metallum_agent.jar
#     python Natives/extract_blaze3d_group.py --check      # 只核对清单/源目录/闭包
import sys, os, zipfile, hashlib, argparse, datetime, re, struct

HERE = os.path.dirname(os.path.abspath(__file__))     # <tree>/Natives
TREE = os.path.dirname(HERE)                          # <tree>
SRC_DIR = os.path.join(HERE, "shader_glslang", "blaze3d")
MANIFEST = os.path.join(HERE, "shader_glslang", "blaze3d_group.txt")
# ★ [BLAZE3D-ONDEMAND] 「两个清单」静态证据产物: 每行 "<verdict>  <class>"
#   GAMEJAR-PROVIDED = 该类的【链接面依赖】都能由 client-26.2.jar 提供(⇒ 26.2/knot
#                       路径上会被 agent 探测判定"本就有", 绝不 define);
#   ABSENT           = 缺(仅在非 26.2 命名空间/无游戏 jar 的 loader 上才可能出现).
RESOLVABLE_OUT = os.path.join(HERE, "shader_glslang", "blaze3d_group_resolvable.txt")
MIXIN_TARGETS_OUT = os.path.join(HERE, "shader_glslang", "blaze3d_group_mixintargets.txt")

B3 = "com/mojang/blaze3d/"
PREFIXES = ["classes262iris/", "classes262/", ""]
IFACES = ["com/mojang/blaze3d/systems/GpuSurfaceBackend",
          "com/mojang/blaze3d/systems/CommandEncoderBackend",
          "com/mojang/blaze3d/systems/TransientMemory"]

# ★ [SHADER-BLAZE3D-GROUP] 参与「求组」的种子 = agent 真正会 define 进目标 loader 的类。
#    agent 的 collectClassNames 只收这几个前缀： com/mojang/blaze3d/ 、
#    org/lwjgl/sdl/ 、 com/metallum/shims/ 、 com/metallum/client/ (+ MTLCommandEncoder、
#    com/metallum/Metallum)。 com/metallum/mixin/** 与 agent/** 是 mod jar / mixin
#    框架提供的、agent【不】define —— 若把它们当种子，它们的 descriptor 会把
#    mixin 目标类 (opengl/GlStateManager、systems/RenderSystem) 拖进组里；而那些类
#    一旦被 agent 用 ClassLoader.defineClass 原始 define 进 Knot，就会【绕过
#    Fabric/Iris mixin 变换】（真机 GlStateManagerMixin 生效的证据：
#    `[metallum:gl] reporting 6 GL extension(s)`）。 故必须排除。
SEED_REST = ("com/metallum/client/",)
SEED_EXACT = ("com/metallum/Metallum",
              "com/metallum/client/metal/render/mtl/MTLCommandEncoder")
_L = re.compile(r"L(com/mojang/blaze3d/[A-Za-z0-9_$/]+);")


def parse_cp(data):
    """返回 (utf8{idx:str}, cls{idx:name_idx}, 常量池结束偏移)。"""
    n = struct.unpack(">H", data[8:10])[0]
    i, idx, utf8, cls = 10, 1, {}, {}
    while idx < n:
        tag = data[i]; i += 1
        if tag == 1:
            ln = struct.unpack(">H", data[i:i+2])[0]; i += 2
            utf8[idx] = data[i:i+ln].decode("utf-8", "replace"); i += ln
        elif tag in (3, 4):
            i += 4
        elif tag in (5, 6):
            i += 8; idx += 1
        elif tag == 7:
            cls[idx] = struct.unpack(">H", data[i:i+2])[0]; i += 2
        elif tag in (8, 16, 19, 20):
            i += 2
        elif tag in (9, 10, 11, 12, 17, 18):
            i += 4
        elif tag == 15:
            i += 3
        else:
            raise ValueError("bad cp tag %d" % tag)
        idx += 1
    return utf8, cls, i


def surface_refs(data):
    """★ [SHADER-BLAZE3D-GROUP] 一个类【链接面】上的 blaze3d 引用：
       超类 + 接口 + 字段/方法 descriptor + 泛型 Signature/字符串里的 L..; +
       方法 throws 子句(Exceptions 属性)。 故意【不含】方法体里的 CONSTANT_Class
       （body-only 引用）—— 反射 API 面需要解析的正是这些。"""
    utf8, cls, cp_end = parse_cp(data)
    refs = set()
    for s in utf8.values():
        for m in _L.findall(s):
            refs.add(m)
    off = cp_end + 6                       # access(2) this(2) super(2) -> ifc_count
    ifc = struct.unpack(">H", data[off:off+2])[0]; off += 2
    sup = struct.unpack(">H", data[cp_end+4:cp_end+6])[0]
    for ci in [sup] + [struct.unpack(">H", data[off+2*k:off+2*k+2])[0] for k in range(ifc)]:
        if ci and ci in cls:
            nm = utf8.get(cls[ci], "")
            if nm.startswith(B3):
                refs.add(nm)
    # --- 字段/方法属性里的 Exceptions(=throws) 引用 ---
    def cn(idx):
        return utf8.get(cls.get(idx, 0), "")
    p = off + 2 * ifc
    nf = struct.unpack(">H", data[p:p+2])[0]; p += 2
    for _ in range(nf):                      # field_info
        p += 6
        na = struct.unpack(">H", data[p:p+2])[0]; p += 2
        for _ in range(na):
            alen = struct.unpack(">I", data[p+2:p+6])[0]; p += 6 + alen
    nmethods = struct.unpack(">H", data[p:p+2])[0]; p += 2
    for _ in range(nmethods):                # method_info
        p += 6
        na = struct.unpack(">H", data[p:p+2])[0]; p += 2
        for _ in range(na):
            aidx = struct.unpack(">H", data[p:p+2])[0]
            alen = struct.unpack(">I", data[p+2:p+6])[0]
            if utf8.get(aidx) == "Exceptions":
                q = p + 6; cnt = struct.unpack(">H", data[q:q+2])[0]; q += 2
                for k in range(cnt):
                    nm = cn(struct.unpack(">H", data[q+2*k:q+2*k+2])[0])
                    if nm.startswith(B3):
                        refs.add(nm)
            p += 6 + alen
    return refs


def _seed_rest(name):
    for pfx in PREFIXES:
        if pfx and name.startswith(pfx):
            return name[len(pfx):]
        if pfx == "" and not name.startswith("classes"):
            return name
    return None


def agent_seeds(agent_jar):
    """★ 返回 (种子集合, {种子类: 其链接面 blaze3d 引用})。"""
    z = zipfile.ZipFile(agent_jar)
    seeds, who = set(IFACES), {}
    for info in z.infolist():
        n = info.filename
        if not n.endswith(".class"):
            continue
        rest = _seed_rest(n)
        if not rest:
            continue
        if not (rest.startswith(SEED_REST) or rest in SEED_EXACT):
            continue
        refs = surface_refs(z.read(n))
        if refs:
            who[rest] = refs
            seeds |= refs
    z.close()
    return seeds, who


def closure(client_jar, seeds):
    """★ 链接面传递闭包（闭 = 组内任一成员的链接面引用都在组内）。"""
    z = zipfile.ZipFile(client_jar)
    names = set(i.filename for i in z.infolist())
    seen, missing, stack = set(), set(), sorted(seeds)
    while stack:
        c = stack.pop()
        if c in seen:
            continue
        e = c + ".class"
        if e not in names:
            missing.add(c)
            continue
        seen.add(c)
        for x in surface_refs(z.read(e)):
            if x not in seen:
                stack.append(x)
    z.close()
    return seen, missing


def md5s(b):
    return hashlib.md5(b).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--client", default=os.environ.get("METALLUM_CLIENT_JAR",
                    r"D:\CTF\client-26.2.jar"))
    ap.add_argument("--agent", default=os.environ.get("METALLUM_AGENT_JAR",
                    os.path.join(TREE, "JavaApp", "libs", "others", "metallum_agent.jar")))
    ap.add_argument("--check", action="store_true")
    # ★ [BLAZE3D-ONDEMAND] 生成「两个清单」静态证据(每行 "<verdict>  <class>"):
    #   对 --client(26.2, knot 能看到游戏 jar) = 绝大多数 GAMEJAR-PROVIDED;
    #   若给 --client-alt(如 client-26.3.jar, renderpearl 家族无 blaze3d) 再出一份,
    #   二者之差即运行时「本就有(跳过)」 vs 「真缺(补镜像)」的清单。
    ap.add_argument("--resolvable", action="store_true")
    ap.add_argument("--client-alt", default=None)
    a = ap.parse_args()

    for p, lbl in ((a.client, "client jar"), (a.agent, "agent jar")):
        if not os.path.isfile(p):
            print("FATAL: %s not found: %s" % (lbl, p)); return 2

    seeds, who = agent_seeds(a.agent)
    group, missing = closure(a.client, seeds)
    group = sorted(group)
    cz = zipfile.ZipFile(a.client)
    total = sum(len(cz.read(c + ".class")) for c in group)
    cz.close()

    print("[group] metallum classes with blaze3d refs : %d" % len(who))
    print("[group] seeds (direct)                     : %d" % len(seeds))
    print("[group] closure (group size)                : %d" % len(group))
    print("[group] closure bytes (single copy)         : %d" % total)
    print("[group] dangling (in refs, absent in client): %d %s"
          % (len(missing), sorted(missing) if missing else ""))
    if missing:
        print("FATAL: closure has dangling blaze3d refs -> 镜像后仍会 NCDFE"); return 2
    for must in ("com/mojang/blaze3d/systems/GpuSurface$PresentMode",
                 "com/mojang/blaze3d/systems/GpuSurface",
                 "com/mojang/blaze3d/systems/GpuSurface$Configuration"):
        if must not in group:
            print("FATAL: expected member missing from group: %s" % must); return 2
    # ★ [SHADER-BLAZE3D-GROUP] 安全断言：组内不得含 mixin 目标本体
    #   （agent 用原始 defineClass 把它们 define 进 Knot 会绕过 Fabric/Iris mixin；
    #    真机证据：GlStateManagerMixin 生效打出 `[metallum:gl] reporting 6 GL extension(s)`）。
    MIXIN_TARGETS = ("com/mojang/blaze3d/opengl/GlStateManager",
                     "com/mojang/blaze3d/systems/RenderSystem")
    bad = [c for c in group if c in MIXIN_TARGETS]
    if bad:
        print("FATAL: group contains mixin-target classes (would bypass mixins): %s" % bad)
        return 2
    # ★ [BLAZE3D-ONDEMAND] 另一类 mixin 靶子【确实在组内】(闭包需要它们), 由 agent 侧
    #   硬黑名单 + 运行时探测兜底: VertexFormat 是 Sodium VertexFormatMixin 的靶子,
    #   被原始 define 会绕过 mixin ⇒ 真机 ClassCastException(见文件头)。这里只做【提示】,
    #   不 FATAL(闭包下界仍要保留它们给"没有游戏 jar"的 loader 兜底)。
    MIXIN_TARGETS_IN_GROUP = ("com/mojang/blaze3d/vertex/VertexFormat",
                              "com/mojang/blaze3d/vertex/VertexFormatElement")
    mtg = sorted(c for c in group if c in MIXIN_TARGETS_IN_GROUP)
    print("[group] mixin-targets-in-group (agent hard-skips, runtime-probe backs up): %s" % (mtg or "none"))
    with open(MIXIN_TARGETS_OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("# ★ [BLAZE3D-ONDEMAND] 组内 mixin 靶子 —— agent BLAZE3D_MIXIN_TARGETS 硬跳过,\n")
        f.write("#   运行时再经 Class.forName 探测(能解析即跳过), 两者都保证【绝不原始 define】。\n")
        for c in mtg:
            f.write(c + "\n")

    # ★ [BLAZE3D-ONDEMAND] --resolvable: 生成「两个清单」静态证据(不写源目录, 不碰清单)。
    if a.resolvable:
        def _classify(jar_path):
            res = {}
            if not jar_path or not os.path.isfile(jar_path):
                return res
            zz = zipfile.ZipFile(jar_path)
            have = set(zz.namelist())
            for c in group:
                ok = (c + ".class") in have
                if ok:
                    for d in surface_refs(zz.read(c + ".class")):
                        if (d + ".class") not in have:
                            ok = False
                            break
                res[c] = "GAMEJAR-PROVIDED" if ok else "ABSENT"
            zz.close()
            return res
        primary = _classify(a.client)
        with open(RESOLVABLE_OUT, "w", encoding="utf-8", newline="\n") as f:
            f.write("# ★ [BLAZE3D-ONDEMAND] 两个清单(静态; 依据 %s)\n" % os.path.basename(a.client))
            f.write("# GAMEJAR-PROVIDED = 游戏 jar 能提供 ⇒ 26.2/knot 上 agent 探测判定「本就有」, 绝不 define\n")
            for c in group:
                f.write("%-16s %s\n" % (primary.get(c, "?"), c))
        npv = sum(1 for v in primary.values() if v == "GAMEJAR-PROVIDED")
        print("[resolvable] %s: GAMEJAR-PROVIDED=%d ABSENT=%d (of %d)"
              % (os.path.basename(a.client), npv, len(group) - npv, len(group)))
        if a.client_alt and os.path.isfile(a.client_alt):
            alt = _classify(a.client_alt)
            nav = sum(1 for v in alt.values() if v == "GAMEJAR-PROVIDED")
            miss = sorted(c for c in group if alt.get(c) != "GAMEJAR-PROVIDED")
            print("[resolvable] %s: GAMEJAR-PROVIDED=%d ABSENT=%d (of %d)"
                  % (os.path.basename(a.client_alt), nav, len(group) - nav, len(group)))
            altout = RESOLVABLE_OUT.replace(".txt", "_vs_%s.txt" % os.path.basename(a.client_alt).replace(".jar", ""))
            with open(altout, "w", encoding="utf-8", newline="\n") as f:
                f.write("# 真缺清单(依据 %s, 该命名空间没有这些类 ⇒ 需 define 镜像): %d\n"
                        % (os.path.basename(a.client_alt), len(miss)))
                for c in miss:
                    f.write(c + "\n")
            print("[resolvable] wrote %s" % altout)
        print("[resolvable] wrote %s" % RESOLVABLE_OUT)
        return 0

    # load manifest
    man = {}
    if os.path.isfile(MANIFEST):
        for ln in open(MANIFEST, encoding="utf-8"):
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            h, sz, nm = ln.split(None, 2)
            man[nm] = (h, int(sz))
    msrc = set(man)

    if a.check:
        gs = set(group)
        if msrc != gs:
            print("FATAL: manifest != computed group  (manifest %d / computed %d)"
                  % (len(msrc), len(gs)))
            print("  only-manifest:", sorted(msrc - gs)[:10])
            print("  only-computed:", sorted(gs - msrc)[:10])
            return 2
        bad = []
        for nm, (h, sz) in sorted(man.items()):
            p = os.path.join(SRC_DIR, nm + ".class")
            if not os.path.isfile(p):
                bad.append("MISSING-SRC " + nm); continue
            b = open(p, "rb").read()
            if len(b) != sz or md5s(b) != h:
                bad.append("SRC-MISMATCH " + nm)
        if bad:
            print("FATAL: source dir mismatch: %s" % bad[:20]); return 2
        print("[group] CHECK OK: manifest=%d, src-dir byte-identical, closure closed" % len(man))
        return 0

    # ---- materialize source dir + manifest (idempotent) ----
    cz = zipfile.ZipFile(a.client)
    for c in group:
        b = cz.read(c + ".class")
        p = os.path.join(SRC_DIR, c + ".class")
        os.makedirs(os.path.dirname(p), exist_ok=True)
        if (not os.path.isfile(p)) or open(p, "rb").read() != b:
            open(p, "wb").write(b)
    cz.close()
    # prune stale sources not in the group (keep verify_exports.py etc.)
    for dp, _dn, fns in os.walk(SRC_DIR):
        for fn in fns:
            if not fn.endswith(".class"):
                continue
            rel = os.path.relpath(os.path.join(dp, fn), SRC_DIR).replace(os.sep, "/")[:-6]
            if rel not in group:
                os.remove(os.path.join(dp, fn))
    with open(MANIFEST, "w", encoding="utf-8", newline="\n") as f:
        f.write("# ★ [SHADER-BLAZE3D-GROUP] blaze3d mirror group manifest (auto-generated)\n")
        f.write("# src = client-26.2.jar  com/mojang/blaze3d/**  (API-surface closure of the\n")
        f.write("#       classes the agent force-defines: com/metallum/client/** + 3 ifaces)\n")
        f.write("# keys: surface_direct=%d  group=%d  bytes=%d\n" % (len(seeds), len(group), total))
        f.write("# generated = %s\n" % datetime.datetime.now().isoformat(timespec="seconds"))
        f.write("# <md5>  <size>  <class-name>\n")
        for c in group:
            b = open(os.path.join(SRC_DIR, c + ".class"), "rb").read()
            f.write("%s  %8d  %s\n" % (md5s(b), len(b), c))
    print("[group] wrote %d classes -> %s" % (len(group), SRC_DIR))
    print("[group] wrote manifest -> %s" % MANIFEST)
    return 0


if __name__ == "__main__":
    sys.exit(main())
