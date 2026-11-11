import 'package:app_ui/app_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/features/settings/presentation/widgets/settings_form_row.dart';

/// Строка формы в приложении с нужной шириной области.
class _RowHost extends StatelessWidget {
  const _RowHost({required this.width, this.withTrailing = false});

  final double width;
  final bool withTrailing;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: SettingsFormRow(
            title: 'Title',
            description: 'Description',
            action: withTrailing ? null : const Text('Action'),
            trailing: withTrailing ? const Text('Trailing') : null,
            child: const Text('Field'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('wide area puts the label beside the fields', (tester) async {
    await tester.pumpWidget(const _RowHost(width: 720));

    final title = tester.getTopLeft(find.text('Title'));
    final field = tester.getTopLeft(find.text('Field'));
    // Название и поля начинаются на одной линии: строка, а не колонка.
    expect(field.dy, title.dy);
    expect(field.dx, greaterThan(title.dx));
  });

  testWidgets('the action sits under the fields on the right', (tester) async {
    await tester.pumpWidget(const _RowHost(width: 720));

    final field = tester.getBottomLeft(find.text('Field'));
    final action = tester.getTopLeft(find.text('Action'));
    expect(action.dy, greaterThan(field.dy));
    expect(
      tester.getTopRight(find.text('Action')).dx,
      greaterThan(tester.getTopRight(find.text('Field')).dx - 1),
    );
  });

  testWidgets('trailing sits beside the field on the same line', (
    tester,
  ) async {
    await tester.pumpWidget(const _RowHost(width: 720, withTrailing: true));

    final field = tester.getTopLeft(find.text('Field'));
    final trailing = tester.getTopLeft(find.text('Trailing'));
    // Действия занимают строку поля, поэтому строка не растёт из-за них.
    expect(trailing.dx, greaterThan(field.dx));
    expect(trailing.dy, closeTo(field.dy, 30));
  });

  testWidgets('narrow area stacks the label above the fields', (tester) async {
    await tester.pumpWidget(const _RowHost(width: 360));

    final title = tester.getTopLeft(find.text('Title'));
    final field = tester.getTopLeft(find.text('Field'));
    expect(field.dy, greaterThan(title.dy));
  });
}
