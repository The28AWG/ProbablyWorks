# Уровень размышлений модели: исследование и дорожная карта

## 0. Статус реализации

Реализовано:

- доменные типы `ReasoningEffort`, `ReasoningPreference`,
  `LlmReasoningCapability` и `resolveReasoning`;
- возможности OpenRouter из `model.reasoning`; для llama.cpp возможности
  неизвестны, поэтому показывается общий набор уровней;
- `LlmRequest.reasoning` вместо `skipReasoning`;
- хранение уровня в чате и возможностей в сохранённых моделях (схема v19);
- настройки `defaultReasoning`, `memoryReasoning`, `subagentReasoning`,
  `fallbackReasoning`;
- второе окно выбора уровня после выбора модели;
- подменю «Размышления» в меню «+» композера для смены уровня без смены
  модели;
- индикатор уровня на чипе модели в `ChatMetaBar`;
- селектор уровня в полях моделей настроек;
- передача уровня в основной ход, fallback, заголовок, память, сжатие и
  субагентов.

Не реализовано (вынесено на потом):

- per-message audit `model`/`reasoningEffort` в сообщении;
- отдельный бюджет `reasoning.max_tokens`;
- глобальная память «последний уровень для модели».

## 1. Цель

Дать пользователю управлять «уровнем размышлений» (reasoning effort) там, где
выбирается модель: в чате, в настройках модели по умолчанию, памяти, субагентов и
запасной модели. Если провайдер не сообщает, какие уровни поддерживает модель,
это не ошибка: показываем безопасный набор и по умолчанию ничего не отправляем.

Ограничения:

- не ломать существующее поведение: без выбора уровня запрос уходит как сейчас;
- не добавлять провайдерские поля в общие слои;
- не раздувать строку настроек композера: она уже сворачивает чипы;
- старые базы, старые клиенты и старые демоны должны продолжать работать;
- уровень хранится в чате и в настройках, а не только в памяти.

## 2. Что есть сейчас

### 2.1. Порт LLM

`packages/pw_agent/lib/providers/ai/llm_port.dart`:

- `LlmRequest` знает только `skipReasoning: bool` — «не тратить токены на
  рассуждения»;
- `LlmModelInfo` описывает id, имя, окно, tool calling, цены, модальности, но не
  возможности рассуждений;
- `SavedModel` (модель, сохранённая в БД) повторяет эти поля без reasoning.

`skipReasoning` используется в двух местах:

- генерация заголовка чата (`chat_session_runtime.dart`) — `true`;
- основной запрос хода — значение из `LlmRequest`, но пользователь его не задаёт.

Память проекта (`project_memory_service.dart`) и сжатие истории
(`context_compactor.dart`) создают `LlmRequest` без `skipReasoning`, то есть
отдают решение провайдеру.

### 2.2. Провайдеры

OpenRouter (`openrouter_llm_provider.dart`):

- `listModels` получает `model.reasoning` с полями `default_effort`,
  `supported_efforts`, `mandatory`, `supports_max_tokens`;
- `_toRequest` уже умеет отправлять `ChatRequestReasoningValue(effort: none)`
  для `skipReasoning`;
- в стриме уже разбирается `delta.reasoning` в `LlmReasoningDelta`.

llama.cpp (`llama_cpp_llm_provider.dart`):

- `LlamaCppOpenAiChatRequest` поддерживает `reasoning_effort`, а также
  `reasoning_budget_tokens` и родственные поля;
- `listModels` не отдаёт сведений о reasoning: у `LlamaCppModelInfo` их нет;
- сейчас отправляется только `reasoningEffort: 'none'` при `skipReasoning`.

Вывод: транспорт уже готов, не хватает доменного типа, возможностей модели,
хранения и UI.

### 2.3. Хранение

