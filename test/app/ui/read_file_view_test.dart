import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/host/read_file_output.dart';

Future<void> _pump(WidgetTester tester, ReadFileOutput output) =>
    tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        localizationsDelegates: appLocalizationsDelegates,
        home: Scaffold(
          body: SizedBox(width: 600, child: ReadFileView(output: output)),
        ),
      ),
    );

void main() {
  testWidgets('строки показываются с номерами, без служебного заголовка', (
    tester,
  ) async {
    await _pump(
      tester,
      const ReadFileText(
        totalLines: 3,
        totalBytes: 16,
        lines: [
          ReadFileLine(number: 1, text: 'alpha'),
          ReadFileLine(number: 2, text: 'beta'),
          ReadFileLine(number: 3, text: 'gamma'),
        ],
        footer: ReadFileEndOfFile(),
      ),
    );

    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('gamma'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('End of file'), findsOneWidget);
    expect(find.textContaining('[file:'), findsNothing);
  });

  testWidgets('подвал продолжения показывает начальную строку', (tester) async {
    await _pump(
      tester,
      const ReadFileText(
        totalLines: 5,
        totalBytes: 14,
        lines: [ReadFileLine(number: 2, text: 'l2')],
        footer: ReadFileMore(offset: 3),
      ),
    );

    expect(
      find.text('Output limit reached. Continue from line 3'),
      findsOneWidget,
    );
  });

  testWidgets('обрезанная строка описана байтами', (tester) async {
    await _pump(
      tester,
      const ReadFileText(
        totalLines: 2,
        totalBytes: 103,
        lines: [ReadFileLine(number: 1, text: 'abc')],
        footer: ReadFileCut(
          line: 1,
          byte: 30,
          lineBytes: 100,
          offset: 1,
          byteOffset: 30,
        ),
      ),
    );

    expect(
      find.text(
        'Line 1 is cut at byte 30 of 100; the rest is read in the next call',
      ),
      findsOneWidget,
    );
  });

  testWidgets('пустой файл выводится сообщением, а не пустым блоком', (
    tester,
  ) async {
    await _pump(
      tester,
      const ReadFileBeyondEnd(offset: 1, totalLines: 0, totalBytes: 0),
    );

    expect(find.text('File is empty'), findsOneWidget);
  });

  testWidgets('начало за концом файла называет строку и число строк', (
    tester,
  ) async {
    await _pump(
      tester,
      const ReadFileBeyondEnd(offset: 10, totalLines: 3, totalBytes: 5),
    );

    expect(
      find.text('Line 10 is past the end of the file (3 lines)'),
      findsOneWidget,
    );
  });

  testWidgets('бинарный файл — понятное сообщение', (tester) async {
    await _pump(tester, const ReadFileError(ReadFileErrorKind.binary));

    expect(find.text('Binary file: cannot be shown as text'), findsOneWidget);
  });

  testWidgets('файл не читается — понятное сообщение', (tester) async {
    await _pump(tester, const ReadFileError(ReadFileErrorKind.notReadable));

    expect(
      find.text('Not a regular file or no read permission'),
      findsOneWidget,
    );
  });

  testWidgets('длинная строка не переносится и листается по горизонтали', (
    tester,
  ) async {
    final long = 'x' * 300;
    await _pump(
      tester,
      ReadFileText(
        totalLines: 1,
        totalBytes: 300,
        lines: [ReadFileLine(number: 1, text: long)],
        footer: const ReadFileEndOfFile(),
      ),
    );

    final size = tester.getSize(find.text(long));
    // Одна строка по высоте: текст не перенесён.
    expect(size.height, lessThan(30));
    // Ширина больше блока 600: текст уходит за край и доступен через скролл.
    expect(size.width, greaterThan(600));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      ),
      findsOneWidget,
    );
  });

  testWidgets('при горизонтальном скролле номера строк остаются на месте', (
    tester,
  ) async {
    final long = 'y' * 300;
    await _pump(
      tester,
      ReadFileText(
        totalLines: 1,
        totalBytes: 300,
        lines: [ReadFileLine(number: 1, text: long)],
        footer: const ReadFileEndOfFile(),
      ),
    );

    final horizontal = find.byWidgetPredicate(
      (widget) =>
          widget is SingleChildScrollView &&
          widget.scrollDirection == Axis.horizontal,
    );
    final textBefore = tester.getTopLeft(find.text(long)).dx;
    final numberBefore = tester.getTopLeft(find.text('1')).dx;

    tester
        .state<ScrollableState>(
          find
              .descendant(of: horizontal, matching: find.byType(Scrollable))
              .first,
        )
        .position
        .jumpTo(200);
    await tester.pump();

    // Текст ушёл влево вместе со скроллом, номер остался на месте.
    expect(tester.getTopLeft(find.text(long)).dx, lessThan(textBefore));
    expect(tester.getTopLeft(find.text('1')).dx, numberBefore);
  });

  testWidgets('текст выровнен по левому краю рядом с номерами', (tester) async {
    await _pump(
      tester,
      ReadFileText(
        totalLines: 2,
        totalBytes: 205,
        lines: [
          const ReadFileLine(number: 1, text: 'alpha'),
          ReadFileLine(number: 2, text: 'x' * 200),
        ],
        footer: const ReadFileEndOfFile(),
      ),
    );

    // Короткая строка рядом с длинной: при центрировании она уехала бы к середине длинной строки.
    final gap =
        tester.getTopLeft(find.text('alpha')).dx -
        tester.getTopLeft(find.text('1')).dx;
    expect(gap, lessThan(60));
  });

  testWidgets('есть вертикальный и горизонтальный скроллбары', (tester) async {
    await _pump(
      tester,
      ReadFileText(
        totalLines: 40,
        totalBytes: 400,
        lines: [
          for (var i = 1; i <= 40; i++)
            ReadFileLine(number: i, text: 'z' * 300),
        ],
        footer: const ReadFileMore(offset: 41),
      ),
    );

    final axes = tester
        .widgetList<Scrollbar>(find.byType(Scrollbar))
        .map((bar) => bar.controller!.position.axis)
        .toSet();
    expect(axes, {Axis.vertical, Axis.horizontal});
  });

  testWidgets('при вертикальном скролле номера едут вместе с текстом', (
    tester,
  ) async {
    await _pump(
      tester,
      ReadFileText(
        totalLines: 40,
        totalBytes: 40,
        lines: [
          for (var i = 1; i <= 40; i++) ReadFileLine(number: i, text: 'l$i'),
        ],
        footer: const ReadFileEndOfFile(),
      ),
    );

    final horizontal = find.byWidgetPredicate(
      (widget) =>
          widget is SingleChildScrollView &&
          widget.scrollDirection == Axis.horizontal,
    );
    // Внутри горизонтального скролла два вертикальных: сам текст и вложенный; берём последний.
    final rows = tester.state<ScrollableState>(
      find.descendant(of: horizontal, matching: find.byType(Scrollable)).last,
    );
    final textBefore = tester.getTopLeft(find.text('l5')).dy;
    final numberBefore = tester.getTopLeft(find.text('5')).dy;

    rows.position.jumpTo(100);
    await tester.pump();

    final textMoved = textBefore - tester.getTopLeft(find.text('l5')).dy;
    final numberMoved = numberBefore - tester.getTopLeft(find.text('5')).dy;
    expect(textMoved, greaterThan(0));
    expect(numberMoved, textMoved);
  });

  testWidgets('текст строки очищается от ESC-последовательностей файла', (
    tester,
  ) async {
    await _pump(
      tester,
      const ReadFileText(
        totalLines: 1,
        totalBytes: 12,
        lines: [ReadFileLine(number: 1, text: '\x1b[31mred\x1b[0m')],
        footer: ReadFileEndOfFile(),
      ),
    );

    expect(find.text('red'), findsOneWidget);
    expect(find.textContaining('\x1b'), findsNothing);
  });
}
