import 'dart:math' as math;

import 'package:app_ui/app_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/core/util/ansi_text.dart';
import 'package:probably_works/host/read_file_output.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Вид результата инструмента read_file: строки файла с номерами и подвал с подсказкой продолжения.
///
/// Показывает только содержимое, без скрипта и служебных заголовков: их уже разобрал [parseReadFileOutput].
/// Строки не переносятся. Колонка номеров стоит на месте, а длинные строки листаются горизонтально
/// только в колонке текста. Вертикальный скролл общий: номера синхронизированы с текстом по смещению.
/// Высота строки фиксирована и измерена по шрифту, поэтому высота блока точно совпадает с содержимым.
/// Номера выровнены по ширине самого большого номера. Ожидаемые отказы (бинарный файл, не обычный файл,
/// начало за концом) выводятся обычной строкой, а не как сбой: для модели это штатный исход.
/// Текст строк проходит через [plainTerminalText], иначе ESC-последовательности из файла поменяли бы вид.
///
/// Высота растёт по содержимому до [maxHeight], дальше прокрутка по вертикали. Выделение охватывает только текст строк: номера не попадают в выделение и в копирование с клавиатуры.
class ReadFileView extends StatelessWidget {
  const ReadFileView({required this.output, this.maxHeight = 240, super.key});

  /// Разобранный вывод read_file.
  final ReadFileOutput output;

  /// Предел высоты видимой части.
  final double maxHeight;

  /// Шрифт совпадает с [CodeBlock] и выводом команд, чтобы код выглядел одинаково везде.
  ///
  /// [Text.rich] кладёт спан внутрь стиля темы. У движка незаданный [TextStyle.letterSpacing]
  /// не сбрасывает уже заданный, поэтому 0.25 из body-стиля остаётся на моноширинной строке.
  /// Строка становится шире [TextPainter], и хвост самой длинной обрезается колонкой.
  /// Поэтому интервалы и насыщенность заданы явно, а `inherit` выключен.
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
    return switch (output) {
      ReadFileText text => _ReadFileBody(text: text, maxHeight: maxHeight),
      ReadFileBeyondEnd(:final offset, :final totalLines) => _ReadFileMessage(
        totalLines == 0
            ? l10n.readFileEmpty
            : l10n.readFileBeyondEnd(offset, totalLines),
      ),
      ReadFileError(:final kind) => _ReadFileMessage(switch (kind) {
        ReadFileErrorKind.notReadable => l10n.readFileNotReadable,
        ReadFileErrorKind.binary => l10n.readFileBinary,
      }),
    };
  }

  /// Спан строки. Единственная точка, где позже можно подключить подсветку синтаксиса:
  /// подсветка заменит только эту функцию, разбор вывода и вёрстка не меняются.
  static TextSpan _lineSpan(String text, TextStyle style) =>
      TextSpan(text: text, style: style);

  /// Текст подвала на языке интерфейса.
  static String _footerText(AppLocalizations l10n, ReadFileFooter footer) =>
      switch (footer) {
        ReadFileEndOfFile() => l10n.readFileEndOfFile,
        ReadFileMore(:final offset) => l10n.readFileMore(offset),
        ReadFileCut(:final line, :final byte, :final lineBytes) =>
          l10n.readFileCut(line, byte, lineBytes),
      };
}

/// Тело вида: блок кода с колонкой номеров, колонкой текста и подвалом.
///
/// Три контроллера прокрутки. [_rows] ведёт вертикальный скролл текста, [_numbers] — колонку номеров,
/// и они синхронизируются по смещению. [_columns] ведёт горизонтальный скролл только колонки текста.
/// Колонка номеров не скроллится горизонтально, поэтому номера остаются на месте.
///
/// Скроллбары строятся снаружи области текста. [Scrollbar] получает нотификации только от своих
/// потомков, а горизонтальный скролл вложен во вертикальный. Поэтому оба бара оборачивают область
/// и рисуются по краям видимой части: вертикальный справа, горизонтальный снизу, а не по всему содержимому.
/// Так же, как у [CommandOutput], толщина фиксирована, а встроенные скроллбары выключены.
///
/// Размеры считаются один раз за build одним [TextPainter]: высота строки, ширина колонки номеров
/// и ширина самой длинной строки.
class _ReadFileBody extends StatefulWidget {
  const _ReadFileBody({required this.text, required this.maxHeight});

  final ReadFileText text;
  final double maxHeight;

  /// Внутренний отступ блока. Совпадает с отступом [CommandOutput] и [CodeBlock].
  static const _padding = AppSpacing.md;

  /// Промежуток между колонкой номеров и текстом.
  static const _gap = AppSpacing.md;

  /// Толщина скроллбара. Совпадает с [CommandOutput]: тот же вид полос прокрутки во всём приложении.
  static const _scrollbarThickness = 8.0;

  /// Принимает нотификации любой глубины. Без этого скроллбар не видел бы прокрутку внутреннего
  /// скролла, а фильтр по оси отсекает чужие нотификации.
  static bool _anyNotification(ScrollNotification _) => true;

