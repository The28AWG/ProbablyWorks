# Открытые задачи по агенту ProbablyWorks

Здесь остались только незакрытые вопросы. Завершённые задачи удалены из
рабочего списка: их описание, решения и проверки есть в истории git по этому
файлу. ID стабильны и не переиспользуются.

Статусы: **в работе**, **todo**, **частично**.

## Сводка

| ID | Приоритет | Статус | Тема |
|---|---|---|---|
| PW-016 | P1 | частично | Автоматический выбор модели под задачу |
| PW-017 | P1 | частично | Release, подпись и интеграционные проверки демона |
| PW-018 | P1 | частично | Семантический поиск по истории и файлам |
| PW-023 | P1 | todo | Подпись Android и имена приложений |
| PW-024 | P2 | todo | Временные исключения после обновления Flutter 3.50 |
| PW-025 | P2 | todo | Убрать dependency_overrides для equatable |

## P1

### PW-016. Автоматический выбор модели под задачу

**Статус:** частично. Fallback-модель, повтор при временных ошибках, проверка
tool calling и запись стоимости по фактической модели уже работают.

**Открытый вопрос.** Как выбирать модель по сложности задачи: дешёвую для
рутины и сильную для сложного, не отменяя явный выбор пользователя.

**Что сделать.**
- Сформулировать правила выбора и порог сложности.
- Добавить автоматический выбор модели для подзадачи.
- Оставить явный выбор пользователя и fallback выше автоматики.

**Критерии приёмки.**
- Временная ошибка провайдера не завершает задачу.
- Модель без tool calling не получает tools молча.
- Автоматический выбор объясним и не переопределяет явно выбранную модель.

**Файлы:** `packages/pw_agent/lib/agent/loop/chat_session_context.dart`,
`packages/pw_agent/lib/core/data/settings_repository.dart`.

### PW-017. Release, подпись и интеграционные проверки демона

**Статус:** частично. Ядро, headless-демон, HTTP API, удалённый клиент, профили,
планировщик и упаковка уже есть. Открыты release- и интеграционные проверки.
Web выпускается отдельной статической сборкой, а также в дистрибутиве
«сервер + web»; статика не встраивается в бинарник.

**Открытые вопросы.**
- Snap-пакет не собран и не установлен на реальной системе: локальная сборка
  блокируется Ubuntu Pro, classic-режим требует ручной проверки Snap Store.
- Windows EXE и macOS DMG собираются в CI, но для публичного релиза нет
  подписи Authenticode и notarization macOS.
- Windows Credential Manager для демона подключён через FFI, но не проверен
  на реальной Windows-машине.
- Встроенного TLS нет. Нужно проверить инструкцию с SSH-туннелем, Caddy и
  nginx: SSE, таймауты, токен.
- Нет интеграционного теста планировщика с реальным агентом: проверены HTTP
  API на фейковом backend, клиент с реальным `ApiServer` и запуск демона без
  выполнения хода.

**Критерии приёмки.**
- Пакет устанавливается и запускается на целевой ОС, подпись проверена.
- Планировщик выполняет отложенную задачу с настоящим агентом после
  перезапуска демона.
- Удалённое подключение описано и проверено без ослабления политики.
- Статический web-архив работает на хостинге без rewrite; bundled-вариант
  отдаёт web и API с одного origin, а `/api/**` остаётся под токеном.
- В bundled-дистрибутиве `server/` и `web/` лежат отдельно.

**Ссылки:** [DAEMON.md](DAEMON.md), [SECURITY.md](SECURITY.md),
[PACKAGING.md](PACKAGING.md), [SERVER_WEB.md](../web/SERVER_WEB.md).

### PW-018. Семантический поиск по истории и файлам

**Статус:** частично. FTS-поиск по всем чатам и проектам, `chat_history_search`
с `scope=chat|project|all` и саммари проекта уже работают.

