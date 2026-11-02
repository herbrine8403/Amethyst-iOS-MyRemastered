#!/bin/bash
# Build libjnidispatch.dylib (JNA 5.13.0) for iOS arm64.
#
# Why: the app passes -Djna.boot.library.path=<app>/Frameworks and MinecraftResourceUtils.m
# pins JNA to 5.13.0, but no signed libjnidispatch was shipped. JNA then extracts its own
# native lib into the data container, which TXM devices refuse to dlopen ("code signature
# invalid"). Shipping this dylib in Frameworks/ lets it be signed with the app.
#
# Usage (macOS with Xcode + a JDK for `javac -h`):
#   scripts/build_jnidispatch_ios.sh [output.dylib]
# Env: JNA_TAG (default 5.13.0), MIN_IOS (default 14.0), WORKDIR, JNI_INCLUDE (dir with
#      jni.h + jni_md.h; default derived from javac), JNA_HDR_DIR (pre-generated
#      com_sun_jna_*.h; if unset they are generated with `javac -h`).
set -euo pipefail

JNA_TAG="${JNA_TAG:-5.13.0}"
MIN_IOS="${MIN_IOS:-14.0}"
WORKDIR="${WORKDIR:-$(mktemp -d)}"
OUT="${1:-$PWD/libjnidispatch.dylib}"
mkdir -p "$WORKDIR"; cd "$WORKDIR"

[ -d jna ] || git clone -q --depth 1 --branch "$JNA_TAG" https://github.com/java-native-access/jna.git
N="$PWD/jna/native"; F="$N/libffi"

# JNI version/checksum must match com.sun.jna.Native.VERSION_NATIVE. native/Makefile carries
# stale defaults (5.1.0), the authoritative values live in build.xml.
major=$(sed -n 's/.*name="jni.major" value="\([0-9]*\)".*/\1/p' jna/build.xml)
minor=$(sed -n 's/.*name="jni.minor" value="\([0-9]*\)".*/\1/p' jna/build.xml)
rev=$(sed -n 's/.*name="jni.revision" value="\([0-9]*\)".*/\1/p' jna/build.xml)
md5=$(sed -n 's/.*name="jni.md5" value="\([0-9a-f]*\)".*/\1/p' jna/build.xml)
JNI_VERSION="$major.$minor.$rev"
echo "[jnidispatch] JNA $JNA_TAG native version $JNI_VERSION checksum $md5"

# JNI headers
if [ -z "${JNI_INCLUDE:-}" ]; then
  JH=$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")
  JNI_INCLUDE="$JH/include"
fi
HDR="${JNA_HDR_DIR:-$PWD/hdr}"
if [ -z "${JNA_HDR_DIR:-}" ]; then
  mkdir -p hdr cls
  javac -h hdr -d cls -nowarn -proc:none \
    $(find jna/src -name '*.java' -path '*com/sun/jna/*' ! -path '*/win32/*' ! -path '*/platform/*') 2>/dev/null
fi

# libffi sources for iOS (generator needs no autotools for the arm64 slice)
( cd "$F" && python3 generate-darwin-source-and-headers.py --only-ios >/dev/null 2>&1 || true )
[ -f "$F/darwin_ios/src/aarch64/ffi_arm64.c" ] || { echo "libffi iOS sources not generated" >&2; exit 1; }

W="$PWD/work"; rm -rf "$W"; mkdir -p "$W/inc" "$W/obj"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=(xcrun --sdk iphoneos clang -arch arm64 "-miphoneos-version-min=$MIN_IOS" -isysroot "$SDK")

sed -e 's/@VERSION@/3.4.4/' -e 's/@TARGET@/AARCH64/' -e 's/@HAVE_LONG_DOUBLE@/0/' \
    -e 's/@HAVE_LONG_DOUBLE_VARIANT@/0/' -e 's/@FFI_EXEC_TRAMPOLINE_TABLE@/1/' \
    "$F/include/ffi.h.in" > "$W/inc/ffi.h"
cp "$F/src/aarch64/ffitarget.h" "$W/inc/"
cat > "$W/inc/fficonfig.h" <<'EOC'
#define EH_FRAME_FLAGS "aw"
#define FFI_EXEC_TRAMPOLINE_TABLE 1
#define HAVE_INTTYPES_H 1
#define HAVE_MEMCPY 1
#define HAVE_MMAP 1
#define HAVE_MMAP_ANON 1
#define HAVE_MMAP_FILE 1
#define HAVE_MMAP_DEV_ZERO 0
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_MMAN_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HAVE_ALLOCA_H 1
#define STDC_HEADERS 1
#define SYMBOL_UNDERSCORE 1
#define VERSION "3.4.4"
#ifdef __ASSEMBLER__
#define FFI_HIDDEN(name) .private_extern name
#else
#define FFI_HIDDEN __attribute__((visibility("hidden")))
#endif
EOC
# note: HAVE_AS_CFI_PSEUDO_OP is intentionally left undefined (clang rejects the
# ".cfi_adjust_cfa_offset" expressions in sysv_arm64.S); only unwind info for ffi frames is lost.

INC=(-I"$W/inc" -I"$F/darwin_common/include" -I"$F/darwin_ios/src/aarch64" -I"$F/include" -I"$JNI_INCLUDE" -I"$JNI_INCLUDE/darwin" -I"$HDR")
COMMON=(-O2 -fPIC -fvisibility=hidden -DFFI_STATIC_BUILD -D_REENTRANT)

for f in prep_cif types raw_api java_raw_api closures tramp debug; do
  "${CC[@]}" "${COMMON[@]}" "${INC[@]}" -w -c "$F/darwin_common/src/$f.c" -o "$W/obj/$f.o"
done
"${CC[@]}" "${COMMON[@]}" "${INC[@]}" -w -c "$F/darwin_ios/src/aarch64/ffi_arm64.c" -o "$W/obj/ffi_arm64.o"
"${CC[@]}" "${COMMON[@]}" "${INC[@]}" -c "$F/darwin_ios/src/aarch64/sysv_arm64.S" -o "$W/obj/sysv_arm64.o"

JNA_DEFS=(-DJNA_JNI_VERSION="\"$JNI_VERSION\"" -DCHECKSUM="\"$md5\"" -DNO_JAWT -DNO_WEAK_GLOBALS
          -DFFI_MMAP_EXEC_WRIT -DHAVE_PROTECTION -DTARGET_RT_MAC_CFM=0)
for f in dispatch callback; do
  "${CC[@]}" "${COMMON[@]}" "${INC[@]}" "${JNA_DEFS[@]}" -x objective-c -w -c "$N/$f.c" -o "$W/obj/$f.o"
done

"${CC[@]}" -dynamiclib -install_name @rpath/libjnidispatch.dylib \
  -compatibility_version "$major.0.0" -current_version "$JNI_VERSION" \
  -framework Foundation -o "$W/libjnidispatch.dylib" "$W"/obj/*.o
codesign -f -s - "$W/libjnidispatch.dylib" >/dev/null 2>&1 || true
cp "$W/libjnidispatch.dylib" "$OUT"
echo "[jnidispatch] wrote $OUT"
vtool -show-build "$OUT" | sed -n 1,6p
