# Каталог виджетов ProbablyWorks

Каталог описывает собственные виджеты в `lib/app/ui/` и правило замены стандартных виджетов Material.
Экраны импортируют один файл:

```dart
import 'package:probably_works/app/ui/ui.dart';
```

Правила оформления (токены, раскладка, состояния) описаны в [RULEBOOK.md](RULEBOOK.md).

## 1. Когда брать собственный виджет

Собственный виджет используется вместо стандартного, если выполняется хотя бы одно условие:

- стандартный виджет выглядит хуже (например, `Card` без связи с темой проекта);
- стандартный виджет требует много повторяющихся настроек (поле ввода с ошибкой и подсказкой);
- нужна семантика, которой нет в Material (статус агента, ожидание ответа, diff);
- нужна единая логика (подтверждение, snackbar с правилами длительности).

## 2. Таблица замен

| Стандартный виджет | Собственный виджет | Когда использовать собственный |
| --- | --- | --- |
| `Scaffold` | `AppScaffold` | Всегда для страниц. Ограничивает ширину через `maxWidth`. |
| `Card` | `AppCard` | Все карточки. Поддерживает `onTap`, `accent` (полоска слева), `color`. |
| `TextField` / `TextFormField` | `AppTextField` | Все поля ввода. Есть `label`, `hint`, `helper`, `error`, `mono`, `suffix`. |
| `Column` с заголовком и полями | `AppSection` | Группа полей или настроек с заголовком, описанием и действием справа. |
| `MaterialBanner`, встроенные `Container` с текстом | `AppBanner` | Статусы в потоке: предупреждение, ошибка, доверие к workspace, лимит шагов. |
| `Card` + `Row` с кнопками (ожидание ответа) | `ActionCard` | Подтверждение команды агента, вопрос агента, очередь сообщений. |
| `MarkdownBlock` без конфига | `AppMarkdown` | Ответы агента. Пакетная палитра светлая: без конфига текст в тёмной теме нечитаем. |
| `Container` + моноширинный `Text` | `CodeBlock` | JSON, содержимое файлов, команды в подтверждении. Копирование встроено. |
| `Container` + `SelectableText` для вывода команды | `CommandOutput` | Команды агента в настоящем терминале (PTY на Host, пакет `xterm`): ввод, размер, ANSI-цвета, код выхода. |
| Построчная раскраска `Text` | `DiffView` | Изменения файлов (`+` и `-` строки). |
| `Icon` + `Text` для статуса | `StatusChip` / `StatusDot` | Статус хоста, агента, процесса. Цвет берётся из `AppTone`. |
| `Center` + `Column` с иконкой | `AppEmptyState` | Пустые списки, пустой чат, отсутствие результатов поиска. |
| `AlertDialog` с кнопками «Отмена» и «OK» | `ConfirmDialog.confirm` | Подтверждение действия, в том числе деструктивного. |
| `AlertDialog` с `TextField` | `ConfirmDialog.prompt` | Переименование и короткий текстовый ввод. |
| `ScaffoldMessenger.showSnackBar` | `AppSnackBar.show` | Короткие результаты действий, с опциональным действием. |
| `LinearProgressIndicator` с подписью | `ContextUsageBar` | Заполнение контекста модели. Цвет меняется у предела. |
| `Stepper` или набор точек | `OnboardingStepper` | Шаги онбординга: сегменты и счётчик. |
| `Container` с `BoxDecoration` и штрихом | `DashedBorder` | Зона перетаскивания файлов и пустые слоты. |

Стандартные виджеты, которые не заменены, допустимы: `ListView`, `ListTile`, `IconButton`,
`FilledButton`, `TextButton`, `OutlinedButton`, `SegmentedButton`, `FilterChip`,
`DropdownMenu`, `PopupMenuButton`, `NavigationRail`, `NavigationBar`, `Dialog` (для форм),
Внешний вид стандартных виджетов задаётся через тему (`AppTheme`). `MarkdownBlock` напрямую не используется, см. `AppMarkdown`.

## 3. Токены и тон

