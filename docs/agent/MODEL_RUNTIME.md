# Состояние и загрузка моделей

Каталог отвечает на вопрос «какие модели существуют», а слой runtime — «что с
моделью сейчас»: загружена ли она в память, идёт ли загрузка, можно ли ей
управлять. Состояние эфемерно: в БД оно не пишется, после перезапуска
запрашивается у провайдера заново.

## Ключевые файлы

- `packages/pw_agent/lib/providers/ai/model_runtime.dart` — доменные типы,
  `ModelRuntimeSource` и необязательный `LlmModelRuntimeProvider`;
- `packages/pw_agent/lib/providers/ai/model_runtime_service.dart` — слияние
  провайдеров, переподключение, действия load/unload;
- `packages/pw_agent/lib/providers/ai/llama_cpp/llama_cpp_model_runtime.dart` —
  адаптер llama.cpp;
- `lib/features/models/presentation/widgets/model_runtime_builder.dart` —
  точечная подписка UI;
- `lib/features/models/presentation/model_runtime_labels.dart` — подписи и
  tooltip-тексты;
- `lib/features/chat/presentation/widgets/chat_meta_bar.dart` — чип модели;
- `lib/features/chat/presentation/widgets/chat_attention_dock.dart` — баннер
  блокирующей загрузки;
- `lib/features/models/presentation/widgets/model_picker_dialog.dart` — состояние
  и действия в выборе модели;
- `lib/features/settings/presentation/widgets/provider_section.dart` — сводка и
  управление в настройках провайдера.

## Универсальная модель

`ModelRuntime` описывает одну модель:

- `phase`: `unknown`, `unloaded`, `loading`, `loaded`, `unloading`, `sleeping`,
  `downloading`, `incomplete`, `failed`;
- `progress`: общая доля 0..1, этап `weights/projector/draft/other` и номер
  этапа;
- `startedAt`, `loadedAt`, `expiresAt`, `error`, `reported`.

`ModelRuntimeCapabilities` говорит, что провайдер умеет: сообщать состояние,
сообщать прогресс, загружать, выгружать, усыплять.

Провайдер реализует `LlmModelRuntimeProvider` только если у него есть такая
возможность. Остальные (например, OpenRouter) не реализуют — UI не показывает
runtime и работает как раньше.

## Источники состояния

| Провайдер | Состояние | Прогресс | Управление |
| --- | --- | --- | --- |
| llama.cpp router | `GET /models`, `GET /models/sse` | `model_status` / `status_change`, `progress.value` по этапам | `POST /models/load`, `POST /models/unload` |
| llama.cpp single-model | `/health` 200/503, `/v1/models` | нет | нет |
| llamadart (локальные файлы) | состояние движка в процессе | только скачивание проектора при загрузке | `load`/`unload` через среду |
| OpenRouter | нет | нет | нет |
| Ollama (при добавлении) | `/api/ps` | нет | `generate` с `keep_alive: 0` |
| LM Studio (при добавлении) | `/api/v1/models` | только в SSE нативного чата | `/api/v1/models/load|unload` |
| vLLM (при добавлении) | `/is_sleeping` | нет | `/sleep`, `/wake_up` |

В llama.cpp `progress.value` — прогресс **текущего этапа**, а не общий. Адаптер
считает общий как `(индекс_этапа + value) / количество_этапов` и не даёт
прогрессу откатываться внутри одной загрузки.

SSE не присылает начальный снимок: сначала `GET /models`, затем подписка на
`/models/sse`. После переподключения снимок запрашивается снова.

## UI

- **Чип модели в композере.** Во время загрузки меняет тон на
  `AppTone.progress`, показывает кольцо/спиннер и tooltip с процентом и этапом.
  Загруженная модель не подсвечивается постоянно: это шум.
- **Док чата.** Баннер появляется только если загрузка блокирует текущий ход
  дольше секунды и текста ещё нет. Иначе пользователь принимает загрузку за
  зависание.
- **Выбор модели.** Бейджи `loading/loaded/failed/...` и действия
  `Загрузить/Выгрузить`. Выгрузка подтверждается: она может прервать запрос.
- **Настройки провайдера.** Список моделей в памяти и загружающихся, кнопки
  управления. Полный каталог остаётся в выборе модели.
- **Список чатов не используется.** Runtime — глобальное состояние сервера;
  дублировать прогресс в каждой строке, где встречается модель, нельзя.
- **Недоступный провайдер.** Ошибка runtime сразу переводит провайдера в
  offline в `ModelCatalogState`, а его модели перестают быть доступными:
  выбор модели скрывает их и показывает предупреждение, чип чата помечает
  текущую модель `!`, в доке появляется баннер. После переподключения статус
  и модели возвращаются сами.

## Локальные модели

`llamadart` сообщает только состояние памяти: скачивание файла — это
операция среды выполнения, она видна в `/models/files` и SSE `localModels`.
В `/models/runtime` попадают лишь `unloaded/loading/loaded/unloading/failed`
по установленным файлам. См. [LOCAL_MODELS.md](LOCAL_MODELS.md).

## API

Локальный и удалённый агент отдают одинаковое состояние:

```text
GET  /api/v1/models/runtime
POST /api/v1/models/runtime/load    {"model": "llamacpp:qwen"}
POST /api/v1/models/runtime/unload  {"model": "llamacpp:qwen"}
```

Изменения приходят в SSE событием `modelRuntime` с полем `runtime`. Событие
глобальное, не привязано к чату.

## Границы

- Не добавляйте поля конкретного провайдера в `ModelCatalogState` и
  `ChatState`: runtime — отдельный поток.
- Не кладите прогресс в `ChatState` без троттлинга: это перестроит ленту.
  Используйте `ModelRuntimeBuilder`.
- Ошибка runtime не делает провайдера недоступным: чат и каталог продолжают
  работать.
- Секреты не попадают в состояние и логи; ошибки провайдера уже проходят через
  `Redactor`/`LlmFailure`.
