import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_colors.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/command_prompt.dart';
import 'package:probably_works/core/util/utf8_chunk_decoder.dart';
import 'package:probably_works/host/host_terminal.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:xterm/xterm.dart';

/// Доступ к тексту терминала снаружи виджета, например для кнопки копирования в заголовке блока.
/// Пока виджет смонтирован, [text] — то, что видно в терминале (без хвостовых пробелов); иначе пусто.
class CommandOutputController {
  String Function()? _read;

  String get text => _read?.call() ?? '';
}

/// Терминал команды. Пока команда выполняется и передан [terminal], виджет подключён к её PTY:
/// вывод идёт из Host, клавиши уходят в команду, размер окна передаётся в PTY.
/// Без [terminal] (завершённый или сохранённый запуск) вывод воспроизводится из [text].
///
/// Занимает всю доступную ширину. Экран терминала всегда [maxHeight] (как у настоящей консоли, PTY
/// получает стабильный размер), а видимая часть растёт по содержимому от одной строки до [maxHeight].
///
/// Если передана [command], первой строкой выводится `$ команда` с подсветкой (см. [commandPromptLine]).
class CommandOutput extends StatefulWidget {
  const CommandOutput({
    required this.text,
    this.command,
    this.exitCode,
    this.active = false,
    this.terminal,
    this.maxHeight = 240,
    this.controller,
    super.key,
  });

  /// Команда, которая выполняется. Выводится строкой промпта перед выводом.
  final String? command;

  /// Весь вывод команды. Используется, когда терминала нет. Живой вывод только растёт в конце,
  /// поэтому дописывается разница.
  final String text;

  /// Код выхода: показывается под выводом, когда команда завершилась.
  final int? exitCode;

  /// Команда ещё выполняется.
  final bool active;

  /// Терминал команды на Host (PTY). Вывод, ввод и размер идут через него, пока команда активна.
  final HostTerminal? terminal;

  /// Предел высоты видимой части. Бесконечный предел: видна вся запись по содержимому.
  /// Для команды с живым PTY предел должен быть конечным: высота задаёт размер экрана, а значит и размер PTY.
  final double maxHeight;

  /// Позволяет читать текст вывода снаружи, например для копирования.
  final CommandOutputController? controller;

  @override
  State<CommandOutput> createState() => _CommandOutputState();
}

class _CommandOutputState extends State<CommandOutput> {
  static const _style = TerminalStyle(
    fontSize: 12.5,
    height: 1.5,
    fontFamily: AppTheme.monoFamily,
  );
  static const _padding = EdgeInsets.all(AppSpacing.md);
  static const _maxLines = 10000;

  /// Толщина скроллбара терминала.
  static const _scrollbarThickness = 8.0;

  /// Одиночный перевод строки без возврата каретки: в терминале он сдвигает строку без сброса столбца.
  static final _lineFeed = RegExp(r'(?<!\r)\n');
  static final _escape = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
  static final _trailingBlanks = RegExp(r'[ \t]+$', multiLine: true);

  late Terminal _terminal;

  /// Новый терминал пересоздаёт TerminalView, поэтому старый вывод не склеивается с новым.
  var _generation = 0;

  /// Текст, уже записанный в терминал (режим текста).
  var _written = '';

  /// Терминал Host, к которому подключён виджет. `null` — режим текста.
  HostTerminal? _host;
  StreamSubscription<Uint8List>? _feed;
  var _decoder = Utf8ChunkDecoder();

  /// Прокрутка TerminalView. Нужна, чтобы сохранять вид, когда вывод вытесняет строки из буфера.
  final _scroll = ScrollController();

  /// Допуск, с которым считаем, что вид стоит внизу (там xterm сам держит конец вывода).
  static const _atBottomSlack = 0.5;

  @override
  void initState() {
    super.initState();
    _reset();
    final host = widget.terminal;
    if (host != null) _attach(host);
    _sync();
    _bindController(widget.controller);
  }

