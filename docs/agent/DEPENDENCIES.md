# Зависимости и Android-тулчейн

Документ описывает, как обновлять Flutter, Android Gradle Plugin, Gradle,
Kotlin и pub-зависимости, не превращая случайную удачную комбинацию версий в
непроверяемое состояние.

## Принципы

- **Источник истины для Android-тулчейна — шаблон установленного Flutter.**
  Flutter проверяет совместимость Gradle, AGP и Kotlin между собой и со своим
  Gradle-плагином. Версии новее шаблона допустимы, но выходят за проверенный
  диапазон: их можно пробовать только с полной сборкой всех целевых платформ.
- **Сначала шаблон Flutter, потом абсолютно последние версии.** Обновление до
  последних стабильных AGP/Gradle/Kotlin без проверки Flutter может дать
  несовместимость KGP и Gradle, которую CI заметит только на сборке.
- **Мажорные обновления pub-зависимостей — отдельная задача.** Смотрим
  changelog, миграцию и причины, почему версия ещё не разрешается.
- **Не подавляем замечания анализатора ради обновления.** Если новая версия
  требует `ignore` или исключения, причина и условие снятия фиксируются в
  `docs/agent/ISSUES.md`, а не остаются только комментарием в коде.

## Вендоренные пакеты

`third_party/flutter_pty2` — локальный форк с патчем для iOS-сборки. Его
зависимости заданы caret-диапазонами от проверенных версий, фактические версии
фиксирует корневой `pubspec.lock`; Dependabot для пакета отключён, а обновление
не делается через `flutter pub upgrade`: порядок сверки с upstream и повторного
применения патча описан в [PTY.md](PTY.md).

## Текущее состояние

Проверено на Flutter 3.50.0 / Dart 3.14.0:

| Компонент | Версия | Источник |
|---|---|---|
| Gradle | 9.6.0 | минимум для AGP 9.5.1 |
| AGP | 9.5.1 | новее шаблона Flutter 3.50 (9.3.1) |
| Kotlin Gradle Plugin | 2.4.21 | патч к 2.4.20 из шаблона Flutter |
| `desugar_jdk_libs` | 2.1.5 | последняя стабильная |
| `compileSdk` | 37 | требование `flutter_local_notifications` 23 |
| `targetSdk` | 36 | шаблон Flutter |

AGP 9.3.1 из шаблона Flutter 3.50 валит **release**-сборку Android: lint
падает с `NoSuchMethodError: java.util.List.removeLast()` на
`file_selector_android`. Debug-сборка при этом проходит. Поэтому проект
намеренно использует AGP 9.5.1 и минимальный для него Gradle 9.6.0. Kotlin
2.4.21 — патч к версии из шаблона, менять её на мажор без проверки Flutter не
нужно. Flutter 3.50 знает Gradle до 9.5.0 и AGP до 9.3.1; комбинация 9.6.0 +
9.5.1 проверена debug- и release-сборкой APK этого проекта, а не валидатором
Flutter.

`flutter_local_notifications` 23 требует `compileSdk 37`, а шаблон Flutter 3.50
ещё использует 36. Поэтому в `android/app/build.gradle.kts` стоит
`maxOf(flutter.compileSdkVersion, 37)`: когда Flutter поднимет значение,
проект автоматически пойдёт за ним. Когда шаблон дойдёт до 37, литерал можно
убрать и вернуться к `flutter.compileSdkVersion`.

## Регулярная проверка

Из корня репозитория:

```bash
# Сверка Android-версий с шаблоном Flutter и список обновлений pub.
dart run tool/ci/check_dependencies.dart

# Подробный отчёт pub: current / upgradable / resolvable / latest.
flutter pub outdated
```

Скрипт помечает версии `[ok]`, если они совпадают с шаблоном, `[new]` — если
проект ушёл вперёд осознанно, и `[!!]` — если отстал. Отдельно выводятся
`dependency_overrides`. `--strict` возвращает код 1 для `[!!]`, обновлений
прямых зависимостей и override. Его стоит запускать в плановой проверке перед
релизом, а не на каждом коммите: обновления выходят независимо от кода
проекта. `[new]` не ошибка, но требует полной сборки целевых платформ и записи
причины в этом документе.

Версии шаблона Flutter можно посмотреть и напрямую:

```bash
flutter_root="$(flutter --version --machine | grep -o '"flutterRoot":"[^"]*"' | cut -d'"' -f4)"
grep -E 'template(DefaultGradle|AndroidGradlePlugin|KotlinGradlePlugin)Version' \
  "$flutter_root/packages/flutter_tools/lib/src/android/gradle_utils.dart"
```

## Порядок обновления

1. Обновить Flutter локально и в CI, поднять ограничение `sdk` в `pubspec.yaml`
   и пакетах.
2. Запустить `dart run tool/ci/check_dependencies.dart` и привести Gradle, AGP и
   Kotlin к версиям шаблона. Если проект уже ушёл вперёд (как AGP 9.5.1),
   проверить, что новая версия Flutter не догнала её без причины, а отставание
   помечено `[!!]`. Gradle wrapper обновляется правкой
   `android/gradle/wrapper/gradle-wrapper.properties`.
3. Выполнить `flutter pub upgrade` для патчей и миноров в текущих ограничениях.
4. Для мажоров: прочитать changelog и migration guide, поднять ограничение в
   `pubspec.yaml`, при необходимости обновить код и Android-конфигурацию.
5. Перегенерировать код, если менялись `injectable`, `auto_route` или `drift`:
   `dart run build_runner build --delete-conflicting-outputs`.
