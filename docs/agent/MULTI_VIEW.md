# Несколько клиентов и точек отображения

Документ описывает модель «один агент — много окон и устройств»: рукопожатие
клиента, временные сессии, присутствие и правила синхронизации состояния.
Это не многопользовательский режим: пользователь один, а клиентов может быть
несколько.

## Термины

| Термин | Что означает |
|---|---|
| **AgentProfile** | Клиентская запись «куда звонить»: URL демона и токен. На сервере такой сущности нет. |
| **instanceId** | Идентификатор запущенного экземпляра сервера. Новый процесс — новый `instanceId`. Не переживает перезапуск и нужен, чтобы отличить «тот же самый экземпляр» от «сервер перезапустился». |
| **sessionId** | Временный идентификатор клиента, который выдаёт сервер при рукопожатии. Живёт до TTL или явного закрытия. Не является токеном авторизации. |
| **deviceId** | Устройство в модели: короткий SHA-256 от `X-Client-*` (приложение, пакет, версия, сборка, платформа). Одинаковый `deviceId` и разные `sessionId` означают одно устройство с несколькими подключениями. Это не глобальный идентификатор и не граница безопасности, но для группировки внутри одного экземпляра агента его достаточно. |
| **Bearer-токен** | Секрет API, один на экземпляр сервера. Он не является пользователем, не создаёт учётные записи и не привязывает сессии к пользователям. Сессия не заменяет и не ослабляет его. |

Смысл разделения:

- `AgentProfile` отвечает на вопрос **куда** подключаться;
- `instanceId` — **какой запуск** сервера отвечает;
- `sessionId` — **какой клиент** сейчас работает;
- `deviceId` — **устройство в модели**, сгруппированное по описанию клиента.

## Что реализовано

- Сервер выдаёт `sessionId` при рукопожатии, хранит сессии в памяти и
  проверяет `X-Client-Session` на всех запросах, кроме `/health` и
  `/client/handshake`.
- `instanceId` создаётся при старте `ApiServer` и отдаётся в `/health` и в
  ответе рукопожатия. Перезапуск сервера меняет `instanceId`; старые сессии
  после него недействительны.
- `deviceId` вычисляется сервером из заголовков `X-Client-*` как короткий
  SHA-256. Он попадает в список сессий и в журнал доступа.
- У клиента есть `ClientSessionStore` и `ClientSessionChannel`: память для
  desktop/mobile, `sessionStorage` и `BroadcastChannel` для web.
- `RemoteAgentApi` делает рукопожатие один раз на профиль, повторяет запрос
  после `410 session_expired`/`400 session_required`, шлёт heartbeat и
  заголовок сессии в SSE.
- Состояние между клиентами синхронизируется событиями и ревизиями:
  - закрытие подтверждений, вопросов и выбора откатов файлов;
  - полная очередь с `queueRevision`;
  - настройки и каталог моделей;
  - метаданные открытого чата;
  - снимок живого хода `turnSnapshot`;
  - независимые ревизии черновика и правок сообщений;
  - точечный `PATCH` метаданных чата с `expectedRevision`;
  - присутствие и список клиентских сессий.
- В `docs/agent/DAEMON.md` обновлён контракт API и список SSE-событий.

Синхронизация не делает из одного агента многопользовательский сервер:
пользователь один, а клиентов/окон может быть несколько.

## Рукопожатие

Запрос:

```http
POST /api/v1/client/handshake
Authorization: Bearer <token>
Content-Type: application/json
X-Client-App: ProbablyWorks
X-Client-Version: 1.2.3
X-Client-Build: 42
X-Client-Platform: linux

{"protocol": 1, "previousSessionId": "..."}
```

`previousSessionId` необязателен. Это подсказка для непрерывности после
перезагрузки вкладки или повторного подключения, а не доказательство. Запрос
уже авторизован Bearer-токеном сервера; если сервер не знает старый id
(истёк TTL, перезапуск, другой экземпляр), он создаёт новую сессию.

Ответ:

