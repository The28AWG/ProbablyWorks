# Удалённый relay и модель устройств: справочник

> **Статус:** справочный документ, а не план работ и не порядок реализации.
> Ничего из описанного здесь не реализовано. Документ не заменяет
> [REMOTE_RELAY.md](REMOTE_RELAY.md) и [MULTI_VIEW_DIRECTIONS.md](MULTI_VIEW_DIRECTIONS.md),
> а фиксирует пространство решений: как идеи из «направлений» расширяются,
> если устройства не ограничены локальной сетью.
>
> Оценок сроков, приоритетов и объёма здесь нет. Любой пункт можно брать
> отдельно; документ не говорит, что делать первым.

## 1. Назначение

`REMOTE_RELAY.md` отвечает на вопрос «как доставить запросы к агенту за NAT,
не доверяя relay». `MULTI_VIEW_DIRECTIONS.md` отвечает на вопрос «что ещё
хочется синхронизировать между окнами и устройствами». Этот документ — карта
их пересечения:

- какие идеи из directions уже опираются на relay;
- что меняется, когда устройства могут быть в разных сетях;
- какие сущности нужно разделить, чтобы не построить две конкурирующие
  модели устройства;
- какие места `REMOTE_RELAY.md` стоит пересмотреть;
- какие инварианты и тесты понадобятся.

Это не протокол и не модель угроз в деталях. Криптография, формат кадров,
handshake и pairing по-прежнему требуют отдельного проектирования и ревью.

## 2. Идентичности и транспорт

Главная развилка — не «local или remote», а **кто**, **чем** и **через что**
общается.

| Сущность | Что означает | Где живёт | Чем не является |
|---|---|---|---|
| `agentId` | Отпечаток публичного ключа агента | Агент; клиент пиннит ключ | Не URL, не relay-аккаунт, не профиль |
| `agentPublicKey` | Долгоживущий identity-ключ агента | `SecretStore` агента | Не ключ устройства |
| `deviceKey` | Публичный ключ устройства или его отпечаток | Allowlist на агенте; keychain устройства | Не `clientId` |
| `installationId` | Стабильный id установки; сейчас это `clientId` | Настройки клиента | Не граница безопасности |
| `deviceId` | Отпечаток `X-Client-*` для старых клиентов и журнала | Заголовки клиента | Не уникальный id устройства |
| `sessionId` | Конкретное представление: окно, вкладка, SSE-поток | Память агента | Не авторизация |
| `transport` | Путь к агенту: loopback, LAN, relay, direct | Профиль/клиент | Не идентичность агента |
| `relayId` | Конкретный экземпляр relay | Relay/клиент | Не идентичность агента |

### 2.1. Почему это важно

Сейчас в коде уже есть конфликт имён: `ClientSessionView.deviceKey` — это
`clientId` или `deviceId` для группировки вкладок, а в `REMOTE_RELAY.md`
«device key» — это криптографический ключ устройства. Если оставить так,
при реализации легко перепутать доверие с группировкой.

Предлагаемое разделение имён:

- `deviceGroupKey` / `installationId` — для UI-группировки вкладок и окон;
- `devicePublicKeyFingerprint` — для доверия, push, аудита и allowlist;
- `sessionId` — для представления;
- `agentId` — для выбора агента и пиннинга.

### 2.2. Один агент — много путей

Если локальная сеть не ограничивает, один и тот же агент может быть доступен:

- по loopback на своей машине;
- по LAN;
- через relay;
- по direct/QUIC-пути после rendezvous.

Это не три агента и не три профиля. Это **один `agentId` и несколько
transport-путей**. Пользователь должен видеть «Рабочий Mac — напрямую»,
«iPhone — через relay», «планшет — через relay, 180 мс», а не три записи
«ProbablyWorks remote».

## 3. Что уже даёт `REMOTE_RELAY.md`

| Уже есть | Что это значит для модели устройств |
|---|---|
| WSS + прикладной E2E | Транспорт не читает payload; relay не командует агентом |
| `agentId` как отпечаток ключа | Клиент может пиннить агента, а не доверять relay |
| Device-ключи и allowlist | Устройство — долгоживущая сущность, а не только сессия |
| QR/ссылка + pairing mode + локальный approve | Relay не может одобрить устройство |
| Отзыв устройства | Можно убрать одно устройство, не меняя остальные |
| API-токен остаётся на агенте | Клиент не хранит общий секрет |
| Relay — rendezvous, не CA | Relay не хранит ключи и не эмитит сертификаты |
| Web-клиент: требование доверенного origin | E2E не спасает от подмены JS, это учтено |

