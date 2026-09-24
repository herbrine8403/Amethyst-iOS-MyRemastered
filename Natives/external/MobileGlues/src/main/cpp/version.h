// MobileGlues - version.h
// Copyright (c) 2025-2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v2.1:
//   https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt
// SPDX-License-Identifier: LGPL-2.1-only
// End of Source File Header

#ifndef MOBILEGLUES_VERSION_H

#define VERSION_DEVELOPMENT 0
#define VERSION_ALPHA 1
#define VERSION_BETA 2
#define VERSION_RC 3
#define VERSION_RELEASE 10

#define MAJOR 2
#define MINOR 0
// 0 -> 1: force-invalidate the on-disk GLSL conversion cache. The 2.0.0 builds
// that shipped with a mis-populated 3rdparty/ tree cached ESSL that ANGLE-Metal
// rejects with "ERROR: 1:1: '' : syntax error"; the cache key embeds
// MAJOR.MINOR.REVISION, so this bump makes every device discard those entries
// on first run instead of re-serving them.
// 1 -> 2: iOS host-driver binding rework (explicit ANGLE dlopen instead of the
// RTLD_DEFAULT free-for-all) + per-shader submit/readback records. The bump
// invalidates cached conversion results once more and, more importantly, makes
// "MobileGlues 2.0.2" visible in the runtime log so a stale dylib in the IPA
// is instantly obvious.
// 2 -> 3: mg_init_gles() now pins the GL ES table to the REAL ANGLE libGLESv2
// instead of libtinygl4angle, whose glShaderSource does not forward into
// ANGLE's object namespace (every pipeline died with "ERROR: 1:1: ''" and a
// zero-byte driver readback). Shader conversions now ALWAYS run on the
// dedicated 32 MB-stack thread (the >= 8 MB inline fast path depended on the
// caller's stack-size report and could still overflow inside glslang).
// 3 -> 4: process_sampler_buffer() rewrote texelFetch argument lists with a
// [^)]+? regex that truncated at the first ')', shredding any coordinate with
// nested calls. Sodium 0.9.x's
//     texelFetch(u_SectionTimeInfo, int((u_RegionID * 256u) + uint(chunkId)))
// became 'temp uint % uniform int' garbage -> glslang parse failure -> every
// Sodium terrain pipeline invalid -> no blocks rendered. Rewritten with a
// paren-depth scanner; coordinates now also pass through int(...) so
// driver-lenient uint indices cannot re-mix sign with u_BufferTexWidth.
// REVISION 6: stage-tagged SIGSEGV crash-site report + optimizer-disabled
// retry on the conversion thread.
// REVISION 7: buffer-texture emulation runtime repair. (1) Draw-time sampler
// rewiring now repoints ONLY the samplers converted from samplerBuffer at the
// emulation unit; it used to repoint every sampler2D in the program, which on
// Sodium 0.9's chunk program hijacked the block atlas (u_BlockTex) and light
// map (u_LightTex) onto the section-info texture -- every chunk fragment then
// discarded itself below ALPHA_CUTOUT and the whole terrain vanished
// (MobileGlues-release issue #432). (2) The snapshot is refreshed whenever the
// backing buffer is mutated (glBufferData/glBufferSubData/glUnmapBuffer/
// glBufferStorage); it used to be taken exactly once at glTexBuffer. (3) The
// GL_TEXTURE_BUFFER binding point no longer reaches an ES 3.0/3.1 driver (it
// answered GL_INVALID_ENUM there, silently swallowing every mutation MC issued
// through that target); it is tracked here and the mutations borrow
// GL_COPY_WRITE_BUFFER instead.
// REVISION 8: glslang emission-side swizzle null guards. Device log 2.0.7:
// 264 conversions SIGSEGV'd at ONE site -- (anon)::TGlslangToSpvTraverser::
// convertSwizzle+0x1c via visitBinary+0x1318 (symbolicated from the crash-site
// report, pc-libmobileglues+0x24a838) -- the selector aggregate read as
// missing/malformed on iOS/arm64 for inputs that convert cleanly under
// x86_64/qemu-arm64/ASan and converted fine in the 2.0.6 process. Same defect
// family as the 2.0.1-2.0.3 lValueErrorCheck kill, one stage later. The
// nullguard patch now covers SPIRV/GlslangToSpv.cpp: convertSwizzle returns
// bool and rejects unusable selectors (null/non-constant element, out-of-range
// index) instead of dereferencing them, and both call sites (visitBinary
// EOpVectorSwizzle, createInvertedSwizzle) fall back to the identity swizzle
// of the result's component count. Byte-identical output vs pristine glslang
// on all swizzle-heavy positive tests and every edge-case candidate.
// REVISION 9: MC 26.x transparency-pipeline depth-path hardening + device
// diagnostics. The game's clouds/weather/particles are composited by
// post/transparency.fsh, which per-pixel-sorts six layers (main + five
// dedicated FBOs, each with its own D32F depth texture) and blends far to
// near. If any depth texture reads garbage the sort degenerates to insertion
// order and the last layer -- clouds -- draws over everything, including from
// underground. A locally built libmobileglues (Linux) replaying the exact
// blaze3d call sequence against a conformant ES 3.0 driver (Mesa llvmpipe)
// passes every hop end to end: D32F allocation, D32F sampling, reversed-Z
// draw, copyDepthFrom's depth-only glBlitFramebuffer (byte-exact), composite
// sort. So the on-device breakage is a per-driver divergence this layer must
// flatten. Two changes: (1) glFramebufferTexture2D redirects depth-ONLY
// textures attached at GL_DEPTH_STENCIL_ATTACHMENT to GL_DEPTH_ATTACHMENT and
// detaches the stencil point. blaze3d's fallback DirectStateAccess attaches
// every depth texture at the combined point; strict drivers (Mesa, measured)
// answer FRAMEBUFFER_INCOMPLETE_ATTACHMENT for a depth-only image there, and
// the lenient drivers that accept it are left with a stencil attachment
// pointing at a stencil-less image. (2) One-shot W_FORCE diagnostics on the
// first depth-texture allocation (driver-reported internalformat/depth/
// stencil bits), the first combined-point depth+stencil attach (driver
// completeness verdict), the first DEPTH blit (both FBOs' completeness +
// error verdict), and the first draw of the composite program (all twelve
// sampler uniforms with unit, texture name and internalformat). Together
// these grade every hop the composite depends on directly from a device log.
// REVISION 10: 2.0.9 device log results -- the depth blit (copyDepthFrom) is
// healthy on device (both FBOs complete, GL_NO_ERROR), but the combined-point
// redirect never fired AND the composite sampler dump never fired. Two
// corrections and one new probe. (1) Constant correction: 36096 is
// GL_DEPTH_ATTACHMENT, not GL_DEPTH_STENCIL_ATTACHMENT -- MC attaches depth
// directly at GL_DEPTH_ATTACHMENT and the 2.0.9 combined-point redirect is
// dead code for this application (kept for spec hygiene). The attach
// diagnostic now grades the FIRST EIGHT depth-family attaches at whichever
// point they actually use, with the registry's view of each texture. (2) The
// depth-allocation probe read GL_TEXTURE_INTERNAL_FORMAT, which is not an
// ES 3.0 pname (ANGLE rejects it; Mesa tolerates it), so its zeros were
// ambiguous. Rewritten to separate the three confounded things per
// allocation: the shadow's texture, the DRIVER's texture on the active unit,
// the upload's own error, and GL_TEXTURE_DEPTH_SIZE of what the driver
// actually has. (3) The composite dump never fired because nothing verified
// the composite draws reach this layer's glDrawArrays at all; a 24-draw
// census plus a depth-sampler dump keyed on any program with a "Depth"-named
// sampler2D now grades reachability and the composite's inputs together.
// (4) One-shot symbol-theft check in glXGetProcAddress: the app-facing proc
// addresses come from dlsym(RTLD_DEFAULT), whose flat namespace also holds
// the host ANGLE libGLESv2; if dyld's image order ever lets ANGLE win a name
// this layer exports, the application bypasses this layer for that function
// entirely.
// REVISION 11: 2.0.10 device log results + the real reason the composite was
// never observed. The log graded three things: depth allocations healthy
// (shadow == driver binding, upload clean), depth blit healthy (both FBOs
// complete, GL_NO_ERROR), no symbol theft -- and the draw census answered a
// question nobody had asked: every one of the first 24 programs was first
// seen on "other draw", meaning MC 26.2 never issues plain glDrawArrays or
// glDrawElements at all. Disassembling the shipped client.jar's
// GlCommandEncoder.drawFromBuffers confirms it: the non-indexed branch is
// glDrawArraysInstanced / glDrawArraysInstancedBaseInstance, the indexed one
// glDrawElementsInstancedBaseVertex(_BaseInstance) -- there is NO plain
// glDrawArrays branch, so the transparency composite (a 3-vertex, 1-instance
// non-indexed draw) sailed through the glDrawArraysInstanced native
// passthrough without ever reaching prepareForDraw: no TBO sampler rewiring
// for any instanced draw, and no diagnostic could ever see the composite's
// inputs. (1) glDrawArraysInstanced moved from the native table into
// gl/drawing.cpp behind prepareForDraw(3); glDrawArraysInstancedBaseInstance
// now tags prepareForDraw(4); the ARB alias the NATIVE_FUNCTION_HEAD macro
// used to emit is kept. (2) The depth-family attach census turned out to
// query glCheckFramebufferStatus BEFORE the forward -- its odd 0x8cd7 rows
// measured the pre-attach emptiness of fresh temp fbos, not driver verdicts;
// it now runs after the forward and records the attach error plus the
// color0/depth attachment object names. (3) The depth blit gets a content
// probe: for the first two DEPTH blits, five depth texels are read back from
// both sides and logged -- NO_ERROR says the driver accepted the copy, only
// the values say the data moved. (4) The depth-sampler program dump (now
// reachable through the instanced hooks) grades per sampler: unit, shadow and
// driver texture, registry internal format, the texture's own MIN/MAG filter,
// and any bound sampler object's MIN/MAG filter -- sampling depth with a
// LINEAR filter is the classic silent killer on strict ES drivers (an
// unfilterable depth texture reads black, which in reversed-z is "infinitely
// far" and un-occludes everything), and the draw fbo's color0/depth
// attachments are logged with it.
// REVISION 12: 2.0.11 device log results + the root cause of the transparency
// occlusion break (clouds visible through terrain, underground clouds, water/
// particles/weather sorting against nothing). The log closed the case with the
// depth-sampler dump: the composite program's twelve sampler2D uniforms all
// have one SamplerCache sampler object bound over them whose MIN filter is
// GL_LINEAR_MIPMAP_NEAREST (9986) -- with the dump's 9728/9729 labels fixed,
// its MAG is GL_NEAREST, and the "LINEAR" the 2.0.11 log printed for MIN was
// the value 9986, not a NEAREST/linear mistake on MC's part. 9986 is what
// Mojang's GlSampler deliberately emits for minFilter=NEAREST (LINEAR goes to
// 9987), kept pointed at level 0 by TEXTURE_MAX_LEVEL=0 on the texture and the
// sampler's own MAX_LOD=0. The within-level part of 9986 is a LINEAR sample,
// and GLES 3.0 does not filter depth images (desktop GL does, which is why the
// same state renders fine on PC): on ANGLE Metal the composite's depth samples
// are undefined and read 0.0, which in reversed-z is "infinitely far", so
// every layer-vs-layer sort degenerates and the last-blended clouds layer
// wins over everything. The dump's own filter table had GL_NEAREST/GL_LINEAR
// swapped, which is why 2.0.11's log reads as MAG=LINEAR at first glance --
// fixed here so the next log is readable. The fix, desktop semantics on ES:
// (1) every depth-family allocation (TexImage2D/3D, TexStorage2D/3D) joins a
// depth registry and gets MIN/MAG = NEAREST on the texture object itself;
// (2) glTexParameteri/glTexParameterf aimed at a registered depth texture
// cannot set anything but NEAREST for MIN/MAG; (3) the sampler objects are
// now tracked (glGenSamplers/glDeleteSamplers/glBindSampler/glSamplerParameteri/
// glSamplerParameterf moved from the native table into gl/texture.cpp, ARB
// aliases kept), and prepareForDraw forces a bound sampler's driver-side
// MIN/MAG to NEAREST exactly while any unit it is bound on holds a depth
// image, restoring the application's parameters on the first draw where the
// pairing no longer holds (two-pass per draw so one cache sampler shared by a
// colour and a depth unit in the same composite draw converges on forced);
// comparison-mode samplers are left alone so hardware PCF is untouched; the
// enforcement is skipped while FSR1 makes the per-unit binding shadow
// untrustworthy. Retired diagnostics that had answered their questions: the
// 24-program draw census, the depth-family attach census, and the depth blit
// content probe (ANGLE Metal refuses every depth glReadPixels with
// GL_INVALID_OPERATION, so a probe can only report its own refusal). The
// depth-sampler program dump stays, with the corrected filter names, and the
// force/restore transitions log their first eight occurrences.
// REVISION 13: 2.0.12 device log results + why the depth-filter enforcement
// never armed where it was needed. The log shows deployment healthy, the
// composite dump firing (program 197, twelve sampler2D inputs, one SamplerCache
// sampler 26 bound across all of them, MIN 9986, six D32F depth textures whose
// texture-object filters read NEAREST/NEAREST from fix (1)) -- and not one
// "depth filter force" line. The enforcement's precondition,
// driver_texture_shadow_trustworthy(), is false on the iOS/ANGLE host for a
// reason nothing had exercised before: the app talks to ANGLE's libEGL
// directly, so mg_texture_bind_context never fires and the texture layer sits
// on the shared fallback record forever -- the same precondition the TBO
// rewiring survives by falling back to a direct driver query, which the
// enforcement lacked. (The dump's "tex 0/9" rows are this gate refusing to
// answer, not an empty binding map.) Fix: two modes in
// mg_enforce_depth_sampling_nearest. Tracked mode is 2.0.12 unchanged. The
// untracked mode treats the fallback record as a HINT -- every hooked bind
// still maintains it, and the decompiled GlCommandEncoder shows MC 26.2 binds
// textures exclusively through _activeTexture/_bindTexture/glBindSampler, all
// hooked -- and confirms every depth hint against the driver
// (glActiveTexture + GL_TEXTURE_BINDING_2D, borrowed and restored via the
// GLES entry points directly) before a filter may be forced. A stale hint
// costs a rejected confirmation; acting on the record alone is what the
// layer's invariant forbids. FSR1 keeps enforcement off entirely, as before:
// its binding leak is silent, so neither a record nor a confirm can see it.
// One line logs once when the untracked scan arms, so the next device log
// can distinguish "armed and confirming" from "never ran".
// REVISION 14: 2.0.13 verified on device (armed line + force/restore pairs +
// occlusion restored in play), and a self-correction the verification pass
// uncovered. The filter labels this layer printed since 2.0.12 -- and the
// gl.h definitions behind them -- were themselves wrong: the Khronos
// registry (and Mesa's and ANGLE's headers, all cross-checked) define
// 0x2701 = GL_LINEAR_MIPMAP_NEAREST and 0x2702 = GL_NEAREST_MIPMAP_LINEAR,
// so 2.0.12's "corrected" gl.h had in fact inverted a correct header, and
// Mojang's GlSampler maps minFilter=NEAREST to 9986 = GL_NEAREST_MIPMAP_
// LINEAR (nearest within a level, blended across levels, clipped to one
// level by MAX_LOD=0) -- not GL_LINEAR_MIPMAP_NEAREST. The mechanism
// narrative is relabelled accordingly and gets tighter: GLES 3.0 keeps a
// depth-family texture filter-complete only while MIN_FILTER is NEAREST or
// NEAREST_MIPMAP_NEAREST, so the MIPMAP_LINEAR family alone is enough to
// make every D32F image under that sampler read incomplete (0.0 on ANGLE
// Metal, "infinitely far" in reversed-z). No behavioural change to the
// enforcement itself: the force still writes plain NEAREST, and the
// decision paths only ever compared against GL_NEAREST. Fixed here: the
// gl.h pair, the dump's filter_name table (9985/9986 labels), the sampler
// record's GLES-default MIN (9986, not 9985 -- the restore write-back for a
// never-parameterised sampler used to hand back LINEAR_MIPMAP_NEAREST
// instead of the default), and the rationale comments in gl/texture.{h,cpp}.
// REVISION 15: the MC 26.3 SDL3 host turned the 2.0.10 theft canary from a
// hypothetical into the actual failure. 26.3's renderpearl GlBackend.loadLibrary
// cross-checks its two GL entry points: the LWJGL function provider (built on
// this layer's exported glXGetProcAddress) must return the SAME address for
// "glGetError" as SDL_GL_GetProcAddress (hooked by the host to dlsym this
// layer's handle). glXGetProcAddress resolved names through the process-wide
// flat namespace (RTLD_DEFAULT), where this layer and the host's ANGLE
// libGLESv2 both export every gl* name and dyld image order decides the
// winner. In the 26.3 path ANGLE loads first, the LWJGL side bound ANGLE's
// GLES exports, the SDL side bound this layer's exports, the pointer check
// failed ("glGetError mismatch"), the OpenGL backend was rejected and the
// game fell back to MoltenVK (which then died in shaderc's unpatched glslang).
// Fixed by resolving from this layer's own image first (RTLD_SELF: the
// calling image, then its dependents), so this layer's exports win regardless
// of image order; RTLD_DEFAULT remains the fallback for names this layer does
// not export. The flat-namespace canary stays as environment diagnostics --
// resolution no longer depends on what it reports.
// REVISION 16: 2.0.15's RTLD_SELF did not survive contact with the device --
// the 3c13d5e5 build still reported "glGetError mismatch" and fell back to
// MoltenVK. Root cause of the trap: dyld derives the "caller image" of the
// special handles (RTLD_SELF/RTLD_NEXT) from __builtin_return_address(0), and
// the host launcher rebinding dlsym process-wide (fishhook) redirects every
// dlsym issued from this layer through host code, so the "caller" dyld saw was
// the host binary, not this layer -- RTLD_SELF searched the host's dependency
// subtree and the outcome depended on where the dlopen'd renderers sit in it.
// Fixed by dropping special handles entirely: glXGetProcAddress now resolves
// through a handle to THIS image (dladdr on an own function + dlopen
// RTLD_NOLOAD, which can never map a duplicate) and falls back to
// RTLD_DEFAULT only for names this layer does not export. Handle-based dlsym
// has no caller-image ambiguity, so this layer's exports win for every name
// it implements, independent of image order and of who is calling. One-time
// W_FORCE line reports the resolved own-image path for device-log verification.
// REVISION 17: Amethyst Task 32 -- two ESSL-output bugs that surfaced once the
// Task 30/31 lifecycle locks stopped the SIGSEGV (build a09e020 ran all 390
// shaderc compiles with zero native crashes, revealing what the crash used to
// hide). (1) process_uniform_declarations() matched the "uniform" keyword as
// a raw substring, so RenderPearl's _uniform_instance_00_XX block-instance
// identifiers triggered a bogus has_initializer rewrite that destroyed the
// enclosing statement -- every core pipeline fragment failed in ANGLE with
// "'_uniform' : undeclared identifier" + "'_instance_00_XX' : syntax error".
// Now token-guarded on both sides. (2) Minecraft 26.x OIT shaders index
// fragment-output arrays (coeff[attachmentIndex][i]) with loop variables,
// which ESSL 300 rejects outright; the converter now routes those accesses
// through a scratch array and copies out with constant indices at the end of
// main(). This bump also force-invalidates the on-disk conversion cache:
// entries written by <= 2.0.16 embed the corrupted ESSL and would keep being
// re-served for identical sources. "MobileGlues 2.0.17" in the runtime
// Graphics Drivers line identifies the fixed build on device.
// REVISION 1 -> 17: 与参考仓库 Air 的 MobileGlues-cpp（2.0.17 Release）对齐。
// 本仓库 src/main/cpp 的源码内容与 2.0.17 一致（逐文件比对仅 9 个文件不同，
// 其中 2 个是本次同步过来的 Air Task78/Task81，3 个是 FSR1，1 个 CMakeLists，
// 2 个是本仓库刻意保留的本地改动，1 个就是本文件），但 REVISION 宏停在 1，
// 于是设备日志显示 "MobileGlues 2.0.1 Dev1"、且磁盘上的 GLSL 转换缓存键
// （内嵌 MAJOR.MINOR.REVISION）与参考仓库不同。此处对齐到 17：既让版本号如实
// 反映源码水平，也强制失效旧转换缓存，避免旧构建写下的 ESSL 被反复命中。
#define REVISION 17
#define PATCH 0

#define VERSION_TYPE VERSION_RELEASE

#if VERSION_TYPE == VERSION_RC
#define VERSION_RC_NUMBER 2
#endif

// Development builds are numbered for the reason release candidates are: several
// of them carry the same MAJOR.MINOR.REVISION, and a bug report has to be able to
// name which one it came from. Bump this whenever a build leaves this machine.
#if VERSION_TYPE == VERSION_DEVELOPMENT
#define VERSION_DEV_NUMBER 4
#endif

#define VERSION_SUFFIX ""

#define MOBILEGLUES_VERSION_H

#endif // MOBILEGLUES_VERSION_H
