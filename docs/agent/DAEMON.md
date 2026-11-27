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
- `--web-dir <path>` — отдавать статическую web-сборку из каталога;
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
GET    /api/v1/client/probe         проверка демона и токена без сессии
POST   /api/v1/client/handshake
PUT    /api/v1/client/session       heartbeat и присутствие
DELETE /api/v1/client/session
DELETE /api/v1/client/sessions/{id} убрать другое подключение по fingerprint
GET    /api/v1/client/sessions
GET    /api/v1/hosts
PUT    /api/v1/hosts/{id}
DELETE /api/v1/hosts/{id}
POST   /api/v1/hosts/{id}/test
PUT    /api/v1/hosts/{id}/trust
GET    /api/v1/chats
POST   /api/v1/chats                 {"hostId": "local"}
GET    /api/v1/chats/{id}
PUT    /api/v1/chats/{id}
PATCH  /api/v1/chats/{id}            точечные метаданные и expectedRevision

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
PUT    /api/v1/chats/{id}/read             {"seq": 42, "expectedRevision": 3}
GET    /api/v1/chats/{id}/session    очередь, ревизия и turnSnapshot
PATCH  /api/v1/chats/{id}/queue/{itemId}   {"expectedRevision": 3, "position": 0}
DELETE /api/v1/chats/{id}/queue/{itemId}?expectedRevision=3

GET    /api/v1/attention             входящие
GET    /api/v1/attention/digest      дайджест «пока вас не было»
DELETE /api/v1/attention/{chatId}    убрать проблемное завершение хода

GET    /api/v1/chats/{id}/messages
POST   /api/v1/chats/{id}/messages   {"text": "...", "sendNow": false, "clientMessageId": "..."}
GET    /api/v1/chats/{id}/runs
GET    /api/v1/chats/{id}/events     Server-Sent Events по чату

`clientMessageId` необязателен и уникален в пределах чата. Повтор запроса с
тем же значением после сетевого таймаута не создаёт второе сообщение и не
запускает второй ход: сервер проверяет уже записанный идентификатор. Один и
тот же идентификатор в разных чатах обозначает разные действия.

PUT    /api/v1/approvals/{id}/decision         {"action": "allowOnce|allowTurn|allowChat|deny"}
PUT    /api/v1/questions/{id}/answer           {"answer": "..."}
PUT    /api/v1/edit-file-changes/{id}/decision {"choice": "rollbackAndContinue|continueWithoutRollback|cancel"}

GET    /api/v1/push
PUT    /api/v1/push                           {"enabled": true, "relayUrl": "...", "token": "...", "expectedRevision": 1}
POST   /api/v1/push/test
GET    /api/v1/settings
PUT    /api/v1/settings/{key}                 {"value": "..." | null}
PUT    /api/v1/settings/pinned                {"pinnedModels": ["..."]}
PUT    /api/v1/settings/steps                 {"group": true, "expandWhileActive": true, "thoughts": "...", "tools": "..."}
PUT    /api/v1/settings/limits                {"limits": {...}}
PUT    /api/v1/settings/denylist              {"denylist": ["..."]}
PUT    /api/v1/settings/security-profile      {"profile": "{...}"}
POST   /api/v1/providers/{id}/key            {"key": "..."}
DELETE /api/v1/providers/{id}/key
GET    /api/v1/providers
GET    /api/v1/providers/{id}
PUT    /api/v1/providers/{id}                {"enabled": true, "baseUrl": "..."}
POST   /api/v1/providers/{id}/check
GET    /api/v1/models
POST   /api/v1/models/refresh
POST   /api/v1/models/remember                {"ids": ["..."]}
GET    /api/v1/models/runtime
POST   /api/v1/models/runtime/load            {"model": "llamacpp:..."}
POST   /api/v1/models/runtime/unload          {"model": "llamacpp:..."}

GET    /api/v1/security/audit
GET    /api/v1/plugins
PUT    /api/v1/plugins/enabled                {"ids": ["..."], "enabled": false, "expectedRevision": 3}
GET    /api/v1/plugins/{id}/missing-dependencies
GET    /api/v1/plugins/{id}/dependents
GET    /api/v1/plugins/{id}/settings
PUT    /api/v1/plugins/{id}/settings          {"value": {...}}
GET    /api/v1/plugins/{id}/secrets/{name}    -> {"exists": true}
PUT    /api/v1/plugins/{id}/secrets/{name}    {"value": "..." | null}
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

