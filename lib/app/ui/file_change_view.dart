import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_colors.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/core/util/ansi_text.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Как показывать изменение: весь файл как добавленный или diff фрагмента.
enum FileChangeKind { created, edited }

/// Роль строки в unified diff.
enum FileChangeLineKind { context, addition, removal }

/// Одна строка изменения. Номера относятся к показанному фрагменту, а не к целому файлу:
/// у `edit_file` в аргументах нет окружающего текста, поэтому отсчёт начинается с 1.
class FileChangeLine {
  const FileChangeLine({
    required this.kind,
    required this.text,
    this.oldNumber,
    this.newNumber,
  });

  final FileChangeLineKind kind;
  final String text;

  /// Номер строки в старом фрагменте. Пусто у чистого добавления.
  final int? oldNumber;

  /// Номер строки в новом фрагменте. Пусто у чистого удаления.
  final int? newNumber;
}

/// Изменение файла, которое рисует [FileChangeView].
///
/// [lines] может быть короче полного изменения: длинная запись обрезается, чтобы не строить
/// тысячи виджетов в ленте. [added] и [removed] при этом считаются по всему изменению.
class FileChange {
  const FileChange({
    required this.kind,
    required this.path,
    required this.lines,
    required this.added,
    required this.removed,
    required this.copyText,
    required this.totalLines,
    this.hunkHeader = '',
    this.replaceAll = false,
  });

  final FileChangeKind kind;

  /// Путь в заголовке шага. Пустая строка — путь не удалось прочитать из запуска.
  final String path;
  final List<FileChangeLine> lines;

  /// Добавленные строки всего изменения, включая скрытый хвост.
  final int added;

  /// Удалённые строки всего изменения, включая скрытый хвост.
  final int removed;

  /// Текст кнопки копирования: содержимое нового файла или unified diff правки.
  final String copyText;

  /// Строк в изменении до отсечения. Больше [lines.length] — вид показывает подвал.
  final int totalLines;

  /// Заголовок хунка `@@ -a,b +c,d @@`. Пустой, если показывать нечего.
  final String hunkHeader;

  /// `edit_file` с `replace_all`: тот же фрагмент заменён во всех местах файла.
  final bool replaceAll;

  bool get truncated => lines.length < totalLines;
}

/// Вид записи или правки файла в журнале шага.
///
/// Новый файл выглядит как `git diff` против пустого: все строки добавлены, номера идут с 1,
/// заголовок хунка `@@ -0,0 +1,N @@`. Правка — unified diff фрагмента: контекст без фона,
/// удаления и добавления своими цветами, две колонки номеров. Номера при горизонтальной
/// прокрутке остаются на месте и едут вместе с текстом по вертикали, как у вида чтения файла.
/// Текст строк проходит через [plainTerminalText], иначе ESC-последовательности из файла
/// поменяли бы вид.
class FileChangeView extends StatelessWidget {
  const FileChangeView({required this.change, this.maxHeight = 240, super.key});

  final FileChange change;

  /// Предел высоты колонки строк. Подписи сверху и снизу в него не входят.
  final double maxHeight;

  /// Шрифт совпадает с видом чтения файла и выводом команд.
  ///
  /// Интервалы заданы явно. Незаданный [TextStyle.letterSpacing] не сбрасывает
  /// интервал родительского спана, строка рисуется шире [TextPainter], и хвост обрезается.
  static const _style = TextStyle(
    inherit: false,
    fontFamily: AppTheme.monoFamily,
    fontSize: 12.5,
    fontWeight: FontWeight.w400,
    height: 1.5,
    letterSpacing: 0,
    wordSpacing: 0,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.appColors;
    final caption = colors.codeText.withValues(alpha: 0.7);
    final change = this.change;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.codeSurface,
        borderRadius: AppRadius.mdAll,
      ),
      child: ClipRRect(
        borderRadius: AppRadius.mdAll,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (change.replaceAll)
              _DiffCaption(l10n.fileChangeReplaceAll, color: caption),
            if (change.hunkHeader.isNotEmpty)
              _DiffCaption(change.hunkHeader, color: caption),
            if (change.lines.isEmpty)
              _DiffCaption(l10n.readFileEmpty, color: caption)
            else
              _FileChangeBody(change: change, maxHeight: maxHeight),
            if (change.truncated)
              _DiffCaption(
                l10n.fileChangeTruncated(
                  change.lines.length,
                  change.totalLines,
                ),
                color: caption,
              ),
          ],
        ),
      ),
    );
  }
}

