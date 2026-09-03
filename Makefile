APP = dist/CodeCat.app

# The marketing version is edited by hand in Resources/Info.plist — a human's
# decision, not a consequence of the commit log.
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
# CFBundleVersion, on the other hand, is derived from the commit count: it used to
# be "1" in every build without exception, so two different builds were
# indistinguishable — in Finder and in a crash report alike.
BUILD := $(shell git rev-list --count HEAD)

# Matched by substring rather than pinned by hash: certificates are reissued yearly,
# and a hard-coded fingerprint would quietly turn `make release` into an error a
# year from now.
SIGN_ID ?= $(shell security find-identity -v -p codesigning \
	| grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
NOTARY_PROFILE ?= codecat

ZIP = dist/CodeCat-$(VERSION).zip
DMG = dist/CodeCat-$(VERSION).dmg

.PHONY: app bundle release notarize verify-skins assets test clean

test:
	swift test

# Assets that may not be kept in the repository. There is one today — Elthen's
# sheet: the author allows using the sprites but not passing the files on, and a
# public repository does exactly that. The script does not fail the build: without
# the sheet one skin of eight is simply missing, and failing because itch.io is
# unreachable earns nothing.
assets:
	@bash scripts/fetch-optional-assets.sh

# Assembling the bundle without signing. A separate target because there are two
# different signatures: ad-hoc for local work (`app`) and Developer ID for
# distribution (`release`).
bundle: assets
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/CodeCatApp $(APP)/Contents/MacOS/CodeCat
	cp .build/release/codecat-hook $(APP)/Contents/MacOS/codecat-hook
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	# The icon. It sits in Contents/Resources under the name CFBundleIconFile gives;
	# it is redrawn by `swift scripts/make-icon.swift` rather than by the build — the
	# generator redraws the cat from `CatView`, and running that on every build moves
	# 350 KB around for a file that does not change.
	cp Resources/CodeCat.icns $(APP)/Contents/Resources/
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD)" $(APP)/Contents/Info.plist
	cp scripts/install-lid-mode.sh scripts/uninstall-lid-mode.sh $(APP)/Contents/Resources/
	# Localisation. `.strings`, not `.xcstrings`: a string catalog is compiled by
	# Xcode's build system, and there is none here — this Makefile assembles the
	# bundle from a SwiftPM package. They are found through `Bundle.main` (see
	# `L10n`), so they have to live in Contents/Resources, where the signature covers
	# them along with everything else.
	cp -R Resources/en.lproj $(APP)/Contents/Resources/
	# The skin assets go to Contents/Resources/Skins so the signature covers them.
	# The app finds them through Bundle.main (see SpriteSheetStore), never touching
	# Bundle.module.
	cp -R .build/release/CodeCat_CodeCatApp.bundle/Skins $(APP)/Contents/Resources/

app: bundle
	codesign --force -s - $(APP)
	@$(MAKE) --no-print-directory verify-skins
	@echo "Done: $(APP) — version $(VERSION) ($(BUILD)), ad-hoc signature"

# The signature for distribution. Three things differ from ad-hoc, and every one is
# mandatory:
#  * --options runtime — hardened runtime; without it notarisation refuses;
#  * --entitlements — restores the right to send Apple events, which hardened
#    runtime takes away (see the comment in Resources/CodeCat.entitlements);
#  * --timestamp — a trusted timestamp, also a notarisation requirement.
#
# codecat-hook is signed SEPARATELY and FIRST. It is a second executable in
# Contents/MacOS, and signing the bundle does not give it a signature of its own —
# the notary service rejects a bundle like that. The inside-out order is mandatory:
# the bundle's signature seals its contents, so editing any nested file afterwards
# breaks it.
sign: bundle
	@test -n "$(SIGN_ID)" || (echo "ERROR: no Developer ID Application certificate found."; \
		echo "Check with: security find-identity -v -p codesigning"; exit 1)
	@echo "Signing as: $(SIGN_ID)"
	codesign --force --options runtime --timestamp \
		--sign "$(SIGN_ID)" $(APP)/Contents/MacOS/codecat-hook
	codesign --force --options runtime --timestamp \
		--entitlements Resources/CodeCat.entitlements \
		--sign "$(SIGN_ID)" $(APP)
	codesign --verify --deep --strict --verbose=2 $(APP)
	# This checks not "is it signed" but "would Gatekeeper accept this as an app for
	# distribution". codesign --verify says yes to an ad-hoc signature too, so on its
	# own it does not guard against this file's main mistake.
	@codesign -dv $(APP) 2>&1 | grep -q "TeamIdentifier=T" \
		|| (echo "ERROR: TeamIdentifier is not set — this is not a Developer ID signature"; exit 1)
	@codesign -d --entitlements - --xml $(APP) 2>/dev/null | grep -q "apple-events" \
		|| (echo "ERROR: the Apple-events entitlement did not reach the signature —"; \
		    echo "jump-to-session will break in the release build"; exit 1)
	@$(MAKE) --no-print-directory verify-skins
	@echo "Signed: $(APP) — version $(VERSION) ($(BUILD))"

