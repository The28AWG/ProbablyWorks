import 'package:app_ui/app_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/features/settings/presentation/widgets/attachment_limit_fields.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Поля лимитов вложений в приложении заданной ширины. Русская локаль выбрана
/// намеренно: суффикс «символов» самый длинный, на нём и ломался перенос.
class _FieldsHost extends StatelessWidget {
  const _FieldsHost(this.width);

  final double width;

  @override
  Widget build(BuildContext context) {
    final perMessage = TextEditingController(text: '8');
    final maxBytes = TextEditingController(text: '262144');
    final inlineChars = TextEditingController(text: '4000');
    return MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('ru'),
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: AttachmentLimitFields(
              perMessage: perMessage,
              maxBytes: maxBytes,
              inlineChars: inlineChars,
              error: null,
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('wide area puts the three fields on one line', (tester) async {
    await tester.pumpWidget(const _FieldsHost(720));

    final tops = [
      for (final field in find.byType(TextField).evaluate())
        tester.getTopLeft(find.byWidget(field.widget)).dy,
    ];
    expect(tops, hasLength(3));
    expect(tops.toSet(), hasLength(1), reason: 'все поля на одной линии');
  });

  testWidgets('narrow area stacks the fields instead of squeezing them', (
    tester,
  ) async {
    await tester.pumpWidget(const _FieldsHost(360));

    final tops = [
      for (final field in find.byType(TextField).evaluate())
        tester.getTopLeft(find.byWidget(field.widget)).dy,
    ];
    expect(tops, hasLength(3));
    // Поля идут друг под другом: сужение не сжимает их до нечитаемой ширины.
    expect(tops[1], greaterThan(tops.first));
    expect(tops[2], greaterThan(tops[1]));
  });

  testWidgets('a stacked field is wide enough for its unit suffix', (
    tester,
  ) async {
    await tester.pumpWidget(const _FieldsHost(360));

    final width = tester.getSize(find.byType(TextField).first).width;
    expect(width, greaterThanOrEqualTo(300));

    // Суффикс единицы измерения занимает столько же строк, сколько короткий
    // «байт»: раньше «символов» переносился («симво/лов») при трех полях в узкой
    // строке. Высоты сравниваются, а не числа: метрики шрифта зависят от среды.
    expect(
      tester.getSize(find.text('символов')).height,
      tester.getSize(find.text('байт')).height,
    );
  });

  testWidgets('the validation error is shown once under the fields', (
    tester,
  ) async {
    final perMessage = TextEditingController(text: '8');
    final maxBytes = TextEditingController(text: '262144');
    final inlineChars = TextEditingController(text: '4000');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('ru'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AttachmentLimitFields(
            perMessage: perMessage,
            maxBytes: maxBytes,
            inlineChars: inlineChars,
            error: 'Целое число больше 0',
          ),
        ),
      ),
    );

    expect(find.text('Целое число больше 0'), findsOneWidget);
  });
}