| Пока нет | Что нужно для directions |
|---|---|
| Read state | A1/A8/C4: прочитанное, unread, позиция чтения |
| Attention inbox | A2/A3: решения, дайджест, «требует вас» |
| Per-device push | A6/A7/B2: адресная доставка, дедупликация, отмена |
| Handoff-запись | C1/C2/C8: передача чата и рабочей области |
| Action origin | D1: device key и транспорт в событиях и аудите |
| Control lease | D4: владелец PTY/терминала |
| Device capabilities | B3: что устройство умеет показывать и делать |
| Device delegation | B4/B6: доверенное устройство одобряет новое |
| Multi-agent trust | Один device key у нескольких `agentId` |

## 4. Принципы удалённой модели устройств

Это не порядок работ, а инварианты проектирования. Их можно принимать
частями, но лучше не смешивать противоположные.

### P1. Agent identity ≠ transport

`agentId` и пиннинг ключа — это «кто». Relay, LAN, direct — это «через что».
Смена сети не должна создавать нового агента или нового профиля.

### P2. Relay stateless, агент durable

Read state, attention, handoff-записи, device registry, push-политика,
история действий — всё живёт на агенте. Relay хранит только эфемерную
маршрутизацию: `agentId → активный туннель`, `online/lastSeen`, размеры и
тайминги. Никакого store-and-forward чата на relay.

### P3. Presence authority — агент, не relay

Relay может врать, задерживать или устаревать в `online/lastSeen`. Для
подавления push и выбора активного устройства агент опирается на свои сессии:
`visibility`, `lastInteractionAt`, `activeChatId`, `focused`, `lastReadSeq`.
Relay online можно показывать в UI, но не делать единственным критерием
уведомлений.

### P4. Device key первичен, `clientId` — атрибут

Доверие, push-токен, политика уведомлений и аудит привязаны к device key.
`clientId` остаётся для группировки вкладок и совместимости. Через relay
`X-Client-*` — подсказка для UI, а не доказательство личности.

### P5. Заголовки не доверенные

`X-Client-Id`, `X-Client-Name`, `X-Client-Platform` приходят из туннеля.
Агент может их показывать, но не должен на них опираться для allowlist,
push или approve. Источник истины — E2E-аутентифицированный device key.

### P6. Push — отдельный слой

Control-relay (WSS + E2E) и push-relay (APNs/FCM/WebPush) — разные сервисы
с разной видимостью. Push-токен привязан к device key; payload минимальный
или шифрованный; отмена и дедупликация — на агенте. Relay не решает, кому
доставлять.

### P7. Handoff — запись на агенте, а не очередь на relay

Целевое устройство может быть offline. Агент хранит `Handoff` с TTL и
`generation`; relay только доставляет запрос или будит push. Target забирает
запись при подключении. Source не может писать после передачи в режиме
`move`.

### P8. Тяжёлый трафик идёт лучшим путём

Companion upload, diff, голос, PTY-вывод — не обязаны идти через один
WSS-хоп. После rendezvous возможен direct/QUIC-путь; relay остаётся
signaling и fallback. Для больших тел нужны streaming, chunking, resumable
upload и backpressure.

### P9. Доверие — по устройству и по агенту, не по relay

Relay не одобряет устройства и не ведёт глобальный allowlist. Каждый агент
хранит свой allowlist device-ключей. Один device key может быть доверен
нескольким агентам, но это решение каждого агента.

### P10. Web-клиент зависит от целостности кода

Если relay раздаёт web-клиент со своего origin, оператор relay контролирует
JS и может украсть device key. E2E этого не предотвращает. Нужен отдельный
доверенный origin и non-extractable `CryptoKey`; иначе web-клиент — не
доверенная поверхность для approve и handoff.

### P11. Offline — норма, а не исключение

Мобильная сеть, сон, relay-обрыв и вытеснение приложения — обычные
состояния. Клиент должен уметь слать идемпотентные действия из outbox,
догонять состояние снимком/журналом и не считать «нет связи» потерей данных.