| Элемент | Назначение |
| --- | --- |
| `AppSpacing`, `AppRadius`, `AppDurations`, `AppBreakpoints`, `AppLayout` | Числовые константы (`lib/app/theme/app_tokens.dart`) |
| `AppTone` | Смысл элемента: `neutral`, `progress`, `waiting`, `success`, `warning`, `danger`, `info` |
| `AppToneColors` (`toneColors(context, tone)`) | Пара цветов `foreground` и `background` для тона |
| `AppColors` / `context.appColors` | Семантические цвета (`ThemeExtension`) |
| `AppTheme.light`, `AppTheme.dark`, `AppTheme.monoFamily` | Тема Material 3 и имя моноширинного шрифта |

Тон — единственный способ выбрать цвет статуса. Не передавайте `Color` напрямую туда, где есть `tone`.

## 4. Каталог компонентов

### Структура страницы

**`AppScaffold`**: обёртка `Scaffold` с ограничением ширины.

```dart
AppScaffold(
  appBar: AppBar(title: Text(l10n.navHosts)),
  maxWidth: AppLayout.pageMaxWidth,
  body: ListView(...),
  floatingActionButton: FloatingActionButton.extended(...),
)
```

Параметры: `body`, `appBar`, `maxWidth` (без ограничения, если не задан), `floatingActionButton`,
`drawer`, `bottomNavigationBar`.

**`AppSection`**: заголовок, описание, действие справа и список детей с единым зазором.

```dart
AppSection(
  title: l10n.hostFormSectionAuth,
  trailing: FilledButton(onPressed: _save, child: Text(l10n.commonSave)),
  children: [AppTextField(controller: _keyPath, label: l10n.hostKeyPathLabel)],
)
```

**`AppCard`**: карточка с фоном из темы, обводкой и опциональным `accent`.

```dart
AppCard(
  accent: colors.success,
  onTap: () => _open(host),
  child: Text(host.name),
)
```

### Ввод

**`AppTextField`**: поле с меткой, подсказкой, ошибкой и моноширинным режимом.

```dart
AppTextField(
  controller: _address,
  label: l10n.hostAddressLabel,
  error: _addressError,
  mono: true,
  onSubmitted: (_) => _save(),
)
```

Параметры: `controller`, `label`, `hint`, `helper`, `error`, `prefixIcon`, `suffix`, `obscure`,
`mono`, `enabled`, `autofocus`, `minLines`, `maxLines` (по умолчанию 1), `keyboardType`,
`onChanged`, `onSubmitted`, `focusNode`.

Поле сообщения в чате не является `AppTextField`: там нужен собственный обработчик клавиш
(`ComposerInput`, см. раздел 5).

### Обратная связь

**`AppBanner`**: сообщение в потоке или на странице.

```dart
AppBanner(
  title: l10n.trustTitle,
  message: l10n.trustBody,
  icon: Icons.shield_outlined,
  tone: AppTone.warning,
  action: FilledButton(onPressed: _trust, child: Text(l10n.trustAction)),
)
```

**`AppSnackBar.show(context, message, {actionLabel, onAction})`**: короткое уведомление.
Ошибки, которые пользователь должен прочитать, выводятся через `AppBanner`, а не через snackbar.

**`ConfirmDialog`**:

```dart
final ok = await ConfirmDialog.confirm(
  context,
  title: l10n.commonDelete,
  message: l10n.hostDeleteConfirm,
  cancelLabel: l10n.commonCancel,
  confirmLabel: l10n.commonDelete,
  destructive: true,
);

final name = await ConfirmDialog.prompt(
  context,
  title: l10n.commonRename,
  initialText: chat.title,
  cancelLabel: l10n.commonCancel,
  confirmLabel: l10n.commonSave,
);
```

`confirm` возвращает `Future<bool>`, `prompt` возвращает `Future<String?>` (`null` при отмене).
Параметр `barrierDismissible` задаётся явно там, где закрытие по фону опасно (подтверждение
ключа хоста).

**`AppEmptyState`**: пустое состояние с иконкой, заголовком, пояснением и действием.

```dart
AppEmptyState(
  icon: Icons.chat_bubble_outline,
  title: l10n.chatsEmpty,
  action: FilledButton(onPressed: _createChat, child: Text(l10n.chatsNew)),
)
```

### Статусы и агент

**`StatusChip`** и **`StatusDot`**:

```dart
StatusChip(label: l10n.hostStatusOnline, tone: AppTone.success)
StatusDot(tone: AppTone.progress, pulse: isRunning)
```

