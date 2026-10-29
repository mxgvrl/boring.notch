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

1. `enums/generic.swift` → `enum NotchViews { case home, shelf, translator }` — какие вкладки существуют.
2. `components/Tabs/TabSelectionView.swift` → `let tabs = [TabModel(label:icon:view:)]` — кнопки в шапке (иконка — SF Symbol); `visibleTabs` прячет выключенные в настройках. Клик ставит `BoringViewCoordinator.shared.currentView`.
3. `ContentView.swift` (~стр. 345) → `switch coordinator.currentView { case .home: NotchHomeView(...); case .shelf: ShelfView(); case .translator: TranslatorView() }` — какой view рисуется в открытом вырезе.
4. `components/Notch/BoringHeader.swift` — переключатель вкладок показывается, если доступен Shelf (`Defaults[.boringShelf]` и shelf не пуст или `coordinator.alwaysShowTabs`) или включён переводчик (`Defaults[.showTranslatorTab]`).

Добавить вкладку = новый case в `NotchViews` + элемент в `tabs` (и в `visibleTabs`) + ветка в `switch` в `ContentView` (Swift заставит обработать case во всех `switch`).

### Вкладка Translator (кастомная)

- `components/Translator/TranslatorManager.swift` — состояние, DeepL-клиент (`DeepLClient`, ключ `:fx` → api-free; `/v2/translate`, `/v2/languages`), выбор языков, избранные языки, захват выделения (синтетический ⌘C через XPC-хелпер, буфер восстанавливается). Модель `TranslatorLanguage` + запасной список языков на случай, если `/v2/languages` недоступен.
- `components/Translator/TranslatorView.swift` — UI вкладки (`LanguageMenu` источника/цели, кнопка ⇄) и `TranslatorSettings` (раздел настроек «Translator», включая список Starred languages).
- Языки: `Defaults[.translatorSource]` / `[.translatorTarget]` (nil = авто: источник определяет DeepL, цель «любой → RU, RU → EN»), `[.translatorStarredLanguages]` — коды целей (`EN-US`, не `EN`); для меню источника сравниваются по базовому коду.
- Ключ DeepL — `Defaults[.deeplAPIKey]` (plist в контейнере песочницы; не Keychain, т.к. ad-hoc подпись меняется при каждой сборке).
- Ввод с клавиатуры: окно выреза (`BoringNotchSkyLightWindow.canBecomeKey`) может стать key только на вкладке translator. Пока поле в фокусе или открыто меню языков (`TranslatorManager.keepsNotchOpen`), hover-out не закрывает вырез. При уходе с вкладки фокус возвращается через `orderOut` + `orderFrontRegardless`.
- Хоткей `.translateSelection` (⌃⌥T) — обработчик в `boringNotchApp.swift`, нажатие ⌘C — `postCopyShortcut` в `BoringNotchXPCHelper` (протокол продублирован в `BoringNotchXPCHelper/` и `boringNotch/XPCHelperClient/` — менять оба).
- Нужен доступ Accessibility. После каждой ad-hoc пересборки macOS может перестать его признавать: удалить Boring Notch из списка в System Settings → Privacy & Security → Accessibility и выдать заново.

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
