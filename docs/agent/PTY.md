# Локальный PTY и форк flutter_pty2

Этот документ фиксирует, почему проект использует не `portable_pty`, а
вендоренный `flutter_pty2`, что именно изменено в форке и как его обновлять.
Документ нужен, чтобы через несколько месяцев не восстанавливать причины
решения по истории коммитов.

## Зачем вообще PTY

Локальный Host выполняет команды в настоящем TTY: так работают цвета,
интерактивные программы, `stty`, пагинаторы и терминальные приложения.
Реализация живёт в `packages/pw_agent/lib/host/` и используется и
Flutter-приложением, и демоном `pw_server` (через `dart build cli`).

На iOS локальный Host не создаётся: `AppPlatform.hasLocalHost` равно
`!isWeb && !isIOS`. Там работает только виртуальный Host, которому PTY не
нужен. iOS-сборка всё равно должна проходить, потому что пакет PTY входит в
граф зависимостей `pw_agent` и его build hook запускается для iOS.

## Почему ушли от portable_pty

`portable_pty` 0.0.7-beta.2 (и 0.0.5) для iOS отдаёт `static_library`:

```yaml
# native_prebuilt.yaml пакета
- target: {os: ios, architecture: arm64, sdk: iphoneos}
  ...
  kind: static_library
```

Flutter 3.47.9 для iOS выставляет `LinkModePreference.dynamic`, а его
`_targetLocationIOS()` не умеет `StaticLinking` и падает с
`Unsupported asset link mode ...`. В `code_assets` прямо написано, что
статическая линковка ещё не поддержана Dart/Flutter
(`dart-lang/sdk#49418`). Поэтому iOS-сборка ломалась, даже когда локальный
PTY на iOS никогда не вызывается.

Даунгрейд `portable_pty` не помогает: stable 0.0.5 возвращает для iOS тот же
`StaticLinking()`.

## Почему flutter_pty2

`flutter_pty2` 3.0.0:

- собирает нативную библиотеку build hook-ом через `native_toolchain_c`;
- учитывает `linkModePreference` Flutter, поэтому для iOS делает dynamic
  library, которую Flutter штатно упаковывает в framework;
- не зависит от Flutter и подходит для `dart build cli` (в отличие от
  старого `flutter_pty`, который является Flutter-плагином и заброшен);
- не требует Rust: нужен только C-компилятор, который уже есть в CI.

## Почему форк, а не просто зависимость с pub.dev

В `flutter_pty2` 3.0.0 есть регрессия: коммит `99684e68` добавил в
`src/unix/pty_unix_spawn.c` безусловный `#include <libproc.h>` под
`#if defined(__APPLE__)`. `libproc.h` есть только в macOS SDK; в iOS SDK
есть `libproc.tbd`, но нет публичного заголовка. Из-за этого пакет не
компилируется для iOS.

Патч маленький, но без него iOS-сборка не проходит. Держать его в форке
проще, чем ждать upstream-релиза. Заодно мы фиксируем версию и можем
обновляться осознанно.

## Статус upstream

Проверено 18.11.2026:

- последняя версия на pub.dev — `flutter_pty2` 3.0.0, она же вендорена;
- в ветке `develop` есть один невыпущенный коммит с `hasForegroundProcess`;
  он не исправляет iOS и требует обновления сгенерированных биндингов,
  поэтому пока не берём;
- `libproc.h` в upstream по-прежнему подключается под `__APPLE__`, а
  `libutil` в build hook по-прежнему линкуется только для Linux. Наши
  патчи остаются нужны;
- в issues/PR upstream нет исправления этих проблем.

При следующей проверке сравнить версию на pub.dev с `3.0.0` и посмотреть
`src/unix/pty_unix_spawn.c` и `hook/build.dart` в `develop`.

## Диапазоны версий

В pubspec вендоренного пакета стоят caret-диапазоны от проверенных версий.
Точные используемые версии фиксирует корневой `pubspec.lock`, поэтому
фактическая сборка не расходится с записанным:

| Пакет | Диапазон | В `pubspec.lock` |
|---|---:|---:|
| `code_assets` | ^2.2.0 | 2.2.0 |
| `ffi` | ^2.2.0 | 2.2.0 |
| `hooks` | ^2.2.0 | 2.2.0 |
| `native_toolchain_c` | ^0.19.6 | 0.19.6 |
| `lints` (dev, только для analyze) | ^6.1.0 | 6.1.0 |

`ffigen` и `test` из dev-зависимостей убраны: биндинги лежат готовыми, а
тесты upstream в вендоренную копию не входят. Если понадобится
перегенерировать биндинги, `ffigen` добавляется временно и удаляется после
проверки. Dependabot настроен на корень
workspace и не должен предлагать обновление `flutter_pty2`; в
`.github/dependabot.yml` для него добавлено явное `ignore`. Обновление
вендоренного пакета и его зависимостей — только вручную по инструкции ниже.

## Что изменено относительно upstream

Базовая версия: `flutter_pty2` 3.0.0, тег `3.0.0`
(commit `5b64d45237`), https://github.com/SoFluffyOS/flutter_pty2.

Локальные изменения:

- `src/unix/pty_unix_spawn.c`:
  - `#include <TargetConditionals.h>`;
  - `#include <libproc.h>` только для macOS (`#if !TARGET_OS_IPHONE`);
  - две ветки с `proc_pidinfo()` (`fd_list_prepare` и
    `close_listed_fds_except`) собираются только для macOS. На iOS
    используется уже существующий общий fallback с перебором fd.