- `Chat` (`chat_models.dart`) хранит `model`, но не уровень.
- Таблица `chats` (`tables.dart`) не имеет колонки reasoning.
- `SavedModels` хранит id, имя, окно, tool calling и входные модальности.
- Настройки — kv-ключи в `SettingsRepository`: `defaultModel`, `titleModel`,
  `memoryModel`, `subagentModel`, `fallbackModel`, `pinnedModels`.
- `AgentSettingsSnapshot` и API `/settings` перечисляют эти поля явно.
- Схема БД — `AppDatabase.currentSchemaVersion = 18`.

### 2.4. Поток выбора модели

1. `ChatBloc` отдаёт `state.effectiveModelId`: модель чата, иначе модель по
   умолчанию.
2. `ChatSession._prepare` читает чат из БД и берёт `chat.model` или
   `keyDefaultModel`.
3. Собирает `LlmRequest(model: model, messages, tools)`.
4. `LlmProviderRegistry` маршрутизирует запрос по префиксу провайдера.
5. `ChatModelChanged` в `ChatBloc` сохраняет `model` и `contextLength`.

Точка вставки уровня — шаг 3. Важно, что `_prepare` читает чат на каждом шаге:
смена уровня применится к следующему запросу, даже если ход уже идёт.

### 2.5. UI

- `ModelPickerDialog` возвращает `LlmModelInfo?`. Внутри есть поиск, фильтры,
  закреплённые, группы провайдеров, клавиатура.
- `ChatMetaBar` — одна строка чипов: проект, хост, папка, модель, контекст.
  Ширины измеряются `TextPainter`, при нехватке чипы сворачиваются до значков.
- `ModelSettingField` — карточка модели в настройках, открывает тот же picker.
- `ChatComposer` держит меню «+» с вложением, папкой и режимом выполнения.

## 3. Доменная модель

### 3.1. Уровни

Нужны два перечисления, потому что «наследовать» и «автоматически» — разные
состояния.

```dart
/// Значение, которое реально уходит провайдеру.
enum ReasoningEffort { none, minimal, low, medium, high, xhigh, max }

/// Выбор пользователя. inherit — «как в настройках», auto — «не отправлять,
/// пусть провайдер решит сам».
enum ReasoningPreference {
  inherit,
  auto,
  none,
  minimal,
  low,
  medium,
  high,
  xhigh,
  max,
}
```

`ReasoningPreference` живёт в чате и настройках. `ReasoningEffort` — только в
`LlmRequest` после разрешения. Это не даёт случайно отправить `inherit` в API.

### 3.2. Возможности модели

```dart
class LlmReasoningCapability extends Equatable {
  /// false — модель точно не умеет; true — умеет; null — провайдер не сообщил.
  final bool? supported;

  /// null — список неизвестен, разрешаем общий набор.
  final List<ReasoningEffort>? efforts;

  /// Уровень по умолчанию, если провайдер его сообщил.
  final ReasoningEffort? defaultEffort;

  /// true — отключить нельзя, none будет отклонён.
  final bool mandatory;

  /// Модель принимает reasoning.max_tokens (Anthropic-подобные API).
  final bool supportsMaxTokens;
}
```

Добавить `LlmModelInfo.reasoning` и `SavedModel.reasoning`. `SavedModel` нужен,
чтобы UI не ждал загрузки каталога и переживал офлайн.

### 3.3. Запрос

```dart
class LlmRequest {
  const LlmRequest({
    ...
    this.reasoning, // null — не отправлять, провайдер решит сам
  });

  final ReasoningEffort? reasoning;
}
```

`skipReasoning` заменяется на `reasoning: ReasoningEffort.none` или на
`ReasoningPreference.auto` для служебных вызовов, где нельзя гарантировать
поддержку `none`. После миграции всех вызовов поле `skipReasoning` удаляется.

### 3.4. Разрешение уровня

Чистая функция в `pw_agent` (например,
`packages/pw_agent/lib/providers/ai/reasoning.dart`):

