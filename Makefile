APP = dist/CodeCat.app

# Маркетинговая версия правится руками в Resources/Info.plist — это решение
# человека, а не следствие истории коммитов.
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
# А CFBundleVersion выводится из числа коммитов: раньше он был «1» во всех сборках
# без исключения, поэтому две разные сборки на руках было нечем различить — ни в
# Finder, ни в отчёте о падении.
BUILD := $(shell git rev-list --count HEAD)

# Ищется по подстроке, а не прописывается хешем: сертификат раз в год перевыпускают,
# и захардкоженный отпечаток тихо превратил бы `make release` в ошибку через год.
SIGN_ID ?= $(shell security find-identity -v -p codesigning \
	| grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
NOTARY_PROFILE ?= codecat

ZIP = dist/CodeCat-$(VERSION).zip
DMG = dist/CodeCat-$(VERSION).dmg

.PHONY: app bundle release notarize verify-skins assets test clean

test:
	swift test

# Ассеты, которые нельзя держать в репозитории. Сейчас такой один — лист Elthen:
# автор разрешает использовать спрайты, но не раздавать сами файлы, а публичный
# репозиторий делает именно это. Скрипт не валит сборку: без листа просто нет
# одного облика из восьми, и падать из-за недоступного itch.io незачем.
assets:
	@bash scripts/fetch-optional-assets.sh

# Сборка бандла без подписи. Отдельной целью — потому что подписей две разные:
# ad-hoc для локальной работы (`app`) и Developer ID для раздачи (`release`).
bundle: assets
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/CodeCatApp $(APP)/Contents/MacOS/CodeCat
	cp .build/release/codecat-hook $(APP)/Contents/MacOS/codecat-hook
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD)" $(APP)/Contents/Info.plist
	cp scripts/install-lid-mode.sh scripts/uninstall-lid-mode.sh $(APP)/Contents/Resources/
	# Локализация. `.strings`, а не `.xcstrings`: каталог строк компилирует сборочная
	# система Xcode, а здесь её нет — бандл собирается этим Makefile из пакета SwiftPM.
	# Ищутся они через `Bundle.main` (см. `L10n`), поэтому лежать обязаны именно в
	# Contents/Resources — и подпись их покрывает вместе с остальным содержимым.
	cp -R Resources/en.lproj Resources/ru.lproj $(APP)/Contents/Resources/
	# Ассеты обликов идут в Contents/Resources/Skins, поэтому подпись их покрывает.
	# Приложение находит их через Bundle.main (см. SpriteSheetStore), не трогая
	# Bundle.module.
	cp -R .build/release/CodeCat_CodeCatApp.bundle/Skins $(APP)/Contents/Resources/

app: bundle
	codesign --force -s - $(APP)
	@$(MAKE) --no-print-directory verify-skins
	@echo "Готово: $(APP) — версия $(VERSION) ($(BUILD)), подпись ad-hoc"

# Подпись для раздачи. Отличий от ad-hoc три, и каждое обязательно:
#  * --options runtime — hardened runtime, без него нотаризация отказывает;
#  * --entitlements — вернуть право слать Apple events, которое hardened runtime
#    отбирает (см. комментарий в Resources/CodeCat.entitlements);
#  * --timestamp — доверенная метка времени, тоже требование нотаризации.
#
# codecat-hook подписывается ОТДЕЛЬНО и ПЕРВЫМ. Он лежит в Contents/MacOS вторым
# исполняемым файлом, и подпись бандла его собственной подписью не наделяет —
# нотариус такой бандл отклоняет. Порядок «изнутри наружу» обязателен: подпись
# бандла запечатывает содержимое, поэтому любая правка вложенного файла после
# неё эту подпись ломает.
sign: bundle
	@test -n "$(SIGN_ID)" || (echo "ОШИБКА: не найден сертификат Developer ID Application."; \
		echo "Проверь: security find-identity -v -p codesigning"; exit 1)
	@echo "Подписываю как: $(SIGN_ID)"
	codesign --force --options runtime --timestamp \
		--sign "$(SIGN_ID)" $(APP)/Contents/MacOS/codecat-hook
	codesign --force --options runtime --timestamp \
		--entitlements Resources/CodeCat.entitlements \
		--sign "$(SIGN_ID)" $(APP)
	codesign --verify --deep --strict --verbose=2 $(APP)
	# Проверяет не «подписано ли», а «примет ли это Gatekeeper как приложение для
	# раздачи». codesign --verify отвечает «да» и на ad-hoc подпись, поэтому сам по
	# себе он от главной ошибки этого файла не защищает.
	@codesign -dv $(APP) 2>&1 | grep -q "TeamIdentifier=T" \
		|| (echo "ОШИБКА: TeamIdentifier не проставлен — подпись не Developer ID"; exit 1)
	@codesign -d --entitlements - --xml $(APP) 2>/dev/null | grep -q "apple-events" \
		|| (echo "ОШИБКА: entitlement на Apple events не попал в подпись —"; \
		    echo "переход к сессии сломается в релизной сборке"; exit 1)
	@$(MAKE) --no-print-directory verify-skins
	@echo "Подписано: $(APP) — версия $(VERSION) ($(BUILD))"

# Нотаризация. Заверяется .zip, а прикрепляется тикет к .app: notarytool принимает
# только контейнер, а stapler умеет писать тикет внутрь бандла. Без stapler
# приложение на чужой машине проверялось бы онлайн и не открылось бы без сети.
notarize: sign
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	xcrun notarytool submit $(ZIP) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(APP)
	xcrun stapler validate $(APP)

# Финальная проверка — единственная, которая отвечает на вопрос «откроется ли это
# у человека, который скачал файл из интернета». Все предыдущие проверяют подпись,
# а эта — вердикт самого Gatekeeper.
release: notarize
	rm -f $(DMG) $(ZIP)
	hdiutil create -volname "CodeCat $(VERSION)" -srcfolder $(APP) \
		-ov -format UDZO $(DMG)
	codesign --force --timestamp --sign "$(SIGN_ID)" $(DMG)
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(DMG)
	@spctl -a -vvv -t install $(APP) 2>&1 | grep -q "source=Notarized Developer ID" \
		|| (echo "ОШИБКА: Gatekeeper не признал сборку нотаризованной"; \
		    spctl -a -vvv -t install $(APP); exit 1)
	@echo "Готово к раздаче: $(DMG) — версия $(VERSION) ($(BUILD))"

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
verify-skins:
	@test -d "$(APP)/Contents/Resources/Skins" \
		|| (echo "ОШИБКА: ассеты обликов не попали в бандл"; exit 1)
	# Локализация проверяется здесь же, а не отдельной целью: пропущенный `.lproj`
	# не роняет приложение — оно молча показывает английский, — и потому это ровно
	# та ошибка сборки, которую никто не заметит без проверки.
	@test -f "$(APP)/Contents/Resources/ru.lproj/Localizable.strings" \
		|| (echo "ОШИБКА: локализация не попала в бандл"; exit 1)
	@out=$$(CODECAT_SKINS_DIR="$(CURDIR)/$(APP)/Contents/Resources/Skins" swift test --filter SkinAssetsTests 2>&1); \
		echo "$$out" | grep -qE "Executed [1-9][0-9]* tests?, with 0 failures" \
		&& echo "$$out" | grep -q "SKINS DIR: .*Contents/Resources/Skins" \
		|| (echo "$$out"; echo "ОШИБКА: проверка листов обликов в собранном .app не прошла"; exit 1)

clean:
	rm -rf .build dist
