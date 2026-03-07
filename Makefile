APP_NAME = ClaudeUsageBar
BUILD_DIR = .build/release
BUNDLE_DIR = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS_DIR = $(BUNDLE_DIR)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
RESOURCES_DIR = $(CONTENTS_DIR)/Resources

.PHONY: build bundle install run clean

build:
	swift build -c release

bundle: build
	mkdir -p $(MACOS_DIR) $(RESOURCES_DIR)
	cp $(BUILD_DIR)/$(APP_NAME) $(MACOS_DIR)/$(APP_NAME)
	cp Resources/Info.plist $(CONTENTS_DIR)/Info.plist
	cp Resources/AppIcon.icns $(RESOURCES_DIR)/AppIcon.icns
	xattr -cr $(BUNDLE_DIR)
	codesign --force --sign - $(BUNDLE_DIR)

install: bundle
	cp -R $(BUNDLE_DIR) /Applications/$(APP_NAME).app

run: bundle
	open $(BUNDLE_DIR)

clean:
	swift package clean
	rm -rf $(BUNDLE_DIR)
