# Headless-демон и HTTP API

Демон запускает агент без Flutter-интерфейса, владеет базой и отдаёт локальный
HTTP API. Клиент по-прежнему работает с агентом напрямую и **не зависит** от
пакета API.

## Пакеты

```
packages/pw_agent   # агент, БД, Host, провайдеры; чистый Dart
packages/pw_client  # HTTP/SSE клиент AgentApi для удалённых профилей
packages/pw_server  # HTTP API и headless-запуск поверх pw_agent; чистый Dart
```

Зависимости направлены только вниз:

```
Flutter-клиент ──► pw_agent
pw_server    ──► pw_agent
```

Flutter-части (keyring, уведомления, тема, `path_provider`) остаются в клиенте.
Демон подставляет headless-реализации через `get_it` до
`configureAgentDependencies()`.

## Запуск

```bash
dart run packages/pw_server/bin/pw_server.dart --print-token
```

Полезные аргументы:

- `--data-dir <path>` — каталог данных; по умолчанию тот же, что у клиента;
- `--port <port>` — порт API (по умолчанию `7787`, `0` — выбрать свободный);
- `--bind <address>` — адрес (по умолчанию `127.0.0.1`);
- `--print-token` — напечатать токен один раз;
- `--rotate-token` — выпустить новый токен и напечатать его.

Демон и embedded-GUI не могут одновременно владеть одной базой: single-instance
lock остаётся общим. Поэтому на desktop GUI сначала ищет демон, а при его
отсутствии запускает сервис сам (см. ниже). Для работы «при закрытом окне»
пользователь закрывает GUI, а не демон.

## API

Все endpoint'ы, кроме `/api/v1/health`, требуют
`Authorization: Bearer <token>`.

Все метки времени в JSON — ISO-8601 в UTC с суффиксом `Z`. Клиент хранит
их как UTC и переводит в локальную зону только при отображении.

```
GET    /api/v1/health
GET    /api/v1/hosts
PUT    /api/v1/hosts/{id}
DELETE /api/v1/hosts/{id}
POST   /api/v1/hosts/{id}/test
PUT    /api/v1/hosts/{id}/trust
GET    /api/v1/chats
POST   /api/v1/chats                 {"hostId": "local"}
GET    /api/v1/chats/{id}

PUT    /api/v1/chats/{id}/presence   зарегистрировать карточки после перезапуска
PUT    /api/v1/chats/{id}/turn       продолжить ход после лимита шагов
DELETE /api/v1/chats/{id}/turn       остановить текущий ход
POST   /api/v1/chats/{id}/forks      форк чата
POST   /api/v1/chats/{id}/regenerations
POST   /api/v1/chats/{id}/compactions
PATCH  /api/v1/chats/{id}/messages/{messageId}
DELETE /api/v1/chats/{id}/messages/{messageId}/following
PUT    /api/v1/chats/{id}/draft            {"text": "...", "attachments": [...], "revision": 1}
PUT    /api/v1/chats/{id}/message-edits    {"edits": {...}, "revision": 1}
GET    /api/v1/chats/{id}/session
PATCH  /api/v1/chats/{id}/queue/{index}
DELETE /api/v1/chats/{id}/queue/{index}

GET    /api/v1/chats/{id}/messages
POST   /api/v1/chats/{id}/messages   {"text": "...", "sendNow": false}
GET    /api/v1/chats/{id}/runs
GET    /api/v1/chats/{id}/events     Server-Sent Events по чату

PUT    /api/v1/approvals/{id}/decision         {"action": "allowOnce|allowTurn|allowChat|deny"}
PUT    /api/v1/questions/{id}/answer           {"answer": "..."}
PUT    /api/v1/edit-file-changes/{id}/decision {"choice": "rollbackAndContinue|continueWithoutRollback|cancel"}

GET    /api/v1/push
PUT    /api/v1/push                           {"enabled": true, "relayUrl": "...", "token": "..."}
POST   /api/v1/push/test
GET    /api/v1/settings
PUT    /api/v1/settings/{key}                 {"value": "..." | null}
PUT    /api/v1/settings/pinned                {"pinnedModels": ["..."]}
PUT    /api/v1/settings/steps                 {"group": true, "expandWhileActive": true, "thoughts": "...", "tools": "..."}
PUT    /api/v1/settings/limits                {"limits": {...}}
PUT    /api/v1/settings/denylist              {"denylist": ["..."]}
PUT    /api/v1/settings/security-profile      {"profile": "{...}"}
POST   /api/v1/settings/api-key               {"key": "..."}
DELETE /api/v1/settings/api-key
POST   /api/v1/settings/api-key/check
GET    /api/v1/models
POST   /api/v1/models/refresh
POST   /api/v1/models/remember                {"ids": ["..."]}

GET    /api/v1/security/audit
GET    /api/v1/plugins
PUT    /api/v1/plugins/enabled                {"ids": ["..."], "enabled": false}
GET    /api/v1/plugins/{id}/missing-dependencies
GET    /api/v1/plugins/{id}/dependents
GET    /api/v1/plugins/{id}/settings
PUT    /api/v1/plugins/{id}/settings          {"value": {...}}
POST   /api/v1/plugins/refresh

GET    /api/v1/mcp
POST   /api/v1/mcp/ready
PUT    /api/v1/mcp/servers/{id}
DELETE /api/v1/mcp/servers/{id}
POST   /api/v1/mcp/servers/{id}/restart
POST   /api/v1/mcp/servers/{id}/tools/refresh
POST   /api/v1/mcp/import                     {"text": "...", "sourcePath": "..."}
GET    /api/v1/mcp/export

GET    /api/v1/projects
GET    /api/v1/projects/counts
PUT    /api/v1/projects/{id}
DELETE /api/v1/projects/{id}
GET    /api/v1/projects/{id}/chats
GET    /api/v1/projects/{id}/facts
POST   /api/v1/projects/{id}/facts
DELETE /api/v1/projects/{id}/facts/{factId}
GET    /api/v1/projects/{id}/skills
PUT    /api/v1/projects/{id}/skills/{name}
POST   /api/v1/projects/{id}/trust
GET    /api/v1/policy-profiles
PUT    /api/v1/policy-profiles/{id}
DELETE /api/v1/policy-profiles/{id}

GET    /api/v1/schedules
POST   /api/v1/schedules              {"chatId": "...", "prompt": "...", "dueAt": "ISO-8601"}
GET    /api/v1/schedules/{id}
DELETE /api/v1/schedules/{id}

GET    /api/v1/events?chatId=...      SSE по всем чатам или одному
```