`StatusDot` мерцает только при `pulse: true` и если система не запрашивает отключение анимаций.

**`ActionCard`**: карточка, которая ждёт решения пользователя (подтверждение команды,
вопрос агента). Содержимое передаётся в `children`, кнопки в `actions`.

```dart
ActionCard(
  title: l10n.approvalTitle,
  icon: Icons.lock_clock_outlined,
  tone: AppTone.waiting,
  actions: [
    TextButton(onPressed: _deny, child: Text(l10n.approvalDeny)),
    FilledButton(onPressed: _allow, child: Text(l10n.approvalApprove)),
  ],
  children: [
    CodeBlock(text: request.summary, maxHeight: 160),
    if (diff != null) DiffView(diff: diff),
  ],
)
```

**`CodeBlock`**: моноширинный блок с кнопкой копирования и ограничением высоты. Для текста, который
не является выводом процесса.

```dart
CodeBlock(text: request.summary, maxHeight: 160)
```

**`CopyButton`**: кнопка копирования. Текст берётся в момент нажатия через `textOf`, поэтому кнопку
можно ставить вне блока, чей текст она копирует. Для вывода терминала текст отдаёт `CommandOutputController`.

**`CommandOutput`**: терминал команды (пакет `xterm`). Занимает всю доступную ширину и интерпретирует
ANSI-последовательности и возврат каретки. Кнопки копирования нет: копирует владелец блока через
`CopyButton` и `CommandOutputController` (в шагах чата кнопка стоит в заголовке блока, рядом с «на всю высоту»).
Ширина скроллбара фиксирована через `ScrollbarTheme`. Видимая высота растёт по содержимому и анимируется.

Два режима:
- **Живой** (`terminal` передан, команда выполняется): терминал подключён к PTY команды на Host.
  Вывод PTY пишется в терминал, клавиши уходят в команду, изменение размера окна передаётся в PTY.
  Экран терминала всегда `maxHeight` (PTY получает стабильный размер, как у настоящей консоли),
  а видимая часть растёт по содержимому от одной строки до `maxHeight`.
- **Текстовый** (`terminal` не передан, завершённый или сохранённый запуск): вывод воспроизводится из `text`.
  Высота растёт по содержимому от одной строки до `maxHeight`.

`exitCode` выводит код выхода под выводом, когда команда завершилась.

```dart
CommandOutput(
  text: output,
  exitCode: run.exitCode,
  active: active,
  terminal: active ? terminalFor(run.id) : null,
  maxHeight: active ? 320 : 220,
)
```

Текст записывается в терминал инкрементально: живой вывод только растёт, и дописывается разница.
Если вывод перестал быть продолжением записанного, терминал пересоздаётся. Компонент нельзя
помещать в `IntrinsicHeight`/`IntrinsicWidth`: он считает строки через `LayoutBuilder`.

**`DiffView`**: построчная раскраска diff. Строки, начинающиеся с `+ ` — добавления, с `- ` —
удаления, остальные — нейтральные. Пустые строки сохраняются.

```dart
DiffView(diff: patch, maxHeight: 260)
```

**`ContextUsageBar`**: заполнение окна контекста. Цвет становится `error` при доле выше 0.9.

```dart
ContextUsageBar(
  label: l10n.contextUsage(used.toString(), limit.toString()),
  fraction: used / limit,
)
```

### Онбординг

**`OnboardingStepper`**: сегменты шагов и подпись счётчика. Подпись формирует ARB с
плейсхолдерами `current` и `total`.

```dart
OnboardingStepper(
  index: state.step.index,
  total: OnboardingStep.values.length,
  counterLabel: l10n.onboardingStepCounter(
    state.step.index + 1,
    OnboardingStep.values.length,
  ),
)
```

### Текст и Markdown

**`AppMarkdown`**: Markdown ответа агента в цветах текущей темы. Использовать вместо `MarkdownBlock`.

```dart
AppMarkdown(data: message.text)
```

Что задаёт компонент:

- Текст берётся из `textTheme` и `colorScheme`, а не из светлой палитры пакета.
- Inline-код скруглённый, на фоне `surfaceContainerHighest` и цвете `onSurface`: он виден и на
  светлом, и на тёмном фоне страницы. Блоки кода используют `AppColors.codeSurface` и `codeText`.
  Подсветка синтаксиса выбирается по токенам: ключевые слова, строки, комментарии.