### P12. Не хранить данные чата на relay

Relay не должен становиться резервной базой, очередь или журналом. Даже
«временное» хранение payload создаёт retention, abuse и приватностный
контур. Единственное возможное исключение — короткоживущий шифрованный
указатель, но это отдельное решение.

### Что остаётся как есть

- HTTP/SSE API по-прежнему слушает loopback; туннель добавляет локальный
  `Authorization` после E2E-аутентификации.
- `sessionId`, `resumeSecret`, TTL, heartbeat, `closeGrace` и SSE-ping
  сохраняют смысл; relay не заменяет клиентскую сессию.
- `clientMessageId`, ревизии очереди/черновика/метаданных и
  `expectedRevision` остаются механизмами идемпотентности и конфликтов.
- Данные чата, read state, attention и handoff живут в БД агента, а не в
  relay.
- Локальный GUI на той же машине продолжает ходить по loopback, даже если
  для удалённых устройств включён relay.

## 5. Модель данных: эскиз

Это не схема БД и не финальные имена. Это набор сущностей, которые стоит
держать в голове, чтобы не смешивать уровни.

```text
AgentIdentity {
  agentId;                 // отпечаток публичного ключа
  agentPublicKey;
  transports: TransportPath[];
  createdAt;
}

TransportPath {
  kind;                    // loopback | lan | relay | direct
  endpoint;                // адрес/имя
  relayId?;                // если kind == relay
  lastLatencyMs?;          // подсказка для UI, не истина
}

DeviceRecord {
  devicePublicKeyFingerprint;
  installationId?;         // текущий clientId, если есть
  legacyDeviceId?;         // отпечаток X-Client-*, если есть
  name;                    // «Рабочий Mac», «iPhone»
  platform;
  capabilities;            // diff, terminal, camera, voice, approve...
  pushToken?;              // привязан к device key
  notificationPolicy;      // все / только решения / тихо
  trustedAt;
  revokedAt?;
  lastSeenAt;
}

SessionPresence {
  sessionId;
  devicePublicKeyFingerprint;
  transport;               // через какой путь пришла сессия
  visibility;              // foreground | background | locked | idle
  focused;
  lastInteractionAt;
  activeChatId?;
  openChatIds;             // из подписок, если нужно
  capabilities;
}

ReadState {
  chatId;
  lastReadSeq;
  readRevision;
}

AttentionItem {
  id;
  chatId;
  kind;                    // approval | question | failure | turnFinished | ...
  severity;
  createdAt;
  originDevice?;
  snoozedUntil?;
}

Handoff {
  id;
  chatId;
  fromDevice;
  toDevice;
  anchorSeq?;
  mode;                    // move | mirror
  generation;
  expiresAt;
  status;                  // pending | accepted | declined | expired
}

NotificationDelivery {
  noticeId;
  devicePublicKeyFingerprint;
  sentAt;
  ackedAt?;
  escalateAt?;
}
```

`ReadState`, `AttentionItem`, `Handoff`, `DeviceRecord` и
`NotificationDelivery` — данные агента. `TransportPath` — клиентская/
серверная подсказка. Relay не обязан знать ни одну из этих сущностей, кроме
эфемерного `agentId → tunnel`.

## 6. Как расширяются идеи

Ниже — не приоритеты, а карта: что меняется на агенте, relay и клиенте.

### 6.1. Внимание

| Идея | Что даёт relay | На агенте | На клиенте |
|---|---|---|---|
| A1. Read-state | Доставка запросов и событий | `lastReadSeq`, `readRevision`, unread | Локальный anchor, «первое непрочитанное» |
| A2. Attention inbox | Push-пробуждение, если offline | Агрегат approvals/questions/failures | Экран «Требует вас», действия |
| A3. Дайджест | Ничего, кроме транспорта | Снимок изменений с `since`/read-cursor | Показ при возврате |
| A4. Snooze | Отложенный push | `snoozedUntil`, `attentionDue` | «Напомнить позже» |
| A5. Тихие часы | Подавление push | Глобальное `pausedUntil` | Локальный статус на всех устройствах |
| A6. Маршрутизация push | Доставка по токенам | Выбор активного устройства по presence | Ack/открытие, локальные уведомления |
| A7. Группировка/отмена | Collapse/cancel | `noticeId`, `NotificationDelivery` | Inline-ответ, отмена |
| A8. Бейджи | Push badge | Сумма unread по чатам | Web/desktop/mobile badge |

