# Провайдеры LLM: состояние и план универсализации

## Статус

Коммит `bab3172` — `feat(agent): добавить провайдер llama.cpp`.

Сейчас в агенте два провайдера:

- OpenRouter — `packages/pw_agent/lib/providers/ai/openrouter/`;
- llama.cpp — `packages/pw_agent/lib/providers/ai/llama_cpp/`.

Общий порт — `LlmProvider` в `packages/pw_agent/lib/providers/ai/llm_port.dart`.
Агрегатор — `MultiLlmProvider` в `packages/pw_agent/lib/providers/ai/multi_llm_provider.dart`.

## Что уже работает

- Каталог объединяет модели двух провайдеров, ошибка одного не скрывает модели другого.
- Модели llama.cpp получают префикс `llamacpp:`; id OpenRouter не меняются.
- Настройки llama.cpp: адрес, необязательный ключ, включение, проверка сервера.
- Локальный и удалённый агент умеют читать и сохранять эти настройки.
- Вложения: изображение → `image_url`, аудио → `input_audio`, видео → `input_video`,
  читаемый текст → `text`; неизвестный бинарный формат уходит как `file`,
  ошибку формата возвращает сервер.
- Модели llama.cpp группируются под провайдером `llama.cpp`, название очищается
  от суффикса квантизации, полный id остаётся в бейдже.
- Есть тесты на адаптер llama.cpp, на провайдерную группировку и фильтр.

## Почему текущее добавление не универсально

Критерий универсальности: новый провайдер = 1 адаптер + 1 дескриптор + 1 регистрация,
без правок каталога, DTO настроек, HTTP-маршрутов, UI, l10n и фейков.

| Слой | Сейчас жёстко привязано | Что будет при третьем провайдере |
|---|---|---|
| DI | `AgentCoreModule` создаёт OpenRouter, llama.cpp и `MultiLlmProvider` | править модуль и агрегатор |
| Агрегатор | `MultiLlmProvider` знает два поля и префикс `llamacpp:` | новая ветка или новый класс |
| Каталог | `ModelCatalogState.llamaCpp` | новое поле в generic-состоянии |
| Снимок настроек | `AgentSettingsSnapshot.llamaCpp` | новое поле в DTO |
| API настроек | `LlamaCppSettingsApi`, `/settings/llama-cpp/*`, `_requireLlamaCppSettingsApi` | новый интерфейс, маршруты и метод |
| UI | `LlamaCppSection`, ключи `settingsLlamaCpp*` | новая секция и l10n |
| ID модели | `providerOf` и `modelIdForDisplay` знают `llamacpp:` | новое знание в UI |
| Секреты | `openRouterKeyName`, `llamaCppKeyName`, env только для OpenRouter | новое имя секрета и env |
| Guard/онбординг | проверяется только ключ OpenRouter | локальный провайдер не пройдёт |
| `LlmProvider` | `checkKey()` — OpenRouter-специфичный | llama.cpp возвращает фиктивный `LlmKeyInfo` |
| Тесты/фейки | каждый фейк реализует `LlamaCppSettingsApi` | фейки растут с каждым провайдером |

Баг `aliases.first` на пустом списке, пустые `tags` и группировка каждого
`llamacpp:`-id в отдельного «провайдера» — симптомы того, что знание о
провайдере размазано по слоям.

## Целевая архитектура

### 1. Дескриптор и реестр

```dart
class LlmProviderDescriptor {
  final String id;          // 'openrouter', 'llama.cpp', 'ollama'
  final String label;       // для UI
  final String modelPrefix; // 'llamacpp:', 'ollama:'
  final bool requiresApiKey;
}

abstract interface class LlmProvider {
  LlmProviderDescriptor get descriptor;
  Stream<LlmEvent> stream(LlmRequest request);
  Future<List<LlmModelInfo>> listModels();
  Future<LlmProviderStatus> status();
}
```

`LlmProviderRegistry` регистрирует провайдеров, агрегирует модели,
маршрутизирует запросы и отдаёт статусы. `MultiLlmProvider` становится
тонкой обёрткой над реестром или исчезает.

### 2. Общий статус вместо `llamaCpp`

```dart
final Map<String, LlmProviderStatus> providerStatuses;
```

`ModelCatalogState` и `AgentSettingsSnapshot` больше не знают про
конкретного провайдера. `LlmProviderStatus` содержит `enabled`, `available`,
`modelCount`, `error`, `checkedAt` и, при необходимости, `label`/`keyTail`.

### 3. Общий API настроек

```text
GET    /providers
GET    /providers/{id}
PUT    /providers/{id}
POST   /providers/{id}/check
POST   /providers/{id}/key
DELETE /providers/{id}/key
```