```json
{
  "sessionId": "…",
  "instanceId": "…",
  "deviceId": "9f1c2d3e4a5b6c7d",
  "protocol": 1,
  "expiresAt": "2026-11-24T12:00:00.000Z",
  "heartbeatIntervalMs": 20000
}
```

Дальше клиент обязан передавать сессию:

```http
X-Client-Session: <sessionId>
```

на всех запросах, включая `GET /api/v1/events` и обычные REST-вызовы.

Исключения:

- `GET /api/v1/health` — открыт и не требует сессии;
- `POST /api/v1/client/handshake` — единственный маршрут, который сессию
  создаёт;
- статические файлы web-сборки — не API.

Ошибки:

- `400 session_required` — заголовка нет, а сервер требует сессию;
- `410 session_expired` — сессия неизвестна или истекла; клиент делает новое
  рукопожатие и один раз повторяет запрос.

Проверка сессии выполняется до маршрута. Поэтому `410` гарантирует, что
изменяющий запрос не был выполнен, и повтор безопасен. Для сетевых таймаутов
это не так: там нужна отдельная идемпотентность, например `clientMessageId`
у сообщения.

## Жизненный цикл сессии

- TTL по умолчанию — 60 секунд, heartbeat — каждые 20 секунд. Значения
  приходят в ответе рукопожатия, чтобы клиент не зашивал их в код.
- Любой запрос с валидной сессией продлевает `lastSeenAt`.
- Сервер раз в 10 секунд удаляет истёкшие сессии.
- `instanceId` меняется при каждом запуске `ApiServer`, поэтому сессии
  автоматически становятся недействительными после падения или остановки.
- Сессии живут только в памяти. В SQLite они не пишутся: это runtime-состояние,
  а не данные пользователя.
- Явное закрытие — `DELETE /api/v1/client/session`; если клиент не успел, TTL
  всё равно уберёт сессию.

### Web: вкладка, reload и дубликат

Правила:

- `sessionStorage` — per-tab хранилище. Reload вкладки сохраняет `sessionId`,
  закрытие вкладки — нет.
- `localStorage` не подходит: он общий для вкладок и переживает закрытие
  браузера, а нам нужны разные сессии у разных вкладок.
- Новая вкладка не имеет `sessionId` и делает новое рукопожатие.
- Дублирование вкладки может скопировать `sessionStorage`. Поэтому перед
  рукопожатием клиент спрашивает через `BroadcastChannel`, не занят ли этот id
  другой живой вкладкой. Если занят — id стирается и выдаётся новый.
- `BroadcastChannel` не синхронизирует id между вкладками, а наоборот
  защищает от того, чтобы две вкладки стали одной сессией.

Алгоритм на старте вкладки:

1. Прочитать `sessionId` из `sessionStorage`.
2. Если он есть — отправить в `BroadcastChannel` сообщение `claim`.
3. Если другая вкладка ответила `taken` (ожидание — до 1 секунды) — это
   дубликат: удалить id и делать рукопожатие без `previousSessionId`.
4. Если ответа нет — это reload: отправить `previousSessionId`.
5. Записать выданный сервером id обратно в `sessionStorage`.

Обнаружение дубликата через `BroadcastChannel` — best-effort: вкладка в фоне
может не успеть ответить, и тогда сервер увидит одну сессию. Это ограничение
принято, чтобы не усложнять протокол; обычные новые вкладки и reload работают
как описано.

`sessionStorage` и `BroadcastChannel` могут быть недоступны (приватный режим,
sandbox iframe, отключённое хранилище). В этом случае клиент работает без
сохранения между reload: новый id после перезагрузки. Ошибки хранилища не
должны ломать приложение.

## Сервер

Новые маршруты:

```text
POST   /api/v1/client/handshake
PUT    /api/v1/client/session          heartbeat и presence
DELETE /api/v1/client/session          закрыть текущую сессию
GET    /api/v1/client/sessions         список клиентских сессий
```

`PUT /api/v1/client/session` принимает:

```json
{"focused": true, "activeChatId": "…"}
```

`focused` и `activeChatId` необязательны. Они нужны для будущего presence:
«кто открыл чат», «на каком устройстве приложение в фокусе», «откуда запущен
ход».