```dart
ReasoningEffort? resolveReasoning({
  required LlmReasoningCapability? capability,
  required ReasoningPreference preference,
});
```

Правила:

1. `inherit` и `auto` → `null`, поле в запрос не попадает.
2. `capability?.supported == false` → `null`: модель не умеет, не отправляем.
3. `capability == null` или `supported == null` → отправляем выбранный уровень
   как есть. Это осознанный риск: провайдер может ответить 400, и пользователь
   увидит причину.
4. `mandatory && preference == none` → `defaultEffort` или `null`. Отключить
   нельзя, показываем «всегда включено».
5. Если `efforts` задан и выбранного уровня нет — понижаем до ближайшего
   поддерживаемого, не выше выбранного. Если ниже нет — берём самый низкий.
   Это важно для fallback и смены модели.

Эффективное значение в чате:

```dart
final preference = chat.reasoning == ReasoningPreference.inherit
    ? settings.defaultReasoning
    : chat.reasoning;
```

`inherit` в чате означает «следовать настройке по умолчанию». `auto` —
явное «провайдер сам решит», даже если в настройках стоит `high`.

## 4. Провайдеры

### 4.1. OpenRouter

В `listModels`:

```dart
final reasoning = model.reasoning;
LlmReasoningCapability? capability;
if (reasoning != null) {
  capability = LlmReasoningCapability(
    supported: true,
    efforts: [
      for (final effort in reasoning.supportedEfforts ?? const [])
        if (effort != null && effort != ReasoningEffort.unknown_)
          _reasoningEffortOf(effort),
    ],
    defaultEffort: _reasoningEffortOf(reasoning.defaultEffort),
    mandatory: reasoning.mandatory,
    supportsMaxTokens: reasoning.supportsMaxTokens ?? false,
  );
} else {
  // null в OpenRouter — это и «не умеет», и «динамический роутер».
  // supported_parameters помогает отличить.
  final canReason = model.supportedParameters.any(
    (p) => p == Parameter.reasoning ||
        p == Parameter.reasoningEffort ||
        p == Parameter.includeReasoning,
  );
  capability = LlmReasoningCapability(
    supported: canReason ? true : false,
    efforts: canReason ? null : const [],
  );
}
```

В `_toRequest`:

```dart
reasoning: request.reasoning == null
    ? null
    : ChatRequestReasoningValue(effort: _openRouterEffort(request.reasoning!)),
```

`none` отправляется как `ChatRequestReasoningValueEffortValue.none`.

### 4.2. llama.cpp

`listModels` не даёт метаданных. Возвращаем `LlmReasoningCapability(supported:
null, efforts: null)` — «неизвестно». UI покажет общий набор, по умолчанию
`auto`, то есть в запрос ничего не уйдёт.

В `_toRequest`:

```dart
reasoningEffort: request.reasoning?.name, // none/minimal/...
```

Если сервер не поддерживает `reasoning_effort`, он вернёт ошибку. Её нужно
показать как обычную `LlmFailure`. В будущем можно добавить повтор без
reasoning при явной ошибке 400, но это отдельное решение.

### 4.3. Новый провайдер

В `docs/agent/LLM_PROVIDERS.md` добавить требование:

- `listModels` заполняет `LlmModelInfo.reasoning`, если API сообщает
  возможности; иначе `supported: null`;
- `stream` переводит `LlmRequest.reasoning` в своё поле и опускает его при
  `null`;
- не добавлять поля конкретного провайдера в `ModelCatalogState`,
  `AgentSettingsSnapshot` и маршруты.

## 5. Хранение и миграция

### 5.1. Чат

В `Chats`:

```dart
/// Уровень размышлений чата. inherit — следовать настройке по умолчанию.
TextColumn get reasoning =>
    text().withDefault(const Constant('inherit'))();
```

В `Chat`:

```dart
final ReasoningPreference reasoning; // по умолчанию inherit
```