`GET /settings` отдаёт снимок настроек агента и каталога моделей; язык и тема
интерфейса остаются настройками клиента и в API не входят. Ключ OpenRouter
принимается только тем же `SecretStore`, что использует демон, и никогда не
возвращается: клиент видит лишь последние три символа. Тело запросов ограничено
8 MiB, чтобы несколько вложений помещались в одно сообщение.

`GET /chats/{id}` отдаёт чат, сообщения, запуски инструментов и текущие
карточки (`approvals`, `questions`, `editFileChanges`). `PUT /chats/{id}/presence`
идемпотентно регистрирует карточки после перезапуска — как открытие чата в GUI.
`DELETE /chats/{id}/turn` останавливает текущий ход; повторный вызов безопасен.

SSE отдаёт `turnStarted`, `turnFinished`, `messageAdded`, `textDelta`,
`reasoningDelta`, `runChanged`, `queueChanged`, `failure`, `trustNeeded`,
`usage`, `stateChanged`, `stateAreaChanged`, `draftChanged`, `approval`,
`question`, `editFileChanges`. `stateAreaChanged` сообщает, что после
изменяющего запроса нужно перечитать список (`chats`, `projects` или
`hosts`); клиент обновляет watcher без периодического polling-а.
`draftChanged` сообщает, что черновик чата изменил другой клиент; поле ввода
обновляется по `draftRevision`.

## Push-уведомления

Push выключен по умолчанию. Демон не делает ни одного сетевого запроса,
пока в настройках профиля не сохранены одновременно:

- `enabled: true`;
- URL relay;
- токен relay в `SecretStore`.

`GET /push` возвращает `enabled`, `relayUrl` и `hasToken`; сам токен никогда
не возвращается. `PUT /push` сохраняет настройки, `POST /push/test` отправляет
тестовое событие. Если конфигурация неполная, тест завершается ошибкой
`push_not_configured`, а обычные уведомления молча пропускаются.

