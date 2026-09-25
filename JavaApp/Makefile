# Prerequisite variables
SOURCEDIR := src
OUTPUTDIR := build

SOURCES := $(shell find $(SOURCEDIR) -type f -name '*.java')
CLASSES := $(SOURCES:$(SOURCEDIR)/%.java=$(OUTPUTDIR)/%.class)

TARGETS := $(shell find $(SOURCEDIR) -mindepth 1 -maxdepth 1 -type d)
TARGETS := $(TARGETS:$(SOURCEDIR)/%=$(OUTPUTDIR)/%.jar)

# Add all jars to classpath and allow compiling with private API
# 编译期 classpath 顺序说明：$(wildcard libs/*/*.jar) 按字典序展开，
# libs/lwjgl < libs/lwjgl-333 < libs/lwjgl-341，因此老版 Amethyst 预编译 jar
# （含 GLFW.mGLFWWindowWidth 等扩展 API 表面）会排在版本化集合之前。
# 参考仓库显式列出各目录是为了固定该顺序，此处 wildcard 的字典序已等价满足。
# 运行时只使用 lwjgl-333.jar / lwjgl-341.jar，不依赖 libs/lwjgl。
JCFLAGS := -cp "$(subst $() $(),:,$(wildcard $(SOURCEDIR)/*/):$(wildcard libs/*/*.jar))" -XDignore.symbol.file

all: $(TARGETS)

