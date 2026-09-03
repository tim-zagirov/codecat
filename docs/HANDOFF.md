# CodeCat — handoff to the next session

Last updated 2026-09-03, during the public-release pass. Read this first.

**Summary.** The code is done and green; what is left is release mechanics —
a Developer ID certificate, notarisation credentials, the GitHub rename, and the
manual checklist. Sections below cover where things stand, what to do next, how
work is done in this repository, and the loose ends. The working notes further
down are in Russian: they are the author's own, and translating them would only
blur them. Anything a user reads is English — see the [README](../README.md).

## Where things stand

- `master` is green: **400 tests**, `swift test`, clean working tree. The public
  release pass (licence, English UI, icon, CI, docs) is on top of it.
- Installed at `/Applications/CodeCat.app`, ad-hoc signed. That is fine locally
  and **not** fine for distribution: see `docs/release.md`.
- Hooks are installed in `~/.claude/settings.json` — all **five** events point at
  `/Applications/CodeCat.app/Contents/MacOS/codecat-hook`. Backup:
  `~/.claude/settings.json.backup-before-codecat`.
- Closed-lid mode is installed and was verified on the real machine.
- One skin (Elthen's "Silver") is no longer in the repository — its licence
  forbids redistribution. `make bundle` fetches it; without it the app shows
  seven skins instead of eight, which is a supported state.

Building: `make app` puts the bundle in `dist/`. After a rebuild you **must**
copy it to `/Applications`, or the installed hooks keep calling the old binary:

```bash
make app && pkill -x CodeCat; rm -rf /Applications/CodeCat.app && cp -R dist/CodeCat.app /Applications/ && open -a /Applications/CodeCat.app
```

## What to do next

In order. The first two need a human; nothing else is blocked.

1. **Get a Developer ID Application certificate and store notarisation
   credentials.** This is the only real blocker for shipping to anyone else, and
   it cannot be automated: it needs an Apple Developer account. Exact commands:
   [docs/release.md](release.md). Until then every reinstall changes the
   signature, so macOS asks for the automation permission again each time
   (`tccutil reset AppleEvents com.codecat.app` to re-test that path).
2. **Rename the GitHub repository** `vibe-coding-utility` → `codecat`, and
   force-push the history-rewritten `master` (the Elthen sheet was purged from
   history — see RELEASE_NOTES.md).
3. **Run [docs/verification-checklist.md](verification-checklist.md) end to
   end** on a fresh build. Item 34 needs a second Mac and a real release build;
   item 35 is new and covers the Russian localisation.
4. **Replace the app icon** if the generated one is not good enough — it is drawn
   from `CatView`, not designed.
5. Then the loose ends below, none of which block a release.

### Still unverified by eye: jump-to-session

Всё, что ниже слоя интерфейса, покрыто тестами и проверено сквозь (хук на живом дереве процессов, AppleScript — компиляцией против настоящего словаря Terminal.app). **Не проверено глазами** и ждёт человека — пункты 10–13 чек-листа в `docs/verification-checklist.md`:

10. Навести на строку сессии → подсветка и курсор-указатель.
11. Клик по строке сессии из Terminal.app → разрешение на автоматизацию (один раз), потом переключение ровно в её вкладку.
12. Клик по строке сессии десктопного Claude → приложение выходит вперёд.
13. Отказать в разрешении → приложение всё равно выведено вперёд и **видно сообщение** (не спрятано за окном).

Программно это не проверить: CodeCat — `LSUIElement`, инструменты управления экраном его не находят (`request_access` отвечает «not installed»). Ветка iTerm2 не проверялась вовсе — iTerm2 на машине нет.

Приложение переустанавливалось в этой сессии, поэтому подпись сменилась и разрешение на
автоматизацию спросят заново. Сбросить выданное, чтобы проверить пункт 13:
`tccutil reset AppleEvents com.codecat.app`.

### Skins — done

Спек вычитан и уточнён, план написан, реализация прошла все восемь задач с ревью,
два круга финальных исправлений. Ветка `claude/codecat-mascot-skins-spec-b6a4de`.

- Восемь выбираемых обликов: шесть котов LuizMelo + Elthen + mxmaze, по умолчанию —
  Рыжий кот LuizMelo (`luizmelo-cat-1`). Нарисованный кот больше не в списке выбора —
  он остался в коде только как аварийная отрисовка на случай, если лист спрайтов не
  читается (было решено позже, той же датой, см. пункт 11 в «Что изменилось после
  вычитки» спека).
- Переключение — сетка живых превью 4×2 в панели деталей, там же раскрывающаяся строка
  «Об ассетах» с авторами и лицензиями.
- Ассеты переехали в `Sources/CodeCatApp/Skins/`, объявлены ресурсами таргета, а `make app`
  кладёт их в `Contents/Resources/Skins` **до** `codesign`, чтобы подпись их покрывала.
  Проверка в `make app` перечисляет реестр (через `SkinAssetsTests` и `CODECAT_SKINS_DIR`),
  а не три файла руками, и грепает вывод: `swift test --filter` возвращает ноль и когда
  не нашёл ни одного теста.
- Приложение пересобрано и установлено в `/Applications/CodeCat.app`, подпись запечатана.

**Что осталось человеку:** пункты 14–17 чек-листа в `docs/verification-checklist.md` (сетка обликов,
переключение кликом, сохранение выбора между запусками, «Об ассетах» с CC BY 4.0 у mxmaze).

Уроки этой работы, которые стоит помнить:

- **Разрешение на автоматизацию привязано к подписи, а подпись — к содержимому бандла.**
  Первая версия сборки клала ресурсный бандл SwiftPM в корень `.app` и подписывала до
  копирования: ассеты оставались вне подписи. Так делать нельзя — сломается переход к сессии.
- **`Bundle.module` нельзя трогать в приложении, которое обязано пережить пропажу ассетов.**
  Сгенерированный аксессор падает с `fatalError` ровно тогда, когда ассетов нет, — то есть
  в том случае, ради которого и задуман откат на нарисованного кота. В логах машины нашёлся
  настоящий отчёт о таком падении. Пути перебираются вручную, `nil` означает откат.
- **`onAppear` не срабатывает при смене, которая оставляет ту же ветку `if/else`.**
  Нарисованный кот и сломанный спрайтовый облик рисуются одной веткой, поэтому SwiftUI не
  пересоздавал вид, и пользователь не узнавал об ошибке. Спасает `.task(id:)`.
- **Проверка размеров не ловит ошибку в координатах.** Переворот вертикали в измерении рамки
  сохранял ширину и высоту, поэтому дамп метрик его не видел; ломался только Elthen. Ловится
  сравнением `origin` с эталоном, посчитанным независимо (PIL по тем же PNG).

## How work is done here

Скилл `subagent-driven-development`: на каждую задачу свежий субагент-исполнитель, потом субагент-ревьюер (соответствие спеку + качество), правки — отдельным субагентом, в конце широкое ревью всей ветки. Прогресс пишется в `.superpowers/sdd/progress.md` (в gitignore) — **читай его после компактификации, он переживает потерю контекста**.

Полезные факты из опыта:

- **Финальное ревью всей ветки окупается каждый раз.** В MVP оно нашло четыре критических дефекта на стыках компонентов; в «переходе к сессии» — **две критические находки, которых не увидело ни одно потаск-ревью**, обе про время жизни, а не про код в одном файле: (1) исполнитель активировал приложение по сохранённому PID, не проверяя, что PID всё ещё принадлежит тому же бандлу, а macOS переиспользует PID'ы, и у ждущей сессии PID никто не обновляет часами; (2) хук обходил предков от `getpid()`, а сам хук лежит внутри `CodeCat.app`, поэтому владельцем сессии записывался сам CodeCat всякий раз, когда выше по цепочке нет ни одного `.app` (tmux, ssh, нативно поставленный `claude`). **Не пропускай его.**
- **Ревью исправлений тоже находит дефекты.** После финального ревью понадобилось четыре волны: таймаут скрипта срабатывал на системном диалоге разрешения (то есть на первом же переходе); запрос разрешения шёл на главном потоке вопреки документации Apple и не был покрыт никаким дедлайном; два сообщения описывали события, которых не было. Правило, которое всё это ловит: **сообщение не имеет права утверждать то, чего код не знает**.
- **Код-примеры в планах регулярно неверны.** В этой сессии план сам себе противоречил трижды (английский комментарий в файле с русскими; `fellBack: false` там, где откат вообще не делался; обход предков от `getpid()`). Не транскрибируй план дословно — проверяй.
- **Измеряй, а не спорь о геометрии.** Баг с хвостом закрылся за один заход, потому что стенд рендерил `CatView` на большом холсте и печатал bounding box непрозрачных пикселей для каждого состояния и обеих фаз анимации. Стенд пересоздаётся за пару минут: отдельный SwiftPM-пакет, куда копируются `CatView.swift` и заглушка `AggregateStatus`, и `ImageRenderer` пишет PNG. Трюк с фазами — при копировании заменить `.phaseAnimator([false, true])` на свою `staticPhase(...)`, тогда рисуются крайние фазы, а не только первая.
- **Скриншот-проверка ловит то, чего не видит код-ревью.** Самый тяжёлый дефект MVP: все анимации котика были навешены на `EmptyView()`, SwiftUI выбрасывал поддеревья, кот рендерился без тела. Ни имплементер, ни ревьюер этого не увидели — нашлось только рендером в PNG.
- **AppleScript проверяется, не запускаясь.** `osacompile` компилирует скрипт против настоящего словаря приложения (так проверены `tty of tab`, `selected of tab` у Terminal.app) и при этом не шлёт Apple events, то есть не дёргает разрешение на автоматизацию.
- **Хук проверяется сквозь.** Останови CodeCat, подними на его сокете (`~/Library/Application Support/CodeCat/codecat.sock`) слушателя unix datagram, прогони `codecat-hook` — увидишь ровно тот JSON, который получает приложение. Для tty-веток заворачивай запуск в `script -q /dev/null`, он выделяет псевдотерминал.
- **Панель CodeCat нельзя проверить инструментами управления экраном:** приложение `LSUIElement`, `request_access` его не находит. Всё про наведение, курсор и клики проверяет только человек.

## Known loose ends

Ни одна не блокирует:

- Текущее состояние питания не выводится ни в панели, ни в меню-баре (спек MVP это обещал).
- Grace-период (2 мин) и порог батареи (15%) зашиты константами.
- Меню-бар перестраивается целиком на каждое событие сессии.
- `hooksInstalled` вычисляется только при запуске.
- Тумблер «показывать котика» есть только в меню-баре, в панели его нет.
- Звук повторяется при переходе `.waiting(1) → .waiting(2)`.
- `AppState.presentJumpAlert` поднимает своё окно поверх возможного системного диалога разрешения — проверить без запуска диалога не вышло.
- `jumpDeadline` — один максимум на все параллельные переходы, поэтому зависший короткий не отмечается, пока идёт длинный.
- Крылья острова перекрывают строку меню: клики по меню приложения слева и по статус-иконкам справа в зоне крыльев достаются острову. Это цена выбранной формы, крылья сделаны минимально возможными. С появлением галтелей у кромки (2026-09-01) окно шире корпуса ещё на 10 pt с каждой стороны — перекрытие выросло на столько же.

## What the user has still not seen with their own eyes

Плавность анимаций, перетаскивание котика и сохранение позиции между запусками, отклик переключателей в панели деталей, сводка «пока тебя не было» после разблокировки экрана, весь переход к сессии (пункты 10–13) и весь переключатель обликов (пункты 14–17). Спрайтовые облики проверены только рендером в PNG — все 45 сочетаний «облик × состояние» отрисованы и просмотрены, но в живом приложении их никто не видел. И весь остров целиком — второй режим отображения, в вырезе экрана, в живом приложении никто не видел: пункты 18–27.

## Open question

Отчёт `docs/cat-assets-research.md` содержит и покупные варианты (самый выгодный — около 6 долларов). Пользователь говорил, что готов купить, если недорого; решение не принято и в спек обликов не входит.
