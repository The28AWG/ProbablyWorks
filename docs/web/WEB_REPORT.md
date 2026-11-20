# Web-клиент ProbablyWorks: отчёт о реализации

Статус: **реализован тонкий web-клиент к серверу.** Браузер не
запускает локальный Host, SSH, PTY или базу. Он подключается к уже работающему
демону по HTTP/SSE, сохраняет удалённый профиль и дальше работает с чатами,
настройками и карточками через профильный API.

Есть две сборки web-клиента:

- `lib/main_web.dart` — статический релиз с hash-навигацией; его можно
  разместить на публичном хостинге без URL rewrite;
- `lib/main_web_hosted.dart` — страница, которую отдаёт сам сервер; использует
  path-навигацию и SPA fallback. Устройство bundled-варианта описано в
  [SERVER_WEB.md](SERVER_WEB.md).

Дата проверки: 20 ноября 2026. Проверки выполнялись на Linux в Chrome против
реального демона. Сборка web проверена отдельно.

С 20 ноября 2026 обе сборки выпускаются с `--wasm`: Chromium 137+ исполняет
WebAssembly, остальные браузеры автоматически получают JS-fallback из той же
сборки.

## 1. Что реализовано

- Точка входа `lib/main_web.dart` и отдельный bootstrap
  `lib/app/bootstrap/web_bootstrap.dart`.
- Web-сборка компилируется в WebAssembly (`--wasm`); `flutter_bootstrap.js`
  выбирает Wasm или JS-fallback по поддержке WasmGC и `wasmAllowList`.
- В web-bootstrap нет локальной БД, `AgentHub`, MCP-клиента и SSH. В DI
  регистрируются только клиентские зависимости: настройки, `SecretStore`,
  профили, роутер, локаль, тема, клавиши, `WebAppNotifier` и пустые реестры
  UI-плагинов.
- `ProfileService(includeLocal: false)`: локальный профиль не создаётся,
  доступны только удалённые профили.
- Первый экран `WebConnectPage`: имя профиля, адрес сервера и токен. Адрес
  проверяется как `http://` или `https://`; пустой токен не принимается.
- Если удалённый профиль уже сохранён, стартовый экран открывает его
  workspace. При offline профиль не удаляется и вход не блокируется.
- `ApiKeyGuard` в web не ведёт на нативный онбординг: неизвестный профиль
  перенаправляется на `/connect`.
- Работа с сервером идёт через `RemoteAgentApi` из `packages/pw_client`:
  HTTP-запросы, SSE `/api/v1/events`, повторное подключение и восстановление
  списков после reconnect.
- Включён CORS в `packages/pw_server`: разрешённые origin задаются
  `--allow-origin`, preflight не требует токена.
- `AppPlatform.isWeb` отключает локальный Host, PTY, фоновый сервис Android и
  drag-and-drop файлов. Вложения в web читаются из байтов выбранного файла,
  а не из пути ОС.
- Системные уведомления в web заменены на `WebAppNotifier`: он ничего не
  показывает. Браузерные уведомления в этот срез не входят.
- URL использует hash-стратегию Flutter (`#/a/<profileId>/chats`). Роутер
  нормализует хвостовой `/` и пустой `?`, а неизвестный путь перенаправляет
  на `/`.

## 2. Подключение и профиль

Последовательность фактическая:

1. Пользователь открывает web-сборку.
2. `StartPage` при `AppPlatform.isWeb` ищет первый удалённый профиль.
3. Если профиля нет, открывается `WebConnectPage`; если есть — workspace этого
   профиля, даже когда сервер сейчас недоступен.
4. `WebConnectPage` сохраняет адрес и токен через `ProfileService.addRemote`
   или `updateRemote`. Токен хранится через `FlutterSecureStorage`.
5. `RemoteAgentApi` проверяет `/health`, открывает SSE и загружает состояние
   профиля.
6. Дальше UI работает через те же `AgentApi`, `ChatApi`, `HostsApi`,
   `ProjectsApi`, `AgentSettingsApi` и другие интерфейсы, что и desktop.

Для web-хранилища токенов используется браузерное хранилище
`FlutterSecureStorage` (`localStorage`). Отдельной защиты от XSS для него нет:
это ограничение браузерной модели, а не серверной авторизации.

## 3. Offline и восстановление

Общий offline-режим работает и в web, и в desktop-демоне:

- при потере сервера показывается баннер «Сервер недоступен»;
- список чатов очищается, открытый чат закрывается, композер скрывается;
- профиль и токен сохраняются, в настройках можно добавить или переключить
  агента;
- удалённые группы настроек скрыты, локальные язык, тема и клавиши работают;
- после reconnect `RemoteAgentApi` публикует `reconnect`, и списки
  перечитываются через SSE/API.