`Chat.copyWith` получает `ReasoningPreference? reasoning` — поле не nullable,
поэтому отдельный `clearReasoning` не нужен.

`ChatRepository.saveChat` и `_chat` пишут/читают `row.reasoning`.
Неизвестное значение в БД читается как `inherit`, а не падает.

### 5.2. Сохранённые модели

В `SavedModels` — одна JSON-колонка, чтобы не плодить пять колонок под
будущие возможности:

```dart
/// Возможности reasoning в JSON (LlmReasoningCapability). Null — неизвестно.
TextColumn get reasoningJson => text().nullable()();
```

`SavedModelRepository` сериализует `LlmReasoningCapability.toJson()`.
`ModelCatalogService._detailsOf` копирует capability из живого каталога или из
сохранённой модели.

### 5.3. Настройки

Новые kv-ключи:

```dart
static const keyDefaultReasoning = 'defaultReasoning';
static const keyMemoryReasoning = 'memoryReasoning';
static const keySubagentReasoning = 'subagentReasoning';
static const keyFallbackReasoning = 'fallbackReasoning';
```

Значение — имя `ReasoningPreference` (`auto`, `high`, ...). Пустое или
неизвестное — `auto`.

Для заголовка отдельный ключ не нужен: заголовок всегда без рассуждений
(`auto`/`none` по возможности модели).

### 5.4. Миграция v18 → v19

```dart
static const currentSchemaVersion = 19;
...
// Версия 19: уровень размышлений чата и возможности reasoning сохранённых моделей.
if (from < 19) {
  await m.addColumn(chats, chats.reasoning);
  await m.addColumn(savedModels, savedModels.reasoningJson);
}
```

Колонки аддитивные, с default/null. Бэкфилл не нужен: старые чаты получают
`inherit`, старые сохранённые модели — `null` и обновятся при следующем
обновлении каталога.

Проверки:

- `test/core/db_migration_test.dart`: база v18 с чатом и сохранённой моделью
  открывается, чат читается с `inherit`, модель — без capability;
- `dart run build_runner build --delete-conflicting-outputs` в корне и в
  `packages/pw_agent`;
- `test/core/saved_model_repository_test.dart`: capability переживает
  сохранение и чтение.

## 6. API демона

### 6.1. Настройки

`AgentSettingsSnapshot` получает:

```dart
final ReasoningPreference defaultReasoning;
final ReasoningPreference memoryReasoning;
final ReasoningPreference subagentReasoning;
final ReasoningPreference fallbackReasoning;
```

`LocalAgentSettingsApi.load` читает новые ключи. `GET /settings` отдаёт их
строками. `RemoteAgentApi` (`_snapshotFrom`) читает с fallback `auto`.
`_RemoteAgentSettings._value` должен маппить новые ключи, иначе в daemon-режиме
`settings.read(keyDefaultReasoning)` вернёт `null`.

Запись идёт через существующий `PUT /settings/{key}` — отдельные маршруты не
нужны.

### 6.2. Чат

`_chatJson`, `_chatFromJson`, `_chatBody` в сервере и `_chat`/`_chatBody` в
клиенте получают `reasoning`. Старый демон без поля → `inherit`; старый клиент
игнорирует новое поле.

### 6.3. Каталог

`_modelJson`, `_catalogJson` (блок `saved`), `_model`, `_savedModel` получают
`reasoning` объектом:

```json
{
  "supported": true,
  "efforts": ["minimal", "low", "medium", "high"],
  "default": "medium",
  "mandatory": false,
  "maxTokens": false
}
```

`null` — возможности неизвестны.

### 6.4. Сообщения (опционально, но полезно)

Добавить в payload сообщения `model` и `reasoningEffort`, чтобы после fallback
и смены модели было видно, кто и с каким уровнем ответил. Это не требует
миграции БД: поля живут в JSON `payload`. API `/messages` и клиент должны их
пробросить.