`GET /api/v1/client/sessions` возвращает все живые сессии экземпляра и
помечает текущую. Токен здесь не делит пользователей: он один на сервер:

```json
{
  "currentSessionId": "…",
  "sessions": [
    {
      "id": "…",
      "deviceId": "9f1c2d3e4a5b6c7d",
      "clientApp": "ProbablyWorks",
      "clientVersion": "1.2.3",
      "clientBuild": "42",
      "clientPlatform": "linux",
      "createdAt": "…",
      "lastSeenAt": "…",
      "expiresAt": "…",
      "focused": true,
      "activeChatId": "…",
      "online": true,
      "current": true
    }
  ]
}
```

`ClientSessionRegistry`:

- `handshake(...)` создаёт сессию или переиспользует `previousSessionId`,
  если он ещё жив;
- `touch(...)` продлевает сессию и различает `missing` и `expired`;
- `updatePresence(...)` обновляет `focused` и `activeChatId`;
- `attach`/`detach` связывают SSE-соединение с сессией, чтобы `DELETE` мог
  закрыть поток;
- `list()` отдаёт снимок для `GET /client/sessions`;
- `sweep()` удаляет истёкшие записи.

`instanceId` — поле `ApiServer`, а не настройка. Оно создаётся через
`Random.secure` при конструировании и отдаётся в `/health` и рукопожатии.
Ни в SQLite, ни в `daemon.json` его хранить не нужно: после перезапуска это
уже другой экземпляр.

Важно не путать уровни: у экземпляра один API-токен, а сессий много. Токен —
ключ к серверу, а не пользователь. Сессии не делят данные по пользователям и
не привязаны к токену. Если когда-нибудь появится многопользовательский агент,
это будет отдельная модель прав, а не следствие текущей схемы.

### Журнал доступа

В JSONL-журнал добавляются:

- `instanceId` запуска;
- `clientSession` — короткий fingerprint сессии, не сырой id;
- `deviceId` — отпечаток `X-Client-*`.

Тела, query и сам Bearer-токен по-прежнему не пишутся. Сессия не является
секретом, но и хранить её в журнале в открытом виде незачем.

### CORS

`X-Client-Session` добавлен в `Access-Control-Allow-Headers`. Web-клиент
отправляет его на всех API-запросах, включая SSE; поэтому `EventSource` не
используется — он не умеет задавать заголовки.

## Клиент

В `pw_client`:

```dart
abstract interface class ClientSessionStore {
  String? read(String key);
  void write(String key, String value);
  void delete(String key);
}

abstract interface class ClientSessionChannel {
  Future<bool> isActive(String id);
  void close();
}
```

Реализации по умолчанию:

- `MemoryClientSessionStore` — desktop, mobile, тесты;
- `NoopClientSessionChannel` — там, где нет вкладок.

`RemoteAgentApi`:

- делает рукопожатие один раз (single-flight) на профиль;
- хранит id в `ClientSessionStore` по ключу профиля;
- добавляет `X-Client-Session` в REST и SSE;
- при `410 session_expired` очищает id, делает рукопожатие и один раз
  повторяет запрос;
- при `401` не повторяет бесконечно, а переводит профиль в offline;
- шлёт heartbeat и останавливает таймер в `dispose`;
- отдаёт `sessionId` и `instanceId` для диагностики и UI.

`sessionKey` — id профиля: у каждого профиля своя сессия. Для локального
демона используется отдельный ключ, потому что локальный профиль создаёт
`RemoteAgentApi` напрямую, до полной загрузки `ProfileService`.

## Web: платформенный код

Используется conditional import по `dart.library.js_interop`: он работает и
для JavaScript, и для WebAssembly. `dart:html` не используется.

```dart
// lib/core/session/client_session_store.dart
export 'client_session_store_stub.dart'
    if (dart.library.js_interop) 'client_session_store_web.dart';
```

Web-хранилище:

```dart
import 'package:pw_client/pw_client.dart';
import 'package:web/web.dart' as web;

final class PlatformClientSessionStore implements ClientSessionStore {
  static const _prefix = 'pworks.session.';

  @override
  String? read(String key) {
    try {
      return web.window.sessionStorage.getItem('$_prefix$key');
    } on Object {
      return null;
    }
  }

  @override
  void write(String key, String value) {
    try {
      web.window.sessionStorage.setItem('$_prefix$key', value);
    } on Object {
      // Приватный режим или отключённое хранилище: работаем без сохранения.
    }
  }

  @override
  void delete(String key) {
    try {
      web.window.sessionStorage.removeItem('$_prefix$key');
    } on Object {
      // Нечего чистить.
    }
  }
}
```

Канал использует `BroadcastChannel` и `dart:js_interop`:

```dart
import 'dart:async';
import 'dart:js_interop';
import 'package:pw_client/pw_client.dart';
import 'package:web/web.dart' as web;

final class PlatformClientSessionChannel implements ClientSessionChannel {
  PlatformClientSessionChannel() {
    _channel = web.BroadcastChannel('pworks.client-session');
    _channel.onmessage = ((web.Event event) {
      final data = (event as web.MessageEvent).data?.dartify();
      if (data is Map) _handle(data);
    }).toJS;
  }

  late final web.BroadcastChannel _channel;
  final _messages = StreamController<Map<Object?, Object?>>.broadcast();

  @override
  Future<bool> isActive(String id) async {
    final answer = Completer<bool>();
    final sub = _messages.stream.listen((message) {
      if (message['type'] == 'taken' && message['id'] == id) {
        if (!answer.isCompleted) answer.complete(true);
      }
    });
    _channel.postMessage({'type': 'claim', 'id': id}.jsify());
    try {
      return await answer.future.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      return false;
    } finally {
      await sub.cancel();
    }
  }

  void _handle(Map<Object?, Object?> message) {
    final id = message['id'];
    if (message['type'] == 'claim' && id is String) {
      _channel.postMessage({'type': 'taken', 'id': id}.jsify());
    }
    if (!_messages.isClosed) _messages.add(message);
  }

  @override
  void close() {
    _channel.close();
    unawaited(_messages.close());
  }
}
```

Stub-версии для VM повторяют интерфейс: store хранит значения в памяти,
channel всегда отвечает `false`.

`web` добавлен в `pubspec.yaml` прямой зависимостью. После изменения
зависимостей нужен `flutter pub get`.

## Синхронизация состояния

Сессия — фундамент, но расхождения между клиентами закрывают события и
ревизии. Ниже — текущее поведение.

### 1. Карточки

`InteractionBroker` публикует `ApprovalResolved`, `QuestionResolved` и
`EditFileChangesResolved` при фактическом закрытии карточки. События уходят
по SSE как `approvalResolved`, `questionResolved`, `editFileChangesResolved`.
Второй клиент убирает карточку и пересчитывает бейдж `waiting`. `cancelChat`
(Stop) закрывает все карточки чата и порождает те же события.

Повторное закрытие уже закрытой карточки события не даёт.

### 2. Очередь

`AgentQueueChanged` передаёт полную очередь, а не только `size`. В
`GET /chats/{id}/session` и в событии есть `queueRevision`; клиент игнорирует
снимок с меньшей ревизией. Поэтому поздний HTTP-ответ не перетирает более
новое SSE-событие. Элементы очереди передаются с текстом, признаком события,
заметкой, упоминаниями и метаданными вложений без байтов.

### 3. Настройки и каталог

Изменяющие запросы к `/settings/*` публикуют `stateAreaChanged` с областью
`settings`, к `/models/*` и `/providers/*` — с областью `models`.
`RemoteAgentApi` сбрасывает кеш `GET /settings`, перечитывает его и только
после успешного ответа уведомляет подписчиков. Каталог и runtime
перечитываются по событию `models`.

Это покрывает модель по умолчанию, лимиты, закрепления, журнал шагов,
политику и другие настройки.

### 4. Метаданные открытого чата

После `PUT /chats/{id}` и `PATCH /chats/{id}` сервер публикует `chatChanged`
с `chatId`. `RemoteAgentApi` превращает его в `AgentStateChanged`, и
`ChatBloc` перечитывает открытый чат, не трогая локальный черновик и
несохранённые правки.