  /// Размеры в логических пикселях: высота строки, ширина колонки номеров и ширина самой длинной строки.
  /// Строка измеряется без переноса, поэтому её ширина — это вся длина строки файла.
  static ({double rowHeight, double numberWidth, double textWidth}) _measure(
    ReadFileText text,
    TextStyle textStyle,
    TextStyle numberStyle,
    TextScaler textScaler,
  ) {
    // Тот же масштаб, что у [Text]: иначе увеличенный текст шире колонки и обрезается.
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    );
    try {
      painter
        ..text = TextSpan(
          text: '0' * text.totalLines.toString().length,
          style: numberStyle,
        )
        ..layout();
      final numberWidth = painter.width;

      painter
        ..text = TextSpan(text: '0', style: textStyle)
        ..layout();
      final rowHeight = painter.height;

      var textWidth = 0.0;
      for (final line in text.lines) {
        painter
          ..text = ReadFileView._lineSpan(
            plainTerminalText(line.text),
            textStyle,
          )
          ..layout();
        textWidth = math.max(textWidth, painter.width);
      }
      return (
        rowHeight: rowHeight,
        numberWidth: numberWidth,
        textWidth: textWidth,
      );
    } finally {
      painter.dispose();
    }
  }

  @override
  State<_ReadFileBody> createState() => _ReadFileBodyState();
}

class _ReadFileBodyState extends State<_ReadFileBody> {
  /// Вертикальный скролл текста. Он задаёт смещение, колонка номеров идёт за ним.
  final _rows = ScrollController();

  /// Вертикальный скролл колонки номеров. Прокрутка колесом над номерами двигает текст через [_rows].
  final _numbers = ScrollController();

  /// Горизонтальный скролл колонки текста. Колонка номеров его не использует.
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

  /// Переводит [to] на смещение [from]. Цикл не возникает: после первого перевода смещения совпадают,
  /// и второй контроллер больше не сдвигает первый. Пока контроллер не подключён к позиции, смещения нет.
  static void _follow(ScrollController to, ScrollController from) {
    if (!to.hasClients || !from.hasClients) return;
    if (to.offset != from.offset) to.jumpTo(from.offset);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.appColors;
    final lines = widget.text.lines;
    final footer = widget.text.footer;
    final numberStyle = ReadFileView._style.copyWith(
      color: colors.codeText.withValues(alpha: 0.5),
    );
    final textStyle = ReadFileView._style.copyWith(color: colors.codeText);
    final measure = _ReadFileBody._measure(
      widget.text,
      textStyle,
      numberStyle,
      MediaQuery.textScalerOf(context),
    );
    // Округляем вверх: измерение дробное, а колонка должна вместить строку целиком.
    // Запас справа — толщина вертикального скроллбара: он рисуется поверх края,
    // и без запаса последний знак уезжает под полосу.
    final textColumnWidth =
        measure.textWidth.ceilToDouble() + _ReadFileBody._scrollbarThickness;
    final naturalHeight = lines.length * measure.rowHeight;
    // Высота видимой части: все строки, но не больше предела с учётом отступов.
    final visibleHeight = math.max(
      0.0,
      math.min(naturalHeight, widget.maxHeight - _ReadFileBody._padding * 2),
    );
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: ScrollbarTheme(
        data: const ScrollbarThemeData(
          thickness: WidgetStatePropertyAll(_ReadFileBody._scrollbarThickness),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.codeSurface,
            borderRadius: AppRadius.mdAll,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(_ReadFileBody._padding),
                child: SizedBox(
                  height: visibleHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Колонка номеров вне горизонтального скролла: остаётся на месте.
                      SizedBox(
                        width: measure.numberWidth,
                        child: SingleChildScrollView(
                          controller: _numbers,
                          child: SizedBox(
                            height: naturalHeight,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final line in lines)
                                  SizedBox(
                                    height: measure.rowHeight,
                                    width: measure.numberWidth,
                                    child: Text(
                                      '${line.number}',
                                      textAlign: TextAlign.right,
                                      softWrap: false,
                                      style: numberStyle,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: _ReadFileBody._gap),
                      // Скроллбары снаружи области текста: см. описание класса.
                      Expanded(
                        child: Scrollbar(
                          controller: _rows,
                          notificationPredicate: _ReadFileBody._anyNotification,
                          child: Scrollbar(
                            controller: _columns,
                            notificationPredicate:
                                _ReadFileBody._anyNotification,
                            child: SingleChildScrollView(
                              controller: _columns,
                              scrollDirection: Axis.horizontal,
                              child: SizedBox(
                                width: textColumnWidth,
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
                                          for (final line in lines)
                                            SizedBox(
                                              height: measure.rowHeight,
                                              child: Text.rich(
                                                ReadFileView._lineSpan(
                                                  plainTerminalText(line.text),
                                                  textStyle,
                                                ),
                                                // Тот же стиль, что у спана: иначе корень спана
                                                // остаётся темой и её интервал протекает в строку.
                                                style: textStyle,
                                                softWrap: false,
                                              ),
                                            ),
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
                  ),
                ),
              ),
              if (footer != null)
                Padding(
                  padding: const EdgeInsets.only(
                    left: _ReadFileBody._padding,
                    right: _ReadFileBody._padding,
                    bottom: _ReadFileBody._padding,
                  ),
                  child: Text(
                    ReadFileView._footerText(l10n, footer),
                    style: ReadFileView._style.copyWith(
                      fontSize: 12,
                      color: colors.codeText.withValues(alpha: 0.7),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Одна строка пояснения вместо содержимого: пустой файл, отказ чтения, начало за концом.
class _ReadFileMessage extends StatelessWidget {
  const _ReadFileMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Text(
        message,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