Relay получает JSON с типом события, заголовком чата, detail и временем.
Тело сообщений и вложения не передаются. Внешний relay сам доставляет событие
в FCM/APNs или другой транспорт.

## Журнал доступа к API

Демон пишет отдельный JSONL-журнал `logs/api-access.log` с правами `0600`.
Он не смешивается с `app.log` и ротируется по размеру.

Пишутся только метаданные:

- время в UTC, `requestId`, метод и путь без query;
- статус, длительность, адрес TCP-клиента;
- результат авторизации (`ok`, `missing`, `invalid`);
- короткий fingerprint токена, а не сам токен;
- код ошибки;
- для SSE — отдельные события `api.sse.open` и `api.sse.close`.

`requestId` создаёт HTTP-клиент и передаёт в заголовке `X-Request-Id`.
Сервер принимает только безопасный id (буквы, цифры, `.`, `_`, `:`, `-`,
до 64 символов), иначе генерирует свой. Итоговый id возвращается в
заголовке ответа и в поле `requestId` тела ошибки, поэтому запрос клиента
можно сопоставить с журналом сервера.

Клиент также передаёт `X-Client-App`, `X-Client-Package`, `X-Client-Version`,
`X-Client-Build` и `X-Client-Platform`. Эти поля попадают в журнал, чтобы
по инциденту было видно, какая версия приложения и на какой платформе
сделала запрос. Значения ограничены 120 символами.

Тела запросов, заголовки, query-параметры, сообщения и настройки в журнал
не попадают. Health-check не логируется. Ошибка записи журнала не меняет
ответ API.

Для разбора есть CLI:

```bash
# Сводка: события, статусы, авторизация, частые пути, медленные запросы
dart run packages/pw_server/bin/api_log.dart summary \
  --file=/path/to/logs/api-access.log

# Ошибки, 401 и запросы медленнее 1000 мс
dart run packages/pw_server/bin/api_log.dart problems \
  --file=/path/to/logs/api-access.log --slow-ms=1000

# Фильтрация: только 401, только SSE, конкретный путь
dart run packages/pw_server/bin/api_log.dart filter \
  --file=/path/to/logs/api-access.log --status=401
dart run packages/pw_server/bin/api_log.dart filter \
  --file=/path/to/logs/api-access.log --event=api.sse.close
dart run packages/pw_server/bin/api_log.dart filter \
  --file=/path/to/logs/api-access.log --path=/api/v1/chats --json
```

Путь по умолчанию — `logs/api-access.log` или значение
`PROBABLY_WORKS_API_LOG`.

## Локальный демон и GUI

После старта демон пишет `daemon.json` в каталог данных с правами `0600`:

```json
{
  "protocol": 1,
  "pid": 1234,
  "port": 7787,
  "startedAt": "2026-11-12T10:00:00.000Z"
}
```

Если OS-keyring доступен (Secret Service на Linux, Keychain на macOS), токен
хранится там и в файл не попадает. При headless-запуске без keyring или
`PROBABLY_WORKS_NO_KEYRING=1` в файле остаётся поле `token` как fallback.

GUI при старте:

1. читает файл;
2. проверяет protocol;
3. берёт токен из файла или OS-keyring;
4. проверяет `/health`;
5. проверяет токен через `/settings`;
6. при успехе собирает `LocalAgentApis` из `RemoteAgentApi` на
   `127.0.0.1` и **не открывает БД**;
7. при отсутствии демона запускает его и ждёт `daemon.json` до 15 секунд;
8. если запуск не удался, переходит в embedded-режим.

### Автозапуск

Способ запуска зависит от поставки:

- **development** (`flutter run`, отладка из IDE) — `dart run
  packages/pw_server/bin/pw_server.dart --data-dir <support> --port 0`;
  скрипт ищется вверх от текущей директории, поэтому запуск работает и из
  корня репозитория, и из подкаталога;
- **сборка** — готовый бинарник `daemon/bin/pw_server` внутри пакета GUI
  (`daemon/bin/pw_server.exe` на Windows, `Contents/MacOS/daemon` на macOS).
  Демон собирается как `dart build cli` и несёт рядом `daemon/lib` с
  нативными библиотеками; подробности — в [PACKAGING.md](PACKAGING.md).

