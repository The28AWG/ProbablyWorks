# Провайдеры LLM: архитектура и добавление нового

## Статус

Провайдеры OpenRouter, llama.cpp и llamadart переведены на общую схему. Новый
провайдер добавляется адаптером, дескриптором и одной регистрацией;
каталог, API настроек, сервер, клиент и UI править не нужно.

`llamadart` отличается тем, что у него есть отдельная среда выполнения:
файлы, параметры и очередь живут в `LocalModelsService` и не зависят от
включённости провайдера. Подробности — в [LOCAL_MODELS.md](LOCAL_MODELS.md).

## Политика шагов

Дескриптор провайдера объявляет `stepPolicy`:

- `ProviderStepPolicy.standard` — цена вызова предсказуема, шаги
  ограничивают бюджеты хода (`maxTurnTokens`, `maxTurnCostUsd`,
  `turnMaxWallClock`) и общий аварийный потолок `maxAgentSteps`;
- `ProviderStepPolicy.economical` — накладные расходы вызова не измеряются
  (локальная модель, медленный сервер, скрытые затраты). Для такого
  провайдера всегда действует конечный `economicalMaxAgentSteps`, даже если
  общий потолок выключен (`maxAgentSteps: 0`).

`localModels` и `stepPolicy` не связаны: первый — свойство интерфейса,
второй — политика исполнения. Новый локальный провайдер помечается
`economical`, облачный — обычно остаётся `standard`.

Модель не узнаёт причину остановки: в ленту пишется тот же нейтральный
результат невыполненного вызова, что и при обычном лимите шагов. Причина
живёт в логах и интерфейсе.

Ключевые файлы:

- `packages/pw_agent/lib/providers/ai/llm_port.dart` — порт `LlmProvider`,
  `LlmModelInfo`, события и базовая реализация `LlmProviderBase`;
- `packages/pw_agent/lib/providers/ai/llm_provider_meta.dart` —
  `LlmProviderDescriptor`, `LlmProviderConfig`, `LlmProviderStatus`,
  `LlmKeyInfo`;
- `packages/pw_agent/lib/providers/ai/llm_provider_registry.dart` —
  `LlmProviderRegistry`: маршрутизация, префиксы моделей, статусы;
- `packages/pw_agent/lib/providers/ai/provider_settings_store.dart` —
  общие ключи настроек и секретов;
- `packages/pw_agent/lib/providers/ai/model_catalog.dart` —
  `ModelCatalogState.providers` и `providerStatuses`;
- `packages/pw_agent/lib/providers/ai/model_runtime.dart` и
  `model_runtime_service.dart` — необязательное состояние загрузки моделей
  (см. [MODEL_RUNTIME.md](MODEL_RUNTIME.md));
- `packages/pw_agent/lib/agent/loop/step_cap.dart` — эффективный потолок
  шагов с учётом политики провайдера;
- `packages/pw_agent/lib/agent/loop/turn_budget.dart` — бюджеты хода по
  токенам, стоимости и времени;
- `packages/pw_agent/lib/agent/api/agent_settings_api.dart` —
  `LlmProviderSettingsApi` и снимок настроек;
- `packages/pw_client/lib/src/remote_agent_api.dart` — HTTP-клиент
  `/providers/*`;
- `packages/pw_server/lib/src/api/api_server.dart` — маршруты
  `/providers/*`;
- `lib/features/settings/presentation/widgets/provider_section.dart` —
  общая карточка провайдера;
- `lib/app/guards/api_key_guard.dart` — «настроен хотя бы один провайдер».

## Как добавить провайдера

### 1. Адаптер

Реализуйте `LlmProvider` (или наследуйте `LlmProviderBase`, если у
провайдера нет собственных настроек и проверки) и задайте дескриптор:

