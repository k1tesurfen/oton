VERSION  ?= 0.3.0
IDENTITY ?= oton Local
APP      := build/oton.app
DMG      := build/oton.dmg
ZIP      := build/oton.app.zip
BIN      = $(shell swift build -c release --arch arm64 --show-bin-path)
DOMAIN   := gui/$(shell id -u)
# Command Line Tools only (no Xcode): swift test doesn't find the Swift Testing macro plugin on its own.
TESTING_PLUGINS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing

.PHONY: build app install uninstall cleanup-old test cert icon alfred dmg zip release clean

build:
	swift build -c release --arch arm64

# Alfred workflow (keyword: ot); double-click to import. Also shipped inside the app and on the DMG.
alfred:
	mkdir -p build/alfred
	cp alfred/info.plist build/alfred/info.plist
	cp Resources/icon/oton.png build/alfred/icon.png
	rm -f build/oton.alfredworkflow
	cd build/alfred && zip -q ../oton.alfredworkflow info.plist icon.png
	@echo build/oton.alfredworkflow

# Assemble and sign the bundle with the stable self-signed identity, so macOS keeps the microphone
# permission across updates (on every Mac: the requirement names this certificate, trusted or not).
app: build alfred
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" -c "Set :CFBundleVersion $(VERSION)" $(APP)/Contents/Info.plist
	cp Resources/oton.icns $(APP)/Contents/Resources/oton.icns
	cp build/oton.alfredworkflow $(APP)/Contents/Resources/oton.alfredworkflow
	cp $(BIN)/oton $(APP)/Contents/MacOS/oton
	cp $(BIN)/ot $(APP)/Contents/MacOS/ot
	codesign --force --options runtime --timestamp=none --sign "$(IDENTITY)" --identifier local.oton.ot $(APP)/Contents/MacOS/ot
	codesign --force --options runtime --timestamp=none --sign "$(IDENTITY)" --entitlements Resources/oton.entitlements $(APP)
	codesign --verify --strict $(APP) && echo "signed: $(APP) $(VERSION)"

# Local install: replace /Applications/oton.app and start it. The app adds itself to the login items;
# `ot` and Alfred are installed from its menu (Setup).
install: app cleanup-old
	-osascript -e 'tell application id "local.oton" to quit' 2>/dev/null
	-pkill -x oton; sleep 1
	rm -rf /Applications/oton.app
	cp -R $(APP) /Applications/oton.app
	open /Applications/oton.app
	@echo "Installed oton $(VERSION). Check with: ot"

uninstall:
	-pkill -x oton
	rm -rf /Applications/oton.app
	-sudo rm -f /usr/local/bin/ot

# Earlier installs: the Continuum app and oton's old LaunchAgent (now a login item).
cleanup-old:
	@if [ -e $(HOME)/Library/LaunchAgents/local.oton.plist ]; then \
		launchctl bootout $(DOMAIN)/local.oton 2>/dev/null || true; rm -f $(HOME)/Library/LaunchAgents/local.oton.plist; fi
	@if [ -e $(HOME)/Library/LaunchAgents/local.continuum.plist ] || [ -e /Applications/Continuum.app ]; then \
		launchctl bootout $(DOMAIN)/local.continuum 2>/dev/null || true; \
		rm -f $(HOME)/Library/LaunchAgents/local.continuum.plist; rm -rf /Applications/Continuum.app; fi

# Disk image for colleagues: oton.app, an Applications link, the Alfred workflow, a background with the steps.
dmg: app
	scripts/make-dmg.sh $(APP) $(DMG)

# What the self-update downloads (the app checks it's signed with the same certificate before installing).
zip: app
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	@echo "$(ZIP) ($$(du -h $(ZIP) | cut -f1))"

# Build, then publish v$(VERSION) on GitHub with the DMG and the update zip (needs a clean, pushed main).
release: test dmg zip
	@test -z "$$(git status --porcelain)" || (echo "uncommitted changes"; exit 1)
	git tag -a v$(VERSION) -m "oton $(VERSION)"
	git push origin main v$(VERSION)
	gh release create v$(VERSION) $(DMG) $(ZIP) --title "oton $(VERSION)" --notes-file docs/release-notes/$(VERSION).md

# Always from scratch: incremental test builds lose the Testing macro plugin.
test:
	rm -rf .build/test
	swift test --scratch-path .build/test -Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS)

cert:
	scripts/make-cert.sh

# Re-render Resources/oton.icns after editing Resources/icon/oton.svg (needs rsvg-convert).
icon:
	scripts/make-icon.sh

clean:
	rm -rf .build build
