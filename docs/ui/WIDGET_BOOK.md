# Каталог виджетов ProbablyWorks

Каталог описывает собственные виджеты в `packages/app_ui/lib/src/widgets/` и `lib/app/ui/`,
а также правило замены стандартных виджетов Material. Общие компоненты живут в `package:app_ui`,
прикладные — в `lib/app/ui/`. Экраны импортируют один файл:

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
| `TextField` / `TextFormField` | `AppTextField` | Все поля ввода. Есть `label`, `hint`, `helper`, `error`, `mono`, `suffix`, `suffixText`. |
| `Column` с заголовком и полями | `AppSection` | Группа полей или настроек с заголовком, описанием и действием справа. |
| `MaterialBanner`, встроенные `Container` с текстом | `AppBanner` | Статусы в потоке: предупреждение, ошибка, доверие к workspace, лимит шагов или бюджета. |
| `Card` + `Row` с кнопками (ожидание ответа) | `ActionCard` | Подтверждение команды агента, вопрос агента, очередь сообщений. |
| `MarkdownBlock` без конфига | `AppMarkdown` | Ответы агента. Пакетная палитра светлая: без конфига текст в тёмной теме нечитаем. |
| `Container` + моноширинный `Text` | `CodeBlock` | JSON, содержимое файлов, команды в подтверждении. Копирование встроено. |
| `Container` + `SelectableText` для вывода команды | `CommandOutput` | Команды агента в настоящем терминале (PTY на Host, пакет `xterm2`): ввод, размер, ANSI-цвета, код выхода. |
| Вывод инструмента `read_file` (строки с номерами) | `ReadFileView` | Содержимое файла, которое агент прочитал. Распознанный вывод после `parseReadFileOutput`; нераспознанный остаётся в `CommandOutput`. |
| Построчная раскраска `Text` | `DiffView` | Изменения файлов (`+` и `-` строки). Карточка подтверждения. |
| Запись и правка файла в журнале шага | `FileChangeView` | `write_file` как новый файл git (все строки добавлены), `edit_file` как unified diff фрагмента. |
| `Icon` + `Text` для статуса | `StatusChip` / `StatusDot` | Статус хоста, агента, процесса. Цвет берётся из `AppTone`. |
| `Center` + `Column` с иконкой | `AppEmptyState` | Пустые списки, пустой чат, отсутствие результатов поиска. |
| `AlertDialog` с кнопками «Отмена» и «OK» | `ConfirmDialog.confirm` | Подтверждение действия, в том числе деструктивного. |
| `AlertDialog` с `TextField` | `ConfirmDialog.prompt` | Переименование и короткий текстовый ввод. |
| `ScaffoldMessenger.showSnackBar` | `AppSnackBar.show` | Короткие результаты действий, с опциональным действием. |
| `LinearProgressIndicator` с подписью | `ContextUsageBar` | Заполнение контекста модели. Цвет меняется у предела. |
| `Stepper` или набор точек | `OnboardingStepper` | Шаги онбординга: сегменты и счётчик. |
| `Container` с `BoxDecoration` и штрихом | `DashedBorder` | Зона перетаскивания файлов и пустые слоты. |
| `SegmentedButton`, `RadioListTile` в списке для выбора одного варианта с пояснением | `AppChoiceGroup` | Настройки: тема, журнал шагов, политика, система хоста. Варианты карточками с радио-индикатором, делят ширину и переносятся. Без пояснений `SegmentedButton` допустим. |
| `DropdownMenu` без подписи рядом с текстовой подписью | `AppSelect` | Компактный выбор значения в строке: сортировка моделей, уровень размышлений. Без плавающей подписи и фильтра внутри меню. В формах остаётся `DropdownMenu` с `expandedInsets` |
| `Container` с подписью метаданных в строке списка | `MetaChip` | id модели, контекст, цена, возможности: данные, а не статус (без точки). Для статусов — `StatusChip` |

