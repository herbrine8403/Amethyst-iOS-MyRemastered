SHELL := /bin/bash
.SHELLFLAGS = -ec
# Use `make VERBOSE=1` to print commands.
$(VERBOSE).SILENT:

# Prerequisite variables
SOURCEDIR   := $(shell printf "%q\n" "$(shell pwd)")
OUTPUTDIR   := $(SOURCEDIR)/artifacts
WORKINGDIR  := $(SOURCEDIR)/Natives/build
DETECTPLAT  := $(shell uname -s)
DETECTARCH  := $(shell uname -m)
VERSION     := 1.0
BRANCH      := $(shell git branch --show-current)
COMMIT      := $(shell git log --oneline | sed '2,10000000d' | cut -b 1-7)
PLATFORM    ?= 2

# Release vs Debug
RELEASE ?= 0

# Check if running on github runner
RUNNER ?= 0

# Check if slimmed should be built
SLIMMED ?= 0

# Check if slimmed should be built, and additionally skip normal build
SLIMMED_ONLY ?= 0

# If not in a GitHub repository, default to these
# so that compiling doesn't fail
BRANCH ?= "unknown"
COMMIT ?= "unknown"

# Team IDs and provisioning profile for the codesign function
# Default to -1 for check
# Currently requires a paid Apple Developer account, will fix later
SIGNING_TEAMID ?= -1
TEAMID ?= -1
PROVISIONING ?= -1

ifeq (1,$(RELEASE))
CMAKE_BUILD_TYPE := Release
else
CMAKE_BUILD_TYPE := Debug
endif


# Distinguish iOS from macOS, and *OS from others
ifeq ($(DETECTPLAT),Darwin)
OSVER       := $(shell sw_vers -productVersion | cut -b 1-2)
ifeq ($(shell sw_vers -productName),macOS)
IOS         := 0
SDKPATH     ?= $(shell xcrun --sdk iphoneos --show-sdk-path)
BOOTJDK     ?= $(shell /usr/libexec/java_home -v 1.8)/bin
$(warning Building on macOS.)
else
IOS         := 1
SDKPATH     ?= /usr/share/SDKs/iPhoneOS.sdk
BOOTJDK     ?= /usr/lib/jvm/java-8-openjdk/bin
ifeq ($(shell test "$(OSVER)" -gt 14; echo $$?),0)
PREFIX      ?= /var/jb/
else
PREFIX      ?= /
endif
$(warning Building on iOS. Note that all targets may not compile or require external components.)
endif
else ifeq ($(DETECTPLAT),Linux)
IOS         := 0
# SDKPATH presence is checked later
BOOTJDK     ?= /usr/bin
$(warning Building on Linux. Note that all targets may not compile or require external components.)
else
$(error This platform is not currently supported for building Angel Aura Amethyst.)
endif

# Define PLATFORM_NAME from PLATFORM
ifeq ($(PLATFORM),2)
PLATFORM_NAME := ios
$(warning Set PLATFORM to 2, which is equal to iOS.)
else ifeq ($(PLATFORM),3)
PLATFORM_NAME := tvos
$(warning Set PLATFORM to 3, which is equal to tvOS.)
else ifeq ($(PLATFORM),6)
PLATFORM_NAME := maccatalyst
$(warning Set PLATFORM to 6, which is equal to Mac Catalyst.)
else ifeq ($(PLATFORM),7)
PLATFORM_NAME := iossimulator
$(warning Set PLATFORM to 7, which is equal to iOS Simulator.)
else ifeq ($(PLATFORM),8)
PLATFORM_NAME := tvossimulator
$(warning Set PLATFORM to 8, which is equal to tvOS Simulator.)
else ifeq ($(PLATFORM),11)
PLATFORM_NAME := xros
$(warning Set PLATFORM to 11, which is equal to visionOS.)
else ifeq ($(PLATFORM),12)
PLATFORM_NAME := xrsimulator
$(warning Set PLATFORM to 12, which is equal to visionOS Simulator.)
else
$(error PLATFORM is not valid.)
endif

POJAV_BUNDLE_DIR      ?= $(OUTPUTDIR)/AngelAuraAmethyst.app
POJAV_JRE8_DIR        ?= $(SOURCEDIR)/depends/java-8-openjdk
POJAV_JRE17_DIR       ?= $(SOURCEDIR)/depends/java-17-openjdk
POJAV_JRE21_DIR       ?= $(SOURCEDIR)/depends/java-21-openjdk
POJAV_JRE25_DIR       ?= $(SOURCEDIR)/depends/java-25-openjdk
MOLTENVK_LIBRARY      ?= $(SOURCEDIR)/Natives/resources/Frameworks/libMoltenVK.dylib
MOBILEGL_SOURCE_DIR   ?= $(SOURCEDIR)/Natives/external/MobileGL
# MobileGL 源码已 vendoring 在 Natives/external/MobileGL（与 MobileGlues 一样是普通
# 源码目录，不再是 gitlink），可以直接改源码调 iOS 构建。
# 上游不发布 iOS 预编译产物。2026-08-31 首次编译成功（提交 55256e33），
# 两个后端 dylib 已提交在 Natives/resources/Frameworks/ 下，日常构建直接用它，
# 不必重编（编 glslang + SPIRV-Cross 约 30 分钟，Actions 对 macOS 按 10 倍计费）。
# 改源码时才用 BUILD_MOBILEGL=1 重开。
# 更新源码：直接用 git 把 MobileGL-Dev/MobileGL 的 dev 分支（子模块取各自默认
# 分支）同步进 Natives/external/MobileGL，并保持既有剔除规则（SPIRV-Cross/test、
# glslang/Test、Vulkan-Headers/tests、DiligentCore/Samples|Tutorials、
# trace_replay/fixtures、android-plugin）。不依赖任何 workflow。
BUILD_MOBILEGL        ?= 0
MOBILEGL_DYLIB        ?= $(SOURCEDIR)/Natives/resources/Frameworks/libMobileGL.dylib
MOBILEGL_GLES_DYLIB   ?= $(SOURCEDIR)/Natives/resources/Frameworks/libMobileGL-gles.dylib
MITHRIL_PREBUILT_DIR  ?= $(SOURCEDIR)/prebuilt

# Function to use later for checking dependencies
METHOD_DEPCHECK   = $(shell $(1) >/dev/null 2>&1 && echo 1)

# Function to modify Info.plist files
METHOD_INFOPLIST  =  \
	if [ '$(4)' = '0' ]; then \
		plutil -replace $(1) -string $(2) $(3); \
	else \
		plutil -value $(2) -key $(1) $(3); \
	fi

