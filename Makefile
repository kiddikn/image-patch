APP      := ImagePatch
BIN      := .build/release/$(APP)
OUT      := build
BUNDLE   := $(OUT)/$(APP).app
ICONSET  := $(OUT)/AppIcon.iconset

.PHONY: all build icon bundle install run clean uninstall

all: bundle

build:
	swift build -c release

icon:
	@mkdir -p $(OUT)
	swift Tools/makeicon.swift $(OUT)/icon-1024.png
	@rm -rf $(ICONSET)
	@mkdir -p $(ICONSET)
	@sips -z 16 16     $(OUT)/icon-1024.png --out $(ICONSET)/icon_16x16.png      >/dev/null
	@sips -z 32 32     $(OUT)/icon-1024.png --out $(ICONSET)/icon_16x16@2x.png   >/dev/null
	@sips -z 32 32     $(OUT)/icon-1024.png --out $(ICONSET)/icon_32x32.png      >/dev/null
	@sips -z 64 64     $(OUT)/icon-1024.png --out $(ICONSET)/icon_32x32@2x.png   >/dev/null
	@sips -z 128 128   $(OUT)/icon-1024.png --out $(ICONSET)/icon_128x128.png    >/dev/null
	@sips -z 256 256   $(OUT)/icon-1024.png --out $(ICONSET)/icon_128x128@2x.png >/dev/null
	@sips -z 256 256   $(OUT)/icon-1024.png --out $(ICONSET)/icon_256x256.png    >/dev/null
	@sips -z 512 512   $(OUT)/icon-1024.png --out $(ICONSET)/icon_256x256@2x.png >/dev/null
	@sips -z 512 512   $(OUT)/icon-1024.png --out $(ICONSET)/icon_512x512.png    >/dev/null
	@cp $(OUT)/icon-1024.png $(ICONSET)/icon_512x512@2x.png
	iconutil -c icns $(ICONSET) -o $(OUT)/AppIcon.icns

bundle: build icon
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp $(OUT)/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	codesign --force --sign - $(BUNDLE)
	@echo "→ $(BUNDLE)"

install: bundle
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/
	@echo "→ /Applications/$(APP).app"

run: install
	open /Applications/$(APP).app

uninstall:
	rm -rf /Applications/$(APP).app

clean:
	rm -rf .build $(OUT)
