# Исследование готовых анимированных ассетов кота для CodeCat

Дата: 2026-08-30
Контекст: CodeCat — menu-bar утилита для macOS 14+, показывает кота в прозрачной панели ~96×96pt поверх других окон весь день. Нужно 5 спокойных зацикленных состояний: **Asleep, Working, Waiting for you (важнее всего), Done, Problem**. Направление — тёплый рисованный оранжевый кот со спокойным характером. Сейчас в приложении **нулевые сторонние зависимости**, кот нарисован вручную в SwiftUI.

Все цены и условия лицензий ниже проверены через веб-поиск и прямые запросы к страницам продуктов на момент подготовки отчёта (30 августа 2026). Там, где источник — агрегатор, а не сама площадка, это отдельно помечено как "не подтверждено напрямую".

---

## Сводная таблица кандидатов (ранжировано по соответствию 5 состояниям + спокойный стиль)

| # | Название | URL | Цена | Лицензия (кратко) | Формат | Покрытие состояний |
|---|----------|-----|------|--------------------|--------|---------------------|
| 1 | LuizMelo — Pet Cats Pack | https://luizmelo.itch.io/pet-cat-pack | Free (name-your-own-price) | CC0 1.0 Universal | PNG sprite sheet, пиксель-арт, 6 котов | Idle, Sleeping1/2, Lying Down, Sitting, Stretching, Meow, Licking — сон/покой закрыты хорошо, "wave"/"problem" нет |
| 2 | GameDev Market — Animated cat game character pack (RobertBrooks) | https://www.gamedevmarket.net/asset/animated-cat-game-character-pack | $6.00 (разовая покупка) | GameDev Market Pro License | PNG sprite sheet, 10 окрасов пород | idle, sitting, sleeping, sleeping-transition, walk, run, scratch, show belly, dizzy, jump, preen, beg, die — почти все состояния есть, "wave" нет впрямую (beg/scratch как заменитель) |
| 3 | Rive (кастомный файл под заказ через Rive Marketplace / фрилансеров) | https://rive.app/marketplace/ , https://riveanimator.com/pricing/ | От ~$250 (idle + 1 состояние) + ~$100 за каждое доп. состояние → ориентировочно $650–750 за 5 состояний | Rive runtime (rive-ios) — MIT; лицензия на конкретный купленный .riv индивидуальна, уточняется у автора | .riv + RiveRuntime (SPM, MIT) | Не готовый ассет — архитектурно идеально ложится на 5 состояний через State Machine, но требует кастомной отрисовки под бренд |
| 4 | Elthen's Pixel Art Shop — 2D Pixel Art Cat Sprites | https://elthen.itch.io/2d-pixel-art-cat-sprites | Name-your-own-price (от $0) | Собственная лицензия автора (см. ниже) | PNG sprite sheet 32×32 | idle×2, clean×2, movement×2, sleep, paw, jump, scared — сон и "paw" (замена wave) есть |
| 5 | mxmaze — 16-Bit Kitty (FREE) | https://mxmaze.itch.io/16-bit-kitty-free | Free | CC BY 4.0 (атрибуция обязательна) | PNG sprite sheet | idle, walking, sitting, sleeping — нет "wave"/"problem" |
| 6 | CraftPix — Cute Cats Game Character Sprites Pack | https://craftpix.net/product/cute-cats-game-character-sprites/ | Не подтверждена (страница требует подписку/логин для показа цены; упомянута "unlimited downloads" модель) | CraftPix Premium License (см. ниже) | PNG sprite sheet, 15 персонажей-котов | idle, walking, stunned, flying, jumping, hitting, throwing, rolling, dying — нет явного "sleep", по духу это игровой экшн-набор, не спокойный |
| 7 | pixelmia — Pixel Cats Collection / 2 Pixel Cats: Tabby | https://pixelmia.itch.io/pixel-cats-collection , https://pixelmia.itch.io/2-pixel-cats-tabby | $12 / $2.40 (pay-what-you-want, минимум) | Собственная лицензия автора (см. ниже) | PNG sprite sheet, есть окрас "ginger" (оранжевый) | idle, walk, run, jump, fight, hurt, die — набор геймплейный/боевой, "спокойного" сна и wave нет вообще |
| 8 | LottieFiles — отдельные бесплатные ролики (Cat Idle Simple, Cat is sleeping and rolling, Cat Paw) | https://lottiefiles.com/77776-cat-idle-simple , https://lottiefiles.com/57071-cat-is-sleeping-and-rolling , https://lottiefiles.com/free-animations/cat-paw | Free (часть каталога — Pro/платные) | Lottie Simple License (см. ниже) | Lottie JSON / dotLottie + `lottie-ios` (SPM, Apache 2.0) | Разрозненные ролики от разных авторов — идея есть под каждое состояние, но визуальный стиль между роликами не будет совпадать |
| 9 | IconScout — Cat Waving Hand Animation / Fortune Cat Waving | https://iconscout.com/lottie-animation/cat-waving-hand-animation_7703876 , https://iconscout.com/lottie-animation/fortune-cat-waving-animation_5086402 | Free / часть платной подписки (не подтверждено для каждого конкретного файла) | IconScout Digital License (см. ниже) — условия распространения внутри приложения сформулированы нечётко | Lottie JSON / GIF + `lottie-ios` | Закрывает именно "wave" (самое важное состояние), но нужно комбинировать с другими роликами других авторов |
| 10 | Envato Elements — Animated Cartoon Cat Characters | https://elements.envato.com/cartoon-cat-pack-UPT8FN4 | Подписка Envato Elements — по данным сторонних агрегаторов ~$16.50–33/мес (не подтверждено на самой странице цен elements.envato.com/pricing, нужно проверять на актуальный момент) | Envato Elements License (подписочная, см. ниже) | Motion Graphics (AE / video overlay), не нативный формат для SwiftUI | sitting, licking paws, chasing mice, stretching, reacting to dog, sleeping, peering from basket — хорошее смысловое покрытие, но формат "видео/AE", не спрайты и не Lottie |
| 11 | OpenGameArt — Tiny Kitten / A Cat / Cat sprites | https://opengameart.org/content/tiny-kitten-game-sprite , https://opengameart.org/content/a-cat , https://opengameart.org/content/cat-sprites | Free | CC0 (проверять индивидуально на каждой странице — не факт, что у всех один и тот же статус) | PNG | В основном только idle/walk — состояний сильно не хватает |
| 12 | Kenney — Animal Pack / Animal Pack Redux | https://kenney.nl/assets/animal-pack | Free | CC0 | PNG | **Кота нет вообще** в этом паке (жираф, панда, попугай, пингвин, обезьяна, кролик, змея, бегемот, свинья, слон) — упомянут только для полноты картины, не подходит |