```dart
const ollamaDescriptor = LlmProviderDescriptor(
  id: 'ollama',
  label: 'Ollama',
  modelPrefix: 'ollama:',
  defaultBaseUrl: 'http://localhost:11434',
  supportsBaseUrl: true,
  stepPolicy: ProviderStepPolicy.economical,
);

class OllamaLlmProvider implements LlmProvider {
  OllamaLlmProvider({required this.readConfig});

  final Future<LlmProviderConfig> Function() readConfig;

  @override
  List<LlmProviderDescriptor> get providers => const [ollamaDescriptor];

  @override
  Future<List<LlmProviderStatus>> configStatuses() async {
    final config = await readConfig();
    return [
      LlmProviderStatus(
        id: ollamaDescriptor.id,
        enabled: config.enabled,
        baseUrl: config.baseUrl,
        apiKeySet: config.hasApiKey,
        apiKeyTail: config.apiKeyTail,
      ),
    ];
  }

  @override
  Future<List<LlmProviderStatus>> statuses() async {
    // Проверка с сетью. Ошибку вернуть в status.error, не бросать.
  }

  @override
  Future<List<LlmModelInfo>> listModels() async {
    // Локальные id без префикса: реестр добавит его сам.
  }

  @override
  Stream<LlmEvent> stream(LlmRequest request) async* {
    // request.model приходит с префиксом: снимите его через
    // ollamaDescriptor.localModelId(request.model).
  }
}
```

Требования к адаптеру:

- `listModels` возвращает локальные id и человекочитаемые названия;
- `statuses` не бросает: причина в `LlmProviderStatus.error`;
- `stream` бросает `LlmFailure` с причиной;
- секреты не попадают в статус и логи;
- вложения отправляются теми частями, которые реально понимает сервер.

Если сервер умеет сообщать состояние загрузки или управлять им, адаптер
дополнительно реализует `LlmModelRuntimeProvider`: снимок, поток изменений и
`load/unload` по локальному id. Возможность необязательная; провайдеры без неё
работают как раньше. Контракт и UI описаны в [MODEL_RUNTIME.md](MODEL_RUNTIME.md).

### 2. Регистрация

В `AgentCoreModule`:

```dart
@singleton
OllamaLlmProvider ollamaLlmProvider(LlmProviderSettingsStore settings) =>
    OllamaLlmProvider(readConfig: () => settings.read(ollamaDescriptor));

@singleton
LlmProviderRegistry llmProviderRegistry(
  OpenRouterLlmProvider openRouter,
  LlamaCppLlmProvider llamaCpp,
  OllamaLlmProvider ollama,
) => LlmProviderRegistry([openRouter, llamaCpp, ollama]);
```

После этого выполните `dart run build_runner build
--delete-conflicting-outputs` (в корне и в `packages/pw_agent`).

### 3. Проверки

Адаптер покрывается тестами:

- список моделей и названия;
- проверка статуса (успех и недоступный сервер);
- стрим текста и tool calls;
- вложения;
- ошибка сервера → `LlmFailure`.

Общие тесты реестра (`llm_provider_registry_test.dart`) проверяют
маршрутизацию, префиксы и изоляцию ошибок. Новый провайдер не требует
правок этих тестов.

## Локальные модели

Провайдер `llamadart` не хранит адрес и ключ: его модели — установленные файлы
среды выполнения. Поэтому:

- `listModels` читает `LocalModelRuntime.installedModels()` и отдаёт
  `LlmModelInfo` с контекстом и флагом инструментов из параметров файла;
- `stream` снимает префикс `llamadart:` и делегирует генерацию среде;
- `LlmModelRuntimeProvider` отдаёт состояние памяти и команды load/unload;
- файлами, параметрами и очисткой управляет отдельный раздел настроек и API
  `/models/files`, а не карточка провайдера.

## Настройки и секреты

Общая схема:

- `provider.<id>.enabled` — `'true'`/`'false'` в `SettingsRepository`;
- `provider.<id>.baseUrl` — адрес сервера;
- `provider.<id>.apiKey` — ключ в `SecretStore`.

Старые ключи читаются для существующих профилей:

- `llamaCpp.enabled`, `llamaCpp.baseUrl`, `llamacpp.apiKey`;
- `openrouter.apiKey`.

При сохранении пишется новый ключ, старый удаляется: иначе чтение
вернулось бы к прежнему значению.

Переменные окружения:

```text
PROBABLY_WORKS_<ID>_KEY       # id в верхнем регистре, не-буквы → _
PROBABLY_WORKS_OPENROUTER_KEY # OpenRouter
OPENROUTER_API_KEY            # старый fallback OpenRouter
```

## API

Все провайдеры используют один интерфейс:

```text
GET    /providers
GET    /providers/{id}
PUT    /providers/{id}        {"enabled": true, "baseUrl": "..."}
POST   /providers/{id}/check
POST   /providers/{id}/key    {"key": "..."}
DELETE /providers/{id}/key
```

Состояние загрузки моделей — отдельный необязательный слой:

```text
GET  /models/runtime
POST /models/runtime/load    {"model": "..."}
POST /models/runtime/unload  {"model": "..."}
```

`POST /providers/{id}/key` возвращает статус после проверки. Провайдер
с `requiresApiKey: true` сам откатывает нерабочий ключ.

## UI

`ProviderSection` рисуется по дескриптору и статусу: включение, адрес,
ключ, проверка, баннер состояния и маска. Названия провайдеров — данные
из дескриптора, а не ключи локализации. Общие строки:
`providerEnabled*`, `providerBaseUrl*`, `providerApiKey*`, `providerCheck`,
`providerAvailable`, `providerError`, `providerUnavailable`,
`providerCheckedAt`.

Если у провайдера есть метаданные ключа (лимит, расход, срок), задайте
`supportsKeyInfo: true`: карточка покажет `ApiKeyInfoCard`.

## Статусы

`LlmProviderStatus` различает состояния явно:

- `checkedAt == null` — провайдера ещё не проверяли;
- `error != null` — причина последней неудачной проверки;
- `available == true` — проверка прошла;
- `checkedAt != null`, `error == null`, `available == false` — проверка
  прошла, но провайдер не ответил.

Чтение конфигурации без сети не сбрасывает результат проверки:
`mergeProviderStatus` сохраняет `available`, `error`, `modelCount` и
`checkedAt`, если включённость, адрес и ключ не менялись. Иначе UI
показывал бы «не отвечает» вместо реальной причины.

## Guard и онбординг

`ApiKeyGuard` проверяет наличие хотя бы одного провайдера, готового
отдавать модели:

- `enabled == true`;
- при `requiresApiKey == true` задан ключ;
- локальный провайдер без обязательного ключа уже ответил на проверку
  (`available == true`).

Сеть в guard не трогается: используется последний известный статус.
Поэтому выключенный локальный сервер не блокирует интерфейс, а свежая
установка без ключа и без доступного сервера попадает в онбординг.
Онбординг разрешает пропустить шаг ключа OpenRouter, если локальный
провайдер уже настроен и доступен.

## Модели и отображение

- `LlmProviderDescriptor.globalModelId` добавляет префикс при сборке
  каталога;
- `ModelCatalogState.providerOf` и `modelIdForDisplay` используют
  дескрипторы, а не проверки вида `id.startsWith('llamacpp:')`;
- у провайдера без префикса (OpenRouter) id остаются прежними.

## Уровень размышлений

`LlmModelInfo.reasoning` описывает возможности модели, а `LlmRequest.reasoning`
несёт уже разрешённый уровень (`none`, `minimal`, `low`, `medium`, `high`,
`xhigh`, `max`) или null.

- OpenRouter заполняет capability из `model.reasoning`
  (`supported_efforts`, `default_effort`, `mandatory`, `supports_max_tokens`);
- llama.cpp возможностей не сообщает, поэтому `reasoning == null` означает
  «неизвестно». UI показывает общий набор, по умолчанию ничего не отправляет.
  Если сервер не поддерживает явный уровень, он вернёт ошибку;
- адаптер опускает поле при `reasoning == null` и переводит значение в своё
  поле (`reasoning.effort` у OpenRouter, `reasoning_effort` у llama.cpp).

Не добавляйте провайдерские поля в `ModelCatalogState` или
`AgentSettingsSnapshot`: возможности живут в `LlmModelInfo`/`SavedModel`,
а выбор пользователя — в `Chat.reasoning` и ключах настроек.

Подробности и дорожная карта — в [REASONING.md](REASONING.md).

## Грабли

- `aliases.first` на пустом списке → `Bad state: No element`; проверяйте
  `isNotEmpty`.
- `tags: []` не означает «нет tool calling»: пустой список — «неизвестно».
- Нельзя класть текст ошибки вложения в промпт: ошибку возвращает сервер,
  пользователь видит `LlmFailure`.
- `statuses()` не должен бросать: иначе один недоступный провайдер
  скроет статусы остальных.
- Не добавляйте поля конкретного провайдера в `ModelCatalogState`,
  `AgentSettingsSnapshot`, маршруты и `SettingsCubit`: это снова размажет
  знание по слоям.

## Проверки

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
dcm analyze lib test
flutter test

cd packages/pw_agent && dart test && dart analyze && dcm analyze lib test
cd packages/pw_client && dart test && dart analyze && dcm analyze lib test
cd packages/pw_server && dart test && dart analyze && dcm analyze lib test
```