Один интерфейс `LlmProviderSettingsApi`; `RemoteAgentApi` и
`LocalAgentSettingsApi` реализуют его один раз. Для провайдера без ключа
`/key` возвращает `not_supported` или просто не вызывается.

### 4. Общий UI

`ProviderSection` рисует карточку по дескриптору: включение, base URL,
API key, статус, кнопка проверки. Провайдер-специфичные поля —
необязательный builder. Названия провайдеров — данные, не l10n.
Общие ключи: `providerEnabled`, `providerBaseUrl`, `providerApiKey`,
`providerAvailable`, `providerUnavailable`, `providerError`,
`providerCheckedAt`.

### 5. Секреты и конфиг

- `provider.<id>.apiKey` в `SecretStore`;
- `provider.<id>.enabled`, `provider.<id>.baseUrl` в `SettingsRepository`;
- env-override `PROBABLY_WORKS_<ID>_KEY`;
- при чтении поддержать старые `openrouter.apiKey` и `llamacpp.apiKey`,
  чтобы не ломать существующие профили.

### 6. Guard и онбординг

Проверять «есть хотя бы один включённый и доступный провайдер», а не
`openRouterKeyName`. Онбординг должен позволять выбрать OpenRouter **или**
локальный llama.cpp. Сейчас llama.cpp-only пользователь не пройдёт
`ApiKeyGuard`, а секция провайдера в настройках недоступна без ключа
OpenRouter.

### 7. Контрактные тесты

Один набор тестов для любого `LlmProvider`: `listModels`, `stream`,
`status`, пустой список, ошибка сети. Плюс специфичные тесты адаптера.
Новый провайдер не должен требовать правок в тестах каталога и фейках
настроек.

## Этапы рефакторинга

1. **Низкий риск**
   - `checkKey()` → `status()`/`checkHealth()`; `LlmKeyInfo` оставить
     только для провайдеров с метаданными ключа.
   - `ApiKeyGuard` и онбординг: «есть рабочий провайдер», а не ключ OpenRouter.
   - Общие имена секретов и env с обратной совместимостью.

2. **Средний риск**
   - `LlmProviderDescriptor` + `LlmProviderRegistry`.
   - `MultiLlmProvider` → реестр.
   - `ModelCatalogState.providerStatuses` вместо `llamaCpp`;
     `AgentSettingsSnapshot` тоже.
   - `providerOf`/`modelIdForDisplay` берут данные из реестра, а не
     проверяют `llamacpp:` в UI.

3. **Средний риск**
   - Общий `LlmProviderSettingsApi` и маршруты `/providers/*`.
   - Миграция JSON снимка настроек и ключей.
   - `RemoteAgentApi`/`LocalAgentSettingsApi` реализуют один интерфейс.

4. **Низкий/средний риск**
   - `ProviderSection` вместо `LlamaCppSection`, общие l10n-ключи.
   - Контрактные тесты провайдеров.
   - Документация: как добавить провайдера.

## Чек-лист нового провайдера после рефакторинга

- [ ] адаптер реализует `LlmProvider` и отдаёт `descriptor`;
- [ ] провайдер зарегистрирован в `LlmProviderRegistry` (одна строка);
- [ ] дескриптор описывает id, label, префикс модели, нужен ли ключ;
- [ ] настройки читаются через общий `provider.<id>.*`;
- [ ] `status()` возвращает `LlmProviderStatus`, ошибки маппятся в `LlmFailure`;
- [ ] модели имеют стабильный id с префиксом провайдера и человекочитаемое имя;
- [ ] вложения поддерживают те модальности, которые реально умеет сервер;
- [ ] пройдены контрактные тесты;
- [ ] не изменены `ModelCatalogState`, `AgentSettingsSnapshot`, серверные
      маршруты, `SettingsCubit`, `SettingsPage`, l10n и фейки.

## Грабли этого сеанса

- `aliases.first` на пустом списке → `Bad state: No element`; проверять
  `aliases != null && aliases.isNotEmpty`.
- `tags: []` не должно означать «нет tool calling»; пустой список — это
  «неизвестно», модель не нужно скрывать фильтром.
- `providerOf` не должен возвращать весь id, если в нём нет `/`; для
  провайдерных префиксов нужен реестр.
- Нельзя класть текст ошибки в промпт вместо вложения: ошибку должен
  возвращать сервер, а пользователь видеть `LlmFailure`.
- `checkKey()` на провайдере без ключа — фиктивный `LlmKeyInfo`; это
  признак неверной абстракции.
- Guard/онбординг и env-миграция всё ещё OpenRouter-only.

## Проверки

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
dcm analyze lib test
flutter test

cd packages/pw_agent && dart test
cd packages/pw_client && dart test
cd packages/pw_server && dart test
```
