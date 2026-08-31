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
	# Проверяет не три файла, а КАЖДЫЙ лист, объявленный в реестре MascotSkins —
	# SkinAssetsTests перечисляет их из кода, а не из ручного списка, поэтому
	# новый облик, добавленный без своих файлов, тоже завалит эту проверку.
	#
	# Код возврата `swift test --filter` тут недостаточен: он равен 0 и когда
	# фильтр не находит ни одного теста (переименуй SkinAssetsTests — и эта
	# строка молча перестанет что-либо проверять), и когда CODECAT_SKINS_DIR не
	# дошёл до теста (опечатка в имени переменной) — тогда skinsDirectory тихо
	# откатывается на путь к исходникам и проверяет их, а не собранный бандл.
	# Поэтому разбирается вывод: нужно и положительное число тестов с нулём
	# провалов, и напечатанный тестом путь, указывающий внутрь бандла.
	@out=$$(CODECAT_SKINS_DIR="$(CURDIR)/$(APP)/Contents/Resources/Skins" swift test --filter SkinAssetsTests 2>&1); \
		echo "$$out" | grep -qE "Executed [1-9][0-9]* tests?, with 0 failures" \
		&& echo "$$out" | grep -q "SKINS DIR: .*Contents/Resources/Skins" \
		|| (echo "$$out"; echo "ОШИБКА: проверка листов обликов в собранном .app не прошла"; exit 1)
	@echo "Готово: $(APP)"

clean:
	rm -rf .build dist
