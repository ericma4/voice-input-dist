APP_NAME := VoiceInput
APP_BUNDLE := $(APP_NAME).app
BUILD_DIR := $(shell swift build -c release --show-bin-path 2>/dev/null || echo .build/release)

.PHONY: build clean install install-app run

build:
	swift build -c release
	$(eval BUILD_DIR := $(shell swift build -c release --show-bin-path))
	# 目标路径固定在当前仓库，清理的是上一轮生成的 app bundle，不触碰用户数据。
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	if [ -d Resources ]; then cp -R Resources/. $(APP_BUNDLE)/Contents/Resources/; fi
	cp -R Engine $(APP_BUNDLE)/Contents/Resources/Engine
	# 本地测试生成的字节码与目标 Python 版本无关，应用包只分发可审计的源文件。
	find $(APP_BUNDLE)/Contents/Resources/Engine -type f -name '*.pyc' -delete
	find $(APP_BUNDLE)/Contents/Resources/Engine -depth -type d -name '__pycache__' -delete
	cp Info.plist $(APP_BUNDLE)/Contents/
	codesign --force --deep --options runtime --sign - --entitlements VoiceInput.entitlements $(APP_BUNDLE)
	@echo "✅ Built $(APP_BUNDLE)"

run: build
	open $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)

install-app: build
	rm -rf /Applications/$(APP_BUNDLE)
	cp -R $(APP_BUNDLE) /Applications/
	@echo "✅ Installed /Applications/$(APP_BUNDLE)"

install:
	bash Scripts/install.sh