Стандартные виджеты, которые не заменены, допустимы: `ListView`, `ListTile`, `IconButton`,
`FilledButton`, `TextButton`, `OutlinedButton`, `SegmentedButton`, `FilterChip`,
`DropdownMenu`, `PopupMenuButton`, `NavigationRail`, `NavigationBar`, `Dialog` (для форм),
Внешний вид стандартных виджетов задаётся через тему (`AppTheme`). `MarkdownBlock` напрямую не используется, см. `AppMarkdown`.

## 3. Токены и тон

| Элемент | Назначение |
| --- | --- |
| `AppSpacing`, `AppRadius`, `AppDurations`, `AppBreakpoints`, `AppLayout` | Числовые константы (`packages/app_ui/lib/src/theme/app_tokens.dart`) |
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

**`AppSelect<T>`**: компактный селект для строки: значение, стрелка и меню. Подпись ставит владелец
рядом текстом, плавающей подписи и фильтра внутри меню нет — контрол читается как значение
настройки, а не как поле ввода. Ширина `null` растягивает на доступное место. Значение приходит
снаружи и синхронизируется с меню; выбор доступен с клавиатуры (`Tab`, `Enter`, стрелки).
Без `onChanged` контрол заблокирован. `tooltip` нужен там, где подпись рядом не помещается
(сортировка в узком диалоге выбора модели).

```dart
AppSelect<ModelSort>(
  value: sort,
  entries: [
    for (final sort in ModelSort.values)
      AppSelectEntry(value: sort, label: _sortLabel(sort, l10n)),
  ],
  width: AppLayout.selectWidth,
  onChanged: _changeSort,
)
```

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

Параметры: `controller`, `label`, `hint`, `helper`, `error`, `prefixIcon`, `suffix`, `suffixText` (единица
измерения внутри поля, например «байт»; вместо подписи), `obscure`,
`mono`, `enabled`, `readOnly` (поле сохраняет высоту и оформление, текст не редактируется), `autofocus`, `minLines`, `maxLines` (по умолчанию 1), `keyboardType`,
`onChanged`, `onSubmitted`, `focusNode`.

Поле сообщения в чате не является `AppTextField`: там нужен собственный обработчик клавиш
(`ComposerInput`, см. раздел 5).

**`AppChoiceGroup<T>`**: выбор одного варианта карточками. Каждый вариант: радио-индикатор, заголовок,
пояснение (`subtitle`, обязательное) и значок (`icon`: `Icon` или `AppSvgIcon`). По умолчанию значок стоит
справа от заголовка размером `iconSize` (18). Крупные значки (например, система на хосте, `iconSize: 40`)
ставятся над заголовком через `iconAboveTitle: true`, иначе справа они съедают ширину текста и названия
обрезаются. Карточки делят ширину поровну, минимальная ширина карточки 180, на узкой области переносятся. Все карточки группы одной высоты: заголовок в одну строку,
пояснение в две, лишнее обрезается многоточием. Полный текст показывает подсказка при наведении или долгом
нажатии: заголовок жирным и пояснение с новой строки. Выбор отдаётся через `onChanged`, семантика — `selected` в группе.

```dart
AppChoiceGroup<ThemeMode>(
  options: [
    AppChoiceOption(
      value: ThemeMode.system,
      title: l10n.settingsThemeSystem,
      subtitle: l10n.settingsThemeSystemHint,
      icon: Icon(Icons.brightness_auto_outlined),
    ),
    AppChoiceOption(
      value: ThemeMode.dark,
      title: l10n.settingsThemeDark,
      subtitle: l10n.settingsThemeHint,
    ),
  ],
  selected: state.themeMode,
  onChanged: cubit.saveThemeMode,
)
```

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

**`MetaChip`**: подпись метаданных строки (id модели, контекст, цена). Без точки состояния:
это данные, а не статус. `mono` включает моноширинный шрифт, `tone` задаёт смысловой цвет.
`icon` заменяет поясняющее слово: окно контекста — `Icons.data_usage` (как заполнение контекста
в `ChatMetaBar`), цена — `Icons.savings_outlined` (как бюджет в окне контекста), размышления —
`Icons.psychology` (как чип модели с включённым уровнем). Без `label` чип занимает только значок;
тогда `tooltip` обязателен: он объясняет значение при наведении и читается с экрана.

