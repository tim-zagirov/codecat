APP = dist/CodeCat.app

.PHONY: app test clean

test:
	swift test

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/CodeCatApp $(APP)/Contents/MacOS/CodeCat
	cp .build/release/codecat-hook $(APP)/Contents/MacOS/codecat-hook
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp scripts/install-lid-mode.sh scripts/uninstall-lid-mode.sh $(APP)/Contents/Resources/
	codesign --force -s - $(APP)
	@echo "Готово: $(APP)"

clean:
	rm -rf .build dist