### 6.2. Устройства

| Идея | Что даёт relay | На агенте | На клиенте |
|---|---|---|---|
| B1. Реестр устройств | Связь с устройством вне LAN | `DeviceRecord`, allowlist, last seen | Имя, настройки, отзыв |
| B2. Per-device push | Доставка токену | Токен ↔ device key, политика | Регистрация, prefs |
| B3. Capabilities | Ничего | Учёт возможностей в событиях/push | Манифест в handshake |
| B4. Доверенные устройства | Pairing/rendezvous | Allowlist, delegation, revoke | QR/ссылка, approve |
| B5. Активное устройство | Путь и online | `active` по `lastInteractionAt` | «Взять управление» |
| B6. Approve по устройству | Доставка | Риск, trust, step-up | Биометрия/подтверждение |

### 6.3. Непрерывность

| Идея | Что даёт relay | На агенте | На клиенте |
|---|---|---|---|
| C1. Handoff | Wake target, если offline | `Handoff`, generation, TTL | Принять/отклонить, открыть |
| C2. Workspace handoff | Транспорт указателей | `openChatIds`, active/anchor | Восстановить вкладки |
| C3. Черновики карточек | Транспорт ревизий | `answerDraft`, `expectedRevision` | Показ «отвечает на iPhone» |
| C4. Позиция чтения | Транспорт | Общий `readSeq` | Локальный anchor |
| C5. Offline-outbox | Может рвать соединение | Идемпотентные действия | Локальная очередь, retry |
| C6. Side chat | Транспорт | `kind: side`, origin | Навигация |
| C7. Companion upload | Fallback/сигналинг | Приём файла, draft | Камера/файл/диктовка |
| C8. QR-handoff | Rendezvous | Grant scope/TTL/generation | Одноразовая capability |
| C9. Mirror/follow | Транспорт presence | `mirrorOf`, anchor | Read-only наблюдение |
| C10. Cross-host | Транспорт между агентами | Workspace/host state | Выбор хоста |

### 6.4. Управление

| Идея | Что даёт relay | На агенте | На клиенте |
|---|---|---|---|
| D1. Action ledger | Транспорт | `origin`, device key, eventId | Подпись «с iPhone» |
| D2. Replay SSE | Транспорт потока | `seq`, ring buffer, reset | `Last-Event-ID` внутри E2E |
| D3. Steering/pause | Транспорт | `steer`/`queue`/`paused` | Явные действия |
| D4. Control lease | Транспорт | Claim, generation, expiry | «Управление на Mac» |
| D5. Undo | Транспорт | Журнал, обратимые операции | «Отменить» |
| D6. Пульт агента | Транспорт | Агрегат running/waiting | Обзорный экран |
| D7. Monitor | Транспорт | Read-only режим, не active | Доска статуса |
| D8. Contract tests | Тестовый relay | Матрица событий | Два клиента |

### 6.5. Расширения

| Идея | Что даёт relay | На агенте | На клиенте |
|---|---|---|---|
| E1. Запрос к устройству | Wake/транспорт | `deviceRequest`, capability | Карточка «открой diff» |
| E2. Context deposit | Транспорт/direct | Приём контекста в draft | Share/upload |
| E3. Голосовой пульт | Signaling/direct | Команды, approval | WebRTC/voice |
| E4. Durable turn | Транспорт | Чекпоинт хода | Восстановление |
| E5. CRDT черновика | Транспорт | Состояние/ревизии | Курсоры/merge |

## 7. Handoff через разные сети

### 7.1. Чем отличается от локального

В локальной сети можно «просто открыть чат» на другом устройстве. В разных
сетях целевое устройство может быть offline, за NAT, без доступа к агенту
напрямую. Поэтому handoff — это **запись на агенте**, а не клик по ссылке.

### 7.2. Форма

1. Source (device A) вызывает `POST /client/handoffs` с `chatId`,
   `targetDeviceKey`, `anchorSeq?`, `mode: move|mirror`.
