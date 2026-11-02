# CLAUDE.md

Личный форк [Boring Notch](https://github.com/TheBoredTeam/boring.notch) (macOS-приложение на SwiftUI, «динамический остров» в вырезе экрана). Свои изменения ведём в ветке `custom`.

## Правило

**После любых изменений в коде всегда запускай `scripts/dev-install.sh`** и убедись, что он завершился с `Running (pid …)`. Не считай задачу выполненной, пока скрипт не прошёл.

## Сборка и установка

```bash
scripts/dev-install.sh                     # Release: xcodebuild → закрыть запущенный → /Applications → запуск
CONFIGURATION=Debug scripts/dev-install.sh # Debug-сборка
```

- Требуется Xcode 26+ (сейчас стоит 27.1). Схема — `boringNotch`, проект — `boringNotch.xcodeproj` (workspace нет, зависимости через SPM).
- Сборка идёт в `build/` (в .gitignore), полный лог — `build/dev-install.log`. При ошибке скрипт печатает строки `error:`.
- Подпись без Apple Developer аккаунта. Скрипт подписывает самоподписанным сертификатом `macbrow` из login keychain, если он есть (имя можно переопределить через `SIGN_IDENTITY`); иначе — ad-hoc (`CODE_SIGN_IDENTITY=-`) с предупреждением. Зачем: со стабильным сертификатом designated requirement (`certificate leaf = H"…"`) не меняется между сборками и разрешения TCC (Accessibility, камера, календарь) переживают пересборку; при ad-hoc requirement — это cdhash, и разрешения сбрасываются при каждой сборке. После сборки скрипт печатает designated requirement (`certificate leaf` = сертификат, `cdhash` = ad-hoc). `ENABLE_HARDENED_RUNTIME=NO` обязателен: с hardened runtime dyld не грузит встроенный `MediaRemoteAdapter.framework` и приложение падает при старте.
- Разовая настройка сертификата (руками): меню Keychain Access → Certificate Assistant → Create a Certificate… (или `open "/System/Library/CoreServices/Certificate Assistant.app"`): Name `macbrow`, Identity Type «Self Signed Root», Certificate Type «Code Signing». Затем открыть сертификат → Trust → Code Signing: «Always Trust» (иначе `security find-identity -v` и Xcode его не видят). При первой сборке macOS спросит доступ codesign к ключу в keychain — «Always Allow». После перехода с ad-hoc один раз удалить Boring Notch из списка Accessibility и выдать доступ заново. Самоподписанный сертификат по умолчанию действует год: когда истечёт, скрипт перейдёт на ad-hoc с предупреждением — создать новый с тем же именем и выдать Accessibility ещё раз.
- Пока скрипт подписывает ad-hoc (сертификата нет), macOS заново спрашивает разрешения (Accessibility, камера, календарь) после каждой пересборки.
- Запускать только `/Applications/Boring Notch.app`. xcodebuild регистрирует в LaunchServices и копии из `build/Build/Products/*/` с тем же bundle id; запуск по id (логин, Spotlight) может поднять такую ad-hoc копию, и у неё нет выданных разрешений («Grant Accessibility…», хотя в настройках всё включено). Скрипт после установки снимает копии из `build/` с регистрации; после проверки компиляции отдельным xcodebuild приложение не запускать из `build/`. Проверить, что запущено: `ps -axo command | grep "Boring Notch.app/Contents/MacOS"`.
- Краш-репорты: `~/Library/Logs/DiagnosticReports/Boring Notch-*.ips`.
- Проверить, что код хотя бы компилируется, без установки:
  `xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO build`

## Working a task — roles, models, order

The four agents live in `.claude/agents/`. The session you are talking to is
the orchestrator: it
reads the task, delegates, and keeps its own context small by reading only
what the subagents' reports do not cover.

### Roles and models

| Agent | Model / effort | Does | Never |
|---|---|---|---|
| `planner` | Fable, medium, read-only | turns the task into a numbered plan with files, steps, tests, build commands | writes code |
| `coder` | Sonnet, medium | implements the plan step by step, builds after each step, commits when green | redesigns the plan, pushes |
| `ops` | Haiku, low | runs builds, tests, launches the app, collects logs; quotes results | edits source, interprets failures |
| `reviewer` | Opus, high | judges the diff against the task on its own, without the plan | fixes anything |

Why this split: the expensive models sit where decisions are made (plan,
verdict), the cheap ones where the volume is (code, shell output). Measured on
a sibling project: Opus and Fable are about 85 % of a task's cost, coder and
ops the rest, so the planner is the first thing to skip on a small task.

### Order

```
planner → coder → ops → reviewer
   ops red     → coder (at most two rounds), then ops again
   reviewer FIX → coder → ops → reviewer, once; a second FIX stops the task
   reviewer SHIP → done
```

**Small-task shortcut.** If the change touches at most three files and adds no
new type or user-visible behaviour, skip the planner: hand the task straight to
`coder` with the files named. `ops` and `reviewer` still run. When in doubt,
plan.

**Hand-offs are short reports, not transcripts.** Each agent starts with an
empty context and returns under 60 lines (plan), 30 (coder), 40 (reviewer);
the orchestrator passes the plan to the coder verbatim and the reviewer gets
the task text only. Do not paste file contents between agents; name the files.

### Verification is the project's, not the agent's

Build, test and run commands live in this `CLAUDE.md` (fill in the block
below); every agent copies them from here. A task is not done until `ops` has
run them green on the final commit.

```bash
# Compile check, no install (ad-hoc signing flags are required, see "Сборка и установка")
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO build
# Release build → replace /Applications/Boring Notch.app → relaunch; green = ends with "Running (pid …)"
scripts/dev-install.sh
```

There is no test target. The manual check is the user exercising the change in
the installed app; agents cannot click, type or take screenshots, so the report
says exactly what the user should try.

### If the change alters how something works, update this file

A behaviour change (a new setting, a changed default, a different launch path,
a removed feature) is not finished until the matching lines in `CLAUDE.md` say
the new behaviour, in the same commit. Record the decision, not the diff.

## Структура

```
boringNotch/                    основной таргет
  boringNotchApp.swift          точка входа, AppDelegate, окна на каждом экране, хоткеи
  ContentView.swift             корневой view выреза: закрытое состояние, sneak peek/HUD, переключение вкладок
  BoringViewCoordinator.swift   синглтон состояния UI: currentView (активная вкладка), sneakPeek, firstLaunch, alwaysShowTabs
  models/BoringViewModel.swift  состояние конкретного выреза: notchState open/closed, размеры, камера
  models/Constants.swift        все настройки: `extension Defaults.Keys` (библиотека sindresorhus/Defaults)
  enums/generic.swift           NotchViews (список вкладок), NotchState, SettingsEnum и др.
  components/
    Notch/        NotchHomeView (вкладка Home), BoringHeader (верхняя строка открытого выреза), окна, NotchShape
    Tabs/         TabSelectionView (массив `tabs` + переключатель), TabButton
    Shelf/        вкладка Shelf (Views/ShelfView.swift, ViewModels, Services, Models)
    Music/, Calendar/, Webcam/, Live activities/   блоки, из которых собраны вкладки и sneak peek
    Settings/     SettingsView.swift — окно настроек (сайдбар + все разделы в одном файле)
    Onboarding/, Tips/
  managers/       MusicManager, VolumeManager, BrightnessManager, CalendarManager, WebcamManager…
  MediaControllers/  источники «Now Playing» (Apple Music, Spotify, YouTube Music, MediaRemote)
  observers/, helpers/, extensions/, utils/, sizing/, animations/, metal/
  Localizable.xcstrings         строки UI (Crowdin)
BoringNotchXPCHelper/           XPC-сервис (привилегированные операции), отдельный таргет
mediaremote-adapter/            готовый MediaRemoteAdapter.framework (бинарник, не трогать)
```

### Навигация по вкладкам

1. `enums/generic.swift` → `enum NotchViews { case home, shelf, translator, aiChat, notes }` — какие вкладки существуют.
2. `components/Tabs/TabSelectionView.swift` → `let tabs = [TabModel(label:icon:view:)]` — кнопки (иконка — SF Symbol) вертикальной колонкой сверху вниз; рисуется в `ContentView` слева от области контента открытого выреза, не в шапке (5 вкладок не помещаются слева от физического выреза). `visibleTabs` прячет выключенные в настройках. Клик ставит `BoringViewCoordinator.shared.currentView`.
3. `ContentView.swift` (~стр. 345) → `switch coordinator.currentView { case .home: NotchHomeView(...); case .shelf: ShelfView(); case .translator: TranslatorView(); case .aiChat: AIChatView(); case .notes: NotesView() }` — какой view рисуется в открытом вырезе.
4. `components/Notch/BoringHeader.swift` — переключатель больше не рисует (левый слот пуст); сама `TabSelectionView` показывается, если доступен Shelf (`Defaults[.boringShelf]` и shelf не пуст, или `coordinator.alwaysShowTabs`, или включена история буфера `Defaults[.shelfClipboardHistory]`) или включён переводчик (`Defaults[.showTranslatorTab]`) или Ask AI (`Defaults[.showAIChatTab]`) или Notes (`Defaults[.showNotesTab]`).

Добавить вкладку = новый case в `NotchViews` + элемент в `tabs` (и в `visibleTabs`) + ветка в `switch` в `ContentView` (Swift заставит обработать case во всех `switch`).

### Вкладка Translator (кастомная)

- `components/Translator/TranslatorManager.swift` — состояние, DeepL-клиент (`DeepLClient`, ключ `:fx` → api-free; `/v2/translate`, `/v2/languages`), выбор языков, избранные языки, захват выделения (синтетический ⌘C через XPC-хелпер, буфер восстанавливается). Модель `TranslatorLanguage` + запасной список языков на случай, если `/v2/languages` недоступен.
- `components/Translator/TranslatorView.swift` — UI вкладки (`LanguageMenu` источника/цели, кнопка ⇄) и `TranslatorSettings` (раздел настроек «Translator», включая список Starred languages).
- Языки: `Defaults[.translatorSource]` / `[.translatorTarget]` (nil = авто: источник определяет DeepL, цель «любой → RU, RU → EN»), `[.translatorStarredLanguages]` — коды целей (`EN-US`, не `EN`); для меню источника сравниваются по базовому коду.
- Ключ DeepL — `Defaults[.deeplAPIKey]` (plist в контейнере песочницы; не Keychain, т.к. ad-hoc подпись меняется при каждой сборке).
- Ввод с клавиатуры: окно выреза (`BoringNotchSkyLightWindow.canBecomeKey`) может стать key только на вкладках translator, aiChat и notes. Пока поле в фокусе или открыто меню языков (`TranslatorManager.keepsNotchOpen`), hover-out не закрывает вырез. При уходе с вкладки фокус возвращается через `orderOut` + `orderFrontRegardless`.
- Хоткей `.translateSelection` (⌃⌥T) — обработчик в `boringNotchApp.swift`, нажатие ⌘C — `postCopyShortcut` в `BoringNotchXPCHelper` (протокол продублирован в `BoringNotchXPCHelper/` и `boringNotch/XPCHelperClient/` — менять оба).
- Нужен доступ Accessibility. Со стабильным сертификатом `macbrow` достаточно один раз после перехода с ad-hoc: удалить Boring Notch из списка в System Settings → Privacy & Security → Accessibility и выдать заново. Если подпись всё ещё ad-hoc, то это нужно после каждой пересборки (macOS перестаёт признавать доступ).

### Вкладка Ask AI (кастомная)

- `components/AIChat/AIChatProvider.swift` — `AIChatMessage`, `AIChatEvent`, `AIChatError`, протокол `AIChatProvider` и `AnthropicProvider` (модель `claude-haiku-5-5`, SSE-стрим, без temperature/top_p/top_k и без assistant prefill; рендерится только `text_delta`, `thinking`-блоки игнорируются; web search tool `web_search_20250305`, max_uses 2, включается `Defaults[.aiChatWebSearch]`).
- `components/AIChat/AIChatManager.swift` — состояние чата, `keepsNotchOpen` (фокус поля, меню или стрим — стрим только пока активна вкладка Ask AI), `AIChatStore` (история).
- `components/AIChat/AIChatView.swift` — UI вкладки и `AIChatSettings` (раздел «Ask AI»).
- Ключи: `Defaults[.showAIChatTab]` (по умолчанию true), `[.anthropicAPIKey]` (plist, не Keychain, как у DeepL), `[.aiChatWebSearch]`.
- Хоткей `.openAIChat` — без значения по умолчанию, задаётся в настройках; открывает вырез на вкладке Ask AI делает окно key и фокусирует поле через одноразовый `pendingFocus` (обработчик в `boringNotchApp.swift`).
- История: `Application Support/AIChat/YYYY-MM-DD-<uuid>.json`, хранится только текст (без thinking/tool-блоков), сохраняется после каждого ответа, файлы старше 30 дней удаляются через `refreshHistory()` (появление вкладки, открытие меню History, каждое сохранение); `load()` не открывает чат старше 30 дней (удаляет файл); нечитаемые файлы — по дате модификации. В API уходят только текстовые реплики user/assistant. `pause_turn` показывается как «(stopped early)», `max_tokens` — «(cut off)» (лимит 2048), `refusal` — фиксированной фразой.

- Смена чата (New chat / History) синхронно завершает текущий стрим (частичный ответ сохраняется в старый чат); события устаревшего стрима отбрасываются по `turnID`.

### Вкладка Notes (кастомная)

- `components/Notes/NotesView.swift` — `NotesManager` (синглтон, текст, `keepsNotchOpen` = фокус редактора), `NotesView` (одна заметка в `TextEditor`, кнопки Copy/Clear) и `NotesSettings` (раздел «Notes»).
- Ключ `Defaults[.showNotesTab]` (по умолчанию true). Заметка — один простой текст в `Application Support/Notes/note.txt` (не в Defaults: plist перезаписывается целиком); сохранение с задержкой 0.5 с, плюс сразу при уходе с вкладки и при выходе из приложения.
- Ввод с клавиатуры как у Translator/Ask AI: `canBecomeKey` включает `.notes`, пока фокус в редакторе hover-out не закрывает вырез. Copy пишет в буфер с `markOwnWrite()`.
- Clear → Undo: `clear()` кладёт прежний текст в `clearedText` (только в памяти); пока заметка пуста, вместо Clear показывается Undo; любой ввод сбрасывает `clearedText`.

### Shelf + история буфера обмена (кастомное)

- Вкладка Shelf (`NotchViews.shelf`) — общая полка: перетащенные файлы/текст/ссылки плюс всё скопированное. AirDrop и drag & drop — как в upstream.
- `components/Shelf/Services/ClipboardWatcher.swift` — синглтон, опрашивает `NSPasteboard.general.changeCount` раз в 0.5 с; работает, пока включены `Defaults[.boringShelf]` и `[.shelfClipboardHistory]` (по умолчанию true). Запуск — `applicationDidFinishLaunching`. Содержимое буфера на момент запуска не импортируется.
- Что берётся из буфера (по приоритету): file URL из Finder → `.file`; png/tiff (скриншоты ⌃⇧⌘4) → PNG во временном хранилище, элемент `isTemporary` (удаление стирает файл), повтор той же картинки находится по SHA256 (словарь только в памяти, после перезапуска не помнит) и переносится в начало без нового файла; если в буфере есть `.rtf`/`.rtfd` (Excel, Word прикладывают картинку к тексту) — берётся текст, если в нём есть что-то кроме пробелов и U+FFFC, иначе картинка (вложения из Notes/TextEdit); одна http(s)-ссылка → `.link`; иначе непустой текст до 100k символов → `.text` (длиннее — пропускается). Типы `org.nspasteboard.ConcealedType/TransientType/AutoGeneratedType` (менеджеры паролей) игнорируются.
- Собственные записи приложения в буфер не попадают в историю: после каждой записи вызывать `ClipboardWatcher.shared.markOwnWrite()`; захват выделения Translator (⌃⌥T) идёт под `isSuspended`. Новая запись в `NSPasteboard` где-либо в коде — тоже с `markOwnWrite()`.
- `ShelfItem.fromClipboard` (декодируется с дефолтом false — старые `items.json` читаются). Новые элементы (из буфера и drop) вставляются в начало; повторное копирование переносит существующий элемент в начало, не меняя его флаг; перетаскивание элемента, который уже лежит на полке из буфера, снимает флаг (элемент становится постоянным). Автоматически удаляются только элементы из буфера сверх `Defaults[.clipboardHistoryLimit]` (20, в настройках 5–100); перетащенные — никогда. «Keep on Shelf» в контекстном меню снимает флаг.
- `openShelfByDefault` учитывает только перетащенные/закреплённые элементы (`ShelfStateViewModel.hasNonClipboardItems`), иначе история буфера открывала бы каждый вырез на Shelf вместо Home.
- Настройки — раздел Shelf → «Clipboard history»: тумблер, лимит, «Clear clipboard history» (удаляет только элементы из буфера). История хранится открытым текстом в persistence Shelf.

### Как устроена одна вкладка

Обычный SwiftUI `struct XxxView: View`, без параметров или с `albumArtNamespace`. Типовые зависимости:
- `@EnvironmentObject var vm: BoringViewModel` — состояние выреза (размеры, open/closed);
- `@ObservedObject var coordinator = BoringViewCoordinator.shared` и синглтоны менеджеров (`MusicManager.shared`, `WebcamManager.shared`…);
- настройки читаются как `Defaults[.key]` или `@Default(.key)`; новый ключ — в `models/Constants.swift`, тумблер для него — в нужном разделе `SettingsView.swift`.

Пример: `NotchHomeView` (`components/Notch/NotchHomeView.swift`) — `HStack` из `MusicPlayerView`, `CalendarView` (если `Defaults[.showCalendar]`) и камеры (если `Defaults[.showMirror]`). `ShelfView` — более крупная вкладка с MVVM (Models/Services/ViewModels/Views).

### Добавление файлов

Папка `boringNotch/` — **не** synchronized group: новый `.swift`-файл надо зарегистрировать в `boringNotch.xcodeproj/project.pbxproj` (PBXFileReference + PBXBuildFile + группа + Sources build phase), иначе он не скомпилируется. Проще класть новый код в существующие файлы или добавлять файл через Xcode. Автоматически подхватываются только `boringNotch/private/` и `BoringNotchXPCHelper/`.

## Git и синхронизация с upstream

- `origin` — мой форк (`mxgvrl/boring.notch`), `upstream` — `TheBoredTeam/boring.notch`.
- `main` держим чистой копией upstream, вся работа — в `custom`.

```bash
git fetch upstream
git switch main && git merge --ff-only upstream/main && git push origin main
git switch custom && git rebase main      # или `git merge main`, если ветка уже опубликована и rebase не нужен
scripts/dev-install.sh                    # убедиться, что всё собирается и запускается
git push --force-with-lease origin custom # после rebase
```

При конфликтах в `project.pbxproj` разрешай их аккуратно (обычно нужно оставить обе стороны) и сразу пересобирай.
