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
- Подпись ad-hoc (`CODE_SIGN_IDENTITY=-`), без Apple Developer аккаунта. `ENABLE_HARDENED_RUNTIME=NO` обязателен: с hardened runtime dyld не грузит встроенный `MediaRemoteAdapter.framework` и приложение падает при старте.
- Из-за ad-hoc подписи macOS может заново спрашивать разрешения (Accessibility, камера, календарь) после пересборки.
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

1. `enums/generic.swift` → `enum NotchViews { case home, shelf, translator, aiChat }` — какие вкладки существуют.
2. `components/Tabs/TabSelectionView.swift` → `let tabs = [TabModel(label:icon:view:)]` — кнопки в шапке (иконка — SF Symbol); `visibleTabs` прячет выключенные в настройках. Клик ставит `BoringViewCoordinator.shared.currentView`.
3. `ContentView.swift` (~стр. 345) → `switch coordinator.currentView { case .home: NotchHomeView(...); case .shelf: ShelfView(); case .translator: TranslatorView(); case .aiChat: AIChatView() }` — какой view рисуется в открытом вырезе.
4. `components/Notch/BoringHeader.swift` — переключатель вкладок показывается, если доступен Shelf (`Defaults[.boringShelf]` и shelf не пуст или `coordinator.alwaysShowTabs`) или включён переводчик (`Defaults[.showTranslatorTab]`) или Ask AI (`Defaults[.showAIChatTab]`).

Добавить вкладку = новый case в `NotchViews` + элемент в `tabs` (и в `visibleTabs`) + ветка в `switch` в `ContentView` (Swift заставит обработать case во всех `switch`).

### Вкладка Translator (кастомная)

- `components/Translator/TranslatorManager.swift` — состояние, DeepL-клиент (`DeepLClient`, ключ `:fx` → api-free; `/v2/translate`, `/v2/languages`), выбор языков, избранные языки, захват выделения (синтетический ⌘C через XPC-хелпер, буфер восстанавливается). Модель `TranslatorLanguage` + запасной список языков на случай, если `/v2/languages` недоступен.
- `components/Translator/TranslatorView.swift` — UI вкладки (`LanguageMenu` источника/цели, кнопка ⇄) и `TranslatorSettings` (раздел настроек «Translator», включая список Starred languages).
- Языки: `Defaults[.translatorSource]` / `[.translatorTarget]` (nil = авто: источник определяет DeepL, цель «любой → RU, RU → EN»), `[.translatorStarredLanguages]` — коды целей (`EN-US`, не `EN`); для меню источника сравниваются по базовому коду.
- Ключ DeepL — `Defaults[.deeplAPIKey]` (plist в контейнере песочницы; не Keychain, т.к. ad-hoc подпись меняется при каждой сборке).
- Ввод с клавиатуры: окно выреза (`BoringNotchSkyLightWindow.canBecomeKey`) может стать key только на вкладках translator и aiChat. Пока поле в фокусе или открыто меню языков (`TranslatorManager.keepsNotchOpen`), hover-out не закрывает вырез. При уходе с вкладки фокус возвращается через `orderOut` + `orderFrontRegardless`.
- Хоткей `.translateSelection` (⌃⌥T) — обработчик в `boringNotchApp.swift`, нажатие ⌘C — `postCopyShortcut` в `BoringNotchXPCHelper` (протокол продублирован в `BoringNotchXPCHelper/` и `boringNotch/XPCHelperClient/` — менять оба).
- Нужен доступ Accessibility. После каждой ad-hoc пересборки macOS может перестать его признавать: удалить Boring Notch из списка в System Settings → Privacy & Security → Accessibility и выдать заново.

### Вкладка Ask AI (кастомная)

- `components/AIChat/AIChatProvider.swift` — `AIChatMessage`, `AIChatEvent`, `AIChatError`, протокол `AIChatProvider` и `AnthropicProvider` (модель `claude-haiku-5-5`, SSE-стрим, без temperature/top_p/top_k и без assistant prefill; рендерится только `text_delta`, `thinking`-блоки игнорируются; web search tool `web_search_20250305`, max_uses 2, включается `Defaults[.aiChatWebSearch]`).
- `components/AIChat/AIChatManager.swift` — состояние чата, `keepsNotchOpen` (фокус поля, меню или стрим — стрим только пока активна вкладка Ask AI), `AIChatStore` (история).
- `components/AIChat/AIChatView.swift` — UI вкладки и `AIChatSettings` (раздел «Ask AI»).
- Ключи: `Defaults[.showAIChatTab]` (по умолчанию true), `[.anthropicAPIKey]` (plist, не Keychain, как у DeepL), `[.aiChatWebSearch]`.
- Хоткей `.openAIChat` — без значения по умолчанию, задаётся в настройках; открывает вырез на вкладке Ask AI делает окно key и фокусирует поле через одноразовый `pendingFocus` (обработчик в `boringNotchApp.swift`).
- История: `Application Support/AIChat/YYYY-MM-DD-<uuid>.json`, хранится только текст (без thinking/tool-блоков), сохраняется после каждого ответа, файлы старше 30 дней удаляются при первом создании `AIChatManager.shared` (открытие вкладки / первое использование) и при каждом сохранении; нечитаемые файлы — по дате модификации. В API уходят только текстовые реплики user/assistant. `pause_turn` показывается как «(stopped early)», `max_tokens` — «(cut off)» (лимит 2048), `refusal` — фиксированной фразой.

- Смена чата (New chat / History) синхронно завершает текущий стрим (частичный ответ сохраняется в старый чат); события устаревшего стрима отбрасываются по `turnID`.

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