GET    /api/v1/events?chatId=...      SSE по всем чатам или одному
PUT    /api/v1/client/subscriptions   {"chatIds": ["..."]} — чаты с тяжёлыми событиями
```

`GET /api/v1/health` открыт и отдаёт `instanceId` текущего запуска. Это не
стабильный id сервера: после перезапуска он меняется.

### Клиентская сессия

Перед рукопожатием клиент может проверить живой демон и токен запросом
`GET /api/v1/client/probe`. Он требует Bearer, не требует `X-Client-Session`
и не создаёт сессию: локальный discovery не должен появляться в списке
клиентов и рассылать события присутствия. Ответ содержит `ok`, `protocol` и
`instanceId`.

После авторизации по Bearer-токену каждый клиент проходит рукопожатие и
получает временный `sessionId`:

```http
POST /api/v1/client/handshake
Authorization: Bearer <token>
Content-Type: application/json

{"protocol": 1, "previousSessionId": "...", "previousSessionSecret": "..."}
```

Ответ содержит `sessionId`, `resumeSecret`, `instanceId`, отпечаток
`deviceId`, стабильный `clientId`, срок `expiresAt`, интервал heartbeat и
текущую `presenceRevision`. Дальше клиент передаёт
`X-Client-Session: <sessionId>` на всех запросах, включая SSE.

- `sessionId` — идентификатор представления, а не авторизация. Bearer-токен
  остаётся обязательным.
- `resumeSecret` — секрет продолжения. Клиент хранит его рядом с `sessionId`
  и присылает только в следующем рукопожатии. Без него `previousSessionId`
  не переиспользуется: список сессий не должен позволять чужому окну
  «усыновить» представление. Дополнительно сервер требует совпадения
  `clientId`, если обе стороны его прислали.
- `instanceId` меняется при каждом запуске сервера. Это не стабильный id
  сервера, а признак «тот же экземпляр»; после перезапуска сессии исчезают и
  клиент проходит рукопожатие заново.
- `clientId` — стабильный id установки из `X-Client-Id`. Он переживает
  обновление приложения и различает машины с одинаковой версией. `deviceId` —
  короткий хеш заголовков `X-Client-*`: запасной ключ группировки для старых
  клиентов и поле журнала. Ни то, ни другое не является границей
  безопасности.
- TTL сессии по умолчанию 60 секунд, heartbeat — 20 секунд. Любой запрос и
  `PUT /client/session` продлевают сессию. Открытый SSE тоже продлевает её:
  сервер обновляет `lastSeenAt` на ping.
- Закрытие вкладки ускоряет `PUT /client/session` с `{"closing": true}` или
  обрыв последнего SSE. Сессия удаляется через `closeGrace` (5 секунд), если
  за это время не пришёл обычный запрос, heartbeat или новое SSE.
- `410 session_expired` означает, что запрос не выполнен и его можно
  безопасно повторить после нового рукопожатия.
- `400 session_required` — заголовка нет. Исключения: `/health`,
  `/client/probe` и `/client/handshake`.
- `PUT /client/session` принимает `{"focused": true, "activeChatId": "..."}`
  для присутствия, необязательную `presenceRevision` и `{"closing": true}`
  для отложенного закрытия вкладки. Сервер применяет присутствие, только если
  ревизия больше уже принятой, поэтому heartbeat, ушедший раньше свежего
  запроса, не откатывает фокус и открытый чат. Запрос с устаревшей ревизией
  всё равно продлевает сессию, а ответ возвращает принятую ревизию: клиент,
  чей номер отстал (например, две вкладки делят сессию), догоняет сервер
  следующим запросом. Рукопожатие возвращает текущую `presenceRevision`,
  чтобы reload продолжал нумерацию, а не начинал её заново.
- `GET /client/sessions` возвращает все клиентские сессии и помечает текущую;
  `id` и `currentSessionId` — короткие fingerprint, а `resumeSecret` в список
  не попадает. `DELETE /client/session` закрывает текущую; `DELETE
  /client/sessions/{id}` убирает другое подключение по тому же fingerprint.
  Второй маршрут идемпотентен и нужен для зависших экранов, а не для отзыва
  доступа: открытый экран сможет пройти рукопожатие заново. Изменения состава
  сессий и присутствия приходят событием `clientSessionsChanged` со снимком и
  `presenceRevision`; неизменённый heartbeat его не порождает. Снимок избавляет
  каждое окно от отдельного `GET /client/sessions` на каждое изменение.
- `PUT /client/subscriptions` принимает `{"chatIds": [...]}` — чаты, тяжёлые
  события которых нужны этому экрану. Пока клиент не прислал список, он
  получает всё как старый клиент. После первого запроса дельты ответа, полная
  очередь, сообщения и снимок хода приходят только для указанных чатов.
  Карточки, закрытие хода, удаление чата и присутствие остаются глобальными:
  они нужны уведомлениям и бейджам даже там, где чат не открыт. Пустой список
  допустим: окно не держит ни одного чата.
- Один экземпляр сервера использует один API-токен. Токен — не пользователь и
  не делит сессии; несколько сессий — это окна/устройства, а не несколько
  пользователей.

Устройство и ограничения описаны в [MULTI_VIEW.md](MULTI_VIEW.md).

`GET /settings` отдаёт снимок настроек агента и каталога моделей; язык и тема
интерфейса остаются настройками клиента и в API не входят. Ключи OpenRouter и
llama.cpp принимаются только тем же `SecretStore`, что использует демон, и никогда не
возвращаются: клиент видит лишь последние три символа. Тело запросов ограничено
8 MiB, чтобы несколько вложений помещались в одно сообщение. Кроме размера
тела, API ограничивает частоту запросов по IP (`429` с `Retry-After`), число
одновременных запросов (`503 server_busy`) и время обработки маршрута
(`504 request_timeout`). SSE не попадает под общий таймаут: поток живёт до
отключения клиента. Внутренняя ошибка возвращается как нейтральный
`internal_error`, детали остаются в журнале приложения.

`GET /chats/{id}` отдаёт чат, сообщения, запуски инструментов и текущие
карточки (`approvals`, `questions`, `editFileChanges`). `PUT /chats/{id}/presence`
идемпотентно регистрирует карточки после перезапуска — как открытие чата в GUI.
`DELETE /chats/{id}/turn` останавливает текущий ход; повторный вызов безопасен.

Снимок чата (`GET /chats`, `GET /chats/{id}` и ответ `PUT /chats/{id}/read`)
несёт `lastReadSeq`, `lastMessageSeq`, `unreadCount` и `readRevision`.
`lastReadSeq` — общий для всех устройств read-horizon: максимум `seq`, который
пользователь прочитал до конца. `unreadCount` считает сообщения агента и
служебные строки после курсора; собственные сообщения пользователя и `tool`
счётчик не поднимают. `PUT /chats/{id}/read` принимает `seq`, двигает курсор
только вперёд и ограничивает его последним записанным сообщением: устаревший
снимок не может «прочитать» то, чего клиент не видел. Позиция прокрутки
остаётся локальной у устройства и в курсор не входит. Курсор никогда не бывает
выше последнего сообщения: перезапись истории (правка или перегенерация) и
удаление последнего сообщения откатывают его к последнему уцелевшему, иначе
новые сообщения на освободившихся `seq` выглядели бы прочитанными.

`GET /attention` возвращает снимок входящих: `revision` и
`items`, где у каждого чата есть `chatId`, `hostId`, `projectId`, `title`,
`reasons`, готовые карточки `approvals`/`questions`/`editFileChanges`,
`unreadCount`, `lastReadSeq`, `lastMessageSeq`, `running`, `turnAt` и
`updatedAt`. `reasons` — `approval`, `question`, `editFiles`, `failed`,
`stepLimit`, `budget`, `stalled` или `unread`. Снимок собирается из списка
чатов, курсора прочтения, карточек брокера и сохранённого проблемного
завершения хода; отдельной таблицы входящих нет. Проблемное завершение
(`failed`, `stepLimit`, `budget`, `stalled`) хранится в `chat_attention_states`
и переживает перезапуск: его снимает новый ход или
`DELETE /attention/{chatId}`, а чтение чата не снимает. Непрочитанное
снимается обычным `PUT /chats/{id}/read`. Карточки в снимке можно закрыть
существующими `PUT /approvals/...`, `PUT /questions/...` и
`PUT /edit-file-changes/...`; продолжение хода после лимита — `PUT
/chats/{id}/turn`. `revision` монотонна: запоздавший ответ `GET /attention`
не должен вернуть уже закрытую карточку.

`GET /attention/digest` возвращает сводку «пока вас не было»:
`newMessages`, `finishedTurns`, `approvals`, `questions`, `editFileChanges`,
`problems` и `items` с теми же счётчиками по чатам. Сводка строится по общему
курсору прочтения, поэтому прочитанное на одном устройстве не появляется на
другом. `finishedTurns` считает видимые ответы агента после курсора без вызовов
инструментов: промежуточные шаги хода и пустые шаги без текста и вложений
готовым ответом не считаются.
Субагенты и отдельная таблица событий в дайджест не входят — он всегда
отражает текущее неразобранное состояние. Маршрут необязателен для старых
демонов: клиент просто не показывает карточку, если получил `501
not_supported`.

SSE отдаёт `turnStarted`, `turnFinished`, `messageAdded`, `textDelta`,
`reasoningDelta`, `turnSnapshot`, `runChanged`, `queueChanged`, `failure`,
`trustNeeded`, `usage`, `stateChanged`, `chatChanged`, `chatDeleted`,
`chatReadChanged`, `stateAreaChanged`, `draftChanged`, `approval`,
`approvalResolved`, `question`,
`questionResolved`, `editFileChanges`, `editFileChangesResolved`,
`chatStatusChanged`, `clientSessionsChanged`, `modelRuntime`. `modelRuntime` —
глобальное состояние загрузки моделей, не привязанное к чату; оно приходит и в
чат-фильтрованный SSE. `chatStatusChanged` несёт тот же снимок, что и
`GET /attention`, с новой ревизией: окно обновляет бейдж и список решений без
отдельного запроса.

Без `?chatId=` поток остаётся глобальным, но тяжёлые события открытых чатов
(`textDelta`, `reasoningDelta`, `messageAdded`, `turnSnapshot`, `runChanged`,
`usage`, `queueChanged`) приходят только для чатов из
`PUT /client/subscriptions`. Это не даёт каждому окну получать поток токенов
всех чатов. Дельты одного вида и чата склеиваются на коротком окне: один
токен не превращается в отдельное SSE-сообщение. `stateAreaChanged` тоже
склеивается, поэтому всплеск сообщений не заставляет список чатов
перечитываться на каждое из них.

`stateAreaChanged` сообщает, что общий ресурс изменился и его снимок нужно
перечитать. Области: `chats`, `projects`, `hosts`, `settings`, `models`,
`mcp`, `plugins`, `push` и `data`. Событие публикует доменный сервис через
`DomainChangeBus`, а не конкретный HTTP-маршрут: правка `mcp.json` снаружи и
фоновое изменение каталога моделей тоже доходят до окон. `chatChanged`
обновляет открытый чат; `chatDeleted` с `chatId` сообщает, что чат удалён, и
открытый экран закрывает маршрут, а не перечитывает пустую запись.
`chatReadChanged` несёт `lastReadSeq`, `lastMessageSeq`, `unreadCount` и
`readRevision`: соседнее окно уменьшает бейдж, но не двигает свою прокрутку. Удаление
чата и каскадная очистка истории публикуют событие по одному на каждый
удалённый чат, включая скрытых субагентов.
`queueChanged` несёт полную очередь и
`queueRevision` только подписчикам этого чата; `turnSnapshot` позволяет догнать
уже начатый ответ.
У каждого элемента очереди есть устойчивый `id`. Изменение принимает этот
`id` и `expectedRevision`; если снимок уже устарел или элемент исчез, сервер
возвращает `409 queue_conflict` и ничего не меняет. Клиент перечитывает
`GET /chats/{id}/session`; если элемент ещё в очереди, повторяет действие по
тому же `id`, иначе показывает свежую очередь.
`approvalResolved`, `questionResolved` и `editFileChangesResolved` убирают
закрытые карточки у остальных клиентов. `draftChanged` сообщает, что черновик
чата изменил другой клиент; поле ввода обновляется по `draftRevision`, а
правки сообщений — по `messageEditsRevision`.

`PATCH /chats/{id}` принимает `expectedRevision`. При несовпадении сервер
возвращает `409 chat_conflict`; клиент перечитывает чат и повторяет только
свои поля.

Редактируемые общие сущности тоже версионируются. `PUT /hosts/{id}`,
`PUT|PATCH /projects/{id}`, `PUT /mcp/servers/{id}`, `PUT /plugins/enabled` и
`PUT /push` принимают `expectedRevision` — `revision` снимка, на котором
основана форма. Устаревшая форма получает `409` с кодом `host_conflict`,
`project_conflict`, `mcp_conflict`, `plugin_conflict` или `push_conflict`;
сервер ничего не меняет. Без `expectedRevision` проверка не выполняется:
служебная запись и клиент без ревизии сохраняют объект, просто увеличивая
`revision`. Успешное сохранение попадает в снимок и событие
`stateAreaChanged`.

## Статическая web-сборка

`--web-dir` включает раздачу готового web-клиента тем же процессом. Файлы не
встраиваются в бинарник: сервер читает их из указанного каталога.

```bash
pw_server --web-dir web --print-token
```

Правила:

- `/api/**` всегда обслуживает API; статика не может перекрыть эти пути;
- `/api/v1/health` открыт, остальной API требует Bearer-токен;
- статика публичная и не расходует лимит API;
- неизвестный не-API путь без расширения получает `index.html` — это нужно
  для path-URL вида `/a/<profileId>/chats`;
- отсутствующий файл с расширением и отсутствующий ассет дают `404`, а не
  HTML;
- path traversal, скрытые файлы и symlink за пределы `--web-dir` отклоняются;
- `index.html` и точка входа Flutter отдаются с `no-cache`, ассеты — с
  коротким `max-age` и `ETag`.

Для bundled-варианта web собирается с `lib/main_web_hosted.dart` и
path-стратегией. Статический web-релиз использует `lib/main_web.dart` с
hash-навигацией и не требует rewrite. Подробности — в
[docs/web/SERVER_WEB.md](../web/SERVER_WEB.md).

При размещении web отдельно от сервера API остаётся на своём origin, а
`--allow-origin` разрешает запросы браузера. В bundled-варианте web и API
находятся на одном origin, поэтому CORS не нужен. Web должен находиться в
корне origin: клиент обращается к `/api/v1` от корня.

## Push-уведомления

Push выключен по умолчанию. Демон не делает ни одного сетевого запроса,
пока в настройках профиля не сохранены одновременно:

- `enabled: true`;
- URL relay;
- токен relay в `SecretStore`.

`GET /push` возвращает `enabled`, `relayUrl`, `hasToken` и `revision`; сам
токен никогда не возвращается. `PUT /push` сохраняет настройки и принимает
`expectedRevision`, `POST /push/test` отправляет
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
- `instanceId` запуска, короткий fingerprint клиентской сессии и `deviceId`;
- код ошибки;
- для SSE — отдельные события `api.sse.open` и `api.sse.close`.

`requestId` создаёт HTTP-клиент и передаёт в заголовке `X-Request-Id`.
Сервер принимает только безопасный id (буквы, цифры, `.`, `_`, `:`, `-`,
до 64 символов), иначе генерирует свой. Итоговый id возвращается в
заголовке ответа и в поле `requestId` тела ошибки, поэтому запрос клиента
можно сопоставить с журналом сервера.

Клиент также передаёт `X-Client-Id`, `X-Client-App`, `X-Client-Package`,
`X-Client-Version`, `X-Client-Build`, `X-Client-Platform` и
`X-Client-Session`. Поля приложения и платформы попадают в журнал, чтобы по
инциденту было видно, какая версия приложения и на какой платформе сделала
запрос; из них же считается `deviceId`. `clientId` пишется коротким
fingerprint, сессия — тоже только fingerprint. Значения ограничены
120 символами, а `clientId` — 64.

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

### Потеря демона

GUI слушает `AgentApi.statusChanges`. Если демон пропал:

- список чатов очищается, чтобы старые данные не выглядели живыми;
- открытый чат на вкладке чатов заменяется экраном нового чата;
- композер и чаты показывают «Сервер недоступен»;
- настройки остаются доступны: можно добавить новый профиль и переключиться;
  группы, которым нужен сервер, скрываются, а язык, тема и клавиши работают;
- проекты и хосты остаются доступны как разделы, но удалённые действия в них
  не выполняются до восстановления связи;
- удалённый профиль не удаляется, его токен сохраняется;
- кнопка «Повторить» делает `/health`, а после успеха списки перечитываются
  по `reconnect`-событию.

То же поведение использует web-клиент: он не поднимает локальный агент и
работает только с удалённым профилем.

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
- `PROBABLY_WORKS_HUGGINGFACE_TOKEN` или `HF_TOKEN` для закрытых репозиториев
  локальных моделей;
- `PROBABLY_WORKS_API_TOKEN`.

Ключ llama.cpp задаётся в настройках агента и хранится в том же `SecretStore`.

На Linux используется Secret Service через D-Bus, на macOS — Keychain через
`security`, на Windows — Credential Manager через FFI (`CredWriteW`/`CredReadW`).
Файловый fallback остаётся для headless-режима и при недоступном keyring.

## Планировщик

Отложенные задачи создаёт сам агент из чата инструментами `schedule_task`,
`list_scheduled_tasks` и `cancel_scheduled_task`: клиентского API у них нет,
поэтому и «напомни через десять минут», и разовые задачи ставятся одним
способом — сообщением в чат. Время отправки каждой реплики модель видит в самом
сообщении (`[sent at: ...]`), относительное время задаётся через `delay_seconds`.
Постановка и отмена оставляют запись запуска, поэтому видны в журнале шагов
чата (`schedule in 10m · <текст задачи>`, `cancel task <id>`); чтение списка
шага не создаёт.

Задача принадлежит своему шагу: id читается из его вывода (`scheduled task …`).
Поэтому удаление сообщения с шагом удаляет задачу, а форк переносит их вместе
под новыми id. Задачи ниже линии форка не переносятся сознательно.

Задачи лежат в таблице `scheduled_tasks` и переживают перезапуск. Демон раз в
15 секунд отправляет созревшие `pending`-задачи в их чаты и переводит в
`dispatched`. Результат хода остаётся в журнале чата. Задача с `dispatched`
после перезапуска повторно не отправляется.

Срока давности нет: всё, что созрело, пока приложение было закрыто, уходит
следующим проходом. Если опоздание больше часа, перед промптом добавляется
отдельное событие `scheduled task was due …, started … late`, чтобы модель не
приняла старое напоминание за свежее. Создавать задачи может только
пользовательский чат: субагент работает в скрытом чате и сообщает о
напоминании родителю в отчёте, а инструменты расписания ему не показываются.

Задачи без шага `schedule_task` (их создавал прежний HTTP API) относятся к
чату по времени создания: при правке истории удаляются те, что появились
позже переписываемого сообщения (граница строгая — при точности в секунду
одинаковое время считается предыдущим ходом), а форк переносит только задачи
выше линии.

На desktop встроенный в приложение агент запускает тот же таймер. На Android и
iOS дополнительно регистрируется периодическая фоновая задача WorkManager: она
поднимает приложение, когда оно закрыто, и прогоняет очередь. Проходы в фоне и
в приложении разделяет блокировка базы: пока приложение держит данные, фоновый
изолят очередь пропускает.

На iOS фоновая задача — `BGAppRefreshTask`. Ей нужны режим `fetch` в
`UIBackgroundModes`, идентификатор в `BGTaskSchedulerPermittedIdentifiers`
(`ios/Runner/Info.plist`) и перерегистрация обработчиков в `AppDelegate`.
Фоновый изолят — отдельный движок Flutter, поэтому `AppDelegate` регистрирует в
нём плагины через `WorkmanagerPlugin.setPluginRegistrantCallback`: без этого
`path_provider` и `shared_preferences` в нём недоступны и запуск падает.

Бюджет `BGAppRefreshTask` — десятки секунд, а ход агента может быть длиннее.
Задача считается отправленной до начала хода, поэтому оборванный системой ход
не повторяется: напоминание не задвоится, но и не доиграет. После фонового
хода обновление памяти проекта не выполняется — база закрывается сразу после
хода, а память обновится в следующем обычном ходе.

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
