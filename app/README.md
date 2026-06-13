# LayoutSwitcher

Локальный переключатель раскладки RU/EN для macOS. Меню-бар агент, без сети,
нативный Swift. Реализует критический путь из декомпозиции (§9): DetectionEngine
+ Input Pipeline + петля исправления + индикатор + надёжность.

## Сборка

```bash
cd app
swift test            # 20 юнит-тестов ядра (детектор, маппинг, буфер)
bash scripts/build_app.sh   # → dist/LayoutSwitcher.app (+ self-test ядра из .app)
open dist/LayoutSwitcher.app
```

Требования: macOS 13+, Apple Silicon, Xcode/Swift 6 toolchain.

## Первый запуск — разрешения (выдаются один раз вручную)

1. **Универсальный доступ (Accessibility)** — приложение попросит само.
2. **Мониторинг ввода (Input Monitoring)** — Системные настройки →
   Конфиденциальность и безопасность. Без него `CGEventTap` не создаётся;
   приложение покажет инструкцию и само подхватит разрешение (поллинг 3 с).

Иконки в Dock нет (`LSUIElement`). Управление — из меню-бара (`● RU` / `○`/ `◎` shadow).

## Управление

| Действие | Как |
|---|---|
| Исправить последнее слово / выделение + сменить раскладку | двойной **⇧** или **⌃⌥Z** |
| Переключить автоконвертацию | **⌃⌥A** или меню |
| Отменить конвертацию (не ⌘Z) | **⌃⌥X** |
| Транслитерация выделения | **⌃⌥T** |
| Сменить регистр выделения (lower→UPPER→Title) | **⌃⌥C** |
| Исправить Caps/2 заглавные в выделении | **⌃⌥U** |
| Глушить автоконвертацию | удерживать **Fn** (если включено) |
| Shadow-mode / текст-инструменты / настройки / выход | меню-бар |

## Архитектура (модуль → файл)

| Модуль декомпозиции | Файл |
|---|---|
| DetectionEngine (E1) | `SwitcherCore/DetectionEngine.swift`, `LanguageModel.swift` |
| KeyMap RU↔EN | `SwitcherCore/KeyMap.swift` |
| KeystrokeBuffer | `SwitcherCore/KeystrokeBuffer.swift` |
| Текст-инструменты EPIC 7 | `SwitcherCore/TextTools.swift` |
| Store / Settings | `SwitcherCore/Store.swift`, `Settings.swift` |
| InputCapture (CGEventTap, REL-1/2/3) | `LayoutSwitcher/InputCapture.swift` |
| LayoutController (TIS + замена текста) | `LayoutSwitcher/LayoutController.swift` |
| ActionCoordinator (стейт-машина, политика) | `LayoutSwitcher/ActionCoordinator.swift` |
| ContextProvider (AX, secure input REL-6) | `LayoutSwitcher/ContextProvider.swift` |
| AX selection/caret/fullscreen (REL-5, FR-31) | `LayoutSwitcher/AXText.swift` |
| FocusObserver (проактивная FR-4/5/6) | `LayoutSwitcher/FocusObserver.swift` |
| HotkeyManager (Carbon) | `LayoutSwitcher/HotkeyManager.swift` |
| UI меню-бар + caret-оверлей + настройки (E5) | `MenuBarController.swift`, `CaretOverlay.swift`, `SettingsView.swift` |
| Lifecycle/Supervision (E6, REL-7/8) | `AppDelegate.swift`, `Permissions.swift`, `LoginItem.swift` |
| TestHarness | `Tests/SwitcherCoreTests/*` + `--selftest` |

## Как работает детектор (FR-7…FR-10, критерий ≤0.5% ложняков)

Для законченного слова: текущая форма vs форма в другой раскладке.
1. Словарь: если текущая форма — реальное слово, а альтернативная нет → **не трогать**.
   Если наоборот → конвертировать (высокая уверенность).
2. Валидно в обеих раскладках → **не трогать** (при сомнении бездействие).
3. Вне словаря → символьная триграммная модель (строится из тех же списков);
   конвертация только если margin > 0 и confidence ≥ порога.

Исключения / белый список / выученные ручные откаты гасят конвертацию до всего этого.

## Приватность (SEC-1…5)

Нет сетевого кода вообще. Буфер слова эфемерный, чистится на границе/навигации.
Локально хранятся только `settings.json` и `userdata.json`
(`~/Library/Application Support/LayoutSwitcher/`), атомарная запись. Secure input
(пароли) — полное бездействие.

## Покрытие требований

Все FR-1…FR-35, NFR-1…7, REL-1…9, SEC-1…5 реализованы. Карта по группам:

| Группа | Где |
|---|---|
| Индикация FR-1/2/3 | меню-бар badge + caret-оверлей + toast, каждый отключаем |
| Проактивная FR-4/5/6 | `FocusObserver` (AX) → `proactiveLayout`: роль поля → латиница, память app+поле |
| Автопереключение FR-7…10 | `DetectionEngine` (словарь + триграммы), порог, граница слова, контекст |
| Петля/ручное FR-11…15 | двойной ⇧/⌃⌥Z (слово/выделение, цикл), Fn-suppress, ⌃⌥X undo+обучение |
| Смешанный RU/EN FR-16…19 | exceptions / whitelist / learnedReverts / dict-логика |
| Калибровка FR-20…22 | shadow-mode, обзор недавних с «в исключения/whitelist», импорт текста |
| Текст-инструменты FR-23…26 | `TextTools`: транслит, регистр, Caps-fix, сниппеты (+тесты) |
| Фон/поведение FR-27…32 | LSUIElement, SMAppService, тумблер, fullscreen-off, app-blacklist, secure |
| Меню/настройки FR-33…35 | меню-бар + SwiftUI (5 вкладок) + сброс |
| NFR/REL/SEC | event-driven, tap rearm+watchdog, fail-open, AX-replace+fallback, sleep/wake, single-instance, atomic, без сети |

## Известные ограничения (документированы, не блокеры)

- **Распознавание url/email-полей** (FR-5) — через AX-subrole надёжно ловятся
  только secure + search; url/email эвристика ограничена (AX редко их размечает).
  Стоп в полях паролей и поиск-латиница работают.
- **IME-композиция** (REL-4) — конвертация только по завершённому слову обычными
  символами; во время dead-keys/диктовки слово не завершается → не трогаем.
  Явного детекта marked-text нет.
- **Транслит latin→cyrillic** (FR-23) — обратное направление неоднозначно (y→й,
  e→е), best-effort; ru→lat детерминирован.
- Словари ~10.4k RU / ~4.5k EN словоформ + частотные списки (2.5k/2.8k) для tiebreak (генерация по категориям с полными парадигмами) → консервативно (меньше срабатываний,
  но ≤0.5% ложняков). Растут импортом (FR-22) и обучением на откатах.