  @override
  void didUpdateWidget(covariant CommandOutput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller?._read = null;
      _bindController(widget.controller);
    }
    if (widget.command != oldWidget.command) {
      // Строка команды стоит в начале терминала: при смене команды терминал пересоздаётся.
      unawaited(_feed?.cancel());
      _feed = null;
      _host = null;
      _reset();
    }
    final host = widget.terminal;
    if (host != null && !identical(host, _host)) _attach(host);
    _sync();
  }

  @override
  void dispose() {
    widget.controller?._read = null;
    unawaited(_feed?.cancel());
    _scroll.dispose();
    super.dispose();
  }

  void _bindController(CommandOutputController? controller) {
    controller?._read = () => _plainText;
  }

  /// Строка `$ команда` для терминала; пустая строка, если команды нет.
  String get _prompt => commandPromptLine(widget.command ?? '');

  void _reset() {
    _terminal = Terminal(maxLines: _maxLines)..setCursorVisibleMode(false);
    _terminal.onResize = _onResize;
    _terminal.write(_prompt);
    _written = '';
    _generation++;
  }

  /// Экран терминала меняет размер при раскладке. Видимые строки зависят от буфера, который при этом
  /// переразбивается по ширине, поэтому перестраиваемся уже после кадра.
  void _onResize(int columns, int rows, int _, int _) {
    _host?.resize(columns, rows);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {
          return;
        });
      }
    });
  }

  /// Подключает терминал Host: вывод PTY (с историей) пишется в терминал, ввод и размер уходят обратно.
  /// Текст, который уже был показан, заменяется живым выводом, чтобы не дублировать его.
  void _attach(HostTerminal host) {
    if (_host == null) _reset();
    unawaited(_feed?.cancel());
    _host = host;
    _decoder = Utf8ChunkDecoder();
    // Ввода с клавиатуры нет: терминал только отображает вывод, поэтому onOutput не назначается.
    _feed = host.attach().listen(
      (bytes) => setState(() => _write(_decoder.add(bytes))),
      onDone: () => setState(() => _write(_decoder.close())),
    );
  }

  /// Пишет в терминал. Курсор выключен всегда, в том числе когда программа сама включает его (`?25h`).
  void _write(String data) {
    _writeKeepingView(data);
    _terminal.setCursorVisibleMode(false);
  }

  /// Пишет в терминал и сохраняет вид, если пользователь прокрутил вверх.
  ///
  /// Когда буфер полон, новые строки вытесняют самые старые. Видимые строки при этом сдвигаются,
  /// а позиция прокрутки в пикселях остаётся прежней, и вид уезжает к новому выводу. Поэтому
  /// позицию сдвигаем на число вытесненных строк. Число находим по индексу последней строки:
  /// вытеснение уменьшает её индекс, а сама она вытеснена только при записи целого буфера.
  void _writeKeepingView(String data) {
    final position = _scroll.hasClients && _scroll.positions.length == 1
        ? _scroll.position
        : null;
    if (position == null ||
        position.pixels >= position.maxScrollExtent - _atBottomSlack) {
      _terminal.write(data);
      return;
    }
    final lines = _terminal.buffer.lines;
    final last = lines[lines.length - 1];
    final indexBefore = last.index;
    // Высота строки: вся прокручиваемая высота делится на число строк буфера.
    final lineHeight =
        (position.maxScrollExtent + position.viewportDimension) / lines.length;
    _terminal.write(data);
    if (!last.attached) return;
    final dropped = indexBefore - last.index;
    if (dropped <= 0) return;
    position.jumpTo(max(0, position.pixels - dropped * lineHeight));
  }

  /// Режим текста: дописывает в терминал то, что добавилось с прошлого раза. Если вывод перестал быть
  /// продолжением записанного (например, сменился сохранённым), терминал пересоздаётся.
  /// В режиме терминала вывод приходит из PTY, поэтому текст игнорируется.
  void _sync() {
    if (_host == null) {
      final text = widget.text;
      if (!text.startsWith(_written)) _reset();
      if (text.length > _written.length) {
        _write(
          text.characters
              .skip(_written.characters.length)
              .string
              .replaceAll(_lineFeed, '\r\n'),
        );
        _written = text;
      }
    }
  }

  /// Текст для копирования без хвостовых пробелов строк и пустых строк внизу, которые терминал добавляет сам.
  String get _plainText =>
      _terminal.buffer.getText().replaceAll(_trailingBlanks, '').trimRight();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = context.appColors;
    final cell = _measureCell();
    final exitCode = widget.exitCode;
    final live = _host != null;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.codeSurface,
        borderRadius: AppRadius.mdAll,
      ),
      child: ClipRRect(
        borderRadius: AppRadius.mdAll,
        child: LayoutBuilder(
          builder: (context, constraints) {
            const vertical = AppSpacing.md * 2;
            final columns =
                ((constraints.maxWidth - _padding.horizontal) / cell.width)
                    .floor()
                    .clamp(1, 1 << 20);
            final contentRows = live
                ? _terminalRows()
                : _rowsFor(_prompt + widget.text, columns);
            final maxRows = widget.maxHeight.isFinite
                ? ((widget.maxHeight - vertical) / cell.height).floor().clamp(
                    1,
                    1 << 20,
                  )
                : contentRows.clamp(1, _maxLines);
            final screenHeight = maxRows * cell.height + vertical;
            final rows = _clampRows(contentRows, maxRows);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Экран терминала остаётся полной высоты, видна только часть по содержимому.
                // Высота видимой части растёт плавно. Обрезка снаружи не даёт выйти за анимируемую высоту.
                ClipRect(
                  child: AnimatedSize(
                    duration: AppDurations.fast,
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      key: const ValueKey('command-output-viewport'),
                      height: rows * cell.height + vertical,
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.topCenter,
                          minHeight: screenHeight,
                          maxHeight: screenHeight,
                          // Толщина скроллбара фиксирована: иначе он менял бы ширину вывода при наведении.
                          child: ScrollbarTheme(
                            data: const ScrollbarThemeData(
                              thickness: WidgetStatePropertyAll(
                                _scrollbarThickness,
                              ),
                            ),
                            // Скроллбар строим снаружи, у края вывода. Встроенный Scrollable ставит его
                            // внутрь отступов TerminalView, поэтому он отступал бы от края на весь padding.
                            child: Scrollbar(
                              controller: _scroll,
                              child: ScrollConfiguration(
                                behavior: ScrollConfiguration.of(context)
                                    .copyWith(scrollbars: false),
                                child: TerminalView(
                                  _terminal,
                                  key: ValueKey(_generation),
                                  scrollController: _scroll,
                                  theme: _terminalTheme(
                                    colors,
                                    theme.colorScheme,
                                  ),
                                  textStyle: _style,
                                  padding: _padding,
                                  // Ввод с клавиатуры запрещён на всех платформах: вывод только для чтения.
                                  readOnly: true,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (exitCode case final code? when !widget.active)
                  Padding(
                    padding: const EdgeInsets.only(
                      left: AppSpacing.md,
                      right: AppSpacing.md,
                      bottom: AppSpacing.md,
                    ),
                    child: Text(
                      l10n.runExitCode(code),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: AppTheme.monoFamily,
                        fontSize: 12,
                        color: colors.codeText.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  static int _clampRows(int rows, int maxRows) =>
      rows < 1 ? 1 : (rows > maxRows ? maxRows : rows);

  /// Размер ячейки считаем так же, как xterm: по строке из десяти символов.
  static ({double width, double height}) _measureCell() {
    const sample = 'mmmmmmmmmm';
    final painter = TextPainter(
      text: TextSpan(text: sample, style: _style.toTextStyle()),
      textDirection: TextDirection.ltr,
    )..layout();
    final cell = (width: painter.width / sample.length, height: painter.height);
    painter.dispose();
    return cell;
  }

  /// Строки буфера терминала до последней непустой. Буфер всегда занимает весь экран, поэтому пустые
  /// строки внизу не считаем: вывод растёт от одной строки. Пустой терминал занимает одну строку.
  int _terminalRows() {
    final lines = _terminal.buffer.lines;
    for (var i = lines.length - 1; i > 0; i--) {
      if (lines[i].getText().trim().isNotEmpty) return i + 1;
    }
    return 1;
  }

  /// Число строк экрана, которое займёт вывод при переносе по [columns] столбцам.
  static int _rowsFor(String text, int columns) {
    final plain = text.replaceAll(_escape, '').replaceAll('\r', '').trimRight();
    if (plain.isEmpty) return 1;
    var rows = 0;
    for (final line in plain.split('\n')) {
      rows += line.isEmpty ? 1 : (line.length / columns).ceil();
    }
    return rows;
  }

  /// Палитра ANSI из стандартной темы xterm; фон и текст берём из токенов кода приложения.
  static TerminalTheme _terminalTheme(AppColors colors, ColorScheme scheme) {
    const palette = TerminalThemes.defaultTheme;
    return TerminalTheme(
      cursor: colors.codeText,
      selection: scheme.primary.withValues(alpha: 0.35),
      foreground: colors.codeText,
      background: colors.codeSurface,
      black: palette.black,
      red: palette.red,
      green: palette.green,
      yellow: palette.yellow,
      blue: palette.blue,
      magenta: palette.magenta,
      cyan: palette.cyan,
      white: palette.white,
      brightBlack: palette.brightBlack,
      brightRed: palette.brightRed,
      brightGreen: palette.brightGreen,
      brightYellow: palette.brightYellow,
      brightBlue: palette.brightBlue,
      brightMagenta: palette.brightMagenta,
      brightCyan: palette.brightCyan,
      brightWhite: palette.brightWhite,
      searchHitBackground: palette.searchHitBackground,
      searchHitBackgroundCurrent: palette.searchHitBackgroundCurrent,
      searchHitForeground: palette.searchHitForeground,
    );
  }
}