**Открытый вопрос.** Как добавить поиск по смыслу, а не только по точным
словам: embeddings, хранение векторов и инкрементальная индексация.

**Решение:** семантический поиск отложен. Пути решения и рекомендуемая
последовательность собраны в [SEMANTIC_SEARCH.md](SEMANTIC_SEARCH.md).

**Что сделать.**
- Выбрать модель эмбеддингов и формат хранения векторов.
- Индексировать историю и файлы проекта инкрементально.
- Добавить поиск по смыслу в API и UI, не заменяя FTS.

**Критерии приёмки.**
- Агент находит решение из другого чата проекта по смыслу, а не только по
  совпадению слов.
- Индекс обновляется при новых сообщениях и правках, удаление чата очищает
  его векторы.
- Память и поиск не раздувают system prompt без ограничений.

**Файлы:** `packages/pw_agent/lib/agent/memory/`,
`packages/pw_agent/lib/core/data/chat_repository.dart`,
`docs/agent/SEMANTIC_SEARCH.md`.

### PW-023. Подпись Android и имена приложений

**Статус:** todo. Дополняет PW-017: там учтены Windows Authenticode и
notarization macOS, но не Android и не пользовательские имена.

**Проблема.** Release-сборка Android подписывается debug-ключом
(`signingConfig = signingConfigs.getByName("debug")`), в конфигурации остался
шаблонный TODO. Пользовательские имена на Android, Windows, macOS и iOS —
`probably_works`; в macOS остался шаблонный copyright. Если APK или
установщик попадут пользователю, приложение будет выглядеть как черновик, а
release-APK нельзя обновить поверх правильно подписанной версии.

**Что сделать.**
- Настроить release keystore через секреты CI, не хранить ключ в репозитории.
- Задать `ProbablyWorks`/`probably-works` в манифестах и ресурсах, убрать
  шаблонные TODO и copyright.
- Либо добавить Android-сборку в release, либо явно записать в документации,
  что APK не публикуется.

**Критерии приёмки.**
- APK, EXE и DMG показывают правильное имя и не содержат `probably_works` в
  видимых метаданных.
- Release-APK подписан не debug-ключом; ключ и пароль не лежат в репозитории.
- PW-017 и PW-023 не противоречат друг другу по охвату платформ.

**Файлы:** `android/app/build.gradle.kts`,
`android/app/src/main/AndroidManifest.xml`, `windows/runner/Runner.rc`,
`windows/runner/main.cpp`, `macos/Runner/Configs/AppInfo.xcconfig`,
`ios/Runner/Info.plist`.

## P2

### PW-024. Временные исключения после обновления Flutter 3.50

**Статус:** todo. Появилось при переходе на Flutter 3.50 / Dart 3.14.

**Проблема.** Чтобы `flutter analyze` проходил без замечаний, при обновлении
добавлены исключения и `ignore`. Это не целевое состояние, а совместимость с
зависимостями, которые ещё не перешли на `material_ui`:

- `analysis_options.yaml`: каталоги `**/l10n/generated/**` исключены из
  анализа. `flutter gen-l10n` в 3.50 всё ещё генерирует импорт
  `flutter_localizations` и делегаты `GlobalMaterialLocalizations` /
  `GlobalCupertinoLocalizations`, помеченные deprecated. Править
  сгенерированные файлы вручную нельзя.
- `lib/app/locale/app_localization_delegates.dart`: оставлен
  `flutter_l10n.GlobalMaterialLocalizations.delegate` с `ignore`. Он нужен
  legacy-виджетам `package:flutter/material.dart`, в частности `SelectionArea`
  внутри `markdown_widget 2.3.2+8`.
- `packages/app_ui/lib/src/widgets/app_markdown.dart`: импорт
  `package:flutter/material.dart` и `MaterialUiCompatibilityBridge` нужны,
  пока `markdown_widget` собран на старом Material. Импорт помечен `ignore`.