```dart
MetaChip(
  icon: Icons.data_usage,
  label: '128k',
  tooltip: l10n.modelMetaContext('128k'),
)
MetaChip(label: modelIdForDisplay(model.id, providers: providers), mono: true)
```

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
После нажатия две секунды показывает галочку. `richTooltip` заменяет стандартную подсказку
разметкой (например, «Скопировать id модели» и сам id в две строки), `focusNode` позволяет
владельцу показывать кнопку по фокусу с клавиатуры.

**`CommandOutput`**: терминал команды (пакет `xterm2`). Занимает всю доступную ширину и интерпретирует
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

**`ReadFileView`**: вид результата инструмента `read_file` (`lib/app/ui/read_file_view.dart`). Получает
разобранный вывод `parseReadFileOutput` (`packages/pw_agent/lib/host/read_file_output.dart`): строки с номерами, подвал
(конец файла, продолжение, обрезанная строка) или ожидаемую ошибку (бинарный файл, не обычный файл,
начало за концом). Скрипт awk/PowerShell в виде не показывается. Нераспознанный вывод отдаётся в
`CommandOutput`, поэтому парсер строгий: он возвращает `null`, а не угадывает. Текст строк проходит
через `plainTerminalText`, иначе ESC-последовательности из файла изменили бы вид. Номера выровнены по
самому большому номеру. Высота растёт по содержимому до `maxHeight`, дальше прокрутка. Номера стоят на месте
при горизонтальном скролле и едут вместе с текстом при вертикальном. Вертикальный и горизонтальный скроллбары
стоят по краям видимой области и имеют ту же толщину, что у `CommandOutput`. Подвал и ошибки
выводятся локализованными строками. Точка расширения под подсветку синтаксиса: `_lineSpan`.

```dart
ReadFileView(output: parsed, maxHeight: 220)
```

**`DiffView`**: построчная раскраска diff. Строки, начинающиеся с `+ ` — добавления, с `- ` —
удаления, остальные — нейтральные. Пустые строки сохраняются.

```dart
DiffView(diff: patch, maxHeight: 260)
```

**`FileChangeView`**: изменение файла в журнале шага (`lib/app/ui/file_change_view.dart`). Модель собирает
`fileChangeOf` (`lib/features/chat/presentation/file_change.dart`) из аргументов запуска, а не из вывода
команды: успешная запись ничего не печатает. `write_file` рисуется как новый файл git — все строки
добавлены, номера с 1, заголовок `@@ -0,0 +1,N @@`. `edit_file` — unified diff фрагмента `old_string` →
`new_string`: контекст без фона, удаления и добавления своими цветами, две колонки номеров. Номера
относятся к фрагменту, а не ко всему файлу. Длинное изменение обрезается, счётчики добавлений и удалений
остаются полными. `replace_all` подписывается над diff. В заголовке шага путь внутри рабочей папки
проекта заменяется именем файла; путь снаружи папки остаётся полным.

```dart
FileChangeView(change: change, maxHeight: 220)
```

**`ChatSnoozeButton`** и меню сроков (`lib/app/ui/chat_snooze_menu.dart`): действие
«Напомнить позже». Кнопка открывает меню из четырёх сроков — через час, сегодня вечером,
завтра утром, в ближайший рабочий день — и отдаёт выбранный момент в `onSelected`;
закрытие меню ничего не меняет. Срок считает клиент в локальной зоне, поэтому
«завтра утром» — это утро пользователя, а не сервера. Подпись срока
(`formatChatSnoozeUntil`) общая для карточки входящих и подсказки значка в списке чатов:
«сегодня, 18:00», «завтра, 09:00», «28.11, 09:00». Контекстное меню чата
открывает то же меню вторым шагом: Material не поддерживает вложенные меню.

