#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ★ [SHADER-GLSLANG] 静态符号核验（无需 Xcode / nm / otool）：
#   解析 Mach-O(arm64) 的 LC_SYMTAB 与 LC_BUILD_VERSION，核对 glslang C API 导出面。
#   用法:  python3 Natives/shader_glslang/verify_exports.py <dylib> [--mac-ref <other.dylib>]
#   对齐真机要求: GlslangBridge.<clinit> 需要的 17 个 glslang_* ；
#                 shaderc_shim 的 dladdr 另找 2 个 C++ mangled(可选)。
import sys, struct, hashlib

REQUIRED_C = [
    "glslang_default_resource", "glslang_initialize_process",
    "glslang_program_SPIRV_generate", "glslang_program_SPIRV_get",
    "glslang_program_SPIRV_get_size", "glslang_program_add_shader",
    "glslang_program_create", "glslang_program_delete", "glslang_program_get_info_log",
    "glslang_program_link", "glslang_shader_create", "glslang_shader_delete",
    "glslang_shader_get_info_debug_log", "glslang_shader_get_info_log",
    "glslang_shader_parse", "glslang_shader_preprocess", "glslang_shader_set_options",
]
OPTIONAL_CPP = ["__ZN7glslang17InitializeProcessEv", "__ZN7glslang15FinalizeProcessEv"]
PLAT = {1: 'macOS', 2: 'iOS', 3: 'tvOS', 6: 'MacCatalyst', 7: 'iOSSimulator', 11: 'visionOS'}


def parse(path):
    b = open(path, 'rb').read()
    magic, cputype, cpusub, ftype, ncmds, sizeofcmds, flags, _ = struct.unpack_from('<8I', b, 0)
    assert magic == 0xfeedfacf, "not 64-bit Mach-O"
    off, symoff, nsyms, stroff, strsize = 32, 0, 0, 0, 0
    idname = None
    plat = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', b, off)
        if cmd == 0x2:  # LC_SYMTAB
            v = struct.unpack_from('<6I', b, off); symoff, nsyms, stroff, strsize = v[2], v[3], v[4], v[5]
        elif cmd == 0xd:  # LC_ID_DYLIB
            no = struct.unpack_from('<I', b, off + 8)[0]
            idname = b[off+no:off+cmdsize].split(b'\x00')[0].decode('utf-8', 'replace')
        elif cmd == 0x32:  # LC_BUILD_VERSION
            p, minos = struct.unpack_from('<2I', b, off + 8)[:2]
            plat = "platform=%d(%s) minos=%d.%d" % (p, PLAT.get(p, '?'), minos >> 16, (minos >> 8) & 0xff)
        off += cmdsize
    syms = set()
    for i in range(nsyms):
        strx, ntype, nsect, ndesc, nval = struct.unpack_from('<IBBHQ', b, symoff + i * 16)
        if (ntype & 0x01) and (ntype & 0x0e) != 0 and nval:
            s = b[stroff+strx:stroff+strsize].split(b'\x00')[0].decode('utf-8', 'replace')
            syms.add(s)
            if s.startswith('_'):
                syms.add(s[1:])   # macOS 的 C 符号带一个前导下划线；C++ 带两个(__Z..)
    return b, syms, idname, plat


def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    path = sys.argv[1]
    b, syms, idname, plat = parse(path)
    print("== %s" % path)
    print("   size   = %d B   md5 = %s" % (len(b), hashlib.md5(b).hexdigest()))
    print("   arch   = arm64 (Mach-O 64-bit dylib)")
    print("   build  = %s" % plat)
    print("   LC_ID  = %s" % idname)
    miss = [s for s in REQUIRED_C if s not in syms]
    for s in REQUIRED_C:
        print("   [%s] %s" % ("OK " if s in syms else "MISS", s))
    print("   -> required C-API: %d/%d %s" % (len(REQUIRED_C) - len(miss), len(REQUIRED_C),
                                              "ALL PRESENT" if not miss else ("MISSING " + str(miss))))
    for s in OPTIONAL_CPP:
        print("   [%s] %s (shaderc_shim dladdr, optional)" % ("OK " if s in syms else "--", s))
    if "--mac-ref" in sys.argv:
        ref = sys.argv[sys.argv.index("--mac-ref") + 1]
        rb = open(ref, 'rb').read()
        print("   ref    = %s  md5=%s  ->  %s" % (ref, hashlib.md5(rb).hexdigest(),
                                                  "IDENTICAL" if rb == b else "DIFFERENT"))
    return 1 if miss else 0


if __name__ == "__main__":
    sys.exit(main())
