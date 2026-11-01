import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_colors.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/core/util/utf8_chunk_decoder.dart';
import 'package:probably_works/host/host_terminal.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:xterm/xterm.dart';

/// Терминал команды. Пока команда выполняется и передан [terminal], виджет подключён к её PTY:
/// вывод идёт из Host, клавиши уходят в команду, размер окна передаётся в PTY.
/// Без [terminal] (завершённый или сохранённый запуск) вывод воспроизводится из [text].
///
/// Занимает всю доступную ширину. Высота активного терминала фиксирована (как у настоящей консоли),
/// завершённого — растёт по содержимому до [maxHeight].
class CommandOutput extends StatefulWidget {
  const CommandOutput({
    required this.text,
    this.exitCode,
    this.active = false,
    this.terminal,
    this.maxHeight = 240,
    super.key,
  });

  /// Весь вывод команды. Используется, когда терминала нет. Живой вывод только растёт в конце,
  /// поэтому дописывается разница.
  final String text;

  /// Код выхода: показывается под выводом, когда команда завершилась.
  final int? exitCode;

  /// Команда ещё выполняется.
  final bool active;

  /// Терминал команды на Host (PTY). Вывод, ввод и размер идут через него, пока команда активна.
  final HostTerminal? terminal;

  final double maxHeight;

  @override
  State<CommandOutput> createState() => _CommandOutputState();
}

class _CommandOutputState extends State<CommandOutput> {
  static const _style = TerminalStyle(
    fontSize: 12.5,
    height: 1.5,
    fontFamily: AppTheme.monoFamily,
  );
  static const _padding = EdgeInsets.fromLTRB(
    AppSpacing.md,
    AppSpacing.md,
    AppSpacing.xxl,
    AppSpacing.md,
  );
  static const _maxLines = 10000;
  static const _showCursor = '\x1b[?25h';
  static const _hideCursor = '\x1b[?25l';

  /// Одиночный перевод строки без возврата каретки: в терминале он сдвигает строку без сброса столбца.
  static final _lineFeed = RegExp(r'(?<!\r)\n');
  static final _escape = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
  static final _trailingBlanks = RegExp(r'[ \t]+$', multiLine: true);

  late Terminal _terminal;

  /// Новый терминал пересоздаёт TerminalView, поэтому старый вывод не склеивается с новым.
  var _generation = 0;

  /// Текст, уже записанный в терминал (режим текста).
  var _written = '';

  /// Курсор виден, пока команда выполняется: в завершённом выводе он не нужен.
  var _cursorShown = true;
  var _copied = false;

  /// Терминал Host, к которому подключён виджет. `null` — режим текста.
  HostTerminal? _host;
  StreamSubscription<Uint8List>? _feed;
  var _decoder = Utf8ChunkDecoder();

  @override
  void initState() {
    super.initState();
    _reset();
    final host = widget.terminal;
    if (host != null) _attach(host);
    _sync();
  }

  @override
  void didUpdateWidget(covariant CommandOutput oldWidget) {
    super.didUpdateWidget(oldWidget);
    final host = widget.terminal;
    if (host != null && !identical(host, _host)) _attach(host);
    _sync();
  }

  @override
  void dispose() {
    unawaited(_feed?.cancel());
    super.dispose();
  }

  void _reset() {
    _terminal = Terminal(maxLines: _maxLines);
    _written = '';
    _cursorShown = true;
    _generation++;
  }

  /// Подключает терминал Host: вывод PTY (с историей) пишется в терминал, ввод и размер уходят обратно.
  /// Текст, который уже был показан, заменяется живым выводом, чтобы не дублировать его.
  void _attach(HostTerminal host) {
    if (_host == null) _reset();
    unawaited(_feed?.cancel());
    _host = host;
    _decoder = Utf8ChunkDecoder();
    _terminal.onOutput = (data) =>
        host.write(Uint8List.fromList(utf8.encode(data)));
    _terminal.onResize = (columns, rows, _, _) => host.resize(columns, rows);
    _feed = host.attach().listen(
      (bytes) => _terminal.write(_decoder.add(bytes)),
      onDone: () => _terminal.write(_decoder.close()),
    );
  }

  /// Режим текста: дописывает в терминал то, что добавилось с прошлого раза. Если вывод перестал быть
  /// продолжением записанного (например, сменился сохранённым), терминал пересоздаётся.
  /// В режиме терминала вывод приходит из PTY, поэтому текст игнорируется.
  void _sync() {
    if (_host == null) {
      final text = widget.text;
      if (!text.startsWith(_written)) _reset();
      if (text.length > _written.length) {
        _terminal.write(
          text.characters
              .skip(_written.characters.length)
              .string
              .replaceAll(_lineFeed, '\r\n'),
        );
        _written = text;
      }
    }
    if (_cursorShown != widget.active) {
      _cursorShown = widget.active;
      _terminal.write(widget.active ? _showCursor : _hideCursor);
    }
  }

  Future<void> _copy() async {
    // Копируем текст без хвостовых пробелов строк и пустых строк внизу, которые терминал добавляет сам.
    final text = _terminal.buffer
        .getText()
        .replaceAll(_trailingBlanks, '')
        .trimRight();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = context.appColors;
    final cell = _measureCell();
    final exitCode = widget.exitCode;
    final live = _host != null;
    final interactive = live && widget.active;

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
            final maxRows = ((widget.maxHeight - vertical) / cell.height)
                .floor()
                .clamp(1, 1 << 20);
            final rows = interactive
                ? maxRows
                : live
                ? _clampRows(
                    _rowsFor(_terminal.buffer.getText(), columns),
                    maxRows,
                  )
                : _clampRows(_rowsFor(widget.text, columns), maxRows);

            return Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: rows * cell.height + vertical,
                      child: TerminalView(
                        _terminal,
                        key: ValueKey(_generation),
                        theme: _terminalTheme(colors, theme.colorScheme),
                        textStyle: _style,
                        padding: _padding,
                        readOnly: !interactive,
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
                          style: TextStyle(
                            fontFamily: AppTheme.monoFamily,
                            fontSize: 12,
                            color: colors.codeText.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                  ],
                ),
                Positioned(
                  top: AppSpacing.xs,
                  right: AppSpacing.xs,
                  child: IconButton(
                    tooltip: l10n.commonCopy,
                    visualDensity: VisualDensity.compact,
                    color: colors.codeText,
                    icon: Icon(
                      _copied ? Icons.check : Icons.copy_outlined,
                      size: 16,
                    ),
                    onPressed: _copy,
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