---

## Разбор лицензий — что именно написано

### 1. LuizMelo — Pet Cats Pack (рекомендуется как "чистый" бесплатный вариант)
- Лицензия: **Creative Commons Zero v1.0 Universal (CC0)**.
- На странице: *"Credit is not required, but I would appreciate it."*
- CC0 = общественное достояние, автор отказывается от всех прав. Коммерческое использование, встраивание файла внутрь дистрибутива приложения, изменение — всё разрешено без каких-либо условий. Это самый чистый с юридической точки зрения вариант из всех найденных.
- 12 анимаций на кота: Idle (10 кадров), Walk (8), Run (8), Meow (4), Lying Down (8), Itch (2), Sleeping1 (1 кадр), Sleeping2 (1 кадр), Sitting (1 кадр), Licking1 (5), Licking2 (5), Stretching (13).
- Минус: пиксель-арт очень мелкий (кот ~20×14 px в исходнике), стиль далёк от "тёплого рисованного" направления CodeCat — при масштабировании до 96×96pt будет выглядеть чётко пиксельно, а не как акварельная/рисованная иллюстрация. Цвет котов на странице не указан явно — нельзя подтвердить наличие оранжевого без скачивания архива.

### 2. GameDev Market — Animated cat game character pack
- Цена: **$6.00**, автор RobertBrooks.
- Лицензия — GameDev Market **Pro License** (единая лицензия для всех 28 000+ ассетов площадки), текст: *"Licensed Assets can be used in Media Products for the Purchaser's personal use and/or commercial use in which case it may be distributed, sold and supplied by the Purchaser for any fee."*
- Ограничение на редистрибуцию: *"A License does not allow the Purchaser to use, sell, share, transfer, give away, sublicense or redistribute the Licensed Asset or Derivative Works other than as part of the relevant Media Product."* — то есть сам файл спрайта нельзя выкладывать отдельно, но использовать (в том числе изменённым) внутри дистрибутива приложения — можно.
- Официальная страница лицензии (`gamedevmarket.net/about/licences`) отдала 403 при прямом запросе — цитаты выше взяты из результатов поиска, ссылающихся на эту страницу; **рекомендуется свериться вручную перед покупкой**.
- Плюс: почти полное покрытие нужных состояний (idle/sitting/sleeping/sleeping-transition/scratch/show belly/dizzy/beg), 10 окрасов пород (не подтверждено, что среди них есть именно рыжий/оранжевый — "не проверено").

