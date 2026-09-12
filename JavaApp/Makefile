# Prerequisite variables
SOURCEDIR := src
OUTPUTDIR := build

SOURCES := $(shell find $(SOURCEDIR) -type f -name '*.java')
CLASSES := $(SOURCES:$(SOURCEDIR)/%.java=$(OUTPUTDIR)/%.class)

TARGETS := $(shell find $(SOURCEDIR) -mindepth 1 -maxdepth 1 -type d)
TARGETS := $(TARGETS:$(SOURCEDIR)/%=$(OUTPUTDIR)/%.jar)

# Add all jars to classpath and allow compiling with private API
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

$(OUTPUTDIR)/lwjgl.jar: $(CLASSES) check_empty_classes
	@set -e
	@echo "Creating $@"
	@mkdir -p $(OUTPUTDIR)/lwjgl_lib
	@cd $(OUTPUTDIR)/lwjgl_lib && find ../../libs/lwjgl -name 'lwjgl*.jar' -exec $(BOOTJDK)/jar -xf {} \; && rm -rf META-INF
	@cd $(OUTPUTDIR)/lwjgl_lib && $(BOOTJDK)/jar -xf "../../../lwjgl.jar" && rm -rf META-INF
	@cp -R $(OUTPUTDIR)/lwjgl/* $(OUTPUTDIR)/lwjgl_lib/
	# NOTE: com.apple.ios.audio stays in launcher.jar only.  Packing it into
	# lwjgl.jar as well makes modules "lwjgl" and "launcher" both export the same
	# package, and Forge's bootstrap module resolver aborts with
	# ResolutionException ("Modules lwjgl and launcher export package
	# com.apple.ios.audio").  Keep the audio SPI provider out of this jar too.
	@$(BOOTJDK)/jar -cf $@ -C $(OUTPUTDIR)/lwjgl_lib .

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