## 7. Поток агента

### 7.1. Основной ход

В `ChatSession._prepare`:

1. определить модель (`_modelOverride ?? chat.model ?? keyDefaultModel`);
2. определить effective preference:
   `chat.reasoning == inherit ? keyDefaultReasoning : chat.reasoning`;
3. взять capability из `_hub.models.state.modelOf(model)?.reasoning` или
   `saved[model]?.reasoning`;
4. вызвать `resolveReasoning`;
5. положить результат в `LlmRequest.reasoning`.

Смена уровня применится к следующему шагу, потому что `_prepare` читает чат
заново. Отдельная блокировка UI во время хода не нужна.

### 7.2. Fallback

`_withModel` сейчас копирует `skipReasoning`. Заменить на разрешение для
запасной модели:

```dart
reasoning: resolveReasoning(
  capability: capabilityOf(fallback),
  preference: _preferenceFor(request.reasoning),
),
```

Если запасная модель не умеет reasoning — `null`, поле не отправляется.
Если умеет только низкие уровни — понижаем. Это предотвращает 400 при
fallback.

### 7.3. Заголовок чата

Заголовок — служебный вызов. Использовать `ReasoningPreference.auto` для
неизвестных моделей и `none` только если capability подтверждает, что
отключение допустимо. Это заодно чинит старую проблему `openrouter/free`,
который требует reasoning.

### 7.4. Память проекта

Правило:

- если задана отдельная `memoryModel` — уровень `keyMemoryReasoning`;
- если используется модель чата — уровень чата;
- если модель по умолчанию — `keyDefaultReasoning`.

`ProjectMemoryService` получает доступ к каталогу (или к чистому resolver с
capability), чтобы не отправлять неподдерживаемый уровень.

### 7.5. Сжатие истории

Сжатие — механическая задача. Предлагается `auto` (или `none`, если модель
позволяет) вместо текущего «пусть провайдер решит». Это экономит токены и
делает поведение предсказуемым. Если качество сводок упадёт, можно добавить
отдельную настройку.

### 7.6. Субагенты

При создании скрытого чата:

- если модель субагента совпадает с моделью родителя — копировать
  `parent.reasoning` (включая `inherit`);
- если задана отдельная `subagentModel` — взять `keySubagentReasoning`,
  по умолчанию `auto`;
- при восстановлении после перезапуска уровень читается из чата, как обычное
  поле.

`SubagentRun` может показывать уровень в контексте, который видит родитель.

### 7.7. Смена модели

При выборе новой модели:

- сохранить `reasoning` без изменений, если пользователь его не менял;
- effective значение считается для новой модели;
- если новый уровень не поддерживается, UI показывает фактический
  (пониженный) уровень и подсказку «High недоступен, используется Medium»;
- если модель вообще не умеет reasoning, индикатор скрывается, но сохранённое
  значение не затирается: при возврате к старой модели оно снова применится.

Это лучше, чем молча сбрасывать выбор пользователя.

## 8. UI

### 8.1. Варианты

| Вариант | Плюсы | Минусы |
| --- | --- | --- |
| **Второе окно после выбора модели** | просто; не трогает picker; явный выбор уровня | цепочка модалок; при отмене модели уровень остаётся прежним |
| Отдельный чип reasoning в `ChatMetaBar` | видно всегда | строка и так не помещается; ещё один чип ухудшает сворачивание |
| Настройка только в Settings | ничего не ломает | нет управления в чате, а задачи разные |
| **Подменю в «+» композера** | не занимает ширину; меняет уровень без смены модели | скрыто; текущее значение видно только в подсказке чипа модели |
| Футер reasoning в `ModelPickerDialog` | одна модалка; видно текущий уровень | picker становится сложнее и выше |

Выбрано: **второе окно после выбора модели + подменю «Размышления» в «+» +
компактный индикатор на чипе модели + селекторы в настройках**. Композер не
получает новый чип, поэтому ширина строки не меняется.