- Ссылки в `primary`, цитаты и разделители в `outline` и `outlineVariant`, таблицы с фоном
  `surfaceContainerHigh`, маркеры списков в `onSurfaceVariant`.

Не менять `MarkdownConfig` в экранах. Новые правила оформления Markdown добавляются в
`lib/app/ui/app_markdown.dart`, чтобы все места ленты выглядели одинаково.

### Оформление

**`DashedBorder`**: пунктирная рамка вокруг содержимого. Используется для зоны перетаскивания
файлов (`DropTarget`).

```dart
DashedBorder(color: colors.waiting, radius: AppRadius.lg, child: ...)
```

## 5. Компоненты вне kit

Виджеты, которые живут рядом с экранами, но следуют тем же правилам:

| Виджет | Файл | Назначение |
| --- | --- | --- |
| `ChatView` | `lib/features/chat/presentation/widgets/chat_view.dart` | Экран чата: шапка (название и статус), лента, `ChatAttentionDock`, `ChatComposer`. Принимает перетаскивание файлов |
| `ChatTimeline` | `lib/features/chat/presentation/widgets/chat_timeline.dart` | Лента сообщений в колонке `chatMaxWidth`. Перевёрнутая: прокрутка от низа. Следует за концом ответа, пока пользователь там; при прокрутке вверх держит читаемый элемент на месте и показывает кнопку «К новым сообщениям». Последний ход прижат к верху окна, отступ в треть высоты остаётся внизу. Пустой чат показывает `ChatWelcome` |
| `ChatWelcome` | `lib/features/chat/presentation/widgets/chat_welcome.dart` | Приветствие пустого чата: иконка, заголовок, хост и три подсказки (`ActionChip`), которые заполняют поле ввода |
| `ChatMessageTile` | `lib/features/chat/presentation/widgets/chat_message_tile.dart` | Сообщение: пользователь (копировать, правка, удаление после) — действия появляются при наведении или фокусе. Ассистент — кнопка «Копировать» только под последним ответом, видна всегда; у остальных ответов ни кнопки, ни места |
| `ChatCompactionMarker` | `lib/features/chat/presentation/widgets/chat_message_tile.dart` | Метка над сообщениями, которые модель видит через сводку. Сводку можно раскрыть |
| `ChatStepLedger` | `lib/features/chat/presentation/widgets/chat_step_ledger.dart` | Шаги ответа: одна команда — строка без группы; несколько — группа с заголовком «N действий · Ошибок: M», длительностью и раскрываемыми строками с выводом. Группа свёрнута, если всё успешно; раскрыта при активной работе или внимании |
| `ChatAttentionDock` | `lib/features/chat/presentation/widgets/chat_attention_dock.dart` | Панель над композером: ошибка, доверие к папке, лимит шагов, подтверждение (`ActionCard` с `DiffView`), вопрос агента, очередь. Пустая, если решений нет |
| `ChatComposer` | `lib/features/chat/presentation/widgets/chat_composer.dart` | Компактная карточка ввода: кнопка «+» (меню: «Прикрепить файл», «Рабочая папка», подменю «Режим выполнения» Спрашивать / Авто-подтверждение), поле, вложения, строка настроек `ChatMetaBar` и одна кнопка действия справа: отправка при тексте (очередь во время работы), остановка при пустом поле и работающем агенте. `centered` — композер в пустом чате (больше строк поля). Подсказки клавиш нет. Подсвечивается при перетаскивании файлов |
| `ChatDensity` / `ChatDensityScope` | `lib/features/chat/presentation/widgets/chat_density.dart` | Плотность чата по ширине области: `regular`, `narrow`, `tiny`. Отступ колонки, отступы и скругление карточки композера (`composerRadius`), строки поля, высота текста и режим чипов (`iconOnlyChips`). Ставится в `ChatBody`, читается через `ChatDensityScope.of(context)`; без области — `regular` |
| `ChatColumn` | `lib/features/chat/presentation/widgets/chat_column.dart` | Единая колонка чата: `item(context, child)` для элементов ленты, `fixed(context, child)` для шапки, панели и композера. Ширина из `AppLayout.chatMaxWidth`, боковой отступ из `ChatDensity.gutter` |
| `ChatReveal` | `lib/features/chat/presentation/widgets/chat_motion.dart` | Раскрытие по высоте (шаги, вывод, вложения). Содержимое плавно раскрывается и сворачивается; закрытое содержимое не монтируется |
| `ChatMorph` | `lib/features/chat/presentation/widgets/chat_motion.dart` | Смена значения (иконка, метка, чип): размер подстраивается, новое содержимое проявляется. У ребёнка обязательно ключ |
| `ChatMetaBar` | `lib/features/chat/presentation/widgets/chat_meta_bar.dart` | Строка настроек под полем ввода. Все интерактивные чипы одного вида (значение и `▾`): хост — меню, папка и модель — диалог выбора, контекст — окно заполнения. Хост и папка недоступны во время работы агента. Чип папки появляется только при назначенной папке, чип контекста — только при данных о заполнении. Модель без значения — подсказка «Выбрать модель» с предупреждением. Заполнение от 90% подсвечивается. Ширина чипов меряется `TextPainter` до раскладки; если строка не помещается в область, чипы по одному сворачиваются до значков в порядке хост → папка → модель → контекст, значение уходит в подсказку. На `ChatDensity.tiny` все чипы только значки; на `narrow` значение мельче и короче. Внешний `SingleChildScrollView` — только страховка |
| `ChatContextDialog` | `lib/features/chat/presentation/widgets/chat_context_dialog.dart` | Диалог окна контекста: заполнение через `ContextUsageBar` и действие «Сжать историю». Сжатие недоступно без данных и во время работы |
| `ComposerInput` | `lib/features/chat/presentation/widgets/composer_input.dart` | Поле сообщения: Enter отправляет (или ставит в очередь во время работы), Shift+Enter переносит строку, Ctrl/Cmd+Enter во время работы отправляет сразу, IME не перехватывается. `maxLines` задаёт число строк до прокрутки (из `ChatDensity.composerMaxLines`), подсказка одна строка с многоточием |
| `ChatListPanel` | `lib/features/chats/presentation/widgets/chat_list_panel.dart` | Список чатов с группами «сегодня / вчера / раньше» и контекстным меню |
| `WorkspaceSidebar` | `lib/features/workspace/presentation/widgets/workspace_sidebar.dart` | Боковая панель: новый чат, `ChatListPanel`, навигация «Хосты» и «Настройки» внизу. Выбранный чат и активный раздел приходят из маршрутов. Сворачивается кнопкой |
| `WorkspaceRail` | `lib/features/workspace/presentation/widgets/workspace_sidebar.dart` | Свёрнутая панель: развернуть, новый чат, хосты, настройки (только иконки). Активный раздел выделен |
| `WorkspaceLeadingButton` | `lib/features/workspace/presentation/widgets/workspace_shell.dart` | Кнопка слева в шапке страницы на узком экране: меню (`WorkspaceMenuButton`), а поверх оболочки — «назад». В остальных раскладках страницы передают `null` |
| `ModelPickerDialog` | `lib/features/models/presentation/widgets/model_picker_dialog.dart` | Выбор модели: поиск, фильтр «с инструментами», закреплённые модели, группы по провайдеру, клавиатура |

## 6. Утилиты

| Функция | Файл | Назначение |
| --- | --- | --- |
| `dayBucket(DateTime, {now})` | `lib/core/util/short_time.dart` | Группа: `today`, `yesterday`, `earlier` |
| `formatShortTime(DateTime, {now})` | `lib/core/util/short_time.dart` | `HH:mm` для сегодня, иначе `dd.MM` |

## 7. Добавление нового компонента

1. Положить файл в `lib/app/ui/` и экспортировать его из `ui.dart`.
2. Все цвета брать из `AppTone` или `context.appColors`, все размеры из токенов.
3. Все тексты передавать параметрами или брать из `AppLocalizations`.
4. Добавить widget-тест в `test/app/ui/` (состояния, колбэки). Если компонент визуально
   устойчив, добавить его в галерею `ui_kit_golden_test.dart`.
5. Добавить строку в таблицу раздела 2 и описание в раздел 4 этого файла.