```dart
ChatSnoozeButton(onSelected: (until) => cubit.snoozeAttention(chatId, until))
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
`packages/app_ui/lib/src/widgets/app_markdown.dart`, чтобы все места ленты выглядели одинаково.
`markdown_widget` всё ещё на `package:flutter/material.dart`: компонент оборачивает блок
в `MaterialUiCompatibilityBridge` и прозрачный `Material` того пакета, иначе `InkWell`
ссылки или картинки не находит предка (`Scaffold` приложения — это `Material` из `material_ui`).

**`AppSvgIcon`**: SVG из `assets/` для значка, которого нет в Material или который в Material не узнаётся
(логотипы систем). Размер и цвет берутся из `IconTheme`, как у `Icon`, поэтому значок реагирует на выбор и тему.
Пакет `flutter_svg`; ассеты перечислены в `pubspec.yaml`. Значки систем: `assets/icons/os_linux.svg` (пингвин),
`os_macos.svg` (яблоко), `os_windows.svg` (четыре окна). Все три нарисованы в сетке 24×24 с содержимым высотой
20 единиц, как у Material-иконок, поэтому при одном `iconSize` выглядят одинакового размера. Material-ноутбук
(`Icons.laptop_mac`) для систем не годится: одинаков для macOS и Windows.

```dart
AppChoiceOption(
  value: HostOs.posix,
  title: l10n.hostOsPosix,
  subtitle: l10n.hostOsPosixHint,
  icon: const AppSvgIcon('assets/icons/os_linux.svg'),
)
```

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
| `ChatTimeline` | `lib/features/chat/presentation/widgets/chat_timeline.dart` | Лента сообщений в колонке `chatMaxWidth`. Перевёрнутая: прокрутка от низа. Следует за концом ответа, пока пользователь там; при прокрутке вверх держит читаемый элемент на месте и показывает кнопку «К последним». Если у чата есть unread, открывается на первом непрочитанном сообщении и рисует нейтральный разделитель «Новые сообщения»; сам переход пузырь не подсвечивает и прочитанным не отмечает — это делает прокрутка вниз или «К последним». Скрытая вкладка или фоновое приложение unread тоже не снимают. Последний ход прижат к верху окна, отступ в треть высоты остаётся внизу. Пустой чат показывает `ChatWelcome` |
| `ChatWelcome` | `lib/features/chat/presentation/widgets/chat_welcome.dart` | Приветствие пустого чата: иконка, заголовок, хост и три подсказки (`ActionChip`), которые заполняют поле ввода |
| `ChatMessageTile` | `lib/features/chat/presentation/widgets/chat_message_tile.dart` | Сообщение: пользователь (копировать, правка) — действия появляются при наведении или фокусе. «Изменить» не открывает диалог: лента подменяет пузырь `ChatComposer`. Неотправленная правка остаётся текстом пузыря, сам пузырь красится в `primaryContainer`. Ассистент — кнопка «Копировать» под сообщением, которым закрыт каждый законченный ход (текст без вызовов, кроме `finish`; у идущего хода кнопки нет), видна всегда; у остальных ответов ни кнопки, ни места |
| `ChatCompactionMarker` | `lib/features/chat/presentation/widgets/chat_message_tile.dart` | Метка над сообщениями, которые модель видит через сводку. Сводку можно раскрыть |
| `ChatStepLedger` | `lib/features/chat/presentation/widgets/chat_step_ledger.dart` | Шаги ответа: одна команда — строка без группы; несколько — группа с заголовком «N действий · Сбоев вызова: M», длительностью и раскрываемыми строками с выводом. Группа свёрнута, если нет активной работы и внимания; раскрыта при активной работе, ожидании, таймауте или сбое вызова. Успешность вызова не показывается, ошибка результата инструмента группу не раскрывает |
| `ChatAttentionDock` | `lib/features/chat/presentation/widgets/chat_attention_dock.dart` | Панель над композером: ошибка, доверие к папке, лимит шагов или бюджета, подтверждение (`ActionCard` с `DiffView`), вопрос агента, очередь. Пустая, если решений нет |
| `ChatComposer` | `lib/features/chat/presentation/widgets/chat_composer.dart` | Компактная карточка ввода: кнопка «+» (меню: «Прикрепить файл», «Рабочая папка», подменю «Режим выполнения» Спрашивать / Авто-подтверждение и подменю «Размышления»), поле, вложения, строка настроек `ChatMetaBar` и одна кнопка действия справа: отправка при тексте (очередь во время работы), остановка при пустом поле и работающем агенте. `centered` — композер в пустом чате (больше строк поля). Подсказки клавиш нет. Подсвечивается при перетаскивании файлов. В ленте та же карточка (`embedded`, `editing`) заменяет пузырь пользователя: отправка правки, без остановки и без кнопки отмены. Свернуть её можно фокусом нижнего поля, Escape, закрытием или переключением чата; текст правки при этом сохраняется |
| `ChatDensity` / `ChatDensityScope` | `lib/features/chat/presentation/widgets/chat_density.dart` | Плотность чата по ширине области: `regular`, `narrow`, `tiny`. Отступ колонки, отступы и скругление карточки композера (`composerRadius`), строки поля, высота текста и режим чипов (`iconOnlyChips`). Ставится в `ChatBody`, читается через `ChatDensityScope.of(context)`; без области — `regular` |
| `ChatColumn` | `lib/features/chat/presentation/widgets/chat_column.dart` | Единая колонка чата: `item(context, child)` для элементов ленты, `fixed(context, child)` для шапки, панели и композера. Ширина из `AppLayout.chatMaxWidth`, боковой отступ из `ChatDensity.gutter` |
| `ChatReveal` | `lib/features/chat/presentation/widgets/chat_motion.dart` | Раскрытие по высоте (шаги, вывод, вложения). Содержимое плавно раскрывается и сворачивается; закрытое содержимое не монтируется |
| `ChatMorph` | `lib/features/chat/presentation/widgets/chat_motion.dart` | Смена значения (иконка, метка, чип): размер подстраивается, новое содержимое проявляется. У ребёнка обязательно ключ |
| `ChatMetaBar` | `lib/features/chat/presentation/widgets/chat_meta_bar.dart` | Строка настроек под полем ввода. Все интерактивные чипы одного вида (значение и `▾`): хост — меню, папка и модель — диалог выбора, контекст — окно заполнения. Хост и папка недоступны во время работы агента. Чип папки появляется только при назначенной папке, чип контекста — только при данных о заполнении. Модель без значения — подсказка «Выбрать модель» с предупреждением. Если у модели включён уровень размышлений, значок чипа модели меняется на `psychology`, а подсказка показывает уровень; отдельного чипа нет. Заполнение от 90% подсвечивается. Ширина чипов меряется `TextPainter` до раскладки; если строка не помещается в область, чипы по одному сворачиваются до значков в порядке хост → папка → модель → контекст, значение уходит в подсказку. На `ChatDensity.tiny` все чипы только значки; на `narrow` значение мельче и короче. Внешний `SingleChildScrollView` — только страховка |
| `ChatContextDialog` | `lib/features/chat/presentation/widgets/chat_context_dialog.dart` | Диалог окна контекста: заполнение через `ContextUsageBar`, разбивка запроса по строкам (системный промпт, история, результаты инструментов, вложения, схемы инструментов — символы и оценка токенов), приблизительный вес уходящего модели текста в килобайтах (UTF-8 текст плюс вложения, без обвязки запроса) и действие «Сжать историю». Сжатие недоступно без данных и во время работы |
| `ComposerInput` | `lib/features/chat/presentation/widgets/composer_input.dart` | Поле сообщения: Enter отправляет (или ставит в очередь во время работы), Shift+Enter переносит строку, Ctrl/Cmd+Enter во время работы отправляет сразу, IME не перехватывается. `maxLines` задаёт число строк до прокрутки (из `ChatDensity.composerMaxLines`), подсказка одна строка с многоточием |
| `InboxPage` | `lib/features/inbox/presentation/pages/inbox_page.dart` | Входящие: `ActionCard` с подтверждениями, вопросами и выбором отката файлов, проблемы хода и непрочитанное. Решение принимается на месте, каждый пункт ведёт в чат. Порядок задаёт срочность: решения, проблемы, непрочитанное. Снимок и счётчик приходят одним SSE-событием, поэтому список и бейдж панели не расходятся |
| `ChatListPanel` | `lib/features/chats/presentation/widgets/chat_list_panel.dart` | Список чатов с группами «сегодня / вчера / раньше» и контекстным меню. Непрочитанное показано числом справа и жирным названием; пока идёт ход или ждётся решение, приоритет у статуса. В меню есть «Отметить прочитанным» для чата с unread. У чата, открытого на другом экране, в строке стоит значок устройств с числом соседей; подсказка перечисляет их |
| `WorkspaceSidebar` | `lib/features/workspace/presentation/widgets/workspace_sidebar.dart` | Боковая панель: новый чат, строка «Входящие» со счётчиком решений, `ChatListPanel`, строка «Ещё N экранов» при подключённых соседях, навигация «Хосты» и «Настройки» внизу. Выбранный чат и активный раздел приходят из маршрутов. Сворачивается кнопкой |
| `WorkspaceRail` | `lib/features/workspace/presentation/widgets/workspace_sidebar.dart` | Свёрнутая панель: развернуть, новый чат, значок «Входящие» с бейджем, значок соседних экранов, хосты, настройки (только иконки). Активный раздел выделен |
| `ClientPresenceIconButton` / `ClientPresenceDialog` | `lib/features/workspace/presentation/widgets/client_presence.dart` | Присутствие клиентов: кнопка со счётчиком соседей и список подключённых экранов. Открытый список получает изменения потоком и обновляется без закрытия: экраны появляются, исчезают, меняют чат и фокус. В строке платформа, фокус, открытый чат и короткий фрагмент id сессии; переданный текущий экран идёт первым, затем активные окна. Фрагмент id различает одинаковые вкладки одного браузера. Чужой экран можно отключить по fingerprint: это уборка зависшей сессии, а не отзыв доступа; ошибка показывается внутри диалога |
| `WorkspacePresenceRail` | `lib/features/workspace/presentation/widgets/workspace_sidebar.dart` | Значок соседних экранов для `WorkspaceRail`: скрыт, когда других онлайн-сессий нет |
| `PresenceLifecycle` / `VisibleChatScope` | `lib/features/workspace/presentation/widgets/presence_lifecycle.dart` | Присутствие по маршруту: отправляет фокус и активный чат, слушает вкладки и стек чатов, чтобы активным считался только видимый чат. `VisibleChatScope` тем же признаком сообщает ленте, виден ли её чат: скрытая вкладка не отмечает новые сообщения прочитанными. При закрытии рабочей области профиля снимает открытый чат и фокус, иначе сессия осталась бы в списке экранов на исчезнувшем экране |
| `WorkspaceLeadingButton` | `lib/features/workspace/presentation/widgets/workspace_shell.dart` | Кнопка слева в шапке страницы на узком экране: меню (`WorkspaceMenuButton`), а поверх оболочки — «назад». В остальных раскладках страницы передают `null` |
| `ModelPickerDialog` | `lib/features/models/presentation/widgets/model_picker_dialog.dart` | Выбор модели: поиск и фильтры в одном поле (`@provider:`, `@free`, `@tools`) с подсказками, сортировка через `AppSelect` (запоминается в `ClientSettings`), закреплённые модели, группы по провайдеру, клавиатура. Свободный текст ищет по имени, id и провайдеру с учётом опечаток; группы по провайдеру показываются только без поиска. Состояния: загрузка, каталог не загружен, ошибка с повтором, пустой результат со сбросом фильтров; недоступные провайдеры и неверный `@provider:` — баннерами. `onTogglePin` задан — есть кнопки закрепления (композер, настройки закреплённых); `null` — кнопок нет (выбор модели по умолчанию и заголовков). `requireTools: false` — модель без tool calling выбирается, `true` — скрывается и показана подсказка «только с инструментами». `managePins: true` (настройки закреплённых) — нажатие на строку закрепляет или открепляет модель, диалог остаётся открытым и ничего не возвращает; Enter делает то же для подсвеченной строки. Модели с reasoning получают бейдж; после выбора модель может открыть `ReasoningDialog` |
| `ModelRuntimeBuilder` | `lib/features/models/presentation/widgets/model_runtime_builder.dart` | Точечная подписка на `ModelRuntimeSource`: перестраивает только переданный builder, а не ленту чата. Используется чипом модели и доком внимания, потому что прогресс загрузки приходит несколько раз в секунду |
| `ReasoningDialog` | `lib/features/models/presentation/widgets/reasoning_dialog.dart` | Второе окно после выбора модели: `AppChoiceGroup` с уровнями `Default` (для чата), `Auto`, `Off` (если разрешено) и поддерживаемыми уровнями. `Save` возвращает выбор, закрытие — null (оставить прежний уровень). Для mandatory-моделей `Off` скрыт; для неизвестной capability показывается общий набор |
| `HostFormDialog` | `lib/features/hosts/presentation/widgets/host_form_dialog.dart` | Диалог «Хост» (SSH-хост и «Этот компьютер»): строки `SettingsFormRow` в секциях `AppSection`, подписей над полями нет, у каждого поля есть подсказка. Способ входа и система на сервере — `AppChoiceGroup` с пояснениями; система — отдельная секция с крупными значками над заголовками. Ширина содержимого до `AppLayout.formMaxWidth`. Локальный хост редактирует только окружение. Сохранение через колбэк `onSave`, открывается `showHostFormDialog` |
| `ModelSettingField` | `lib/features/settings/presentation/widgets/model_setting_field.dart` | Поле модели в настройках: название, id и предупреждение о статусе (недоступна, нет tool calling). Нажатие открывает `ModelPickerDialog` без кнопок закрепления и, при необходимости, `ReasoningDialog`. Под карточкой — `AppSelect` уровня размышлений; для заголовков чата он скрыт, для модели без reasoning показано «не поддерживается» |
| `ApiKeyInfoCard` | `lib/features/settings/presentation/widgets/api_key_info_card.dart` | Сведения о ключе из сервиса: метка, расходы, лимит и остаток, сброс лимита, срок, тариф. Загрузка, ошибка с «повторить» и пустое состояние внутри карточки |
| `ProviderSection` | `lib/features/settings/presentation/widgets/provider_section.dart` | Блок провайдера на вкладке «Аккаунт»: строка `SettingsFormRow` с ключом API, поле ввода или маска `•••• abc`, проверка, замена и удаление с подтверждением. Черновик ключа живёт в виджете, не в состоянии экрана |
| `SettingsFormRow` | `lib/features/settings/presentation/widgets/settings_form_row.dart` | Строка формы: слева название и необязательное пояснение (`description`), справа поле. `trailing` — иконки действий в той же линии, что и поле (ключ API); `action` — кнопка под полем, прижатая справа (например «Сохранить» у многострочных полей). Ниже `AppLayout.formMaxWidth` колонки складываются. Заменяет «заголовок над полем с подписью». Используется в настройках и в диалоге хоста |

## 6. Утилиты

| Функция | Файл | Назначение |
| --- | --- | --- |
| `dayBucket(DateTime, {now})` | `packages/pw_agent/lib/core/util/short_time.dart` | Группа: `today`, `yesterday`, `earlier` |
| `formatShortTime(DateTime, {now})` | `packages/pw_agent/lib/core/util/short_time.dart` | `HH:mm` для сегодня, иначе `dd.MM` |
| `normalizeSearchText`, `scoreSearchText` | `lib/core/util/search_text.dart` | Нормализация и оценка совпадения для поиска: палитра команд и выбор модели. Термины, опечатки, префиксы |
| `AtQuery` | `lib/core/util/at_query.dart` | Разбор `@`-токенов строки поиска: границы, кавычки, имя и значение. Общий для палитры и выбора модели |

## 7. Добавление нового компонента

1. Общий компонент положить в `packages/app_ui/lib/src/widgets/` и экспортировать из
   `app_ui.dart`; прикладной — в `lib/app/ui/` и экспортировать из `ui.dart`.
2. Все цвета брать из `AppTone` или `context.appColors`, все размеры из токенов.
3. Все тексты передавать параметрами или брать из `AppLocalizations`.
4. Добавить widget-тест в `test/app/ui/` (состояния, колбэки). Если компонент визуально
   устойчив, добавить его в галерею `ui_kit_golden_test.dart`.
5. Добавить строку в таблицу раздела 2 и описание в раздел 4 этого файла.