### 8.2. Второе окно после выбора модели

- `ModelPickerDialog` остаётся прежним и возвращает `LlmModelInfo?`.
- После выбора модели `ChatView` смотрит на `picked.reasoning` (или
  сохранённую capability) и, если модель поддерживает reasoning или
  возможности неизвестны, открывает `showReasoningDialog`.
- Окно показывает `AppChoiceGroup` с уровнями:
  `Default` (`inherit`, только для чата), `Auto`, `Off` (если разрешено),
  затем поддерживаемые уровни.
- `Save` возвращает выбор, закрытие окна — null. Null означает «оставить
  прежний уровень»: модель всё равно применяется, уровень можно поменять
  позже через «+».
- Для модели без reasoning окно не открывается.
- Для `mandatory`-модели `Off` не показывается.
- Для неизвестной capability (llama.cpp) показывается общий набор уровней.
  Если сервер не поддерживает выбранный уровень, он вернёт ошибку, и
  пользователь увидит её в чате.

Почему так: пользователь явно выбирает модель, затем явно подтверждает
уровень. Отмена не отменяет модель и не затирает прежний уровень.

### 8.2.1. Подменю «+»

В меню «+» композера добавлено подменю «Размышления». Оно показывает тот же
набор уровней для текущей модели и отмечает действующий. Выбор применяется
сразу, без смены модели и без второго окна. Если модель не поддерживает
reasoning, остаются только `Default`/`Auto`; для неизвестной capability —
общий набор.

### 8.2.2. `ModelSettingField`

Поле модели в настройках показывает уровень отдельной строкой с
`DropdownMenu`. Для заголовка чата селектор скрыт: заголовки не используют
рассуждения. Для модели без reasoning показывается «не поддерживается».

### 8.3. `ChatMetaBar`

Не добавлять новый чип. Вместо этого:

- чип модели остаётся той же ширины;
- если effective reasoning не `auto`, ведущая иконка меняется с `Icons.memory`
  на `Icons.psychology` (или добавляется маленькая точка);
- подсказка чипа: `Model: X · Reasoning: High`;
- на `tiny` чип и так только значок, подсказка сохраняет информацию.

Так строка не получает ещё один элемент, а состояние видно.

### 8.4. Настройки

`ModelSettingField` получает `reasoning` и `onSelected(ModelSelection)`.
Под названием модели — строка:

```text
Reasoning   [Auto ▾]
```

- Для модели по умолчанию, памяти, субагентов и fallback — селектор.
- Для заголовка — без селектора, с пояснением «заголовки не используют
  рассуждения».
- Для закреплённых моделей — без селектора.
- Если модель не поддерживает reasoning — «Не поддерживается этой моделью».
- Если `mandatory` — `Off` недоступен, показываем «Всегда включено».

Для коротких наборов уровней можно использовать `SegmentedButton`, для полного
набора (7 значений) — `DropdownMenu` или `AppChoiceGroup` в bottom sheet.
Правила `docs/ui/RULEBOOK.md`: один выбор из нескольких — `AppChoiceGroup` или
`SegmentedButton`; для длинного списка лучше `DropdownMenu`.

### 8.5. Сообщения (опционально)

Если добавить `model` и `reasoningEffort` в `ChatMessage`, в подписи ответа
можно показывать `Claude Sonnet · High`. Это особенно полезно после fallback,
когда фактическая модель отличается от выбранной в чате. Показ — ненавязчивый,
в мета-строке ответа или в заголовке журнала шагов.

## 9. Локализация

Добавить в `app_en.arb` и `app_ru.arb` (проверяется
`test/l10n/arb_parity_test.dart`):

- `reasoningLabel` — «Reasoning» / «Размышления»;
- `reasoningDefault` — «Default» / «По умолчанию»;
- `reasoningAuto` — «Auto» / «Авто»;
- `reasoningOff` — «Off» / «Выключено»;
- `reasoningMinimal`, `reasoningLow`, `reasoningMedium`, `reasoningHigh`,
  `reasoningXhigh`, `reasoningMax`;