### 5. Живой ход

`ChatSession` хранит текст и рассуждения текущего шага. `GET
/chats/{id}/session` отдаёт `turnSnapshot`, а при открытии/reconnect SSE
сервер сразу отправляет `turnSnapshot` для запущенных чатов. Клиент
применяет его при открытии и переподключении, поэтому догоняет уже
накопленный ответ. Снимок очищается при завершении шага и Stop.

### 6. Черновик и правки сообщений

У чата две независимые ревизии:

- `draftRevision` — черновик композера;
- `messageEditsRevision` — неотправленные правки сообщений.

Поэтому набор в поле ввода и правка пузыря больше не конфликтуют без
причины. При реальном `409 draft_conflict` клиент сохраняет оба варианта и
показывает баннер: «оставить моё» или «взять серверное». Локальный вариант не
затирается серверным молча.

### 7. Метаданные чата

`Chat.revision` растёт при изменении метаданных. `PATCH /chats/{id}`
принимает `expectedRevision`; при несовпадении возвращается `409
chat_conflict`. Клиент сохраняет только изменившиеся поля, перечитывает
ревизию при конфликте и повторяет точечный PATCH. Заголовок, workspace и
другие поля, изменённые другим клиентом, не затираются.

### 8. Присутствие и уведомления

`focused` и `activeChatId` уходят с heartbeat. Сервер публикует
`clientSessionsChanged`, а `GET /client/sessions` остаётся снимком. Клиент
показывает в шапке чата, что он открыт на другом устройстве, и список
клиентов. Если чат открыт в активной сессии, `PushAppNotifier` не отправляет
дублирующий push.

## Безопасность

- `sessionId` — идентификатор представления, а не авторизация. Bearer-токен
  остаётся обязательным на каждом запросе.
- Один экземпляр сервера — один API-токен. Он не является пользователем и не
  делит сессии: `GET /client/sessions` показывает все клиентские подключения.
  Несколько сессий — это несколько окон/устройств, а не несколько
  пользователей.
- `deviceId` — устройство в модели группировки: одинаковый `deviceId` и разные
  `sessionId` означают одно устройство и несколько подключений. Это не
  глобальный уникальный идентификатор, но и не секрет; для доступа он не
  используется.
- Если понадобится отзыв доступа по отдельному устройству, следующим шагом
  добавляется `deviceToken`: долгоживущий секрет, выданный сервером при
  сопряжении. Это будет отдельная модель устройств, а не текущая сессия.

## Тесты

- Registry: создание, повторное рукопожатие с `previousSessionId`, истечение,
  `sweep`, `delete`.
- API: `/health` содержит `instanceId`; handshake возвращает сессию;
  `requireSession` без заголовка — `400`; протухшая — `410`; heartbeat
  продлевает; список сессий помечает текущую; `DELETE` закрывает; SSE
  принимает заголовок; CORS разрешает `x-client-session`.
- Client: рукопожатие ровно один раз при параллельных запросах; заголовок на
  всех запросах; `410` → рукопожатие и один retry; `401` не повторяется;
  heartbeat; `MemoryClientSessionStore`.
- Синхронизация: закрытие карточек, полная очередь с ревизией, инвалидация
  настроек, `chatChanged`, `turnSnapshot`, раздельные ревизии черновика и
  правок, `expectedRevision` у метаданных чата.
- Web: две вкладки — две сессии; reload — та же сессия; дубликат вкладки —
  новая; недоступное хранилище не ломает приложение.

## Ограничения

- Сессии не переживают перезапуск сервера; это сознательно.
- `instanceId` не стабилен между запусками; это тоже сознательно.
- `deviceId` — устройство в модели, а не глобальный уникальный id. Одинаковые
  `X-Client-*` у двух физических машин не различить; для текущего single-user
  сценария это допустимо.
- Пока нет per-device токенов, отзыв доступа возможен только сменой общего
  Bearer-токена.
- Список сессий показывает клиентов, но не позволяет отозвать отдельное
  устройство: для этого нужна отдельная модель device-токенов.
- Обнаружение дубликата вкладки через `BroadcastChannel` остаётся
  best-effort.