# Function to check directories
METHOD_DIRCHECK   = \
	if [ ! -d '$(1)' ]; then \
		mkdir -p $(1); \
	else \
		rm -rf $(1)/*; \
	fi
	
# Function to change the platform on Mach-O files.
# iOS = 2, tvOS = 3, iOS Simulator = 7, tvOS Simulator = 8, visionOS = 11, visionOS Simulator = 12
# https://github.com/apple-oss-distributions/xnu/blob/main/EXTERNAL_HEADERS/mach-o/loader.h
# TODO: Change Info.plist for visionOS 1.0
METHOD_CHANGE_PLAT = \
	if [ '$(1)' != '11' ] && [ '$(1)' != '12' ]; then \
		vtool -arch arm64 -set-build-version $(1) 14.0 16.0 -replace -output $(2) $(2); \
		ldid -S -M $(2); \
	else \
		vtool -arch arm64 -set-build-version $(1) 1.0 1.0 -replace -output $(2) $(2); \
	fi \
	
# Function to package the application
# 修复：使用统一的命名格式 amethystremastered
METHOD_PACKAGE = \
	if [ '$(TROLLSTORE_JIT_ENT)' == '1' ]; then \
		IPA_SUFFIX="-trollstore.tipa"; \
	else \
		IPA_SUFFIX=".ipa"; \
	fi; \
	rm -f $(OUTPUTDIR)/com.air-devs.air-$(VERSION)-$(PLATFORM_NAME)$$IPA_SUFFIX; \
	rm -f $(OUTPUTDIR)/com.air-devs.air.slimmed-$(VERSION)-$(PLATFORM_NAME)$$IPA_SUFFIX; \
	if [ '$(SLIMMED_ONLY)' = '0' ]; then \
		zip --symlinks -r $(OUTPUTDIR)/com.air-devs.air-$(VERSION)-$(PLATFORM_NAME)$$IPA_SUFFIX Payload; \
	fi; \
	if [ '$(SLIMMED)' = '1' ] || [ '$(SLIMMED_ONLY)' = '1' ]; then \
		zip --symlinks -r $(OUTPUTDIR)/com.air-devs.air.slimmed-$(VERSION)-$(PLATFORM_NAME)$$IPA_SUFFIX Payload --exclude='Payload/AngelAuraAmethyst.app/java_runtimes/*'; \
	fi

# Function to download and unpack Java runtimes.
METHOD_JAVA_UNPACK = \
	cd $(SOURCEDIR)/depends; \
	if [ ! -f "java-$(1)-openjdk/release" ] && [ ! -f "$(ls jre$(1)-*.tar.xz)" ]; then \
		if [ "$(RUNNER)" != "1" ]; then \
			wget '$(2)' -q --show-progress; \
			unzip jre*-ios-aarch64.zip && rm jre*-ios-aarch64.zip; \
		fi; \
		mkdir -p java-$(1)-openjdk; \
		tar xvf jre$(1)-*.tar.xz -C java-$(1)-openjdk; \
	fi

# Function to codesign binaries.
METHOD_CODESIGN = \
	codesign --remove-signature $(2); \
	codesign -f -s $(1) --generate-entitlement-der --entitlements entitlements.codesign.xml $(2); \
	printf 'File: '; printf $(2); printf ', Codesigned with team: '; printf $(1); printf '\n'

# Function to run code when finding Mach-O files.
METHOD_MACHO = \
	for file in $$(find $(1)); do \
		if [[ "$$(file $$file)" == *"Mach-O"* ]]; then \
			$(2); \
		fi; \
	done

# Make sure everything is already available for use. Error if they require something
ifneq ($(call METHOD_DEPCHECK,cmake --version),1)
$(error You need to install cmake)
endif

ifneq ($(call METHOD_DEPCHECK,$(BOOTJDK)/javac -version),1)
$(error You need to install JDK 8)
endif

ifeq ($(IOS),0)
ifeq ($(filter 1.8.0,$(shell $(BOOTJDK)/javac -version &> javaver.txt && cat javaver.txt | cut -b 7-11 && rm -rf javaver.txt)),)
$(error You need to install JDK 8)
endif
endif

ifneq ($(call METHOD_DEPCHECK,ldid),1)
$(error You need to install ldid)
endif

ifneq ($(call METHOD_DEPCHECK,wget --version),1)
$(error You need to install wget)
endif

ifeq ($(DETECTPLAT),Linux)
ifneq ($(call METHOD_DEPCHECK,lld),1)
$(error You need to install lld)
endif
endif

ifneq ($(filter sysctl,$(shell sysctl -n hw.logicalcpu)),)
ifneq ($(call METHOD_DEPCHECK,nproc --version),1)
ifneq ($(call METHOD_DEPCHECK,gnproc --version),1)
$(warning Unable to determine number of threads, defaulting to 2.)
JOBS   ?= 2
else
JOBS   ?= $(shell gnproc)
endif
else
JOBS   ?= $(shell nproc)
endif
else
JOBS   ?= $(shell sysctl -n hw.logicalcpu)
endif

ifndef SDKPATH
$(error You need to specify SDKPATH to the path of iPhoneOS.sdk. The SDK version should be 14.0 or newer.)
endif

all: clean native java jre assets payload package dsym

help:
	echo 'Makefile to compile Angel Aura Amethyst'
	echo ''
	echo 'Usage:'
	echo '    make                                Makes everything under all'
	echo '    make help                           Displays this message'
	echo '    make all                            Builds the entire app'
	echo '    make native                         Builds the native app'
	echo '    make java                           Builds the Java app'
	echo '    make jre                            Downloads/unpacks the iOS JREs'
	echo '    make assets                         Compiles Assets.xcassets'
	echo '    make payload                        Makes Payload/AngelAuraAmethyst.app'
	echo '    make package                        Builds ipa of Angel Aura Amethyst'
	echo '    make deploy                         Copies files to local iDevice'
	echo '    make dsym                           Generate debug symbol files'
	echo '    make clean                          Cleans build directories'
	echo '    make check                          Dump all variables for checking'

check:
	$(foreach v, \
		$(shell echo "$(filter-out METHOD_% .% MAKEFILE_LIST MAKEFLAGS CURDIR,$(.VARIABLES))" | tr ' ' '\n' | sort), \
		$(if $(filter file,$(origin $(v))), \
		$(info $(shell printf "%-20s" "$(v)") = $(value $(v)))) \
	)

native: dep_mg
	echo '[Amethyst v$(VERSION)] native - start'
	mkdir -p $(WORKINGDIR)
	cd $(WORKINGDIR) && cmake \
		-DCMAKE_BUILD_TYPE=$(CMAKE_BUILD_TYPE) \
		-DCMAKE_CROSSCOMPILING=true \
		-DCMAKE_SYSTEM_NAME=Darwin \
		-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
		-DCMAKE_OSX_SYSROOT="$(SDKPATH)" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
		-DCMAKE_C_FLAGS="-arch arm64" \
		-DCONFIG_BRANCH="$(BRANCH)" \
		-DCONFIG_COMMIT="$(COMMIT)" \
		-DCONFIG_RELEASE=$(RELEASE) \
		..

	cmake --build $(WORKINGDIR) --config $(CMAKE_BUILD_TYPE) -j$(JOBS)
	#	--target awt_headless awt_xawt libOSMesaOverride.dylib tinygl4angle AngelAuraAmethyst
	rm $(WORKINGDIR)/libawt_headless.dylib
	echo '[Amethyst v$(VERSION)] native - end'

java:
	echo '[Amethyst v$(VERSION)] java - start'
	# 从 lwjgl-lib/ 源码构建 LWJGL jar（3.3.3 与 3.4.1）。
	# 默认跳过：预编译 jar 已在 git 中，普通构建与 CI 都不需要 Ant / JDK 8 /
	# 网络。只有 BUILD_LWJGL=1 时才真正从源码构建（本地改 LWJGL 时用）：
	#     BUILD_LWJGL=1 make java
	bash $(SOURCEDIR)/scripts/build_lwjgl.sh
	$(MAKE) -C JavaApp -j$(JOBS) BOOTJDK=$(BOOTJDK)
	echo '[Amethyst v$(VERSION)] java - end'

jre: native
	echo '[Amethyst v$(VERSION)] jre - start'
	mkdir -p $(SOURCEDIR)/depends
	cd $(SOURCEDIR)/depends; \
	$(call METHOD_JAVA_UNPACK,8,'https://assets.angelauramc.dev/openjdk/ios-arm64/jre8-ios-aarch64.zip'); \
	$(call METHOD_JAVA_UNPACK,17,'https://assets.angelauramc.dev/openjdk/ios-arm64/jre17-ios-aarch64.zip'); \
	$(call METHOD_JAVA_UNPACK,21,'https://assets.angelauramc.dev/openjdk/ios-arm64/jre21-ios-aarch64.zip'); \
	$(call METHOD_JAVA_UNPACK,25,'https://assets.angelauramc.dev/openjdk/ios-arm64/jre25-ios-aarch64.zip'); \
	if [ -f "$(ls jre*.tar.xz)" ]; then rm $(SOURCEDIR)/depends/jre*.tar.xz; fi; \
	cd $(SOURCEDIR); \
	rm -rf $(SOURCEDIR)/depends/java-{8,17,21,25}-openjdk/{ASSEMBLY_EXCEPTION,bin,include,jre,legal,LICENSE,man,THIRD_PARTY_README,lib/{ct.sym,jspawnhelper,libjsig.dylib,src.zip,tools.jar}}; \
	$(call METHOD_DIRCHECK,$(OUTPUTDIR)/java_runtimes); \
	cp -R $(POJAV_JRE8_DIR) $(OUTPUTDIR)/java_runtimes; \
	cp -R $(POJAV_JRE17_DIR) $(OUTPUTDIR)/java_runtimes; \
	cp -R $(POJAV_JRE21_DIR) $(OUTPUTDIR)/java_runtimes; \
	cp -R $(POJAV_JRE25_DIR) $(OUTPUTDIR)/java_runtimes; \
	cp $(WORKINGDIR)/libawt_xawt.dylib $(OUTPUTDIR)/java_runtimes/java-8-openjdk/lib; \
	cp $(WORKINGDIR)/libawt_xawt.dylib $(OUTPUTDIR)/java_runtimes/java-17-openjdk/lib;
	cp $(WORKINGDIR)/libawt_xawt.dylib $(OUTPUTDIR)/java_runtimes/java-21-openjdk/lib
	cp $(WORKINGDIR)/libawt_xawt.dylib $(OUTPUTDIR)/java_runtimes/java-25-openjdk/lib
	echo '[Amethyst v$(VERSION)] jre - end'

dep_mg:
	echo '[Amethyst v$(VERSION)] dep_mg - start'
	# ---------------------------------------------------------------------------
	# 3rdparty 版本对齐 —— 对齐参考仓库 Air 的 .gitmodules pin
	#
	# Air 的 Makefile 原文警告：
	#   "The shader conversion pipeline (desktop GLSL -> ESSL) is only validated
	#    against the submodule commits pinned in .gitmodules. A 3rdparty/ tree
	#    populated from arbitrary master snapshots produced ESSL that ANGLE-Metal
	#    rejects as empty (ERROR 1:1 syntax error on every shader, MC 26.x black
	#    screen). Force the pinned versions before configuring cmake, and fail
	#    loudly if they are still missing afterwards."
	#
	# 本仓库该目录是 vendored 而非 submodule，且 blob SHA 逐文件比对证明与 pin
	# 版本不同源：SPIRV-Cross 的 spirv_cross.cpp / spirv_cross.hpp /
	# spirv_glsl.cpp / spirv_glsl.hpp / spirv_cfg.cpp 全部不同；glslang 的
	# CHANGES.md / localintermediate.h / Versions.cpp / InfoSink.h /
	# CMakeLists.txt 也不同；xxhash 已一致故跳过。这是 MG + 26.3 黑屏与静默
	# 闪退的根因（转换产物 ESSL 不被 ANGLE-Metal 接受）。
	#
	# 与 Air 的 git submodule update --init 等价：构建期把这两个目录整体替换为
	# pin 快照（tar 直接解压到目标目录，规避 BSD cp -R 的目录覆盖陷阱）。哨兵
	# 文件 .air_pin_<sha> 避免重复下载；glslang 目录内的两个 .patch 先备份、替换
	# 后放回，交由紧随其后的补丁块应用（pin 版本本身不带防护补丁）。
	# 逃生阀：AMETHYST_MG_PIN_ALIGN=0 可跳过（离线调试用，产物未经验证）。
	# ---------------------------------------------------------------------------
	@mg3=$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty; \
	if [ "$${AMETHYST_MG_PIN_ALIGN:-1}" = "0" ]; then \
		echo '[dep_mg] WARNING: 3rdparty pin alignment skipped (AMETHYST_MG_PIN_ALIGN=0) -- MG build NOT validated'; \
	else \
		mkdir -p /tmp/mgpin_patches; \
		cp "$$mg3"/*.patch /tmp/mgpin_patches/ 2>/dev/null; \
		align3rd() { \
			mg_name=$$1; mg_url=$$2; mg_sha=$$3; \
			if [ -f "$$mg3/$$mg_name/.air_pin_$$mg_sha" ]; then \
				echo "[dep_mg] $$mg_name already pinned to $$mg_sha"; return 0; \
			fi; \
			echo "[dep_mg] $$mg_name: replacing vendored tree with pinned snapshot $$mg_sha"; \
			rm -rf "$$mg3/$$mg_name"; \
			mkdir -p "$$mg3/$$mg_name" || return 1; \
			curl -fsSL -o "/tmp/mgpin_$$mg_name.tgz" "$$mg_url" || { echo "ERROR: [dep_mg] $$mg_name pinned tarball download failed"; return 1; }; \
			tar -xzf "/tmp/mgpin_$$mg_name.tgz" -C "$$mg3/$$mg_name" --strip-components=1 || return 1; \
			touch "$$mg3/$$mg_name/.air_pin_$$mg_sha"; \
			echo "[dep_mg] $$mg_name pinned OK"; \
		}; \
		align3rd SPIRV-Cross https://codeload.github.com/KhronosGroup/SPIRV-Cross/tar.gz/a0fba56c34a6700f1724bf9b751da5b488a3775c a0fba56 || { echo 'ERROR: [dep_mg] 3rdparty pin alignment failed - cannot build a validated MobileGlues'; exit 1; }; \
		align3rd glslang https://codeload.github.com/KhronosGroup/glslang/tar.gz/f5f664dee8146676b04a332a7233959fc3ce9681 f5f664d || { echo 'ERROR: [dep_mg] 3rdparty pin alignment failed - cannot build a validated MobileGlues'; exit 1; }; \
		cp /tmp/mgpin_patches/*.patch "$$mg3/" 2>/dev/null; \
		echo '[dep_mg] 3rdparty pinned: SPIRV-Cross=a0fba56 glslang=f5f664d (xxhash already matches c2866db)'; \
	fi
	mkdir -p $(WORKINGDIR)/mobileglues
	# MG 自带 3rdparty/glslang（CMakeLists 里 add_subdirectory 从源码构建）。参考仓库在 cmake
	# 配置前对这份 glslang 打两个防护补丁（本仓库该目录是 vendored 而非 submodule，故用
	# --directory 定位）：
	#   * glslang-lvalue-nullguard.patch —— TParseContext::lValueErrorCheck 取 swizzle
	#     选择器聚合前不判空；iOS/arm64 上解析 MC 26.x 的 position_color 顶点着色器时该链
	#     SIGSEGV，启动/资源重载阶段直接杀进程（无 .ips、无 hs_err，表现为静默闪退）。
	#   * glslang-pool-zero-and-size-guards.patch —— GlslangToSpv::convertSwizzle 的
	#     constArray 尺寸判，必须打在 nullguard 之上。
	# 幂等：先 --check 正向，失败再 --check 反向（判定已打过），两种情况都继续构建。
	@mg_3prel=Natives/external/MobileGlues/MobileGlues-cpp/3rdparty; \
	mg_glrel=$$mg_3prel/glslang; \
	mg_pdir=$(SOURCEDIR)/$$mg_3prel; \
	for p in glslang-lvalue-nullguard.patch glslang-pool-zero-and-size-guards.patch; do \
		if [ ! -f "$$mg_pdir/$$p" ]; then echo "[dep_mg] ERROR: glslang patch $$p MISSING under $$mg_3prel -- MG built WITHOUT the MC 26.x position_color SIGSEGV guards"; continue; fi; \
		if git -C $(SOURCEDIR) apply --check -p1 --directory=$$mg_glrel "$$mg_pdir/$$p" >/dev/null 2>&1; then \
			git -C $(SOURCEDIR) apply -p1 --directory=$$mg_glrel "$$mg_pdir/$$p" && echo "[dep_mg] glslang patch $$p APPLIED" || echo "[dep_mg] WARNING: $$p apply failed"; \
		elif git -C $(SOURCEDIR) apply --check -R -p1 --directory=$$mg_glrel "$$mg_pdir/$$p" >/dev/null 2>&1; then \
			echo "[dep_mg] glslang patch $$p already applied"; \
		else \
			echo "[dep_mg] WARNING: $$p neither applies nor is applied -- MG glslang left UNPATCHED"; \
		fi; \
	done
	# CMAKE_BUILD_TYPE 必须显式给出：--config 对单配置生成器无效。缺失时 CMake 不追加
	# -O2/-DNDEBUG，整库 -O0 且 glslang/SPIRV-Cross/MG 的 assert() 全部激活 —— assert
	# 触发即 __assert_rtn->abort()，表现为直接进启动器错误界面且无 .ips/hs_err。
	cd $(WORKINGDIR)/mobileglues && cmake \
		-DMACOS="1" \
		-DCMAKE_CROSSCOMPILING=true \
		-DCMAKE_SYSTEM_NAME=Darwin \
		-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
		-DCMAKE_OSX_SYSROOT="$(SDKPATH)" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
		-DCMAKE_C_FLAGS="-arch arm64" \
		-DCMAKE_BUILD_TYPE=RelWithDebInfo \
		$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/

	# 额外显式构建 SPIRV / glslang-default-resource-limits 两个静态库：
	# dep_shader_shims 从源码链接 libshaderc_impl.dylib 时需要它们，
	# 而 mobileglues 自身只链接 glslang::glslang，不会带出这两个目标。
	cmake --build $(WORKINGDIR)/mobileglues --config RelWithDebInfo -j$(JOBS) --target mobileglues SPIRV glslang-default-resource-limits
	@mg_bindir=$(WORKINGDIR)/mobileglues/3rdparty/glslang; \
	mg_spirv_a=$$mg_bindir/SPIRV/libSPIRV.a; \
	[ -f "$$mg_spirv_a" ] || mg_spirv_a=$$(find $(WORKINGDIR)/mobileglues -type f -name libSPIRV.a -print -quit 2>/dev/null); \
	mg_glslang_a=$$mg_bindir/glslang/libglslang.a; \
	[ -f "$$mg_glslang_a" ] || mg_glslang_a=$$(find $(WORKINGDIR)/mobileglues -type f -name libglslang.a -print -quit 2>/dev/null); \
	mg_rl_a=$$mg_bindir/glslang/libglslang-default-resource-limits.a; \
	[ -f "$$mg_rl_a" ] || mg_rl_a=$$(find $(WORKINGDIR)/mobileglues -type f -name libglslang-default-resource-limits.a -print -quit 2>/dev/null); \
	if [ -z "$$mg_spirv_a" ] || [ ! -f "$$mg_spirv_a" ] || [ -z "$$mg_glslang_a" ] || [ ! -f "$$mg_glslang_a" ] || [ -z "$$mg_rl_a" ] || [ ! -f "$$mg_rl_a" ]; then \
		echo "ERROR: glslang static libs unresolved (spirv=$$mg_spirv_a glslang=$$mg_glslang_a rl=$$mg_rl_a)"; \
		find $(WORKINGDIR)/mobileglues -type f -name "lib*.a" 2>/dev/null | head -20; \
		exit 1; \
	fi; \
	echo "[shaderc-impl] glslang static libs OK (spirv=$$mg_spirv_a glslang=$$mg_glslang_a rl=$$mg_rl_a)"
	cp $(WORKINGDIR)/mobileglues/libmobileglues*.dylib $(WORKINGDIR)/
	echo '[Amethyst v$(VERSION)] dep_mg - end'
# ---------------------------------------------------------------------------
# shaderc / spirv-cross 串行化垫片（对齐 Air Task 39/42/47/54）
#
# MG + MC 26.3 崩溃家族：资源重载阶段多个 32MB 栈 JVM 线程并发执行 glslang
# 编译，且 compiler_release 与 in-flight 编译竞态 —— 旧 RenderPearl 管线释放
# 时拆全局符号表/释放 glslang 池，编译中的 AST 内存被随后的字符串分配复用，
# ASCII 字节落进 SWIZZLE 节点 constArray 指针字段（偏移 +0xd8），最终在
# glslang::TParseContext::lValueErrorCheck+0x204 SIGSEGV 拖垮整个进程。
#
# 修复：真实库以 *_impl.dylib 落地，本垫片顶替原名并以 -reexport_library
# 透传全部符号；编译入口与 compiler/options 生命周期入口统一收进一把进程级
# 递归互斥锁，编译期接管 SIGSEGV/SIGBUS 做一次重试（崩溃网），从而把
# “进程死亡”降级为“单个 shader 编译失败 + 取证日志”。
#
# 本仓库 Natives/resources/Frameworks 下为预提交二进制，故在 WORKINGDIR 里
# 复制出 impl 名字并改写 LC_ID（reexport 记录的是 impl 的 install name，
# 否则会把构建期绝对路径烧进产物）。
# ---------------------------------------------------------------------------
dep_shader_shims: dep_mg
	echo '[Amethyst v$(VERSION)] dep_shader_shims - start'
	# libshaderc_impl.dylib 从源码构建：Natives/shaderc_impl_glue.c 直接覆在
	# glslang C 接口上，链接 dep_mg 刚构建的（已打 nullguard + pool-zero/size-guard
	# 补丁的）静态库。预编译的 libshaderc.dylib 内含未打补丁的 glslang，其
	# TParseContext::lValueErrorCheck / convertSwizzle 会解引用被堆回收字节污染的
	# swizzle 选择器 constArray（+0xd8）而 SIGSEGV —— 正是 MC 26.3 崩溃家族的成因。
	mg_bindir=$(WORKINGDIR)/mobileglues/3rdparty/glslang; \
	mg_spirv_a=$$mg_bindir/SPIRV/libSPIRV.a; \
	[ -f "$$mg_spirv_a" ] || mg_spirv_a=$$(find $(WORKINGDIR)/mobileglues -type f -name libSPIRV.a -print -quit 2>/dev/null); \
	mg_glslang_a=$$mg_bindir/glslang/libglslang.a; \
	[ -f "$$mg_glslang_a" ] || mg_glslang_a=$$(find $(WORKINGDIR)/mobileglues -type f -name libglslang.a -print -quit 2>/dev/null); \
	mg_rl_a=$$mg_bindir/glslang/libglslang-default-resource-limits.a; \
	[ -f "$$mg_rl_a" ] || mg_rl_a=$$(find $(WORKINGDIR)/mobileglues -type f -name libglslang-default-resource-limits.a -print -quit 2>/dev/null); \
	if [ -z "$$mg_spirv_a" ] || [ ! -f "$$mg_spirv_a" ] || [ -z "$$mg_glslang_a" ] || [ ! -f "$$mg_glslang_a" ] || [ -z "$$mg_rl_a" ] || [ ! -f "$$mg_rl_a" ]; then \
		echo "ERROR: glslang static libs unresolved - from-source shaderc impl cannot link"; \
		exit 1; \
	fi; \
	extra_glslang_libs=""; \
	for l in libOGLCompiler.a libOSDependent.a; do \
		if [ -f "$$mg_bindir/glslang/$$l" ]; then \
			extra_glslang_libs="$$extra_glslang_libs $$mg_bindir/glslang/$$l"; \
		fi; \
	done; \
	echo "[shaderc-impl] linking from-source impl (spirv=$$mg_spirv_a glslang=$$mg_glslang_a rl=$$mg_rl_a extra libs:$$extra_glslang_libs)"; \
	xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
		-install_name @rpath/libshaderc_impl.dylib \
		-I$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/glslang \
		-o $(WORKINGDIR)/libshaderc_impl.dylib \
		$(SOURCEDIR)/Natives/shaderc_impl_glue.c \
		"$$mg_spirv_a" \
		"$$mg_glslang_a" \
		"$$mg_rl_a" \
		$$extra_glslang_libs \
		-lc++ || exit 1
	install_name_tool -id @rpath/libshaderc_impl.dylib $(WORKINGDIR)/libshaderc_impl.dylib || exit 1
	cp $(SOURCEDIR)/Natives/resources/Frameworks/libspirv-cross-c-shared.0.dylib $(WORKINGDIR)/libspirv-cross-c-shared.0.impl.dylib || exit 1
	install_name_tool -id @rpath/libspirv-cross-c-shared.0.impl.dylib $(WORKINGDIR)/libspirv-cross-c-shared.0.impl.dylib || exit 1
	xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
		-install_name @rpath/libshaderc.dylib \
		-Wl,-reexport_library,$(WORKINGDIR)/libshaderc_impl.dylib \
		-o $(WORKINGDIR)/libshaderc.dylib \
		$(SOURCEDIR)/Natives/shaderc_shim.c \
		$(SOURCEDIR)/Natives/shaderc_include.c \
		$(SOURCEDIR)/Natives/shaderc_sandbox.m || exit 1
	xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
		-install_name @rpath/libspirv-cross-c-shared.0.dylib \
		-Wl,-reexport_library,$(WORKINGDIR)/libspirv-cross-c-shared.0.impl.dylib \
		-o $(WORKINGDIR)/libspirv-cross-c-shared.0.dylib \
		$(SOURCEDIR)/Natives/spvc_shim.c || exit 1
	# -------------------------------------------------------------------
	# MobileGlues 的 SPIRV-Cross 与上面的 LWJGL spvc 垫片解耦
	#
	# MG 在 CMakeLists 里链接 libraries/ios/ 下预编译的 libspirv-cross-c-shared.dylib，
	# 其 LC_ID_DYLIB 与上面产出的 spvc 垫片同名。于是运行时 dyld 把 MG 的每一次
	# spvc_* 调用都解析进垫片 —— 即 32MB 栈派发线程 + 进程级主编译锁（日志里
	# "[spvc-shim] ... MG serialization ON" 就是它）。MC 26.3 的 shader 转换量远大于
	# 26.2，这条共享路径被压满后进程被拖死：静默闪退、无 hs_err、无崩溃报告；
	# 26.2 量小所以不受影响。（MG 自身跑得完转换 —— 垫片之前 26.3 + MG 是有声音的，
	# 只是黑屏。）
	#
	# 参考仓库 Air 的 MG 走 add_subdirectory(3rdparty/SPIRV-Cross) 并静态链接
	# spirv-cross-c，根本不存在这份共享库，因此不受影响。本仓库未纳入 SPIRV-Cross
	# submodule，故不改 MG 的链接方式，只在打包前把 libmobileglues 对 spirv-cross
	# 的依赖重定向到一份独立命名的真库；LWJGL 侧仍按原名加载垫片，32MB 栈与
	# 串行锁保护原样保留，行为完全不变。
	#
	# 依赖名由 otool 现场探测、不写死；源库按两条候选路径查找。任一环节缺失都只
	# 打印 WARN 并跳过，不会让构建失败。
	# -------------------------------------------------------------------
	for mg in $(WORKINGDIR)/libmobileglues*.dylib; do \
		[ -f "$$mg" ] || continue; \
		mg_dep=$$(otool -L "$$mg" | awk '/spirv-cross/ { print $$1; exit }'); \
		if [ -z "$$mg_dep" ]; then \
			echo "[dep_shader_shims] $$(basename "$$mg"): no spirv-cross dylib dependency (statically linked) -- skip"; \
			continue; \
		fi; \
		if [ ! -f "$(WORKINGDIR)/libspirv-cross-mg.dylib" ]; then \
			mg_src="$(SOURCEDIR)/Natives/external/MobileGlues/src/main/cpp/libraries/ios/libspirv-cross-c-shared.dylib"; \
			[ -f "$$mg_src" ] || mg_src="$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/libraries/ios/libspirv-cross-c-shared.dylib"; \
			if [ ! -f "$$mg_src" ]; then \
				echo "[dep_shader_shims] WARN: MG spirv-cross prebuilt not found -- skip decoupling"; \
				continue; \
			fi; \
			cp "$$mg_src" "$(WORKINGDIR)/libspirv-cross-mg.dylib" || exit 1; \
			install_name_tool -id @rpath/libspirv-cross-mg.dylib "$(WORKINGDIR)/libspirv-cross-mg.dylib" || exit 1; \
		fi; \
		install_name_tool -change "$$mg_dep" @rpath/libspirv-cross-mg.dylib "$$mg" || exit 1; \
		echo "[dep_shader_shims] MG spvc decoupled: $$mg_dep -> @rpath/libspirv-cross-mg.dylib"; \
	done
	echo '[Amethyst v$(VERSION)] dep_shader_shims - end'


dep_openal_shim:
	# Task 129：OpenAL ALC_SOFT_system_events 兼容垫片（26.1.2 整合包崩溃修复）。
	# - 真库已 git mv 为 libopenal_impl.dylib（openal-soft 1.20.1 iOS 构建，无
	#   ALC_SOFT_system_events 扩展）；本目标构建同名垫片 libopenal.dylib：
	#   re-export impl 全部符号 + 覆盖 alcGetString/alcIsExtensionPresent 宣称扩展
	#   + 提供 alcEventIsSupportedSOFT/alcEventControlSOFT/alcEventCallbackSOFT 桩。
	# - 根因：MC 26.1.2 CallbackDeviceTracker.isSupported 无扩展守卫，直接调
	#   LWJGL 绑定 -> ICD 槽位 0 -> NPE 崩溃（26.3 有守卫故存活）。
	#   桩返回 ALC_FALSE 使 MC 干净回退 PollingDeviceTracker。
	# - 与 dep_shader_shims 同款模式：re-export 必须指向 impl 名（LC_ID 先修正），
	#   否则加载递归；本地函数定义优先于 re-export 符号（shaderc 先例）。
	echo '[Amethyst v$(VERSION)] dep_openal_shim - start'
	cp $(SOURCEDIR)/Natives/resources/Frameworks/libopenal_impl.dylib $(WORKINGDIR)/ || exit 1
	install_name_tool -id @rpath/libopenal_impl.dylib $(WORKINGDIR)/libopenal_impl.dylib || exit 1
	xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
		-install_name @rpath/libopenal.dylib \
		-Wl,-reexport_library,$(WORKINGDIR)/libopenal_impl.dylib \
		-o $(WORKINGDIR)/libopenal.dylib \
		$(SOURCEDIR)/Natives/openal_shim.c || exit 1
	echo '[Amethyst v$(VERSION)] dep_openal_shim - end'

dep_angle_freeze:
	echo '[Amethyst v$(VERSION)] dep_angle_freeze - start'
	# Task 57 (画面分裂根治): 8-byte machine-code patch -- ANGLE Metal
	# WindowSurfaceMtl::checkIfLayerResized: expected size source switched from
	# bounds*contentsScale (poisoned by windowed-mode background-thread portrait
	# geometry, CALayer cross-thread split-brain) to the surface's own latched
	# mWidth/mHeight ([x19,#0x430/0x438]) -- surface size frozen at creation
	# geometry (creation reads always clean); transposition becomes physically
	# impossible; on drawableSize drift the enforcement branch re-writes the
	# frozen value back onto the layer. Idempotent; loud failure on byte
	# mismatch (ANGLE version drift guard); full root-cause chain in script
	# header comments (scripts/patch_angle_surface_freeze.py).
	# 补丁改写源文件后签名哈希失效 —— 打包时 ldid -S 全 app 递归重签覆盖。
	python3 $(SOURCEDIR)/scripts/patch_angle_surface_freeze.py \
		$(SOURCEDIR)/Natives/resources/Frameworks/libGLESv2.framework/libGLESv2 || exit 1
	echo '[Amethyst v$(VERSION)] dep_angle_freeze - end'

dep_sdl3_guard:
	echo '[Amethyst v$(VERSION)] dep_sdl3_guard - start'
	# Task 135 (controlify/JNA closure SIGBUS 源头根治): libSDL3.dylib
	# 入口机器码守卫 -- SDL_SetEventFilter / SDL_AddEventWatch 的非空回调指针
	# 一律置空/拒绝注册。controlify 经 JNA 回退加载本 Frameworks 的 iOS 版 SDL3
	# 后, 把 JNA/libffi closure (RW 不可执行 trampoline 页) 注册进 SDL 事件过滤
	# 器, SDL 调用即 SIGBUS。dlsym 层守卫对 LWJGL/FFM 解析路径有效, 但 JNA 解析
	# 路径仍可绕行; 本补丁把守卫下沉到 SDL 二进制自身, 与符号解析链路完全无关。
	# 启动器自身与 MC/LWJGL 均不使用 SDL 事件过滤器 (全仓 grep 验证), 零误伤;
	# 签名由打包时 ldid -S 全 app 重签覆盖 (dep_angle_freeze 同款流程)。
	# 幂等; 字节不匹配 (SDL3 版本漂移) 响亮失败。
	python3 $(SOURCEDIR)/scripts/patch_sdl3_eventfilter_guard.py \
		$(SOURCEDIR)/Natives/resources/Frameworks/libSDL3.dylib || exit 1
	echo '[Amethyst v$(VERSION)] dep_sdl3_guard - end'

dep_mobilegl:
	@{ echo '== MobileGL build diagnostics =='; \
	  echo "  BUILD_MOBILEGL      = $(BUILD_MOBILEGL)"; \
	  echo "  MOBILEGL_SOURCE_DIR = $(MOBILEGL_SOURCE_DIR)"; \
	  echo "  source exists       = `test -d '$(MOBILEGL_SOURCE_DIR)' && echo yes || echo no`"; \
	  echo "  cmake               = `cmake --version 2>&1 | head -1`"; \
	  echo "  moltenvk            = `test -f '$(MOLTENVK_LIBRARY)' && echo yes || echo no` ($(MOLTENVK_LIBRARY))"; \
	  echo "  glslang dir         = `test -d '$(MOBILEGL_SOURCE_DIR)'/3rdparty/glslang && echo yes || echo no`"; \
	  echo "  spirv-tools dir     = `test -d '$(MOBILEGL_SOURCE_DIR)'/3rdparty/DiligentCore/ThirdParty/SPIRV-Tools && echo yes || echo no`"; \
	} 2>&1 | tee $(SOURCEDIR)/mobilegl-build.log
	@if [ '$(BUILD_MOBILEGL)' != '1' ]; then \
		if [ -f "$(MOBILEGL_DYLIB)" ] && [ -f "$(MOBILEGL_GLES_DYLIB)" ]; then \
			echo '[Amethyst v$(VERSION)] dep_mobilegl - using prebuilt dylibs in Natives/resources/Frameworks/'; \
			echo '[Amethyst v$(VERSION)] dep_mobilegl - (set BUILD_MOBILEGL=1 to rebuild from vendored source)'; \
		else \
			echo '[Amethyst v$(VERSION)] dep_mobilegl - skipped (set BUILD_MOBILEGL=1 to build from vendored source)'; \
		fi; \
	elif [ ! -d "$(MOBILEGL_SOURCE_DIR)" ]; then \
		echo '[Amethyst v$(VERSION)] dep_mobilegl - skipped (source not found: $(MOBILEGL_SOURCE_DIR))'; \
	else \
		echo '[Amethyst v$(VERSION)] dep_mobilegl - start'; \
		rm -f $(SOURCEDIR)/mobilegl-build.status; \
		{ echo '== build output =='; \
		} 2>&1 | tee -a $(SOURCEDIR)/mobilegl-build.log; \
		{ { $(MAKE) -f $(abspath $(lastword $(MAKEFILE_LIST))) dep_mobilegl_build; \
		    echo $$? > $(SOURCEDIR)/mobilegl-build.status; \
		  } 2>&1 | tee -a $(SOURCEDIR)/mobilegl-build.log; \
		}; \
		echo "== exit status = `cat $(SOURCEDIR)/mobilegl-build.status 2>/dev/null` ==" | tee -a $(SOURCEDIR)/mobilegl-build.log; \
		echo '[Amethyst v$(VERSION)] dep_mobilegl - end (log: $(SOURCEDIR)/mobilegl-build.log)'; \
	fi

# MobileGL（MobileGL-Dev，LGPL-3.0）：
# 2026-08-31 首次编译成功（libMobileGL.dylib / libMobileGL-gles.dylib），
# 产物已提交进仓库（55256e33）并关掉 BUILD_MOBILEGL，改源码时才重开。
# MobileGL 是桌面 OpenGL 实现，两个后端各一个二进制：
#   libMobileGL.dylib      -> DirectVulkan (GL -> Vulkan -> MoltenVK -> Metal)
#   libMobileGL-gles.dylib -> DirectGLES   (GL -> OpenGL ES)
# 运行时由环境变量 MOBILEGL_BACKEND_TYPE 选择（见 Natives/JavaLauncher.m）。
#
# 参考实现：Swung0x48/Amethyst-iOS 提交 dc57bfd3d2 "feat: add MobileGL renderer support"。
# 下面所有 perl 补丁都用 grep -q 做幂等守卫：上游若已自行修复则整条跳过，
# 不会因为源码变动而重复插入或报错。
dep_mobilegl_build:
	# asio 是 MobileGL 的 header-only 依赖，但 vendoring 它要额外 636 个文件
	#（约 5MB），而它只被 MG_Util/Async/ShaderCompilePool.cpp 用到，且 asio
	# 是极稳定的库 —— 故按 tag 在构建时拉取，不进仓库。
	# 用 tag（asio-1-38-2）而非分支：tag 不会被 force push，避免上游变动导致
	# 构建突然中断。以 post.hpp 是否存在为判据（而非目录），残缺目录也能补齐。
	if [ ! -f "$(MOBILEGL_SOURCE_DIR)/3rdparty/asio/include/asio/post.hpp" ]; then \
		echo '[Amethyst v$(VERSION)] dep_mobilegl - fetching asio (asio-1-38-2)'; \
		rm -rf $(MOBILEGL_SOURCE_DIR)/3rdparty/asio; \
		git clone --depth 1 --branch asio-1-38-2 https://github.com/chriskohlhoff/asio.git \
			$(MOBILEGL_SOURCE_DIR)/3rdparty/asio || \
			echo '[Amethyst v$(VERSION)] dep_mobilegl - WARNING: asio fetch failed, build will likely fail'; \
	fi
	mkdir -p $(MOBILEGL_SOURCE_DIR)/3rdparty/glslang/External
	ln -sfn $(MOBILEGL_SOURCE_DIR)/3rdparty/DiligentCore/ThirdParty/SPIRV-Tools $(MOBILEGL_SOURCE_DIR)/3rdparty/glslang/External/spirv-tools
	ln -sfn $(MOBILEGL_SOURCE_DIR)/3rdparty/DiligentCore/ThirdParty/SPIRV-Headers $(MOBILEGL_SOURCE_DIR)/3rdparty/glslang/External/spirv-headers
	mkdir -p $(MOBILEGL_SOURCE_DIR)/3rdparty/DiligentCore/ThirdParty/SPIRV-Tools/external
	ln -sfn $(MOBILEGL_SOURCE_DIR)/3rdparty/DiligentCore/ThirdParty/SPIRV-Headers $(MOBILEGL_SOURCE_DIR)/3rdparty/DiligentCore/ThirdParty/SPIRV-Tools/external/spirv-headers
	grep -q 'Range1D() = default' $(MOBILEGL_SOURCE_DIR)/MobileGL/MG_Util/Types.h || perl -i -pe 'if (/struct Range1D {/) { $$_ .= "        Range1D() = default; Range1D(SizeT s, SizeT e) : start(s), end(e) {}\n" }' $(MOBILEGL_SOURCE_DIR)/MobileGL/MG_Util/Types.h
	grep -q '#include <type_traits>' $(MOBILEGL_SOURCE_DIR)/MobileGL/MG_Util/Types.h || perl -i -pe 'if (index($$_, "#include <Includes.h>") == 0) { $$_ .= "#include <type_traits>\n" }' $(MOBILEGL_SOURCE_DIR)/MobileGL/MG_Util/Types.h
	grep -q 'std::is_aggregate_v<T>' $(MOBILEGL_SOURCE_DIR)/MobileGL/MG_Util/Types.h || perl -i -pe 's/        return std::make_unique\x3CT\x3E\(std::forward\x3CArgs\x3E\(args\)\.\.\.\);/        if constexpr (std::is_aggregate_v<T>) {\n            return std::unique_ptr<T>(new T{std::forward<Args>(args)...});\n        } else {\n            return std::make_unique<T>(std::forward<Args>(args)...);\n        }/' $(MOBILEGL_SOURCE_DIR)/MobileGL/MG_Util/Types.h
	grep -q 'BufferChange() = default' $(MOBILEGL_SOURCE_DIR)/MobileGL/MG_State/GLState/BufferState/BufferObject.h || perl -i -pe 'if (/struct BufferChange {/) { $$_ .= "        BufferChange() = default; BufferChange(Flags<BufferChangeBits> bits) : Bits(bits) {}\n" }' $(MOBILEGL_SOURCE_DIR)/MobileGL/MG_State/GLState/BufferState/BufferObject.h
	# AppleClang 15（Xcode 15.4）对 P0960（C++20 聚合体圆括号初始化）支持不完整，
	# 聚合体（DefaultFramebufferInfo/Error/Range1D/BufferChange）用 std::make_unique 圆括号
	# new T(args) 初始化会失败；但非聚合体（如 spirvtools Instruction 有 uint32_t 构造函数，
	# 调用方传 int）用 brace-init new T{args} 会 int->uint32_t narrowing。两者矛盾。
	# 方案：用 if constexpr + std::is_aggregate_v<T> 分派——
	#   聚合体  -> brace-init new T{args}（DefaultFramebufferInfo/Error 安全，不 narrowing）
	#   非聚合体-> make_unique 圆括号（调用构造函数，int->uint32_t 普通隐式转换不 narrowing）
	# Range1D/BufferChange 加了显式构造函数补丁后不再是聚合体（is_aggregate_v=false），
	# 走 make_unique 圆括号调用构造函数 Range1D(SizeT,SizeT)（int->size_t 普通转换）。
	# Range1D/BufferChange 构造函数补丁必须保留：GL_Buffer.cpp 等仍用 Range1D(x,y) 圆括号
	# 直接构造临时对象（不经 MakeUnique），若无构造函数则 C++17 聚合体圆括号语法不可用。
	# DirectGLES 后端在 iOS 上的启动崩溃：
	# ProbeTexture 无条件调用 glTexStorage*Multisample，
	# 而“指针非空”不等于上下文支持
	#（GLES 3.1+/3.2+），ANGLE/Metal 下会段错误。
	# 脚本带幂等与校验，源码变动时会明确报错而非错打。
	python3 $(SOURCEDIR)/Natives/patch_mobilegl_ios.py $(MOBILEGL_SOURCE_DIR)
	python3 $(SOURCEDIR)/Natives/patch_mobilegl_glslang.py $(MOBILEGL_SOURCE_DIR)
	mkdir -p $(WORKINGDIR)/mobilegl
	cd $(WORKINGDIR)/mobilegl && cmake \
		-DCMAKE_BUILD_TYPE=$(CMAKE_BUILD_TYPE) \
		-DCMAKE_CROSSCOMPILING=true \
		-DCMAKE_SYSTEM_NAME=Darwin \
		-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
		-DCMAKE_OSX_SYSROOT="$(SDKPATH)" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
		-DCMAKE_C_FLAGS="-arch arm64" \
		-DCMAKE_CXX_FLAGS="-arch arm64" \
		-DMOBILEGL_IOS=ON \
		-DMOBILEGL_BUILD_TEST=OFF \
		-DMOBILEGL_BUILD_BENCHMARK=OFF \
		-DMOBILEGL_BUILD_TRACE_REPLAY=OFF \
		-DMOBILEGL_VULKAN_LIBRARY="$(MOLTENVK_LIBRARY)" \
		$(MOBILEGL_SOURCE_DIR)
	cmake --build $(WORKINGDIR)/mobilegl --config $(CMAKE_BUILD_TYPE) -j$(JOBS) --target MobileGL
	# MoltenVK 1.4.2 的 install name 已经是 @rpath/libMoltenVK.dylib，与链接时记录的
	# 完全一致，无需改写。只有老版本（1.2.x，install name 为
	# @rpath/MoltenVK.framework/MoltenVK）才需要 -change。
	# 先探测再改：install_name_tool -change 找不到目标时会中断构建，不能无条件执行。
	if otool -l $(WORKINGDIR)/mobilegl/libMobileGL.dylib | grep -q 'MoltenVK.framework/MoltenVK'; then \
		install_name_tool -change @rpath/MoltenVK.framework/MoltenVK @rpath/libMoltenVK.dylib $(WORKINGDIR)/mobilegl/libMobileGL.dylib; \
		echo '[Amethyst v$(VERSION)] dep_mobilegl - rewrote MoltenVK install name (legacy layout)'; \
	else \
		echo '[Amethyst v$(VERSION)] dep_mobilegl - MoltenVK install name already @rpath/libMoltenVK.dylib, no rewrite needed'; \
	fi
	if otool -l $(WORKINGDIR)/mobilegl/libMobileGL.dylib | grep -q 'path $(SOURCEDIR)/Natives/resources/Frameworks '; then \
		install_name_tool -delete_rpath $(SOURCEDIR)/Natives/resources/Frameworks $(WORKINGDIR)/mobilegl/libMobileGL.dylib; \
	fi
	if otool -l $(WORKINGDIR)/mobilegl/libMobileGL.dylib | grep -q 'path @loader_path '; then \
		install_name_tool -delete_rpath @loader_path $(WORKINGDIR)/mobilegl/libMobileGL.dylib; \
	fi
	install_name_tool -add_rpath @loader_path $(WORKINGDIR)/mobilegl/libMobileGL.dylib
	cp $(WORKINGDIR)/mobilegl/libMobileGL.dylib $(WORKINGDIR)/libMobileGL.dylib
	# GLES 变体是同一个二进制的副本，install_name 改掉以便两个 dylib 能同时加载
	cp $(WORKINGDIR)/mobilegl/libMobileGL.dylib $(WORKINGDIR)/libMobileGL-gles.dylib
	install_name_tool -id @rpath/libMobileGL-gles.dylib $(WORKINGDIR)/libMobileGL-gles.dylib
	echo '[Amethyst v$(VERSION)] dep_mobilegl - end'

# Mithril（Uniaball/Mithril-Wrapper）：OpenGL 3.3 Core -> Vulkan -> MoltenVK -> Metal。
# 与 MobileGL 不同，Mithril 只发布预编译 dylib，本仓库不从源码编译。
# libmithril.dylib 已提交在 Natives/resources/Frameworks/ 下，payload 的
# `cp -R Natives/resources/*` 会自动把它打进 app 的 Frameworks 目录。
# 本目标只做存在性检查并给出提示；缺失时只告警不失败 —— Mithril 是可选渲染器，
# 且 LauncherPreferences.m 已按 dylib 是否存在决定是否显示该选项。
dep_mithril:
	if [ -f "$(MITHRIL_PREBUILT_DIR)/libmithril.dylib" ]; then \
		cp "$(MITHRIL_PREBUILT_DIR)/libmithril.dylib" $(SOURCEDIR)/Natives/resources/Frameworks/libmithril.dylib; \
		echo '[Amethyst v$(VERSION)] dep_mithril - installed from prebuilt/'; \
	elif [ -f "$(SOURCEDIR)/Natives/resources/Frameworks/libmithril.dylib" ]; then \
		echo '[Amethyst v$(VERSION)] dep_mithril - using existing Natives/resources/Frameworks/libmithril.dylib'; \
	else \
		echo '[Amethyst v$(VERSION)] dep_mithril - libmithril.dylib not found, Mithril renderer will be hidden'; \
		echo '[Amethyst v$(VERSION)] dep_mithril - run scripts/fetch_mithril.sh to download it'; \
	fi

assets:
	echo '[Amethyst v$(VERSION)] assets - start'
	if [ '$(IOS)' = '0' ] && [ '$(DETECTPLAT)' = 'Darwin' ]; then \
		mkdir -p $(WORKINGDIR)/AngelAuraAmethyst.app/Base.lproj; \
		xcrun actool $(SOURCEDIR)/Natives/Assets.xcassets \
			--compile $(SOURCEDIR)/Natives/resources \
			--platform iphoneos \
			--minimum-deployment-target 14.0 \
			--app-icon AppIcon-Light \
			--output-partial-info-plist /dev/null || exit 1; \
	else \
		echo 'Due to the required tools not being available, you cannot compile the extras for Angel Aura Amethyst with an iOS device.'; \
	fi
	echo '[Amethyst v$(VERSION)] assets - end'

payload: native dep_mg dep_shader_shims dep_openal_shim dep_angle_freeze dep_sdl3_guard java jre assets
	echo '[Amethyst v$(VERSION)] payload - start'
	# Mithril / MobileGL 都是可选渲染器：这里用 - 前缀，任一失败都不阻断主构建。
	# 缺库时对应渲染器会在设置里自动隐藏（见 LauncherPreferences.m 的存在性过滤）。
	-$(MAKE) dep_mithril
	-$(MAKE) dep_mobilegl
	$(call METHOD_DIRCHECK,$(WORKINGDIR)/AngelAuraAmethyst.app/libs)
	$(call METHOD_DIRCHECK,$(WORKINGDIR)/AngelAuraAmethyst.app/libs_caciocavallo)
	$(call METHOD_DIRCHECK,$(WORKINGDIR)/AngelAuraAmethyst.app/libs_caciocavallo17)
	cp -R $(SOURCEDIR)/Natives/resources/en.lproj/LaunchScreen.storyboardc $(WORKINGDIR)/AngelAuraAmethyst.app/Base.lproj/ || exit 1
	cp -R $(SOURCEDIR)/Natives/resources/* $(WORKINGDIR)/AngelAuraAmethyst.app/ || exit 1
	cp $(WORKINGDIR)/*.dylib $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/ || exit 1
	# spirv-cross 软链接（防御性兜底）：若 MobileGlues 构建产出 libspirv-cross-c-shared.0.dylib，
	# 创建 libspirv-cross.dylib 软链接，兼容按 macOS 默认名加载的 native 代码。
	if [ -f "$(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/libspirv-cross-c-shared.0.dylib" ] && [ ! -f "$(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/libspirv-cross.dylib" ]; then \
		ln -sf libspirv-cross-c-shared.0.dylib $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/libspirv-cross.dylib; \
	fi
		cp -R $(SOURCEDIR)/JavaApp/libs/others/* $(WORKINGDIR)/AngelAuraAmethyst.app/libs/ || exit 1
	cp $(SOURCEDIR)/JavaApp/build/launcher.jar $(SOURCEDIR)/JavaApp/build/patchjna_agent.jar $(SOURCEDIR)/JavaApp/build/patchsvc.jar $(SOURCEDIR)/JavaApp/build/mojang-stubs.jar $(WORKINGDIR)/AngelAuraAmethyst.app/libs/ || exit 1
	# LWJGL 以双版本 jar 发布，由启动器按 MC 版本在运行时选择其一。
	# 必须放进各自的 libs/lwjgl-<ver>/ 子目录：若平铺进 libs/，会被 classpath 中
	# 的 libs/* 一并加载，使 3.3.3 与 3.4.1 的同名类同时进入 classpath 造成冲突。
	mkdir -p $(WORKINGDIR)/AngelAuraAmethyst.app/libs/lwjgl-333 $(WORKINGDIR)/AngelAuraAmethyst.app/libs/lwjgl-341; \
	cp $(SOURCEDIR)/JavaApp/build/lwjgl-333.jar $(WORKINGDIR)/AngelAuraAmethyst.app/libs/lwjgl-333/lwjgl.jar || exit 1
	cp $(SOURCEDIR)/JavaApp/build/lwjgl-341.jar $(WORKINGDIR)/AngelAuraAmethyst.app/libs/lwjgl-341/lwjgl.jar || exit 1
	cp -R $(SOURCEDIR)/JavaApp/libs/caciocavallo/* $(WORKINGDIR)/AngelAuraAmethyst.app/libs_caciocavallo || exit 1
	cp -R $(SOURCEDIR)/JavaApp/libs/caciocavallo17/* $(WORKINGDIR)/AngelAuraAmethyst.app/libs_caciocavallo17 || exit 1
	# Copy TouchController static library if available
	if [ -f "$(SOURCEDIR)/TouchController/libproxy_server_ios.a" ]; then \
		mkdir -p $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks; \
		cp $(SOURCEDIR)/TouchController/libproxy_server_ios.a $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/ || exit 1; \
		echo '[Amethyst v$(VERSION)] Copied TouchController device library'; \
	elif [ -f "$(SOURCEDIR)/TouchController/libproxy_server_ios_simulator.a" ]; then \
		mkdir -p $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks; \
		cp $(SOURCEDIR)/TouchController/libproxy_server_ios_simulator.a $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/ || exit 1; \
		echo '[Amethyst v$(VERSION)] Copied TouchController simulator library'; \
	else \
		echo '[Amethyst v$(VERSION)] TouchController library not found, skipping'; \
	fi
	$(call METHOD_DIRCHECK,$(OUTPUTDIR)/Payload)
	cp -R $(WORKINGDIR)/AngelAuraAmethyst.app $(OUTPUTDIR)/Payload
	if [ '$(SLIMMED_ONLY)' != '1' ]; then \
		cp -R $(OUTPUTDIR)/java_runtimes $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app; \
	fi
	ldid -S $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app; \
	if [ '$(TROLLSTORE_JIT_ENT)' == '1' ]; then \
		ldid -S$(SOURCEDIR)/entitlements.trollstore.xml $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/AngelAuraAmethyst; \
	elif [ '$(PLATFORM)' == '6' ]; then \
		ldid -S$(SOURCEDIR)/entitlements.codesign.xml $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/AngelAuraAmethyst; \
	else \
		ldid -S$(SOURCEDIR)/entitlements.sideload.xml $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/AngelAuraAmethyst; \
	fi
	chmod -R 755 $(OUTPUTDIR)/Payload
	# 总是运行平台重打标（对齐 Ynnyny 仓库）—— 对已 iOS 标记的 Mach-O 是幂等的，
	# 但能捕获从 Maven 直接拉取的新 dylib（如 3.3.5 lwjgl-stb），它们 ship 时
	# platform=macos，iOS dyld 会静默拒绝加载，导致 LWJGL 抛 UnsatisfiedLinkError。
	# 原本用 [ PLATFORM != 2 ] 守卫的假设是所有 commit 的 dylib 都已 iOS 标记，
	# 这个假设在同步 Ynnyny 顶层 dylib 时被打破。
	$(call METHOD_MACHO,$(OUTPUTDIR)/Payload/AngelAuraAmethyst.app,$(call METHOD_CHANGE_PLAT,$(PLATFORM),$$file)); \
	$(call METHOD_MACHO,$(OUTPUTDIR)/java_runtimes,$(call METHOD_CHANGE_PLAT,$(PLATFORM),$$file));
	echo '[Amethyst v$(VERSION)] payload - end'

deploy:
	echo '[Amethyst v$(VERSION)] deploy - start'
	cd $(OUTPUTDIR); \
	if [ '$(IOS)' = '1' ]; then \
		ldid -S $(WORKINGDIR)/AngelAuraAmethyst.app || exit 1; \
		ldid -S$(SOURCEDIR)/entitlements.trollstore.xml $(WORKINGDIR)/AngelAuraAmethyst.app/AngelAuraAmethyst || exit 1; \
		sudo mv $(WORKINGDIR)/*.dylib $(PREFIX)Applications/AngelAuraAmethyst.app/Frameworks/ || exit 1; \
		sudo mv $(WORKINGDIR)/AngelAuraAmethyst.app/AngelAuraAmethyst $(PREFIX)Applications/AngelAuraAmethyst.app/AngelAuraAmethyst || exit 1; \
		sudo mv $(SOURCEDIR)/JavaApp/build/launcher.jar $(SOURCEDIR)/JavaApp/build/patchjna_agent.jar $(SOURCEDIR)/JavaApp/build/patchsvc.jar $(PREFIX)Applications/AngelAuraAmethyst.app/libs/ || exit 1; \
		sudo mkdir -p $(PREFIX)Applications/AngelAuraAmethyst.app/libs/lwjgl-333 $(PREFIX)Applications/AngelAuraAmethyst.app/libs/lwjgl-341 || exit 1; \
		sudo mv $(SOURCEDIR)/JavaApp/build/lwjgl-333.jar $(PREFIX)Applications/AngelAuraAmethyst.app/libs/lwjgl-333/lwjgl.jar || exit 1; \
		sudo mv $(SOURCEDIR)/JavaApp/build/lwjgl-341.jar $(PREFIX)Applications/AngelAuraAmethyst.app/libs/lwjgl-341/lwjgl.jar || exit 1; \
		cd $(PREFIX)Applications/AngelAuraAmethyst.app/Frameworks || exit 1; \
		sudo chown -R 501:501 $(PREFIX)Applications/AngelAuraAmethyst.app/* || exit 1; \
	elif [ '$(IOS)' = '0' ] && [ '$(DETECTPLAT)' = 'Darwin' ]; then \
		if [ '$(PLATFORM)' != '2' ] || [ '$(TEAMID)' = '-1' ] || [ '$(SIGNING_TEAMID)' = '-1' ] || [ '$(PROVISIONING)' = '-1' ]; then \
			echo 'Configuration not supported for deploy recipe.'; \
		else \
			$(call METHOD_PACKAGE); \
			if [ '$(SLIMMED_ONLY)' = '0' ]; then \
				open $(OUTPUTDIR)/com.air-devs.air-$(VERSION)-$(PLATFORM_NAME).ipa; \
			else \
				open $(OUTPUTDIR)/com.air-devs.air.slimmed-$(VERSION)-$(PLATFORM_NAME).ipa; \
			fi; \
		fi; \
	else \
		echo 'Device not supported for deploy recipe.'; \
	fi
	echo '[Amethyst v$(VERSION)] deploy - end'

package: payload
	echo '[Amethyst v$(VERSION)] package - start'
	if [ '$(TEAMID)' != '-1' ] && [ '$(SIGNING_TEAMID)' != '-1' ] && [ -f '$(PROVISIONING)' ] && [ '$(DETECTPLAT)' = 'Darwin' ]; then \
		printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n	<key>application-identifier</key>\n	<string>$(TEAMID).com.air-devs.air</string>\n	<key>com.apple.developer.team-identifier</key>\n	<string>$(TEAMID)</string>\n	<key>get-task-allow</key>\n	<true/>\n	<key>keychain-access-groups</key>\n	<array>\n	<string>$(TEAMID).*</string>\n	<string>com.apple.token</string>\n	</array>\n	<key>com.apple.developer.kernel.extended-virtual-addressing</key>\n	<true/>\n	<key>com.apple.developer.kernel.increased-memory-limit</key>\n	<true/>\n</dict>\n</plist>' > entitlements.codesign.xml; \
		$(MAKE) codesign; \
		rm -rf entitlements.codesign.xml; \
	else \
		echo 'Skipped codesigning. If not intentional, check your variables.'; \
	fi
	cd $(OUTPUTDIR); \
	$(call METHOD_PACKAGE); \
	zip --symlinks -r $(OUTPUTDIR)/java_runtimes.zip java_runtimes; \
	echo '[Amethyst v$(VERSION)] package - end'

dsym: payload
	echo '[Amethyst v$(VERSION)] dsym - start'
	dsymutil --arch arm64 $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/AngelAuraAmethyst; \
	rm -rf $(OUTPUTDIR)/AngelAuraAmethyst.dSYM; \
	mv $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/AngelAuraAmethyst.dSYM $(OUTPUTDIR)/AngelAuraAmethyst.dSYM
	echo '[Amethyst v$(VERSION)] dsym - end'
	
codesign:
	echo '[Amethyst v$(VERSION)] codesign - start'
	cp '$(PROVISIONING)' $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/embedded.mobileprovision
	$(call METHOD_MACHO,$(OUTPUTDIR)/Payload/AngelAuraAmethyst.app,$(call METHOD_CODESIGN,$(SIGNING_TEAMID),$$file))
	$(call METHOD_MACHO,$(OUTPUTDIR)/java_runtimes,$(call METHOD_CODESIGN,$(SIGNING_TEAMID),$$file))
	echo '[Amethyst v$(VERSION)] codesign - end'

clean:
	echo '[Amethyst v$(VERSION)] clean - start'
	rm -rf $(WORKINGDIR)
	rm -rf JavaApp/build
	rm -rf $(OUTPUTDIR)
	echo '[Amethyst v$(VERSION)] clean - end'

.PHONY: all clean check native java jre package dsym deploy help