- `reasoningDefaultHint`, `reasoningAutoHint`, `reasoningOffHint`;
- `reasoningHigherCostHint` — «Выше уровень — больше токенов и времени»;
- `reasoningNotSupported`, `reasoningAlwaysOn`;
- `reasoningAdjustedForModel` — «High недоступен, используется Medium»;
- `reasoningModelChipTooltip`;
- `settingsReasoning`, `settingsReasoningHint`;
- `modelMetaReasoning`, `modelMetaReasoningAlways`.

Технические значения (имена уровней) можно не переводить, но названия в UI —
обязательно.

## 10. Дорожная карта

### Этап 0. Контракты и решения (0.5–1 день)

- Утвердить `ReasoningEffort` / `ReasoningPreference` и правила разрешения.
- Утвердить UI: второе окно после выбора модели и подменю «Размышления» в «+».
- Утвердить семантику `inherit` vs `auto`.
- Добавить этот документ и ссылки из `LLM_PROVIDERS.md` и `README.md`.

Готово, когда решения зафиксированы и нет открытых вопросов по модели данных.

### Этап 1. Ядро и провайдеры (2–3 дня)

- `llm_port.dart`: capability, `LlmRequest.reasoning`, `SavedModel.reasoning`.
- `reasoning.dart`: чистая функция разрешения.
- OpenRouter: маппинг capability и запроса.
- llama.cpp: маппинг запроса, `supported: null` в каталоге.
- `ModelCatalogService`: сохранение capability.
- Тесты: resolution, OpenRouter, llama.cpp, каталог.

Готово, когда без UI запросы с `auto` уходят как раньше, а явный уровень
попадает в тело запроса.

### Этап 2. Хранение и API (1–2 дня)

- Схема v19: `chats.reasoning`, `saved_models.reasoning_json`.
- `Chat`, `ChatRepository`, миграция.
- Ключи настроек и `AgentSettingsSnapshot`.
- `LocalAgentSettingsApi`, `SettingsCubit`.
- Сервер и клиент: chat JSON, settings JSON, catalog JSON.
- Тесты миграции, репозитория, API round trip.

Готово, когда старый чат открывается с `inherit`, новая настройка переживает
перезапуск, daemon-клиент читает и пишет уровень.

### Этап 3. Агент (1–2 дня)

- `ChatSession._prepare`: effective preference и `LlmRequest.reasoning`.
- `_withModel`: понижение для fallback.
- Заголовок: безопасный `auto`/`none`.
- Память: `memoryReasoning` и правило наследования.
- Сжатие: `auto`/`none`.
- Субагенты: наследование/настройка.
- Тесты e2e: запрос несёт уровень, fallback не ломается, субагент наследует.

Готово, когда смена уровня в чате влияет на следующий запрос, а fallback и
служебные циклы не отправляют неподдерживаемые значения.

### Этап 4. UI (3–4 дня)

- Второе окно `showReasoningDialog` после выбора модели.
- Подменю «Размышления» в «+» композера.
- Бейджи reasoning в строках picker.
- `ChatMetaBar`: индикатор на чипе модели и подсказка.
- `ChatBloc`: `ChatModelChanged` с уровнем и `ChatReasoningChanged`.
- `ModelSettingField`: селектор уровня, состояния «не поддерживается» и
  «всегда включено».
- `SettingsCubit`: сохранение новых ключей.
- Локализация en/ru.
- Тесты диалога и golden-тесты `chat_meta_bar`, `chat_screen`.

Готово, когда:
- в композере нет нового чипа и нет переполнения;
- уровень выбирается вторым окном после модели;
- уровень меняется из «+» без смены модели;
- в настройках видны и редактируются уровни для всех ролей;
- `Off` недоступен для mandatory-моделей;
- для неизвестной capability показывается безопасный набор.