/// Подпись над или под колонкой строк: заголовок хунка, замена всех вхождений, обрезка.
class _DiffCaption extends StatelessWidget {
  const _DiffCaption(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.md,
      vertical: AppSpacing.xs,
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: FileChangeView._style.copyWith(fontSize: 12, color: color),
    ),
  );
}

Color? _fill(FileChangeLineKind kind, AppColors colors) => switch (kind) {
  FileChangeLineKind.addition => colors.diffAdd,
  FileChangeLineKind.removal => colors.diffRemove,
  FileChangeLineKind.context => null,
};

TextStyle _textStyle(FileChangeLineKind kind, AppColors colors) =>
    FileChangeView._style.copyWith(
      color: switch (kind) {
        FileChangeLineKind.addition => colors.diffAddText,
        FileChangeLineKind.removal => colors.diffRemoveText,
        FileChangeLineKind.context => colors.codeText,
      },
    );

/// Номера и знак. Контекст приглушён: это не изменение, а опора для глаз.
TextStyle _gutterStyle(FileChangeLineKind kind, AppColors colors) =>
    FileChangeView._style.copyWith(
      color: switch (kind) {
        FileChangeLineKind.addition => colors.diffAddText,
        FileChangeLineKind.removal => colors.diffRemoveText,
        FileChangeLineKind.context => colors.codeText.withValues(alpha: 0.5),
      },
    );

String _sign(FileChangeLineKind kind) => switch (kind) {
  FileChangeLineKind.addition => '+',
  FileChangeLineKind.removal => '-',
  FileChangeLineKind.context => '',
};

/// Ширины колонок. Считаются одним [TextPainter]: высота строки общая, цифры моноширинные.
class _Measure {
  const _Measure({
    required this.rowHeight,
    required this.oldWidth,
    required this.newWidth,
    required this.signWidth,
    required this.textWidth,
    required this.gutterWidth,
  });

  factory _Measure.compute(
    FileChange change,
    TextStyle style,
    TextScaler textScaler,
  ) {
    // Тот же масштаб, что у [Text]: иначе увеличенный текст шире колонки и обрезается.
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    );
    try {
      painter
        ..text = TextSpan(text: '0', style: style)
        ..layout();
      final rowHeight = painter.height;

      painter
        ..text = TextSpan(text: '+', style: style)
        ..layout();
      final signWidth = painter.width;

      var oldDigits = 0;
      var newDigits = 0;
      var textWidth = 0.0;
      for (final line in change.lines) {
        final old = line.oldNumber;
        final next = line.newNumber;
        if (old != null && '$old'.length > oldDigits) {
          oldDigits = '$old'.length;
        }
        if (next != null && '$next'.length > newDigits) {
          newDigits = '$next'.length;
        }
        painter
          ..text = TextSpan(text: plainTerminalText(line.text), style: style)
          ..layout();
        textWidth = math.max(textWidth, painter.width);
      }
      final oldWidth = _digitsWidth(painter, style, oldDigits);
      final newWidth = _digitsWidth(painter, style, newDigits);
      return _Measure(
        rowHeight: rowHeight,
        oldWidth: oldWidth,
        newWidth: newWidth,
        signWidth: signWidth,
        textWidth: textWidth,
        gutterWidth: _pad * 2 + _join(oldWidth, _join(newWidth, signWidth)),
      );
    } finally {
      painter.dispose();
    }
  }

  final double rowHeight;
  final double oldWidth;
  final double newWidth;
  final double signWidth;
  final double textWidth;
  final double gutterWidth;

  static const _pad = AppSpacing.sm;
  static const _gap = AppSpacing.xs;

  static double _digitsWidth(TextPainter painter, TextStyle style, int digits) {
    if (digits == 0) return 0;
    painter
      ..text = TextSpan(text: '0' * digits, style: style)
      ..layout();
    return painter.width;
  }

  /// Две соседние колонки и зазор между ними. Нулевая колонка зазора не добавляет.
  static double _join(double left, double right) =>
      left == 0 || right == 0 ? left + right : left + _gap + right;
}

class _Tint extends StatelessWidget {
  const _Tint({required this.color, required this.child});

  final Color? color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final color = this.color;
    if (color == null) return child;
    return ColoredBox(color: color, child: child);
  }
}

/// Колонка строк: номера и знаки стоят на месте, текст листается по горизонтали.
class _FileChangeBody extends StatefulWidget {
  const _FileChangeBody({required this.change, required this.maxHeight});

  final FileChange change;
  final double maxHeight;

  static const _scrollbarThickness = 8.0;

  static bool _anyNotification(ScrollNotification _) => true;

  @override
  State<_FileChangeBody> createState() => _FileChangeBodyState();
}

