VERSION ?= 0.1.1
APP_NAME := ShotX
ICON_PNG := icon/shotx.png
ICON_ICNS := .build/ShotX.icns
ICONSET_DIR := .build/ShotX.iconset

.PHONY: build test icons app verify package clean

build:
	swift build

test:
	swift test

# Generate ShotX.icns from icon/shotx.png (source of truth for APP icon).
icons:
	rm -rf $(ICONSET_DIR)
	mkdir -p $(ICONSET_DIR)
	sips -z 16 16  $(ICON_PNG) --out $(ICONSET_DIR)/icon_16x16.png
	sips -z 32 32  $(ICON_PNG) --out $(ICONSET_DIR)/icon_16x16@2x.png
	sips -z 32 32  $(ICON_PNG) --out $(ICONSET_DIR)/icon_32x32.png
	sips -z 64 64  $(ICON_PNG) --out $(ICONSET_DIR)/icon_32x32@2x.png
	sips -z 128 128 $(ICON_PNG) --out $(ICONSET_DIR)/icon_128x128.png
	sips -z 256 256 $(ICON_PNG) --out $(ICONSET_DIR)/icon_128x128@2x.png
	sips -z 256 256 $(ICON_PNG) --out $(ICONSET_DIR)/icon_256x256.png
	sips -z 512 512 $(ICON_PNG) --out $(ICONSET_DIR)/icon_256x256@2x.png
	sips -z 512 512 $(ICON_PNG) --out $(ICONSET_DIR)/icon_512x512.png
	cp $(ICON_PNG) $(ICONSET_DIR)/icon_512x512@2x.png
	iconutil -c icns $(ICONSET_DIR) -o $(ICON_ICNS)

app: icons
	swift build -c release
	rm -rf $(APP_NAME).app
	mkdir -p $(APP_NAME).app/Contents/MacOS $(APP_NAME).app/Contents/Resources
	cp .build/release/$(APP_NAME) $(APP_NAME).app/Contents/MacOS/$(APP_NAME)
	cp Support/Info.plist $(APP_NAME).app/Contents/Info.plist
	cp $(ICON_ICNS) $(APP_NAME).app/Contents/Resources/$(APP_NAME).icns
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(APP_NAME).app/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" $(APP_NAME).app/Contents/Info.plist
	codesign --force --deep --sign - $(APP_NAME).app

verify:
	codesign --verify --deep --strict --verbose=2 $(APP_NAME).app

package: app verify
	rm -f releases/$(APP_NAME)-$(VERSION).app.zip releases/$(APP_NAME)-$(VERSION)-source.zip
	ditto -c -k --sequesterRsrc --keepParent $(APP_NAME).app releases/$(APP_NAME)-$(VERSION).app.zip
	ditto -c -k --keepParent Sources releases/$(APP_NAME)-$(VERSION)-source.zip
	ls -la releases/$(APP_NAME)-$(VERSION).app.zip releases/$(APP_NAME)-$(VERSION)-source.zip

clean:
	swift package clean
	rm -rf $(APP_NAME).app $(ICON_ICNS) $(ICONSET_DIR)