### Этап 5. Полировка (1–2 дня)

- Per-message audit: `model` и `reasoningEffort` в payload и мета-строке.
- Обработка ошибок провайдера «reasoning not supported» (понятный текст,
  предложение вернуть `auto`).
- Документация: `README.md`, `docs/agent/LLM_PROVIDERS.md`,
  `docs/ui/WIDGET_BOOK.md`, `docs/ui/RULEBOOK.md`.
- Полные проверки:
  `dart format`, `flutter analyze`, `dcm analyze`, `flutter test`,
  `dart test` в пакетах.

Итого: около 8–12 рабочих дней на одного разработчика без учёта ревью и
ручного тестирования на всех провайдерах.

## 11. Матрица ручной проверки

1. OpenRouter, модель с reasoning: выбрать `High`, отправить, увидеть
   рассуждения и проверить, что в запросе есть `reasoning.effort`.
2. OpenRouter, модель без reasoning: селектор скрыт, `auto` не ломает запрос.
3. OpenRouter, mandatory-модель: `Off` недоступен, `auto` работает.
4. llama.cpp: `auto` не отправляет поле; явный `High` отправляет
   `reasoning_effort`; неподдерживаемый сервер даёт понятную ошибку.
5. Смена модели с `High` на модель без `High`: показывается фактический
   уровень, запрос не падает.
6. Fallback на модель без reasoning: поле не отправляется.
7. Новый чат наследует уровень по умолчанию; явный уровень чата переживает
   перезапуск.
8. Старая база v18: чаты открываются, сохранённые модели читаются.
9. Daemon-режим: настройки и уровень чата переживают перезапуск демона.
10. Узкий и `tiny` композер: нет переполнения, подсказка содержит уровень.
11. Заголовок чата и сжатие не тратят лишние рассуждения.
12. Память проекта использует свой уровень; субагент наследует уровень
    родителя.

## 12. Риски и смягчение

| Риск | Смягчение |
| --- | --- |
| Провайдер не поддерживает `reasoning_effort` | по умолчанию `auto`, поле не отправляется; явный выбор — ответственность пользователя; ошибка показывается |
| Модель mandatory, а сохранён `none` | resolver заменяет на `defaultEffort`/`auto`; UI не даёт выбрать `Off` |
| Смена модели ломает сохранённый уровень | resolve на каждом запросе + понижение до поддерживаемого; сохранённое значение не затирается |
| UI композера переполняется | не добавляем чип; индикатор внутри чипа модели; уровень меняется в picker |
| Старый клиент/демон | поля аддитивные, отсутствие читается как `inherit`/`auto`/`null` |
| Стоимость растёт | подсказка в UI; существующий дневной лимит продолжает работать |
| Секреты в рассуждениях | не менять текущую редакцию; не логировать текст рассуждений |
| Модель умеет только `reasoning.max_tokens` | показываем `Auto`; поддержку бюджета токенов выносим в отдельный этап |

## 13. Открытые решения

1. **UI:** выбрано второе окно после выбора модели плюс подменю «Размышления»
   в «+». Футер в picker оставлен как запасной вариант, если второе окно
   окажется слишком навязчивым.
2. **Семантика:** оставляем `inherit` и `auto` разными состояниями
   (рекомендуется) или упрощаем до одного `auto`?
3. **Per-message audit:** добавляем `model`/`reasoningEffort` в сообщение
   сразу или отдельным этапом?
4. **Служебные вызовы:** заголовок и сжатие — `auto`/`none` (рекомендуется)
   или отдельные настройки?
5. **llama.cpp:** показывать общий набор уровней при неизвестной capability
   (рекомендуется) или только `Auto`?
6. **Память по модели:** запоминать последний уровень для каждой модели
   глобально (необязательно) или хранить только в чате и настройках?
