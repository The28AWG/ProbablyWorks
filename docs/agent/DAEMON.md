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

Демон и GUI не могут одновременно владеть одной базой: single-instance lock
остаётся общим. Для работы «при закрытом окне» запускается демон, а не GUI.

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
`usage`, `stateChanged`, `approval`, `question`, `editFileChanges`.

## Токен

Токен — 32 случайных байта в base64url. Он хранится в `SecretStore` демона и
не пишется в логи. `--print-token`/`--rotate-token` печатают его явно.

Headless `SecretStore` — MVP: JSON-файл `0600` в каталоге `0700`. Ключ
OpenRouter и токен API можно задать переменными окружения:

- `PROBABLY_WORKS_OPENROUTER_KEY` или `OPENROUTER_API_KEY`;
- `PROBABLY_WORKS_API_TOKEN`.

Полноценный OS-keyring для демона (libsecret, Keychain, DPAPI) — следующий шаг.

## Планировщик

Отложенные задачи лежат в таблице `scheduled_tasks` и переживают перезапуск.
Демон раз в 15 секунд отправляет созревшие `pending`-задачи в их чаты и
переводит в `dispatched`. Результат хода остаётся в журнале чата. Задача с
`dispatched` после перезапуска повторно не отправляется.

## Ограничения MVP

- только loopback по умолчанию; удалённый доступ — через SSH-туннель, VPN или
  TLS reverse proxy;
- нет TLS внутри демона;
- нет OS-keyring в headless-режиме;
- плагины в демоне работают через общий `pw_agent`; управление — через `/plugins`, Flutter-представления остаются в клиенте;
- GUI не подключается к демону как клиент, процессы взаимоисключающие;
- аудит API-запросов ограничен журналом приложения; отдельного файла доступа
  пока нет.
