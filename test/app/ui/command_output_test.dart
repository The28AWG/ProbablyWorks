import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/host/host_terminal.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

class _TestHost extends StatelessWidget {
  const _TestHost(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SizedBox(width: 600, child: child)),
  );
}

Terminal _terminalOf(WidgetTester tester) =>
    tester.widget<TerminalView>(find.byType(TerminalView)).terminal;

/// Текст экрана без пустых строк снизу: так видно, что именно попало в строки терминала.
List<String> _lines(WidgetTester tester) =>
    _terminalOf(tester).buffer
        .getText()
        .trimRight()
        .split('\n')
        .map((line) => line.trimRight())
        .toList();

void main() {
  _liveGroup();
  testWidgets('a line feed starts the next line at the first column', (
    tester,
  ) async {
    await tester.pumpWidget(
      _TestHost(const CommandOutput(text: 'first\nsecond')),
    );
    expect(_lines(tester), ['first', 'second']);
  });

  testWidgets('command is shown as a prompt line above the output', (
    tester,
  ) async {
    await tester.pumpWidget(
      _TestHost(const CommandOutput(text: 'ok', command: 'ls -la')),
    );
    expect(_lines(tester), ['\$ ls -la', 'ok']);
  });

  testWidgets('prompt line is rewritten when the command changes', (
    tester,
  ) async {
    await tester.pumpWidget(
      _TestHost(const CommandOutput(text: 'a', command: 'echo a')),
    );
    await tester.pumpWidget(
      _TestHost(const CommandOutput(text: 'b', command: 'echo b')),
    );
    expect(_lines(tester), ['\$ echo b', 'b']);
  });

  testWidgets('growing output appends only the new part', (tester) async {
    await tester.pumpWidget(_TestHost(const CommandOutput(text: 'a')));
    await tester.pumpWidget(_TestHost(const CommandOutput(text: 'a\nb')));
    expect(_lines(tester), ['a', 'b']);
  });

  testWidgets('replaced output starts from scratch', (tester) async {
    await tester.pumpWidget(_TestHost(const CommandOutput(text: 'old text')));
    await tester.pumpWidget(_TestHost(const CommandOutput(text: 'new')));
    expect(_lines(tester), ['new']);
  });

  testWidgets('ANSI colour codes are interpreted, not printed', (tester) async {
    await tester.pumpWidget(
      _TestHost(const CommandOutput(text: '\x1b[31mred\x1b[0m done')),
    );
    expect(_lines(tester), ['red done']);
  });

  testWidgets('exit code appears only after the command finished', (
    tester,
  ) async {
    await tester.pumpWidget(
      _TestHost(const CommandOutput(text: 'ok', active: true, exitCode: 0)),
    );
    final l10n = AppLocalizations.of(
      tester.element(find.byType(CommandOutput)),
    );
    expect(find.text(l10n.runExitCode(0)), findsNothing);

    await tester.pumpWidget(
      _TestHost(const CommandOutput(text: 'ok', exitCode: 1)),
    );
    expect(find.text(l10n.runExitCode(1)), findsOneWidget);
  });

  testWidgets('cursor is hidden while and after the command runs', (
    tester,
  ) async {
    await tester.pumpWidget(
      _TestHost(const CommandOutput(text: 'running', active: true)),
    );
    await tester.pumpWidget(
      _TestHost(const CommandOutput(text: 'running', exitCode: 0)),
    );
    expect(_terminalOf(tester).cursorVisibleMode, isFalse);
  });

  testWidgets('output cannot show the cursor again', (tester) async {
    await tester.pumpWidget(
      _TestHost(const CommandOutput(text: '\x1b[?25hshown', active: true)),
    );
    expect(_terminalOf(tester).cursorVisibleMode, isFalse);
  });

  testWidgets('height follows the output up to maxHeight', (tester) async {
    final viewport = find.byKey(const ValueKey('command-output-viewport'));
    await tester.pumpWidget(
      _TestHost(const CommandOutput(text: 'one', maxHeight: 200)),
    );
    final short = tester.getSize(viewport).height;
    expect(short, lessThan(60));

    final long = List.generate(100, (i) => 'line $i').join('\n');
    await tester.pumpWidget(
      _TestHost(CommandOutput(text: long, maxHeight: 200)),
    );
    final tall = tester.getSize(viewport).height;
    expect(tall, greaterThan(150));
    expect(tall, lessThanOrEqualTo(200));
  });

  testWidgets('running terminal starts one line high and grows with output', (
    tester,
  ) async {
    final host = _FakeHostTerminal();
    final viewport = find.byKey(const ValueKey('command-output-viewport'));
    await tester.pumpWidget(
      _TestHost(
        CommandOutput(
          text: '',
          command: 'make',
          active: true,
          terminal: host,
          maxHeight: 200,
        ),
      ),
    );
    final oneLine = tester.getSize(viewport).height;
    expect(oneLine, lessThan(60));

    host.print('step 1\r\nstep 2\r\n');
    await tester.pumpAndSettle();
    final twoLines = tester.getSize(viewport).height;
    expect(twoLines, greaterThan(oneLine));

    host.print(List.generate(100, (i) => 'line $i\r\n').join());
    await tester.pumpAndSettle();
    final full = tester.getSize(viewport).height;
    expect(full, greaterThan(150));
    expect(full, lessThanOrEqualTo(200));
  });

  testWidgets('terminal keeps the full screen size for the process', (
    tester,
  ) async {
    final host = _FakeHostTerminal();
    await tester.pumpWidget(
      _TestHost(
        CommandOutput(text: '', active: true, terminal: host, maxHeight: 200),
      ),
    );
    await tester.pump();
    final screen = tester.getSize(find.byType(TerminalView)).height;
    expect(screen, greaterThan(150));
    expect(screen, lessThanOrEqualTo(200));
    expect(host.sizes.last.$2, _terminalOf(tester).viewHeight);
    expect(_terminalOf(tester).viewHeight, greaterThan(5));
  });

  testWidgets('scrollbar sits at the right edge of the output', (tester) async {
    final long = [for (var i = 0; i < 100; i++) 'line $i'].join('\n');
    await tester.pumpWidget(
      _TestHost(CommandOutput(text: long, maxHeight: 200)),
    );
    await tester.pump();
    final scrollbar = find.byType(Scrollbar);
    expect(scrollbar, findsOneWidget);
    expect(
      tester.getTopRight(scrollbar).dx,
      tester.getTopRight(find.byType(TerminalView)).dx,
    );
  });

  testWidgets('copy puts the visible text on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final controller = CommandOutputController();
    await tester.pumpWidget(
      _TestHost(
        Column(
          children: [
            CopyButton(textOf: () => controller.text),
            CommandOutput(
              text: '\x1b[32mfirst\x1b[0m\nsecond',
              controller: controller,
            ),
          ],
        ),
      ),
    );
    expect(controller.text, 'first\nsecond');
    await tester.tap(find.byTooltip('Copy'));
    await tester.pump();
    expect(copied, 'first\nsecond');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('controller has no text once the output is gone', (tester) async {
    final controller = CommandOutputController();
    await tester.pumpWidget(
      _TestHost(CommandOutput(text: 'ok', controller: controller)),
    );
    expect(controller.text, 'ok');
    await tester.pumpWidget(const _TestHost(SizedBox()));
    expect(controller.text, isEmpty);
  });
}

/// Фейковый терминал Host: вывод задаёт тест, ввод и размер записываются.
class _FakeHostTerminal implements HostTerminal {
  final _output = StreamController<Uint8List>.broadcast();
  final _exit = Completer<int?>();
  final input = <String>[];
  final sizes = <(int, int)>[];

  @override
  Stream<Uint8List> attach() => _output.stream;

  @override
  Future<int?> get pid => Future.value(1);

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  void write(Uint8List data) => input.add(utf8.decode(data));

  @override
  void resize(int columns, int rows) => sizes.add((columns, rows));

  void print(String text) => _output.add(Uint8List.fromList(utf8.encode(text)));

  Future<void> finish(int code) async {
    _exit.complete(code);
    await _output.close();
  }
}

void _liveGroup() {
  testWidgets('live terminal accepts input and saved output stays read-only', (
    tester,
  ) async {
    final host = _FakeHostTerminal();
    await tester.pumpWidget(
      _TestHost(
        CommandOutput(text: '', active: true, terminal: host, maxHeight: 200),
      ),
    );

    final terminal = _terminalOf(tester);
    expect(
      tester.widget<TerminalView>(find.byType(TerminalView)).readOnly,
      isFalse,
    );
    terminal.onOutput?.call('yes\n');
    expect(host.input, ['yes\n']);

    await tester.pumpWidget(_TestHost(const CommandOutput(text: 'done')));
    expect(
      tester.widget<TerminalView>(find.byType(TerminalView)).readOnly,
      isTrue,
    );
  });

  testWidgets('scrolled-up view keeps its line when the buffer drops lines', (
    tester,
  ) async {
    final host = _FakeHostTerminal();
    await tester.pumpWidget(
      _TestHost(
        CommandOutput(text: '', active: true, terminal: host, maxHeight: 200),
      ),
    );
    final big = StringBuffer();
    for (var i = 0; i < 10050; i++) {
      big.write('L${i.toString().padLeft(5, '0')}\r\n');
    }
    host.print(big.toString());
    // Видимая высота анимируется: ждём, пока она установится, иначе позиция считается по меняющемуся окну.
    await tester.pumpAndSettle();

    final terminal = _terminalOf(tester);
    final render = tester.renderObject<RenderTerminal>(
      find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_TerminalView',
      ),
    );
    final position = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(TerminalView),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    String topLine() =>
        terminal.buffer.lines[position.pixels ~/ render.lineHeight].toString();

    tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(TerminalView)),
        scrollDelta: const Offset(0, -600),
      ),
    );
    await tester.pump();
    final before = topLine();
    for (var i = 0; i < 5; i++) {
      host.print('X$i\r\n');
      await tester.pump();
    }
    expect(topLine(), before);
  });

  testWidgets('view at the end keeps following new output', (tester) async {
    final host = _FakeHostTerminal();
    await tester.pumpWidget(
      _TestHost(
        CommandOutput(text: '', active: true, terminal: host, maxHeight: 200),
      ),
    );
    final position = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(TerminalView),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    for (var i = 0; i < 100; i++) {
      host.print('line $i\r\n');
      await tester.pump();
    }
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));
  });

  testWidgets('live terminal shows PTY output', (tester) async {
    final host = _FakeHostTerminal();
    await tester.pumpWidget(
      _TestHost(CommandOutput(text: '', active: true, terminal: host)),
    );
    host.print('hello\r\n');
    await tester.pump();
    expect(_lines(tester), ['hello']);
  });

  testWidgets('live terminal shows the command before PTY output', (
    tester,
  ) async {
    final host = _FakeHostTerminal();
    await tester.pumpWidget(
      _TestHost(
        CommandOutput(
          text: '',
          command: 'echo hello',
          active: true,
          terminal: host,
        ),
      ),
    );
    host.print('hello\r\n');
    await tester.pump();
    expect(_lines(tester), ['\$ echo hello', 'hello']);
  });

  testWidgets('the terminal reports its size to the process', (tester) async {
    final host = _FakeHostTerminal();
    await tester.pumpWidget(
      _TestHost(CommandOutput(text: '', active: true, terminal: host)),
    );
    await tester.pump();
    expect(host.sizes, isNotEmpty);
    expect(host.sizes.last.$1, greaterThan(20));
  });

  testWidgets(
    'finished terminal keeps its output, is read-only and shows the exit code',
    (tester) async {
      final host = _FakeHostTerminal();
      await tester.pumpWidget(
        _TestHost(CommandOutput(text: '', active: true, terminal: host)),
      );
      host.print('done\r\n');
      await host.finish(0);
      await tester.pumpWidget(
        _TestHost(const CommandOutput(text: 'done', exitCode: 0)),
      );
      await tester.pump();
      expect(_lines(tester), ['done']);
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).readOnly,
        isTrue,
      );
      expect(find.text('Exit code 0'), findsOneWidget);
    },
  );
}