Перед запуском GUI проверяет, свободна ли блокировка БД. Если её держит другой
процесс, новый демон не запускается: GUI ждёт готовый `daemon.json` и
подключается к нему либо сообщает, что экземпляр уже запущен. Это защищает от
двух демонов и embedded-GUI на одной базе.

Переменные окружения:

- `PROBABLY_WORKS_NO_DAEMON=1` — не искать и не запускать демон, всегда
  работать embedded (отладка и тесты);
- `PROBABLY_WORKS_SERVER` — путь к скрипту или готовому бинарнику демона;
- `PROBABLY_WORKS_DART` — интерпретатор для development-запуска;
  если не задан, берётся `dart` из `FLUTTER_ROOT` или из `PATH`.

Когда keyring недоступен, токен остаётся в `daemon.json` с правами `0600`.
При остановке демон удаляет `daemon.json`.

## Токен

Токен — 32 случайных байта в base64url. Он хранится в `SecretStore` демона и
не пишется в логи. `--print-token`/`--rotate-token` печатают его явно.

Headless `SecretStore` — MVP: JSON-файл `0600` в каталоге `0700`. Ключ
OpenRouter и токен API можно задать переменными окружения:

- `PROBABLY_WORKS_OPENROUTER_KEY` или `OPENROUTER_API_KEY`;
- `PROBABLY_WORKS_API_TOKEN`.

На Linux используется Secret Service через D-Bus, на macOS — Keychain через
`security`, на Windows — Credential Manager через FFI (`CredWriteW`/`CredReadW`).
Файловый fallback остаётся для headless-режима и при недоступном keyring.

## Планировщик

Отложенные задачи лежат в таблице `scheduled_tasks` и переживают перезапуск.
Демон раз в 15 секунд отправляет созревшие `pending`-задачи в их чаты и
переводит в `dispatched`. Результат хода остаётся в журнале чата. Задача с
`dispatched` после перезапуска повторно не отправляется.

## Удалённый доступ и TLS

Встроенного TLS нет. Демон по умолчанию слушает `127.0.0.1`, а наружу его
выставляет отдельный reverse proxy. Не публикуйте порт демона напрямую:
API даёт выполнение команд, поэтому HTTP без TLS и авторизации недопустим.

### SSH-туннель

Самый простой вариант — пробросить loopback-порт:

```bash
ssh -N -L 7787:127.0.0.1:7787 user@server
```

В GUI добавьте удалённый профиль `http://127.0.0.1:7787` и токен демона.
Токен можно получить на сервере через `--print-token` или
`PROBABLY_WORKS_API_TOKEN`.

### Caddy

Caddy сам получает и обновляет сертификат Let's Encrypt:

```caddyfile
agent.example.com {
    reverse_proxy 127.0.0.1:7787 {
        flush_interval -1
    }
}
```

`flush_interval -1` отключает буферизацию, иначе SSE-события приходят
пачками.

### nginx

```nginx
server {
    listen 443 ssl http2;
    server_name agent.example.com;

    ssl_certificate     /etc/letsencrypt/live/agent.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/agent.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:7787;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # SSE: без буферизации и с длинным таймаутом.
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }
}
```

Для SSE не включайте `gzip` и не ставьте короткий `proxy_read_timeout`:
поток событий может молчать между шагами.

После настройки добавьте в GUI профиль:

```text
https://agent.example.com
```

и токен демона. Проверка: `GET /api/v1/health` должен отвечать без токена,
а `/api/v1/settings` — только с `Authorization: Bearer <token>`.

Рекомендуется также ограничить доступ по IP/VPN, включить rate limit на
прокси и не открывать порт демона в интернет.

## Ограничения MVP

- только loopback по умолчанию; удалённый доступ — через SSH-туннель, VPN или
  TLS reverse proxy;
- нет TLS внутри демона;
- без доступного keyring секреты и токен лежат в файлах `0600`;
- плагины в демоне работают через общий `pw_agent`; управление — через
  `/plugins`, Flutter-представления остаются в клиенте;
- GUI подключается к удалённому демону как к обычному профилю, а к локальному —
  через `daemon.json`. Демон и embedded-GUI делят БД и single-instance lock,
  поэтому одновременно работать может только один из них.