# Sometimes the CI produces empty class file resulting in broken jar, so we check and abort here
# 改进：发现空 class 文件时先从 classes/ 目录重新复制（修复 cp 与 javac 并行竞态
# 导致次级 class 文件如 NarratorDummy.class 为空的偶发问题），重试后仍为空才报错。
check_empty_classes:
	@set -e
	@echo "Checking for empty class files"
	@for f in $$(find $(OUTPUTDIR) -not -path '$(OUTPUTDIR)/classes/*' -name '*.class' -size 0 2>/dev/null); do \
		rel=$${f#$(OUTPUTDIR)/}; \
		module=$$(echo "$$rel" | cut -d/ -f1); \
		classpath=$${rel#$$module/}; \
		src="$(OUTPUTDIR)/classes/$$classpath"; \
		if [ -f "$$src" ] && [ -s "$$src" ]; then \
			echo "Warning: re-copying empty $$classpath from classes/"; \
			cp -f "$$src" "$$f"; \
		fi; \
	done
	@EMPTY_CLASSES=$$(find $(OUTPUTDIR) -not -path '$(OUTPUTDIR)/classes/*' -name '*.class' -size 0 2>/dev/null); \
	if [ -n "$$EMPTY_CLASSES" ]; then \
		echo "Error: found empty class files in $@: $$EMPTY_CLASSES"; \
		exit 1; \
	fi

# Rules for building java class
$(CLASSES): $(OUTPUTDIR)/%.class: $(SOURCEDIR)/%.java
	@set -e
	$(eval TARGET=$(word 2, $(subst /, ,$@)))
	@mkdir -p $(OUTPUTDIR)/classes
	@mkdir -p $(dir $@)
	@echo "Compiling $<"
	@$(BOOTJDK)/javac $(JCFLAGS) -d $(OUTPUTDIR)/classes $<
	@cp $(@:$(OUTPUTDIR)/$(TARGET)/%.class=$(OUTPUTDIR)/classes/%*.class) $(dir $@)/
	@# 防御性校验：CI 偶发产生空 class 文件（cp 与 javac/并行任务竞态），
	@# 复制后若主 class 仍为 0 字节则重试一次，避免 check_empty_classes 误报中断构建。
	@if [ -e "$@" ] && [ ! -s "$@" ]; then \
		echo "Warning: $@ is empty after cp, retrying copy"; \
		cp -f $(@:$(OUTPUTDIR)/$(TARGET)/%.class=$(OUTPUTDIR)/classes/%*.class) $(dir $@)/; \
	fi

$(OUTPUTDIR)/launcher.jar: $(CLASSES) check_empty_classes
	@set -e
	@echo "Creating $@"
	@cp -r $(SOURCEDIR)/launcher/META-INF $(basename $@)/ 2>/dev/null || true
	@$(BOOTJDK)/jar -cf $@ -C $(basename $@) .

# 按 LWJGL 版本分别产出一个合并 jar（3.3.3 与 3.4.1）。
#
# 解压顺序即覆盖优先级（后者覆盖前者）：
#   1) 仓库根 lwjgl.jar —— iOS 专用 LWJGL 补丁层，同时提供 LWJGL2 兼容类
#      （org/lwjgl/opengl/Display、org/lwjgl/input/Keyboard、LWJGLException 等），
#      老版本 MC（Java 8 / 1.12.2 及以下）依赖这些类，必须作为基底保留。
#   2) libs/lwjgl-<ver>/*.jar —— 版本化的 LWJGL3。341 集合含真正的
#      lwjgl-sdl.jar（加载真实 libSDL3），是 SDL3 输入注入的前提。
#      放在基底之后，以便版本化的 LWJGL3 核心类（GLFW / MemoryUtil / SDL 等）
#      覆盖根 jar 中的同名旧类。
#   3) build/lwjgl/ —— Amethyst overlay（GLFW.java 等带 iOS 桥接的改写类），
#      必须最后覆盖。
$(OUTPUTDIR)/lwjgl-%.jar: $(CLASSES) check_empty_classes
	@set -e
	@echo "Creating $@"
	@mkdir -p $(OUTPUTDIR)/lwjgl_lib_$*
	@cd $(OUTPUTDIR)/lwjgl_lib_$* && $(BOOTJDK)/jar -xf "../../../lwjgl.jar" && rm -rf META-INF
	# 仓库根 lwjgl.jar 里混入了 3 个用 JDK 25 编译的类（major 69）：
	#   org/lwjgl/openal/SOFTSystemEvent{,s,ProcI}.class
	# 它是"3.3.3 提供 3.4.1 API 兼容"的定制版，这 3 个类是从 3.4.1 一并塞进来的。
	# 3.4.1 自带它们的 Java 8 版本，下一步解压后会被覆盖回来；但 3.3.3 没有这些
	# 类，若保留 JDK 25 版本，Java 8 上的老版本 MC 一旦碰到就会抛
	# UnsupportedClassVersionError。因此在叠加版本化 jar 之前先删掉。
	@cd $(OUTPUTDIR)/lwjgl_lib_$* && find org/lwjgl/openal -maxdepth 1 -name 'SOFTSystemEvent*.class' -delete 2>/dev/null || true
	@cd $(OUTPUTDIR)/lwjgl_lib_$* && find ../../libs/lwjgl-$* -name 'lwjgl*.jar' -exec $(BOOTJDK)/jar -xf {} \; && rm -rf META-INF
	@cp -R $(OUTPUTDIR)/lwjgl/* $(OUTPUTDIR)/lwjgl_lib_$*/
	@mkdir -p $(OUTPUTDIR)/lwjgl_lib_$*/com/apple/ios/audio
	@cp -R $(OUTPUTDIR)/launcher/com/apple/ios/audio/*.class $(OUTPUTDIR)/lwjgl_lib_$*/com/apple/ios/audio/
	@mkdir -p $(OUTPUTDIR)/lwjgl_lib_$*/META-INF/services
	@cp $(SOURCEDIR)/launcher/META-INF/services/javax.sound.sampled.spi.MixerProvider $(OUTPUTDIR)/lwjgl_lib_$*/META-INF/services/
	@$(BOOTJDK)/jar -cf $@ -C $(OUTPUTDIR)/lwjgl_lib_$* .

# lwjgl.jar 仅作占位：all 目标因 src/lwjgl 是源码目录而列出它，但运行时使用
# lwjgl-333.jar / lwjgl-341.jar。build/lwjgl.jar 不得进入 app 的 libs 目录，
# 否则会被 classpath 中的 libs/* 与版本化 jar 一并加载，造成同名类冲突。
$(OUTPUTDIR)/lwjgl.jar: $(OUTPUTDIR)/lwjgl-333.jar $(OUTPUTDIR)/lwjgl-341.jar
	@echo "Skipping $@ (lwjgl-333.jar / lwjgl-341.jar are used instead)"

$(OUTPUTDIR)/patchjna_agent.jar: $(CLASSES)
	@set -e
	@mv $(basename $@)/com/sun/jna/Platform.class $(basename $@)/com/sun/jna/Platform.class.patch
	@echo "Creating $@"
	@$(BOOTJDK)/jar -cfm $@ $(SOURCEDIR)/patchjna_agent.txt -C $(basename $@) .

$(OUTPUTDIR)/patchsvc.jar: $(CLASSES)
	@set -e
	@mv $(basename $@)/de/maxhenkel/lame4j/Mp3Decoder.class $(basename $@)/de/maxhenkel/lame4j/Mp3Decoder.class.patch
	@mv $(basename $@)/de/maxhenkel/lame4j/Mp3Encoder.class $(basename $@)/de/maxhenkel/lame4j/Mp3Encoder.class.patch
	@mv $(basename $@)/de/maxhenkel/opus4j/OpusDecoder.class $(basename $@)/de/maxhenkel/opus4j/OpusDecoder.class.patch
	@mv $(basename $@)/de/maxhenkel/opus4j/OpusEncoder.class $(basename $@)/de/maxhenkel/opus4j/OpusEncoder.class.patch
	@mv $(basename $@)/de/maxhenkel/rnnoise4j/Denoiser.class $(basename $@)/de/maxhenkel/rnnoise4j/Denoiser.class.patch
	@mv $(basename $@)/de/maxhenkel/speex4j/AutomaticGainControl.class $(basename $@)/de/maxhenkel/speex4j/AutomaticGainControl.class.patch
	@rm -rf $(basename $@)/de/maxhenkel/*/*.class
	@echo "Creating $@"
	@$(BOOTJDK)/jar -cfm $@ $(SOURCEDIR)/patchsvc.txt -C $(basename $@) .

clean:
	rm -rf $(OUTPUTDIR)

.SUFFIXES: .java
.PHONY: all clean
