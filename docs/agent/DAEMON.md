# Headless-демон и HTTP API

Демон запускает агент без Flutter-интерфейса, владеет базой и отдаёт локальный
HTTP API. Клиент по-прежнему работает с агентом напрямую и **не зависит** от
пакета API.

## Пакеты

```
packages/pw_agent   # агент, БД, Host, провайдеры; чистый Dart
packages/pw_api     # HTTP API поверх pw_agent; чистый Dart
packages/pw_daemon  # headless-процесс: pw_api + pw_agent; чистый Dart
```

Зависимости направлены только вниз:

```
Flutter-клиент ──► pw_agent
pw_daemon    ──► pw_api ──► pw_agent
```

Flutter-части (keyring, уведомления, тема, `path_provider`) остаются в клиенте.
Демон подставляет headless-реализации через `get_it` до
`configureAgentDependencies()`.

## Запуск

```bash
dart run packages/pw_daemon/bin/pw_daemon.dart --print-token
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

```
GET    /api/v1/health
GET    /api/v1/hosts
GET    /api/v1/chats
POST   /api/v1/chats                 {"hostId": "local"}
GET    /api/v1/chats/{id}
POST   /api/v1/chats/{id}/open
POST   /api/v1/chats/{id}/messages   {"text": "...", "sendNow": false}
POST   /api/v1/chats/{id}/stop

POST   /api/v1/approvals/{id}         {"action": "allowOnce|allowTurn|allowChat|deny"}
POST   /api/v1/questions/{id}         {"answer": "..."}
POST   /api/v1/edit-file-changes/{id} {"choice": "rollbackAndContinue|continueWithoutRollback|cancel"}

GET    /api/v1/schedules
POST   /api/v1/schedules              {"chatId": "...", "prompt": "...", "dueAt": "ISO-8601"}
DELETE /api/v1/schedules/{id}

GET    /api/v1/events?chatId=...      Server-Sent Events
```

`GET /chats/{id}` отдаёт чат, сообщения, запуски инструментов и текущие
карточки (`approvals`, `questions`, `editFileChanges`). `POST /open`
регистрирует карточки после перезапуска — как открытие чата в GUI.

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
- плагины в демоне не подключены: `PluginRegistry` пуст;
- GUI не подключается к демону как клиент, процессы взаимоисключающие;
- аудит API-запросов ограничен журналом приложения; отдельного файла доступа
  пока нет.
