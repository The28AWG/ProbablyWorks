# Плагины

Плагин — это **скомпилированный в приложение** пакет с отключаемым функционалом.
Пользователь не устанавливает код: он только включает или выключает уже
собранные возможности. MCP — не плагин, а обычный функционал приложения.

## Пакеты

- `packages/plugin_api` — интерфейсы `Plugin`, `PluginTool`, `PluginHost`,
  `PluginSettings` без Flutter.
- `packages/plugin_api_ui` — интерфейс `PluginUi` и `PluginUiRegistry`. Это
  представление, а не плагин: оно привязано к `pluginId` и не влияет на
  включение инструментов.
- `packages/plugin_declarative_commands_core` — ядро фиксированных команд:
  чистый Dart, доступный клиенту и демону.
- `packages/plugin_declarative_http_core` — ядро HTTP-инструментов: чистый Dart,
  доступный клиенту и демону.
- `packages/plugin_declarative_commands` и `packages/plugin_declarative_http` —
  Flutter-представления: локализация и экраны настроек.
- Основное приложение содержит реестр ядра (`PluginRegistry`), реестр
  представлений (`PluginUiRegistry`), граф зависимостей, флаги включения и
  адаптер `PluginToolSource` к общему `ToolExecutor`.

Ядро плагина не импортирует Flutter и подключается демоном. Представление
берёт общие виджеты из `package:app_ui`, а интерфейсы — из `plugin_api_ui`.
Клиент связывает ядро и представление по `pluginId`; если представления нет,
плагин всё равно можно включать и выключать.

## Локализация

У пакета плагина свои `lib/l10n/app_en.arb`, `app_ru.arb` и `l10n.yaml`.
После изменения ARB выполните в каталоге пакета:

```bash
flutter gen-l10n
```

Делегат плагина регистрируется в `lib/app/locale/app_localization_delegates.dart`.
Строки в UI берутся по контексту:

```dart
final l10n = DeclarativeCommandsLocalizations.of(context);
```

Делегат регистрируется всегда, даже если плагин выключен: старые карточки
инструментов в истории должны отображаться.

## Включение и зависимости

Флаг хранится в kv как `plugin.<id>.enabled` (`yes`/`no`). Без сохранённого
флага используется `defaultEnabled`.

- При включении приложение находит все недостающие зависимости, включая
  транзитивные, и предлагает включить их вместе с плагином.
- При отключении показывает включённые зависимые плагины и отключает их вместе.
- Переключать плагины во время активного хода нельзя: набор инструментов не
  должен меняться посреди хода.
- Выключение не удаляет настройки плагина.

## Инструменты

Плагин возвращает `PluginTool`. Приложение адаптирует его в `ToolSource`:

- имя становится `plugin_<pluginId>_<toolName>`;
- вызов проходит общий `PolicyEngine` и подтверждение;
- `PluginHost.runCommand` запускает executable и args без shell-интерполяции;
- если инструмент может менять Host, ход помечается неоткатываемым.

Модель не может подменить executable или фиксированные аргументы команды.

## HTTP-инструменты

Плагин `declarative_http` хранит инструменты в том же JSON-формате:

```json
{
  "id": "weather",
  "title": "Weather",
  "description": "Current weather",
  "method": "GET",
  "url": "https://api.example.com/weather?city={{city}}",
  "headers": {"Authorization": "Bearer ${secret:weather}"},
  "inputSchema": {
    "type": "object",
    "properties": {"city": {"type": "string"}},
    "required": ["city"]
  },
  "timeoutSeconds": 30,
  "maxResponseChars": 20000,
  "responseFormat": "json",
  "jsonPath": "$.current.temperature"
}
```

- `{{name}}` подставляется из аргументов: в URL — с percent-encoding,
  в заголовках и теле — как строка.
- `${secret:name}` в заголовках разрешается приложением через `SecretStore`.
- `responseFormat`: `text`, `json` или `html`.
- Для `json` можно указать `jsonPath`, для `html` — `htmlSelector`.
- Ответ обрезается до `maxResponseChars`, ошибки HTTP возвращаются как
  `isError` с кодом и телом.

## Настройки

Настройки плагина хранятся в kv как JSON по ключу `pluginSettings.<id>`.
`PluginSettings.save` записывает JSON и пересобирает инструменты плагина.

Экран настроек плагина живёт в его пакете и получает `PluginSettings` от
приложения. После закрытия экрана приложение ещё раз обновляет источники
инструментов.

## Новый плагин

1. Создать пакет в `packages/`, добавить его в `workspace` и зависимости
   приложения.
2. Реализовать `Plugin` и, при необходимости, `PluginTool`.
3. Добавить ARB, `l10n.yaml` и сгенерировать локализацию.
4. Зарегистрировать делегат в `app_localization_delegates.dart`.
5. Добавить ядро в `PluginRegistry` клиента и демона.
6. Добавить `PluginUi` в `PluginUiRegistry` клиента, если нужен экран настроек.
7. Покрыть тестами создание инструментов и граф зависимостей.