class _FileChangeBodyState extends State<_FileChangeBody> {
  final _rows = ScrollController();
  final _numbers = ScrollController();
  final _columns = ScrollController();

  @override
  void initState() {
    super.initState();
    _rows.addListener(() => _follow(_numbers, _rows));
    _numbers.addListener(() => _follow(_rows, _numbers));
  }

  @override
  void dispose() {
    _rows.dispose();
    _numbers.dispose();
    _columns.dispose();
    super.dispose();
  }

  /// Переводит [to] на смещение [from]. После первого перевода смещения совпадают,
  /// и второй контроллер больше не сдвигает первый.
  static void _follow(ScrollController to, ScrollController from) {
    if (!to.hasClients || !from.hasClients) return;
    if (to.offset != from.offset) to.jumpTo(from.offset);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final lines = widget.change.lines;
    final measure = _Measure.compute(
      widget.change,
      FileChangeView._style,
      MediaQuery.textScalerOf(context),
    );
    final naturalHeight = lines.length * measure.rowHeight;
    final cap = widget.maxHeight.isFinite ? widget.maxHeight : naturalHeight;
    final visibleHeight = naturalHeight <= cap
        ? naturalHeight
        : math.max(measure.rowHeight, cap);
    final gutter = <Widget>[];
    final texts = <Widget>[];
    for (final line in lines) {
      final fill = _fill(line.kind, colors);
      gutter.add(
        _GutterCell(
          line: line,
          fill: fill,
          measure: measure,
          style: _gutterStyle(line.kind, colors),
        ),
      );
      texts.add(
        _TextCell(
          line: line,
          fill: fill,
          measure: measure,
          style: _textStyle(line.kind, colors),
        ),
      );
    }
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: ScrollbarTheme(
        data: const ScrollbarThemeData(
          thickness: WidgetStatePropertyAll(
            _FileChangeBody._scrollbarThickness,
          ),
        ),
        child: SizedBox(
          height: visibleHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final available = math.max(
                0.0,
                constraints.maxWidth - measure.gutterWidth,
              );
              // Подсветка короткой строки тянется на всю видимую ширину, длинная листается.
              final textWidth = math.max(
                measure.textWidth + AppSpacing.sm * 2,
                available,
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: measure.gutterWidth,
                    child: SingleChildScrollView(
                      controller: _numbers,
                      child: SizedBox(
                        height: naturalHeight,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: gutter,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Scrollbar(
                      controller: _rows,
                      notificationPredicate: _FileChangeBody._anyNotification,
                      child: Scrollbar(
                        controller: _columns,
                        notificationPredicate: _FileChangeBody._anyNotification,
                        child: SingleChildScrollView(
                          controller: _columns,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: textWidth,
                            height: visibleHeight,
                            child: SingleChildScrollView(
                              controller: _rows,
                              child: SizedBox(
                                height: naturalHeight,
                                child: SelectionArea(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      for (final cell in texts)
                                        SizedBox(width: textWidth, child: cell),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _GutterCell extends StatelessWidget {
  const _GutterCell({
    required this.line,
    required this.fill,
    required this.measure,
    required this.style,
  });

  final FileChangeLine line;
  final Color? fill;
  final _Measure measure;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final oldWidth = measure.oldWidth;
    final newWidth = measure.newWidth;
    return _Tint(
      color: fill,
      child: SizedBox(
        height: measure.rowHeight,
        width: measure.gutterWidth,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: _Measure._pad),
          child: Row(
            children: [
              if (oldWidth > 0)
                _Number(line.oldNumber, width: oldWidth, style: style),
              if (oldWidth > 0 && newWidth > 0)
                const SizedBox(width: _Measure._gap),
              if (newWidth > 0)
                _Number(line.newNumber, width: newWidth, style: style),
              if (oldWidth > 0 || newWidth > 0)
                const SizedBox(width: _Measure._gap),
              SizedBox(
                width: measure.signWidth,
                child: Text(_sign(line.kind), softWrap: false, style: style),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Number extends StatelessWidget {
  const _Number(this.number, {required this.width, required this.style});

  final int? number;
  final double width;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Text(
      number == null ? '' : '$number',
      textAlign: TextAlign.right,
      softWrap: false,
      style: style,
    ),
  );
}

class _TextCell extends StatelessWidget {
  const _TextCell({
    required this.line,
    required this.fill,
    required this.measure,
    required this.style,
  });

  final FileChangeLine line;
  final Color? fill;
  final _Measure measure;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => _Tint(
    color: fill,
    child: SizedBox(
      height: measure.rowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            plainTerminalText(line.text),
            softWrap: false,
            style: style,
          ),
        ),
      ),
    ),
  );
}