2. Агент создаёт `Handoff` с `generation`, `expiresAt`, `status: pending`.
3. Если target онлайн через relay/LAN/direct — агент отправляет
   `handoffRequested` по его сессии.
4. Если target offline — агент отправляет push (если разрешено) и ждёт
   подключения.
5. Target при подключении получает `handoffRequested` (или видит список
   pending), открывает чат на `anchorSeq`, принимает/отклоняет.
6. Агент фиксирует `accepted/declined/expired`; source видит результат.
7. В режиме `move` source становится наблюдателем; `generation` не даёт
   старому владельцу писать после передачи.

### 7.3. Что видит relay

Relay видит только факт соединения, `streamId`, размеры и тайминги. Он не
видит `chatId`, `anchorSeq`, `mode` и содержимое. Если target offline,
relay не хранит handoff; запись лежит на агенте.

### 7.4. Неавторизованное устройство

Для TV/чужого браузера вместо `Handoff` на device key выдаётся узкий
`HandoffGrant`:

- одноразовый секрет с TTL;
- scope: только этот чат и, возможно, только чтение/approve;
- pairing-код для подтверждения на исходном устройстве;
- `generation` для отзыва;
- relay — только rendezvous, не хранилище.

Это расширение C8, а не замена device-ключей.

### 7.5. Рабочая область

`Handoff` может нести не только `chatId`, но и `openChatIds`, `activeChatId`,
`anchorSeq` для каждого. Это уже C2. Важно: передаются указатели, а не
содержимое чатов; target сам читает через API.

## 8. Push и уведомления

### 8.1. Два разных relay

- **Control relay** — WSS + E2E, не видит payload.
- **Push relay** — APNs/FCM/WebPush, видит метаданные и, возможно, текст.

Не надо делать вид, что это один сервис. У них разные лимиты, retention и
модель доверия.

### 8.2. Привязка токена

Push-токен должен быть привязан к device key, а не к `clientId`:

- клиент аутентифицируется device-ключом;
- агент принимает токен только от доверенного устройства;
- отзыв устройства удаляет токен;
- relay не может зарегистрировать токен за другое устройство.

### 8.3. Payload

Минимальный payload:

- `noticeId`;
- `kind`;
- `chatId` (если не считается чувствительным);
- `badge`;
- `collapseKey`;
- `actions` (approve/deny/open);
- без текста сообщения и без diff.

Если нужен текст — шифровать под device key или отправлять generic
«откройте приложение» и тянуть детали через E2E. Push-relay не должен
становиться каналом утечки.

### 8.4. Маршрутизация

Решение принимает агент, не relay:

- если пользователь реально видит чат и у нижней границы — не уведомлять;
- если активное устройство есть — уведомить его;
- если активного нет — выбрать доверенное устройство с push;
- для approval — эскалация по `NotificationDelivery`, если нет ack;
- отмена по `noticeId` — на всех устройствах.

Relay online/lastSeen — только подсказка. Он может врать; агент не должен
подавлять уведомление только потому, что relay считает устройство online.

## 9. Read state, attention и дайджест

Всё это — данные агента. Relay не хранит ни unread, ни «прочитано», ни
pending approvals.

### 9.1. Read state

- `lastReadSeq` монотонен;
- общий курсор — максимум по устройствам;
- локальный anchor/scroll — на устройстве;
- `readRevision` защищает от запоздавших записей;
- `GET /chats` отдаёт `lastReadSeq`, `lastMessageSeq`, `unreadCount`;
- после reconnect клиент догоняет снимком или журналом.

### 9.2. Attention inbox

Агент агрегирует:

- approvals/questions/edit-file-changes;
- failures, step limit, budget, stalled;
- завершённые ходы;
- задачи по расписанию;
- очередь, если она требует решения.

Клиент получает `attentionChanged`/`chatStatusChanged` и/или
`GET /attention`. Snooze и quiet hours — на агенте, чтобы все устройства
видели одно состояние.

### 9.3. Дайджест

При возврате после offline:

- `GET /attention/digest?since=...` или локальный расчёт по `readSeq`;
- «пока вас не было: N сообщений, M завершений, K решений»;
- переход к первому непрочитанному;
- те же данные на всех устройствах.

Relay здесь — только транспорт. Если relay пропал, агент всё равно хранит
состояние; клиент заберёт его при следующем подключении.