Это поведение проверено против реального демона: остановка сервера, ожидание
баннера, повторное подключение и возврат списков.

## 4. Ограничения текущего среза

- **Вложения.** Реализовано чтение байтов через `file_selector` и
  `classifyAttachmentBytes`, но отдельного ручного прогона web-вложений нет;
  под Wasm этот сценарий тоже не проверялся.
- **Уведомления.** `WebAppNotifier` — заглушка. Разрешения браузера,
  Service Worker и фоновая вкладка не проверены.
- **Плагины.** Реестры UI-плагинов и команд плагинов в web пустые: локальные
  скомпилированные плагины не подключаются. Поведение серверных плагинов и MCP
  в web отдельно не проверялось.
- **Тестовая оболочка.** `web/index.html` и `web/manifest.json` уже
  используют название ProbablyWorks и описание продукта; стандартные иконки
  Flutter остаются. Оболочка не влияет на функциональность web-клиента.
- **Хостинг.** Статический web-релиз собирается с `base href="/"` и
  размещается в корне сайта. URL используют hash-навигацию, поэтому rewrite
  не нужен. Bundled-вариант отдаёт сервер; он описан в
  [SERVER_WEB.md](SERVER_WEB.md).
- **Браузеры Wasm.** В Flutter 3.50 Wasm по умолчанию работает в Chromium
  137+. Safari и Firefox получают JS-fallback, пока для них явно не включён
  `wasmAllowList`. Fallback проверяется автоматически при старте.
- **Многопоточность.** Bundled-сервер выставляет COOP/COEP и включает
  многопоточный Skwasm. На внешнем статическом хостинге без этих заголовков
  Wasm работает в однопоточном режиме.
- **Выгрузка вкладки.** Поведение при закрытии/засыпании вкладки и потере SSE
  на редких конфигурациях отдельно не проверялось.
- **Тесты.** Раздача статики, SPA fallback, traversal и защита API покрыты
  тестами `pw_server`. Отдельных тестов web-виджетов и CORS-сценариев в
  браузере нет.
- **Windows/macOS/iOS.** Web проверен на Linux/Chrome; реальные проверки
  desktop-платформ остаются отдельной задачей.

## 5. Проверки и измерения

Базовая JS-сборка до включения Wasm (13 ноября 2026):

| Проверка | Результат |
|---|---|
| `flutter build web -t lib/main_web.dart` | успешно, около 40 секунд |
| `build/web` | 47 МБ, 51 файл |
| `probably-works-web.tar.gz` из `build/web` | около 16 МБ |

Сборка без `--no-tree-shake-icons` проходит: Flutter штатно уменьшает
`MaterialIcons` и `CupertinoIcons`. Основной объём даёт `canvaskit` (37 МБ),
затем `main.dart.js` (6 МБ) и `assets` (4 МБ).

Wasm-сборка (20 ноября 2026):

| Проверка | Результат |
|---|---|
| `flutter build web -t lib/main_web.dart --wasm --release` | успешно, 52 секунды |
| `flutter build web -t lib/main_web_hosted.dart --wasm --release` | успешно, 53 секунды |
| `build/web` с Wasm | 53 МБ: `main.dart.wasm` 5,6 МБ, `main.dart.js` 6,5 МБ, Skwasm 3,5 МБ |
| `probably-works-web.tar.gz` | около 18 МБ |
| Chrome 157, headless | загружены `main.dart.wasm`, `main.dart.mjs`, `skwasm.wasm` |
| Подключение к демону | токен, профиль, `FlutterSecureStorage`, чаты и настройки |
| SSE `/api/v1/events` | соединение открыто 30 секунд |
| COOP/COEP и отдельный API-origin | `crossOriginIsolated: true`, API и SSE работают |

`main.dart.js` в Wasm-сборке — это штатный JS-fallback, а не второй
обязательный файл. Браузер загружает либо Wasm, либо JavaScript.

Отложенная загрузка (20 ноября 2026):

| Проверка | Результат |
|---|---|
| `flutter build web ... --wasm --enable-wasm-deferred-loading` | успешно для static и hosted |
| Начальный `main.dart.js` | 6,2 МБ; 17 частей `main.dart.js_*.part.js` на 521 КБ |
| Начальный `main.dart.wasm` | 5,5 МБ; 17 модулей `main.dart_module*.wasm` на 944 КБ |
| Chrome 157, headless, deep link `/#/onboarding` и `/#/connect` | загружены `main.dart.wasm` и отложенные модули, ошибок в консоли нет |

