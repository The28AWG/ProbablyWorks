import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/ui/ui.dart';

/// Пояснение заведомо длиннее двух строк: проверяет обрезку и одинаковую высоту карточек.
const _longSubtitle =
    'Очень длинное пояснение, которое точно не помещается в две строки карточки '
    'и должно обрезаться многоточием в самом конце текста';

const _options = [
  AppChoiceOption(value: 'system', title: 'System', subtitle: 'Auto'),
  AppChoiceOption(
    value: 'light',
    title: 'Light',
    subtitle: _longSubtitle,
    icon: Icons.light_mode,
  ),
  AppChoiceOption(value: 'dark', title: 'Dark', subtitle: 'Dark theme'),
];

/// Хост с состоянием: выбор меняется сам, как в настройках через cubit.
class _Host extends StatefulWidget {
  const _Host({this.width = 600, this.onChanged});

  final double width;
  final ValueChanged<String>? onChanged;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  String selected = 'system';

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: widget.width,
          child: AppChoiceGroup<String>(
            options: _options,
            selected: selected,
            onChanged: _select,
          ),
        ),
      ),
    ),
  );

  void _select(String value) {
    widget.onChanged?.call(value);
    setState(() => selected = value);
  }
}

/// Семантический узел выбранной карточки: Semantics с флагом selected.
Finder get _selectedCard => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.selected == true,
);

/// Семантические узлы всех карточек группы (кнопки в взаимоисключающей группе).
Finder get _cards => find.byWidgetPredicate(
  (widget) =>
      widget is Semantics &&
      widget.properties.button == true &&
      widget.properties.inMutuallyExclusiveGroup == true,
);

void main() {
  testWidgets('tapping a card selects it and reports the value', (
    tester,
  ) async {
    final changes = <String>[];
    await tester.pumpWidget(_Host(onChanged: changes.add));

    expect(_selectedCard, findsOneWidget);
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);

    await tester.tap(find.text('Dark'));
    await tester.pump();

    expect(changes, ['dark']);
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(_selectedCard, findsOneWidget);
    expect(
      find.ancestor(of: find.text('Dark'), matching: _selectedCard),
      findsOneWidget,
    );
    expect(
      find.ancestor(of: find.text('System'), matching: _selectedCard),
      findsNothing,
    );
  });

  testWidgets('every card is a button in a mutually exclusive group', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());

    expect(_cards, findsNWidgets(_options.length));
  });

  testWidgets('all cards share one height, even with a very long subtitle', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host(width: 600));

    final heights = {
      for (var i = 0; i < _options.length; i++)
        tester.getSize(_cards.at(i)).height,
    };
    expect(heights, hasLength(1));
  });

  testWidgets('cards keep the same height in a narrow column too', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host(width: 200));

    final heights = {
      for (var i = 0; i < _options.length; i++)
        tester.getSize(_cards.at(i)).height,
    };
    expect(heights, hasLength(1));
  });

  testWidgets('the tooltip shows the bold title and the subtitle below it', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());

    final tooltip = tester.widget<Tooltip>(
      find.ancestor(of: find.text('Dark'), matching: find.byType(Tooltip)),
    );
    final span = tooltip.richMessage! as TextSpan;
    expect(span.toPlainText(), 'Dark\nDark theme');
    expect(span.children!.first.style?.fontWeight, FontWeight.w600);
  });

  testWidgets('wide area puts all cards in one row', (tester) async {
    await tester.pumpWidget(const _Host(width: 600));

    final top = tester.getTopLeft(find.text('System')).dy;
    expect(tester.getTopLeft(find.text('Light')).dy, top);
    expect(tester.getTopLeft(find.text('Dark')).dy, top);
  });

  testWidgets('narrow area stacks cards in one column', (tester) async {
    await tester.pumpWidget(const _Host(width: 200));

    final first = tester.getTopLeft(find.text('System')).dy;
    final second = tester.getTopLeft(find.text('Light')).dy;
    final third = tester.getTopLeft(find.text('Dark')).dy;
    expect(first < second && second < third, isTrue);
  });
}