## 10. Тяжёлые данные: upload, voice, terminal

### 10.1. Companion upload

Сценарий: телефон делает фото/файл/диктовку, это попадает в активный
черновик на удалённом десктопе.

Что нужно:

- одноразовый `UploadGrant`/`HandoffGrant` с TTL и scope;
- загрузка потоком, а не одним телом;
- chunking/resumable для больших файлов;
- проверка размера/типа;
- запись `AttachmentRef` в draft и `draftChanged`;
- relay — fallback; при наличии direct/LAN — прямой путь.

Текущий лимит `8 MiB` на тело запроса может не подойти; либо отдельный
upload-маршрут, либо chunked/resumable.

### 10.2. Voice

Голосовой пульт — это не «ещё один SSE». Для него лучше WebRTC/direct после
rendezvous, с relay как signaling. Команды (`stop`, `approve`, `dictate`)
идут через E2E-канал; голосовые данные не должны попадать в push-relay.

### 10.3. Terminal и control lease

PTY-вывод и ввод чувствительны к задержке и порядку:

- `terminal/input` и `terminal/data` — раздельно;
- sequence и credits/backpressure;
- claim/lease на агенте, relay не понимает, кто владелец;
- lease heartbeat и expiry;
- direct path для интерактивности;
- relay может ронять, но не подменять кадры (E2E).

## 11. Доверие, approve и делегирование

### 11.1. Approve

Approval должен быть привязан к:

- device key;
- риску действия (`read/write/destructive`);
- политике агента;
- возможно, step-up (биометрия/passkey) на устройстве.

Destructive-approve с непроверенного устройства запрещён на сервере, а не
только скрыт в UI.

### 11.2. Делегирование нового устройства

Когда агент удалённый/headless, добавить устройство удобнее с уже
доверенного:

1. Новое устройство показывает публичный ключ и nonce.
2. Доверенное устройство подписывает `{newDeviceKey, nonce, agentId}`.
3. Агент проверяет подпись доверенного устройства.
4. Добавляет новый ключ в allowlist.
5. Relay не может подписать или одобрить.

Это отдельная модель прав. Её нельзя делать «на глазок»; нужна
формулировка, кто кому может делегировать.

### 11.3. Восстановление

- Потерянное устройство — отозвать.
- Новое — сопрячь заново.
- Переустановка агента — новый `agentId`, все устройства заново.
- Перенос identity агента на новую машину — advanced-сценарий; если делать,
  только с шифрованием старого identity-ключа и явным подтверждением.

## 12. Multi-agent и multi-host

- Один device key может быть доверен нескольким `agentId`.
- Allowlist — на каждом агенте, не глобальный на relay.
- Relay может помогать discovery, но не быть реестром доверия.
- Cross-host handoff (C10) — отдельный слой: перенос чата и workspace state
  между агентами/хостами. Relay может быть транспортом, но не арбитром.
- Не смешивать multi-agent с multi-user: пользователь один, ролей нет.

## 13. Action origin, аудит и replay

### 13.1. Origin

Каждое пользовательское действие должно нести:

- `actor` (`user`, `agent`, `system`);
- `devicePublicKeyFingerprint`;
- `sessionId` (fingerprint);
- `transport`;
- `eventId`/`seq`;
- время.

IP через relay бессмыслен: все будут `127.0.0.1`. В `api-access.log` нужен
device fingerprint и transport, а не IP.

### 13.2. Replay

- `seq` — end-to-end, в рамках `instanceId`;
- `Last-Event-ID`/`afterSeq` — внутри E2E;
- relay не разбирает и не переставляет события;
- при разрыве — replay из буфера или snapshot;
- при смене `instanceId` — сброс ревизий.

### 13.3. Заголовки

`X-Client-*` не должны влиять на allowlist, push или approve. Только
device key. Иначе relay или скомпрометированный клиент сможет выдать одно
устройство за другое в UI/маршрутизации.

## 14. Места `REMOTE_RELAY.md`, которые стоит пересмотреть