# Notarisation. A .zip is submitted and the ticket is stapled to the .app:
# notarytool accepts only a container, while stapler can write the ticket inside the
# bundle. Without stapling, the app would be checked online on someone else's
# machine and would not open without a network.
notarize: sign
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	xcrun notarytool submit $(ZIP) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(APP)
	xcrun stapler validate $(APP)

# The final check — the only one that answers "will this open for a person who
# downloaded the file from the internet". Everything before it checks the signature;
# this one asks Gatekeeper itself.
release: notarize
	rm -f $(DMG) $(ZIP)
	# The image is built from a staged folder rather than straight from the bundle,
	# for two things: the /Applications symlink (without which installing means "drag
	# it somewhere yourself") and the volume icon. The "this volume has its own icon"
	# flag is set by SetFile from Xcode's tools; without it the image still builds,
	# just with the default icon.
	rm -rf dist/dmg && mkdir -p dist/dmg
	cp -R $(APP) dist/dmg/
	ln -s /Applications dist/dmg/Applications
	cp Resources/CodeCat.icns dist/dmg/.VolumeIcon.icns
	@command -v SetFile >/dev/null && SetFile -a C dist/dmg \
		|| echo "WARNING: SetFile not found — the image will have the default volume icon"
	hdiutil create -volname "CodeCat $(VERSION)" -srcfolder dist/dmg \
		-ov -format UDZO $(DMG)
	rm -rf dist/dmg
	codesign --force --timestamp --sign "$(SIGN_ID)" $(DMG)
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(DMG)
	# `-t exec`, not `-t install`: what is being assessed is an application, not an
	# installer, and there is exactly one question — "will this open for a person who
	# downloaded the file". `-t install` answers something for a .app too, so the
	# substitution would have passed in silence.
	@spctl -a -vvv -t exec $(APP) 2>&1 | grep -q "source=Notarized Developer ID" \
		|| (echo "ERROR: Gatekeeper did not recognise the app as notarised"; \
		    spctl -a -vvv -t exec $(APP); exit 1)
	@spctl -a -vvv -t open --context context:primary-signature $(DMG) 2>&1 \
		| grep -q "source=Notarized Developer ID" \
		|| (echo "ERROR: Gatekeeper did not recognise the image itself as notarised"; \
		    spctl -a -vvv -t open --context context:primary-signature $(DMG); exit 1)
	@echo "Ready to distribute: $(DMG) — version $(VERSION) ($(BUILD))"

# This checks not three files but EVERY sheet declared in the MascotSkins registry —
# SkinAssetsTests enumerates them from the code rather than from a hand-written
# list, so a new skin added without its files fails this check too.
#
# The exit code of `swift test --filter` is not enough here: it is 0 both when the
# filter matches no tests at all (rename SkinAssetsTests and this line silently
# stops checking anything) and when CODECAT_SKINS_DIR never reached the test (a typo
# in the variable name) — in which case skinsDirectory quietly falls back to the
# source tree and checks that instead of the assembled bundle. So the output is
# parsed: both a positive number of tests with zero failures, and a path printed by
# the test that points inside the bundle.
verify-skins:
	@test -d "$(APP)/Contents/Resources/Skins" \
		|| (echo "ERROR: the skin assets did not reach the bundle"; exit 1)
	# Localisation is checked here rather than in a target of its own: a missing
	# `.lproj` does not crash the app — it silently shows the English written at the
	# call sites — and so it is exactly the kind of build error nobody notices
	# without a check.
	@test -f "$(APP)/Contents/Resources/en.lproj/Localizable.strings" \
		|| (echo "ERROR: the localisation did not reach the bundle"; exit 1)
	@test -f "$(APP)/Contents/Resources/CodeCat.icns" \
		|| (echo "ERROR: the icon did not reach the bundle"; exit 1)
	@out=$$(CODECAT_SKINS_DIR="$(CURDIR)/$(APP)/Contents/Resources/Skins" swift test --filter SkinAssetsTests 2>&1); \
		echo "$$out" | grep -qE "Executed [1-9][0-9]* tests?, with 0 failures" \
		&& echo "$$out" | grep -q "SKINS DIR: .*Contents/Resources/Skins" \
		|| (echo "$$out"; echo "ERROR: the skin-sheet check against the assembled .app failed"; exit 1)

clean:
	rm -rf .build dist