`main.dart.js` в отложенной сборке тоже разбит на части: этим пользуются
браузеры без Wasm. Имена частей не содержат хэш, поэтому `StaticWeb` отдаёт
их с `no-cache`.

Проверки правки (20 ноября 2026):

| Проверка | Результат |
|---|---|
| `flutter test` | 1329 прошло, 15 пропущено |
| `flutter analyze` | без замечаний |
| `dcm analyze lib test` | без замечаний |
| `dart format --output=none --set-exit-if-changed lib test tool packages` | без изменений |
| `dart test` в `packages/pw_server` | 17 прошло |
| `tool/ci/test_packages.sh` | все пакеты прошли |

Ручной сценарий против реального демона: подключение по адресу и токену,
открытие чатов, настройки, потеря сервера, offline-баннер, Retry и возврат
списков. Вложения, браузерные уведомления и выгрузка вкладки в этот прогон не
входили.

## 6. CI, релиз и артефакты

`ci.yml` собирает оба web-entrypoint’а с `--wasm` и
`--enable-wasm-deferred-loading`: статический `lib/main_web.dart` и hosted
`lib/main_web_hosted.dart`. Это ловит поломки path-стратегии, Wasm-компиляции,
JS-fallback, отложенных модулей и bundled-сборки до релиза.

`release.yml` выпускает три независимых группы артефактов:

- `probably-works-server-...` — только сервер;
- `probably-works-web-...` — только статический web-клиент;
- `probably-works-server-web-...` — сервер и web рядом, без встраивания
  статики в бинарник.

Bundled-дистрибутив содержит `server/`, `web/`, `start.sh`/`start.bat` и
README. Launcher запускает сервер с `--web-dir web`. Устройство и ограничения —
в [SERVER_WEB.md](SERVER_WEB.md).

Отдельный статический хостинг остаётся возможным: в этом случае web и API
разные origin'ы, серверу нужен `--allow-origin` с адресом web-клиента, а
wildcard использовать нельзя.

## 7. Как запустить локально

1. Запустить headless-демон из VS Code конфигурацией `pw_server (daemon)`.
   Она печатает токен и разрешает CORS для `localhost:8080` и
   `127.0.0.1:8080`.
2. Запустить конфигурацию `ProbablyWorks (web)` — откроется
   `http://localhost:8080`.
3. Ввести адрес `http://127.0.0.1:7787` и токен из консоли демона.

Эквивалент без VS Code:

```bash
(cd packages/pw_server && dart run bin/pw_server.dart \
  --print-token --port 7787 \
  --allow-origin http://localhost:8080 \
  --allow-origin http://127.0.0.1:8080)

flutter run -d chrome --wasm -t lib/main_web.dart \
  --web-hostname localhost --web-port 8080
```

Production-сборка:

```bash
flutter build web -t lib/main_web.dart --wasm --release \
  --enable-wasm-deferred-loading -o build/web-static --base-href=/
# содержимое build/web-static отдать статическим сервером в корне домена
```

Для bundled-варианта:

```bash
flutter build web -t lib/main_web_hosted.dart --wasm --release \
  --enable-wasm-deferred-loading -o build/web-hosted --base-href=/
dart run tool/package/package_server_web.dart \
  --platform=linux --arch=x64 --web-dir=build/web-hosted
```

## 8. Файлы

- `lib/main_web.dart` — статический web-entrypoint с hash-навигацией.
- `lib/main_web_hosted.dart` — web-entrypoint для раздачи сервером.
- `lib/app/bootstrap/web_bootstrap.dart` — DI без БД и локального агента.
- `lib/app/bootstrap/web_host_config.dart` — адрес сервера по умолчанию для
  статической и bundled-сборки.
- `lib/features/connect/presentation/pages/web_connect_page.dart` — экран
  подключения.
- `lib/app/profiles/profile_service.dart` — удалённые профили и
  `RemoteAgentApi`.
- `packages/pw_client/lib/src/remote_agent_api.dart` — HTTP/SSE-клиент,
  reconnect и offline-статусы.
- `packages/pw_server/lib/src/api/api_server.dart` — CORS, API и ранняя
  обработка статики.
- `packages/pw_server/lib/src/web/static_web.dart` — раздача web-сборки,
  MIME-типы `.wasm`/`.mjs`, cross-origin isolation, SPA fallback и защита
  путей.
- `lib/app/backend/backend_status.dart` — offline-баннер и заглушка.
- `lib/core/platform/app_platform.dart` — отключение локального Host в web.
- `lib/core/notify/web_app_notifier.dart` — заглушка уведомлений.
- `lib/app/router/app_router.dart` — deep links и fallback-маршрут.
- `web/index.html`, `web/manifest.json` — статическая оболочка.