- `hook/build.dart`: для iOS и macOS явно линкуется `libutil`, в которой
  находится `openpty`. В upstream `util` был указан только для Linux, хотя
  CMake-сборка линкует его для всех Unix.
- `pubspec.yaml`: зависимости заданы caret-диапазонами от проверенных
  версий, из dev-зависимостей оставлен только `lints`.
- Из вендоренной копии удалены `example/`, `benchmark/`, `test/` и пустые
  платформенные каталоги, чтобы не тащить в репозиторий вложенное
  Flutter-приложение и чужие тесты. Остальные файлы, включая `LICENSE`
  (MIT), `README.md`, `CHANGELOG.md`, `doc/architecture.md`, оставлены как
  в upstream.

Патч не меняет поведение на Linux/macOS/Android: на macOS остаётся быстрый
путь через `proc_pidinfo`, на остальных Unix-платформах — прежний fallback.
На iOS библиотека компилируется, но PTY там не используется.

## Где что лежит

- `third_party/flutter_pty2/` — вендоренный пакет;
- `packages/pw_agent/lib/host/flutter_pty_launcher.dart` — адаптер
  `PtySession` к `PtyChannel`;
- `packages/pw_agent/lib/host/local_host_runtime.dart` — создаёт канал для
  локального Host;
- `tool/ci/check_bundle.dart` — проверяет `libflutter_pty2` в демоне и
  framework `flutter_pty2` в iOS-приложении.

## Как обновлять

1. Проверить upstream: https://pub.dev/packages/flutter_pty2 и
   https://github.com/SoFluffyOS/flutter_pty2. Смотреть, не исправлен ли
   `libproc.h` и нет ли других iOS-изменений.
2. Скачать архив новой версии:
   `curl -L -o /tmp/flutter_pty2.tar.gz https://pub.dev/api/archives/flutter_pty2-<версия>.tar.gz`
   и распаковать в временный каталог.
3. Перенести в `third_party/flutter_pty2/` файлы `lib/`, `src/`, `hook/`,
   `doc/`, `tool/`, `pubspec.yaml`, `LICENSE`, `README.md`, `CHANGELOG.md`,
   `analysis_options.yaml`, `ffigen_v2.yaml`. Не переносить `example/`,
   `benchmark/` и `test/`.
4. Перепроверить и при необходимости заново применить патч:
   `grep -R "libproc\|proc_pidinfo\|TARGET_OS" src/unix/pty_unix_spawn.c`.
   Если upstream уже сделал правильный guard, локальный патч можно убрать.
5. Обновить `pubspec.yaml` вендоренного пакета, если upstream поменял
   зависимости, и выполнить `flutter pub get`.
6. Прогнать проверки:
   ```bash
   dart format lib test tool packages
   flutter analyze
   flutter test test/host/local_pty_runtime_test.dart
   dart build cli --target packages/pw_server/bin/pw_server.dart -o /tmp/pw_daemon
   find /tmp/pw_daemon/bundle/lib -name '*flutter_pty2*'
   ```
   Для демона в bundle должна быть `libflutter_pty2.so` (или `.dylib`/`.dll`).
7. Отправить изменения в CI: job `macos-assembly` собирает
   `flutter build ios --simulator --no-codesign` и проверяет состав через
   `check_bundle.dart`.

## Windows и ConPTY

`flutter_pty2` использует на Windows ConPTY и не требует master fd, поэтому
прежнее ограничение `portable_pty` (блокирующее чтение и опрос таймером) на
него не распространяется. Но локальный терминал на Windows пока **выключен**:
`LocalHostRuntime.hasTerminal` возвращает `false`, а `spawnPty` отдаёт ошибку.
Команды идут обычным `Process` без TTY.

Проверка ConPTY идёт на настоящем `windows-latest` в CI: job
`windows-assembly` выполняет `flutter test test/host/windows_conpty_test.dart`.
Тест запускает `FlutterPtyLauncher` напрямую через тот же `cmd /c`, который
использует продукт, и проверяет вывод, код выхода, окружение и рабочую
директорию. POSIX-тесты PTY на Windows пропускаются, потому что используют
`sh`, `stty` и `read`.

Если тест зелёный, Windows-терминал можно включить отдельной правкой:

1. убрать override `hasTerminal` и ветку с ошибкой в `spawnPty` в
   `LocalHostRuntime`;
2. обновить тест `packages/pw_agent/test/host/local_host_runtime_test.dart`.

Если тест падает, сначала разобрать вывод шага `Test Windows ConPTY`; не
включать терминал вслепую.

## Когда форк можно удалить

- upstream исправил `libproc.h` и выпустил версию, которая компилируется для
  iOS. Тогда достаточно перейти на обычную pub-зависимость и удалить
  `third_party/flutter_pty2`;
- либо Flutter/Dart научились статической линковке code assets
  (`dart-lang/sdk#49418`), и можно вернуться на `portable_pty` с его
  статической библиотекой для iOS. Это менее вероятный сценарий.

## iOS и рантайм

На iOS локальный PTY не нужен и не поддерживается приложением: песочница не
разрешает порождать shell-процессы, а `flutter_pty2` использует `fork()`.
Сборка iOS нужна только для того, чтобы приложение с виртуальным Host
собиралось и проходило CI. Не пытайтесь включить `hasLocalHost` на iOS без
отдельного проекта вроде встроенного userland или эмулятора.
