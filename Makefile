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
	# Ассеты обликов идут в Contents/Resources/Skins, поэтому подпись их покрывает.
	# Приложение находит их через Bundle.main (см. SpriteSheetStore), не трогая
	# Bundle.module.
	cp -R .build/release/CodeCat_CodeCatApp.bundle/Skins $(APP)/Contents/Resources/
	codesign --force -s - $(APP)
	@test -d "$(APP)/Contents/Resources/Skins" \
		|| (echo "ОШИБКА: ассеты обликов не попали в бандл"; exit 1)
	@test -f "$(APP)/Contents/Resources/Skins/mxmaze/16x16-Brown.png" \
		|| (echo "ОШИБКА: в бандле нет листов обликов"; exit 1)
	@test -f "$(APP)/Contents/Resources/Skins/elthen/Cat Sprite Sheet.png" \
		|| (echo "ОШИБКА: в бандле нет листа Elthen"; exit 1)
	@test -f "$(APP)/Contents/Resources/Skins/luizmelo/Cat-1/Cat-1-Meow.png" \
		|| (echo "ОШИБКА: в бандле нет листов LuizMelo"; exit 1)
	@echo "Готово: $(APP)"

clean:
	rm -rf .build dist
