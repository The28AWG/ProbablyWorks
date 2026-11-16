import 'package:app_ui/app_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _entries = [
  AppSelectEntry(value: 'name', label: 'By name'),
  AppSelectEntry(value: 'price', label: 'By price'),
];

/// Хост селекта: значение хранится снаружи, как в экранах приложения.
class _Host extends StatefulWidget {
  const _Host({this.enabled = true});

  final bool enabled;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  var _value = 'name';
  final changes = <String>[];

  /// Внешняя смена значения, как после загрузки сохранённой настройки.
  void select(String value) => setState(() => _value = value);

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light,
    home: Scaffold(
      body: Center(
        child: AppSelect<String>(
          value: _value,
          entries: _entries,
          width: AppLayout.selectWidth,
          onChanged: widget.enabled
              ? (value) => setState(() {
                  _value = value;
                  changes.add(value);
                })
              : null,
        ),
      ),
    ),
  );
}

/// Значение, которое показывает сам селект.
String _shown(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText)).controller.text;

/// Пункт открытого меню: у поля значения тот же текст, поэтому ищем в меню.
/// Меню держит по две копии пункта, берём видимую.
Finder _menuItem(String label) => find.text(label).hitTestable().first;

void main() {
  testWidgets('shows the current value and reports a picked one', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());
    await tester.pumpAndSettle();
    expect(_shown(tester), 'By name');

    await tester.tap(find.byType(AppSelect<String>));
    await tester.pumpAndSettle();
    await tester.tap(_menuItem('By price'));
    await tester.pumpAndSettle();

    final host = tester.state<_HostState>(find.byType(_Host));
    expect(host.changes, ['price']);
    expect(_shown(tester), 'By price');
  });

  testWidgets('follows an external value change', (tester) async {
    await tester.pumpWidget(const _Host());
    await tester.pumpAndSettle();

    tester.state<_HostState>(find.byType(_Host)).select('price');
    await tester.pumpAndSettle();

    expect(_shown(tester), 'By price');
  });

  testWidgets('without onChanged the menu does not open', (tester) async {
    await tester.pumpWidget(const _Host(enabled: false));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AppSelect<String>));
    await tester.pumpAndSettle();

    expect(find.text('By price').hitTestable(), findsNothing);
  });

  testWidgets('keyboard: Tab focuses, Enter opens, arrows pick', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text('By price').hitTestable(), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    final host = tester.state<_HostState>(find.byType(_Host));
    expect(host.changes, ['price']);
    expect(_shown(tester), 'By price');
  });
}