### 3. Rive (кастомная разработка)
- Рантайм `rive-ios` — **MIT License**, официально поддерживает iOS/macOS 13.1+, UIKit/AppKit/SwiftUI (источник: https://github.com/rive-app/rive-ios, https://help.rive.app/runtimes/overview/ios). MIT полностью совместим с коммерческим closed-source приложением, никаких ограничений.
- На самом Rive Marketplace (https://rive.app/marketplace/) есть готовые файлы с котами и другими маскотами со state machine, но ни один найденный файл не покрывает конкретно "спящий/работающий/ждёт-машет/доволен/проблема" в тёплом оранжевом стиле — это скорее референсы, чем готовое решение.
- Расценки фрилансеров-аниматоров Rive (riveanimator.com/pricing): базовый пакет — **от $250** (1 персонаж, idle + 1 состояние, .riv-файл, state machine, именованные inputs/triggers), каждое дополнительное состояние — **+$100**. Для 5 состояний ориентировочно **$650–750**.
- Технически это лучший архитектурный вариант (state machine 1:1 ложится на 5 состояний приложения, переходы между произвольными состояниями "из коробки"), но это **не готовый ассет**, а либо кастомный заказ, либо самостоятельная отрисовка в редакторе Rive.
- Архитектурная цена: добавление `RiveRuntime` как SPM-зависимости — первая сторонняя зависимость в проекте, который сейчас их не имеет.

### 4. Elthen's Pixel Art Shop — 2D Pixel Art Cat Sprites
- Цена: name-your-own-price (можно скачать бесплатно).
- Лицензия автора (по её пересказу с itch.io и Patreon): *"Feel free to use the sprites in commercial/non-commercial projects! If you do, please consider tipping."* Отдельно на Patreon уточняется: нельзя использовать в проектах, связанных с крипто/блокчейном, и нельзя использовать для обучения LLM/генеративных ИИ-моделей.
- Состояния: idle×2, clean×2, movement×2, sleep, paw, jump, scared — сон закрыт, "paw" может стать заменителем анимации "машет лапой", но не 1:1 то же самое, что "waving to get attention".
- Полный текст лицензии не был процитирован дословно с официальной лицензионной страницы (ссылка на неё есть на Patreon, но сам документ не открывался напрямую) — **рекомендуется свериться перед использованием**.

### 5. mxmaze — 16-Bit Kitty (FREE)
- Лицензия: **Creative Commons Attribution 4.0 International (CC BY 4.0)**.
- CC BY 4.0 разрешает коммерческое использование и встраивание в дистрибутив, но **требует атрибуции** — то есть в приложении (например, в разделе "About" или в README) нужно будет указать автора Maze.Bit.Boutique. Для скрытого/незаметного маскота в menu bar это создаёт неудобство — придётся продумать, где физически разместить атрибуцию.
- Состояний всего 4 (idle, walking, sitting, sleeping) — не хватает "waiting/wave" и "problem".

### 6. CraftPix — Cute Cats Game Character Sprites Pack
- Точная цена не подтверждена — страница продукта продвигает членство/скидку "Save 98% OFF ALL products", конкретная цена в долларах за этот конкретный пак не была получена (403/paywall на части контента).
- Общая лицензия CraftPix (по цитатам с сайта): Premium-товары — *"You can sell and distribute games with our assets"*, *"you can use each product in unlimited number of free and commercial projects."* Прямой запрет: *"You can NOT resell the art source files (PNG, JPG, EPS, Adobe Illustrator, etc.) or a slightly modified version of the art."* Атрибуция не требуется.
- Состояния этого конкретного пака (idle, walking, stunned, flying, jumping, hitting, throwing, rolling, dying) — набор явно "игровой/боевой", нет отдельного "sleep", тон совсем не спокойный.

### 7. pixelmia — Pixel Cats Collection / 2 Pixel Cats: Tabby
- Цена: $12 (полная коллекция, 10 окрасов, включая **ginger/рыжий**) или $2.40 (только Tabby+Ginger пара), pay-what-you-want минимумы.
- Лицензия автора: коммерческое и некоммерческое использование разрешено, модификация разрешена, **редистрибуция и перепродажа самого пака запрещены**, атрибуция не обязательна но приветствуется, явный запрет на крипто/NFT-проекты.
- Состояния: idle, walk, run, jump, **fight, hurt, die** — набор геймплейный, боевой, для спокойного менюбар-маскота почти не годится по тональности, хотя технически есть нужный оранжевый цвет.

### 8. LottieFiles — свободные ролики (Cat Idle Simple, Cat is sleeping and rolling, Cat Paw)
- Лицензия свободных роликов — **Lottie Simple License** (https://lottiefiles.com/page/license — прямой запрос страницы вернул 403, цитаты взяты из результатов поиска, ссылающихся на официальный текст): *"grants permission to download, reproduce, modify, publish, distribute, publicly display, and publicly digitally perform animation files, including for commercial purposes."* Модификации становятся производными и должны распространяться на тех же условиях, **если сами распространяются как Lottie-файл** — это не блокирует использование внутри closed-source приложения. Атрибуция не обязательна, но рекомендуется. Отдельно запрещено использовать LottieFiles-каталог для создания конкурирующего сервиса — приложению CodeCat это не грозит.
- `lottie-ios` (Airbnb) — **Apache 2.0 License** (https://github.com/airbnb/lottie-ios/blob/master/LICENSE), полностью совместим с коммерческим приложением.
- Минус: ролики от разных независимых авторов ("Cat Idle Simple" — один автор, "Cat is sleeping and rolling" — другой) — визуальный стиль (толщина линии, палитра, характер кота) не будет совпадать между состояниями. Чтобы получить консистентный набор из 5 состояний, реалистичнее заказать кастомную Lottie-анимацию у одного иллюстратора, а не собирать из бесплатного каталога.

### 9. IconScout — Cat Waving Hand Animation / Fortune Cat Waving
- Лицензия — **IconScout Digital License**: разрешает коммерческое и личное использование, *"not allowed to resell or republish (as a separate entity under any other profile) to any platform"*; *"cannot redistribute the creatives as stock, in a tool or template, or with source files even if you modify the asset"*. Формулировка **не даёт однозначного ответа**, можно ли просто встроить конвертированный в бинарный вид Lottie-файл внутрь app bundle обычного desktop-приложения (в отличие от "продажи как шаблон/сток") — это тот случай, когда стоит написать в поддержку IconScout напрямую перед использованием в коммерческом продукте. Помечаю как **лицензия неоднозначная**.
- Закрывает единственное по-настоящему важное состояние — "машет лапой, чтобы привлечь внимание" — но опять же от стороннего автора, стиль не будет совпадать с остальными 4 состояниями, если их брать из других источников.

### 10. Envato Elements — Animated Cartoon Cat Characters
- Модель — **подписка** Envato Elements, не разовая покупка. По данным сторонних агрегаторов (не самого Envato — "не подтверждено") цены варьируются в районе $16.50–$33/мес в зависимости от тарифа и периода оплаты; актуальную цифру нужно смотреть на https://elements.envato.com/pricing непосредственно перед покупкой.
- Лицензия Envato Elements (https://help.elements.envato.com/hc/en-us/articles/360000628966-Envato-Elements-License): нельзя перепродавать/распространять ассет "as-is" отдельно от продукта; ассет должен быть содержательно интегрирован в конечный продукт. Для программного продукта: *"if the item is only hosted in or on one software product and you are not giving users access to the underlying item... then a single license would be all that is needed."* Это в целом совместимо с использованием внутри menu-bar приложения — при условии, что raw-файл анимации не раздаётся пользователям отдельно.
- Важный нюанс архитектуры: это Motion Graphics-контент (для After Effects / видео), а не Lottie/Rive/спрайты — потребуется самостоятельно рендерить в видео/PNG-последовательность и заново собирать зацикленную анимацию под SwiftUI, что добавляет работы по конвертации.
- Состояния по описанию (sitting, licking paws, chasing mice, stretching, reacting to dog, sleeping, peering from basket) смыслово близки к нужным 5 (sleeping = Asleep, stretching/sitting = Done/Working), но нет прямого "wave" и "problem".

### 11. OpenGameArt — Tiny Kitten / A Cat / Cat sprites
- Лицензия — **CC0**, но это нужно перепроверять **на каждой странице отдельно** (сам OpenGameArt хостит контент под разными лицензиями от разных авторов; страница "All CC0 - Uploader: Kenney" подтверждает CC0 только для конкретно загруженных Kenney файлов). Для "Tiny Kitten Game Sprite" и "A Cat" в найденных результатах поиска фигурирует CC0, но полный текст лицензионного блока каждой страницы отдельно не открывался — **не полностью подтверждено**.
- Покрытие состояний крайне скудное — в основном только idle/walk, единой согласованной "линейки" из 5 состояний нет.

### 12. Kenney — Animal Pack / Animal Pack Redux
- CC0, но **кота в этом паке нет** — только жираф, панда, попугай, пингвин, обезьяна, кролик, змея, бегемот, свинья, слон. Приведён только для полноты обзора известного источника чистых CC0-ассетов.

---

## AI-сгенерированные ассеты — отдельная заметка

На маркетплейсах вроде Fab (Epic) есть обязательная маркировка "Created with AI" для контента, сгенерированного нейросетями. Юридическая проблема: по позиции U.S. Copyright Office (Copyrightability Report, январь 2025) *"Human authorship is a bedrock of copyrightability"* — то есть полностью сгенерированный ИИ ассет **может не иметь охраноспособного авторского права** у продавца вообще, а значит формальная "лицензия", которую вам продают, может быть юридически пустой (продавец не может лицензировать то, что ему не принадлежит по закону в разных юрисдикциях). Для небольшого коммерческого приложения это не смертельный риск, но если попадётся анимация кота с пометкой "AI-generated" на любой площадке — стоит рассматривать её как менее надёжную с точки зрения прав, чем ассет, явно нарисованный человеком-автором с понятной лицензией (CC0, MIT, Pro License и т.д.).

---

## Техническая пригодность

- **Спрайт-листы PNG** (LuizMelo, GameDev Market, Elthen, CraftPix, pixelmia, mxmaze, OpenGameArt) — рендерятся нативным SwiftUI (`Image`/`Canvas` + `Timer`/`TimelineView` для покадровой анимации). **Не требуют сторонних зависимостей** — сохраняется текущая архитектура "zero dependencies". Стоимость интеграции — по сути написать один переиспользуемый компонент нарезки кадров + подключить 5 спрайт-листов; это, возможно, дешевле по труду, чем донастройка стороннего рантайма.
- **Lottie/dotLottie** — требует добавления `lottie-ios` (Apache 2.0, SPM) как первой сторонней зависимости. Интеграция простая (`LottieAnimationView`/`LottieView` в SwiftUI), но это уже архитектурное решение — компромисс с "нулевые зависимости".
- **Rive** — требует `RiveRuntime` (MIT, SPM). Даёт наилучшее соответствие "5 состояний = 5 узлов state machine", переходы между произвольными состояниями обрабатываются самим рантаймом. Но готового тёплого оранжевого кота под эти 5 состояний на маркетплейсе не нашлось — по сути это путь "закажи кастомную анимацию", а не "купи готовый файл".
- **Envato Elements (AE motion graphics)** — требует конвертации в видео/PNG-последовательность своими силами, дополнительный шаг рендеринга, который не нужен для остальных вариантов.

---

## Рекомендация

1. **LuizMelo — Pet Cats Pack (CC0, бесплатно)** — самый юридически чистый вариант, ноль риска, есть Sleeping/Lying Down/Sitting/Stretching кадры для Asleep/Done. Подходит как временный/прототипный набор или как база для перерисовки в нужном "тёплом" стиле, но пиксель-арт по духу далёк от текущего hand-drawn направления.
2. **GameDev Market — Animated cat game character pack, $6** — лучшее по деньгам соотношение "цена / покрытие состояний" (idle/sitting/sleeping/scratch/dizzy/beg почти закрывают все 5 сценариев), разовая покупка, разумная Pro License. Стоит свериться с официальной страницей лицензии вручную (сайт отдавал 403 при автоматическом запросе), но по цитатам из независимых источников условия стандартные и разрешают использование внутри коммерческого приложения.
3. **Кастомный Rive-файл на заказ (~$650–750)** — если бюджет и время позволяют, это единственный вариант, который даёт одновременно (а) архитектурно правильную state machine на 5 состояний, (б) MIT-лицензию без вопросов, и (в) визуальный стиль, нарисованный точно под бренд CodeCat ("тёплый рисованный оранжевый кот"), а не подогнанный под чужой стиль пиксель-арта или мультяшной игры.

**Честный вывод**: ни один из найденных готовых (не кастомных) ассетов не совпадает по стилю с "тёплым рисованным спокойным котом" один в один — большинство это либо пиксель-арт для 2D-игр, либо игровые боевые наборы (fight/hurt/die), либо разрозненные Lottie-ролики разных авторов без единого стиля. Если хэндмейд SwiftUI-кот, который уже существует в проекте, визуально устраивает и просто не хватает состояния "Waiting for you" (машет лапой) — дешевле и надёжнее дорисовать **только это одно состояние** в существующем стиле, чем менять весь пайплайн ради готового ассета. Полная замена на стороннее решение оправдана только если: (а) хочется получить полноценную state-machine анимацию с плавными переходами между произвольными состояниями "из коробки" (тогда — Rive, кастом), либо (б) не хватает времени/художника для отрисовки — тогда GameDev Market пак за $6 или LuizMelo CC0-пак закрывают задачу быстрее всего ценой явного стилевого компромисса.

---

## Источники (основные страницы, использованные в отчёте)

- https://luizmelo.itch.io/pet-cat-pack
- https://www.gamedevmarket.net/asset/animated-cat-game-character-pack
- https://www.gamedevmarket.net/about/licences
- https://rive.app/marketplace/
- https://github.com/rive-app/rive-ios
- https://help.rive.app/runtimes/overview/ios
- https://riveanimator.com/pricing/
- https://elthen.itch.io/2d-pixel-art-cat-sprites
- https://mxmaze.itch.io/16-bit-kitty-free
- https://craftpix.net/product/cute-cats-game-character-sprites/
- https://pixelmia.itch.io/pixel-cats-collection
- https://pixelmia.itch.io/2-pixel-cats-tabby
- https://lottiefiles.com/77776-cat-idle-simple
- https://lottiefiles.com/57071-cat-is-sleeping-and-rolling
- https://lottiefiles.com/free-animations/cat-paw
- https://lottiefiles.com/page/license
- https://github.com/airbnb/lottie-ios/blob/master/LICENSE
- https://iconscout.com/lottie-animation/cat-waving-hand-animation_7703876
- https://iconscout.com/lottie-animation/fortune-cat-waving-animation_5086402
- https://iconscout.com/licenses
- https://elements.envato.com/cartoon-cat-pack-UPT8FN4
- https://help.elements.envato.com/hc/en-us/articles/360000628966-Envato-Elements-License
- https://elements.envato.com/pricing
- https://opengameart.org/content/tiny-kitten-game-sprite
- https://opengameart.org/content/a-cat
- https://opengameart.org/content/cat-sprites
- https://kenney.nl/assets/animal-pack
- https://oboropixel.itch.io/character-animations
- https://blog.promise.legal/ai-generated-assets-game-ip-disclosure/