- `test/app/ui/read_file_view_test.dart`: `GoldenFonts.load()` перенесён в
  `setUpAll`. В Flutter 3.50 загрузка шрифта внутри `testWidgets` оставляет
  отложенный кадр переразметки, и проверка инвариантов теста падает с
  «An animation is still running even after the widget tree was disposed».

**Что сделать.**
- Следить за релизами `markdown_widget` и Flutter. Когда `markdown_widget`
  перейдёт на `material_ui`, убрать legacy-импорт,
  `MaterialUiCompatibilityBridge`, отдельный legacy-делегат и связанные
  `ignore`.
- Когда `flutter gen-l10n` начнёт генерировать делегаты из `material_ui` и
  `cupertino_ui`, удалить исключение `**/l10n/generated/**` и проверить
  `flutter analyze` без него.
- После исправления поведения загрузки шрифтов во Flutter вернуть
  `GoldenFonts.load()` в сами тесты либо оставить `setUpAll`, если он станет
  общим правилом, и удалить ссылку на эту задачу.

**Критерии приёмки.**
- В `analysis_options.yaml` нет исключения сгенерированных l10n либо у него
  другая актуальная причина.
- В коде нет `ignore: deprecated_member_use` для legacy Material и
  `MaterialUiCompatibilityBridge`.
- `flutter analyze`, DCM и `flutter test` проходят без этих исключений.

**Файлы:** `analysis_options.yaml`,
`lib/app/locale/app_localization_delegates.dart`,
`packages/app_ui/lib/src/widgets/app_markdown.dart`,
`test/app/ui/read_file_view_test.dart`.

### PW-025. Убрать dependency_overrides для equatable

**Статус:** todo. Введено вместе с переходом на `equatable 3.0.0`.

**Проблема.** `xterm2 5.4.0` объявляет зависимость `equatable ^2.0.3`, но не
импортирует её. Чтобы использовать актуальный `equatable 3.0.0`, в корневом
`pubspec.yaml` добавлен `dependency_overrides: equatable: 3.0.0`. Override
обходит ограничение пакета: если будущий `xterm2` начнёт использовать
удалённый в 3.0.0 API, сборка сломается на компиляции.

Ломающие изменения `equatable 3.0.0` проект не затрагивают: `EquatableMixin`
нигде не используется, `EquatableConfig.stringify` не настраивается, а
сравнение классов по-прежнему учитывает `runtimeType`. Тесты проходят, но
override остаётся временным обходом, а не нормой.

**Что сделать.**
- Следить за релизами `xterm2`: когда он разрешит `equatable ^3.0.0` или
  удалит неиспользуемую зависимость, убрать `dependency_overrides`.
- При необходимости предложить пакету удалить неиспользуемый `equatable`.
- После удаления вернуть обычные ограничения `equatable: ^3.0.0` и проверить
  `flutter pub get`, `flutter analyze`, DCM и тесты.

**Альтернатива.** Взять `xterm2` за основу собственного форка терминального
пакета. Оригинальный `xterm` не обновлялся около двух лет, а полный набор
изменений `xterm2` относительно него не проверен независимо. Свой форк
позволяет убрать неиспользуемый `equatable`, зафиксировать исходный коммит и
контролировать состав патчей. Цена — сопровождение пакета: сравнить `xterm2` с
`xterm`, сохранить историю изменений, перенести тесты терминала и проверить
форк на всех целевых платформах. Пока форк не готов, действует текущий
`dependency_overrides`.

**Критерии приёмки.**
- В `pubspec.yaml` нет `dependency_overrides` для `equatable`.
- `flutter pub get` разрешает зависимости без override.
- `dart run tool/ci/check_dependencies.dart` не показывает override.
- Тесты и сборки проходят.

**Файлы:** `pubspec.yaml`, `pubspec.lock`,
`packages/pw_agent/pubspec.yaml`, `docs/agent/DEPENDENCIES.md`.