6. Прогнать полную проверку `tool/ci/check_local.sh` и собрать затронутые
   платформы: `flutter build linux`, `flutter build windows`,
   `flutter build macos`, `flutter build web`, а для Android — отдельно
   `flutter build apk --debug` и `flutter build apk --release`. Release важен:
   часть ошибок AGP и lint видна только в нём.
7. Записать причину временных исключений, override и условия их снятия в
   `docs/agent/ISSUES.md`.

Перед обновлением или добавлением зависимости проверяйте версию и уязвимости
через Sonatype MCP (`getLatestComponentVersion`,
`getRecommendedComponentVersions`, `getComponentVersion`), как требует
`AGENTS.md`.

## Мажорные обновления, которые ждут внешних пакетов

Эти версии уже опубликованы, но пока не разрешаются в текущем дереве
зависимостей:

| Пакет | Нужная версия | Что блокирует | Когда вернуться |
|---|---|---|---|
| `desktop_drop` | 0.9.2 | требует `cross_file ^0.4`, а `file_selector` и его платформенные пакеты ещё на `cross_file ^0.3`; кроме того, нужна миграция API | после обновления `file_selector` |
| `build_runner` | 2.17.1 | требует `build ^5`, а `injectable_generator ^3.1.3` требует `build ^4` | после обновления генераторов |
| `test` | 1.33.0 | версия закреплена Flutter SDK | вместе со следующим Flutter |

`desktop_drop 0.9` — не только смена версии: у него переименованы callbacks
(`onDragEntered` → `onEnter`, `onDragExited` → `onLeave`, `onDragDone` →
`onDrop`) и изменена модель элементов перетаскивания. Миграцию делать
отдельным изменением с проверкой ручного перетаскивания файлов.

## Замена xterm на xterm2

`xterm` 4.0.0 не обновлялся с февраля 2024 года. В проекте используется
`xterm2` — поддерживаемый форк с тем же API и исправлениями для новых
Flutter и терминальных сценариев. Замена потребовала только сменить имя
пакета в `pubspec.yaml` и импортах; `Terminal`, `TerminalView`, тема и
`RenderTerminal` сохранили совместимый API.

Форк пока менее популярен, чем оригинал, поэтому при обновлении проверяйте
его changelog и полный набор тестов терминала. После замены немного изменился
глиф `✓` в терминале, поэтому эталоны `ui_kit_dark.png` и `ui_kit_light.png`
обновлены осознанно.

В 5.5.0 `TerminalView` перестал автоматически отвечать на запросы OSC 52:
программа не получает буфер обмена, пока приложение не задаст
`Terminal.onClipboardQuery`. Для вывода команд это нужное поведение — запись
в буфер по-прежнему работает, — и оно закреплено тестом
`test/app/ui/command_output_test.dart`.

## equatable 3 и dependency_overrides

`xterm2 5.5.0` объявляет `equatable ^2.0.3`, но нигде его не импортирует. Чтобы
использовать `equatable 3.0.0`, в корневом `pubspec.yaml` стоит
`dependency_overrides`, а обычные ограничения подняты до `^3.0.0`.

Ломающие изменения 3.0.0 проект не затрагивают:

- `EquatableMixin` удалён, но в проекте он не используется;
- сравнение свойств больше не проверяет их `runtimeType`, а сравнение самих
  `Equatable`-классов по-прежнему учитывает `runtimeType`;
- `toString()` без `stringify` теперь возвращает стандартный
  `Instance of '...'`; проект не настраивает `stringify`, а в debug-режиме
  поведение осталось прежним.

Override нужен только из-за неиспользуемой зависимости `xterm2`. Это
временное решение: при обновлении `xterm2` проверьте, не начал ли он
использовать удалённый API, и уберите override, когда пакет ослабит
ограничение. Задача на снятие — PW-025 в `docs/agent/ISSUES.md`.

Если ждать обновления `xterm2` слишком долго, альтернатива — собственный форк
на его основе: оригинальный `xterm` не обновлялся около двух лет, а изменения
`xterm2` стоит проверить самостоятельно. Такой форк позволит сразу убрать
неиспользуемый `equatable`, но потребует сопровождения и синхронизации с
upstream.

## Платформенные файлы

- Linux и Windows: `cmake_minimum_required` и стандарт C++ совпадают с шаблоном
  Flutter 3.50, обновлять нечего.
- macOS: deployment target 12.0, iOS: 15.0 — совпадают с шаблоном Flutter 3.50.
- iOS и macOS используют Swift Package Manager, `Podfile` нет.
- В `linux/runner/my_application.cc`, macOS entitlements и iOS `AppDelegate`
  есть намеренные отличия от шаблона: заголовок GTK, доступ к файлам и сети,
  delegate уведомлений. Их нельзя перезаписывать шаблоном `flutter create`.
- В web обновлены устаревшие метаданные шаблона (`A new Flutter project`,
  `probably_works`); остальная разметка совместима с Flutter 3.50.

## Автоматизация

Сейчас обновления проверяются вручную. Android не входит в релизные платформы,
поэтому в `platforms.yml` нет job-а сборки APK: его нужно проверять локально
командами из шага 6. Если Android станет целевой платформой, добавить туда
`flutter build apk --debug` и `--release`.

Если понадобится бот, для Gradle и GitHub Actions подходит Dependabot, а для
публикаций pub и версии Flutter в workflow — Renovate с regex-правилами.
Перед включением бота нужно убедиться, что он умеет работать с Flutter
workspace и не предлагает версии, которые ломают закреплённую комбинацию
Flutter + AGP + Kotlin.
