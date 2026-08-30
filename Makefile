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
	# Сгенерированный SwiftPM resource_bundle_accessor.swift ищет Bundle.module как
	# Bundle.main.bundleURL.appendingPathComponent("CodeCat_CodeCatApp.bundle") — то
	# есть бандл ресурсов должен лежать рядом с Contents/, в корне самого .app, а не
	# внутри Contents/Resources (подтверждено чтением сгенерированного accessor'а и
	# запуском собранного бинарника с временно спрятанным .build). codesign на этой
	# версии отказывается запечатывать бандл, если в его корне есть что-то кроме
	# Contents/ («unsealed contents present in the bundle root»), поэтому бандл
	# ресурсов копируется ПОСЛЕ подписи — codesign видит только чистое дерево Contents/.
	cp -R .build/release/CodeCat_CodeCatApp.bundle $(APP)/
	@test -d "$(APP)/CodeCat_CodeCatApp.bundle/Skins" \
		|| (echo "ОШИБКА: ассеты обликов не попали в бандл"; exit 1)
	@test -f "$(APP)/CodeCat_CodeCatApp.bundle/Skins/mxmaze/16x16-Brown.png" \
		|| (echo "ОШИБКА: в бандле нет листов обликов"; exit 1)
	@test -f "$(APP)/CodeCat_CodeCatApp.bundle/Skins/elthen/Cat Sprite Sheet.png" \
		|| (echo "ОШИБКА: в бандле нет листа Elthen"; exit 1)
	@test -f "$(APP)/CodeCat_CodeCatApp.bundle/Skins/luizmelo/Cat-1/Cat-1-Meow.png" \
		|| (echo "ОШИБКА: в бандле нет листов LuizMelo"; exit 1)
	@echo "Готово: $(APP)"

clean:
	rm -rf .build dist