| Место | Почему важно | Что решить |
|---|---|---|
| Relay видит публичные ключи в handshake | Rendezvous не нужны ключи; это лишняя корреляция устройств | Оставить relay только `agentId` + шифротекст |
| `X-Client-*` как идентичность | Через relay это не доказательство | Device key — источник истины; заголовки — UI |
| Relay `online/lastSeen` | Может врать/устаревать | Presence и push-маршрутизация — по сессиям агента |
| Push payload | Push-relay видит текст | Generic wake или шифрование под device key |
| `sendSessionClosing` | Ходит напрямую, обходит транспорт | Провести через `RemoteAgentApi` или не отправлять |
| Rate limit по IP | Через tunnel все `127.0.0.1` | Лимит по device key/stream |
| `api-access.log` | IP бесполезен | Device fingerprint + transport |
| 8 MiB body limit | Фото/диффы/вложения | Streaming/chunked/resumable |
| `deviceKey` в коде | Это grouping key, не криптоключ | Переименовать до реализации |
| Store-and-forward | Соблазн хранить чат на relay | Запретить; durable state — на агенте |
| Multi-agent | Один device key у разных агентов | Allowlist на каждом агенте |
| Agent identity transfer | Переустановка ломает все устройства | Решить, нужен ли перенос identity |
| Web origin | Relay может подменить JS | Отдельный доверенный origin |
| Direct path | Терминал/голос/большие файлы | Hole punching/QUIC как отдельный слой |
| Session TTL через relay | Задержки/фоновые вкладки | Heartbeat/SSE-ping; не сокращать TTL без нужды |
| Mobile agent | Фон/сон/вытеснение | Push-wake; отдельная модель |
| Metadata privacy | Relay видит, кто с кем и сколько | Padding/cover traffic — отдельное решение |

## 15. Инварианты

1. **Relay не одобряет устройства и не хранит ключи.**
2. **Device key — источник истины для доверия, push и аудита.**
3. **`clientId` — атрибут установки, а не граница безопасности.**
4. **`sessionId` — представление, а не авторизация.**
5. **Relay stateless; read state, attention, handoff и device registry — на
   агенте.**
6. **Presence и маршрутизация уведомлений — по сессиям агента, не по
   `online` relay.**
7. **Handoff — запись с TTL и `generation`; старый владелец не пишет после
   передачи.**
8. **Push-токен привязан к device key; payload минимален или шифрован.**
9. **Заголовки `X-Client-*` не влияют на trust/approve/push.**
10. **Тяжёлый трафик может идти direct; relay — signaling/fallback.**
11. **Offline — норма; действия идемпотентны, состояние догоняется.**
12. **Web-клиент с origin relay не считается доверенным для approve.**
13. **Relay не хранит данные чата; только эфемерная маршрутизация.**
14. **Один device key может быть доверен нескольким агентам, но allowlist
    ведёт каждый агент.**

## 16. Тестовая матрица удалённого доступа

| Сценарий | Что проверить |
|---|---|
| Pairing через relay | QR/ссылка, E2E, локальный approve, allowlist |
| Делегирование устройства | Подпись доверенного устройства, отказ без подписи |
| Отзыв устройства | Активные сессии рвутся, push-токен удалён, остальные живы |
| Подмена `X-Client-*` | UI не путает устройство, trust/push не меняются |
| Relay врёт `online` | Push не подавляется, если сессия мертва |
| Relay врёт `offline` | Клиент всё равно может подключиться через direct/LAN |
| Push dedupe | Одно уведомление на несколько событий/устройств |
| Push cancel | Закрытие карточки на A убирает push на B |
| Push ack/escalation | Нет ack — уведомление уходит следующему устройству |
| Handoff offline target | Запись ждёт на агенте, target получает при reconnect |
| Handoff expired | Target не может принять; source видит expired |
| Handoff stale generation | Старый source не пишет после `move` |
| Read state reconnect | Мобильный offline читает, потом догоняет кусок |
| Большой upload | Chunked/resumable, лимит, обрыв, повтор |
| Terminal backpressure | Медленный клиент не блокирует остальные streams |
| SSE replay | Разрыв, `Last-Event-ID`, нет дублей/пропусков |
| Multi-agent | Один device key, два агента, независимые allowlist |
| Web key | Non-extractable, очистка хранилища → re-pair |
| Direct path fallback | Relay недоступен, direct/LAN работает |
| Rate limit | Лимит по device key, а не по IP |

## 17. Совместимость и миграция

- `AgentProfile` сейчас `local/remote` с `baseUri`/токеном. Для relay-модели
  полезно разделить **agent identity** и **transport list**; старые профили
  можно временно оставить как один транспорт.
- `clientId` и `deviceId` остаются для совместимости и группировки, но
  `devicePublicKeyFingerprint` добавляется как первичный ключ доверия.
- `ClientSessionView.deviceKey` (grouping) стоит переименовать, чтобы не
  путать с криптоключом.
- `sendSessionClosing` должен либо идти через общий транспорт, либо не
  отправляться для relay-профиля (TTL/SSE закроют сессию).
- `PushSettings` стоит разделить: настройки relay и настройки устройства
  (токен, политика).
- `ApiServer` rate limit/access log нужно ключевать по device key; иначе
  relay делает всех клиентов `127.0.0.1`.
- `GET /client/sessions` может отдавать device fingerprint и transport; это
  полезно для UI, но не должно быть секретом.
- Старые клиенты без device key должны деградировать до текущей модели
  `clientId/deviceId`, но без доверия и push-привязки.

## 18. Открытые вопросы

Это не порядок и не план. Это решения, которые нужно принять до реализации
соответствующих частей.

- **Device key:** один на устройство или на пару «устройство + агент»?
- **Agent identity transfer:** переносить ключ на новую машину или всегда
  пересопрягать?
- **Делегирование:** кто может подписывать новый device key; сколько
  доверенных устройств нужно; как отзывать цепочку?
- **Push payload:** generic wake или шифрование под device key; что делать
  с лимитами APNs/FCM?
- **Relay visibility:** убрать публичные ключи из relay полностью?
- **Presence:** как именно агент вычисляет `active`; какие пороги idle?
- **Handoff:** `move` vs `mirror` по умолчанию; что происходит с черновиком
  и очередью; можно ли принимать handoff без push?
- **Store-and-forward:** нужен ли короткоживущий шифрованный указатель или
  агент всегда ждёт reconnect?
- **Direct path:** hole punching/QUIC; когда relay только signaling?
- **Multi-agent:** один device key на всех агентов или разные; как UI
  показывает доверие?
- **Web:** где раздавать web-клиент; как хранить ключ; нужен ли web push?
- **Mobile agent:** что делать, если агент на телефоне вытеснен системой?
- **Relay metadata:** нужен ли padding/cover traffic; что логировать?
- **Rate limit/audit:** ключевание по device key, stream, agentId; что
  писать в `api-access.log`.
- **Совместимость:** как мигрировать текущие remote-профили и сессии.

## 19. Источники

### Внутренние документы

- [REMOTE_RELAY.md](REMOTE_RELAY.md) — удалённый доступ, relay, pairing,
  device-ключи, E2E.
- [MULTI_VIEW.md](MULTI_VIEW.md) — текущая модель «один агент — много окон
  и устройств».
- [MULTI_VIEW_DIRECTIONS.md](MULTI_VIEW_DIRECTIONS.md) — направления
  развития и идеи сверх текущего состояния.
- [DAEMON.md](DAEMON.md) — контракт API и SSE.
- [PTY.md](PTY.md) — локальный терминал и control lease.

### Внешние источники

- [Agent Host Protocol](https://microsoft.github.io/agent-host-protocol/) —
  каналы, actions, reconciliation, active clients, terminals.
- [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control) —
  remote-сессии, trusted devices, push.
- [Claude Code on mobile](https://code.claude.com/docs/en/mobile) —
  вложения с телефона, remote-поверхности.
- [Codex remote connections](https://learn.chatgpt.com/docs/remote-connections) —
  handoff между hosts, устройство-хост.
- [Cursor Remote Control](https://cursor.com/changelog/remote-control-local-agents) —
  удалённое управление локальными агентами.
- [UIReady: Design Session Handoff Between Devices](https://uiready.dev/system-design/cross-device-session-handoff) —
  одноразовый handoff, pairing, generation.
- [Claude Trusted Devices](https://code.claude.com/docs/en/remote-control#trusted-devices) —
  доверенные устройства и отзыв.
- [Slack: How Slack rebuilt notifications](https://slack.engineering/how-slack-rebuilt-notifications/) —
  разделение «о чём» и «как», синхронизация настроек.
