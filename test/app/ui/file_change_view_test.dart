import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_colors.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

Future<void> _pump(WidgetTester tester, FileChange change) => tester.pumpWidget(
  MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SizedBox(width: 640, child: FileChangeView(change: change)),
    ),
  ),
);

void main() {
  testWidgets('новый файл целиком зелёный, со знаком добавления', (
    tester,
  ) async {
    await _pump(
      tester,
      const FileChange(
        kind: FileChangeKind.created,
        path: 'a.dart',
        lines: [
          FileChangeLine(
            kind: FileChangeLineKind.addition,
            text: 'alpha',
            newNumber: 1,
          ),
          FileChangeLine(
            kind: FileChangeLineKind.addition,
            text: 'beta',
            newNumber: 2,
          ),
        ],
        added: 2,
        removed: 0,
        copyText: 'alpha\nbeta',
        totalLines: 2,
        hunkHeader: '@@ -0,0 +1,2 @@',
      ),
    );

    expect(find.text('@@ -0,0 +1,2 @@'), findsOneWidget);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('+'), findsNWidgets(2));
    expect(find.text('-'), findsNothing);
    expect(
      tester.widget<Text>(find.text('alpha')).style?.color,
      AppColors.light.diffAddText,
    );
    expect(
      tester.widget<Text>(find.text('beta')).style?.color,
      AppColors.light.diffAddText,
    );
  });

  testWidgets(
    'правка показывает контекст, удаление и добавление разными цветами',
    (tester) async {
      await _pump(
        tester,
        const FileChange(
          kind: FileChangeKind.edited,
          path: 'a.dart',
          lines: [
            FileChangeLine(
              kind: FileChangeLineKind.context,
              text: 'keep',
              oldNumber: 1,
              newNumber: 1,
            ),
            FileChangeLine(
              kind: FileChangeLineKind.removal,
              text: 'old',
              oldNumber: 2,
            ),
            FileChangeLine(
              kind: FileChangeLineKind.addition,
              text: 'next',
              newNumber: 2,
            ),
          ],
          added: 1,
          removed: 1,
          copyText: '',
          totalLines: 3,
          hunkHeader: '@@ -1,2 +1,2 @@',
          replaceAll: true,
        ),
      );

      expect(find.text('Every match in the file'), findsOneWidget);
      expect(find.text('@@ -1,2 +1,2 @@'), findsOneWidget);
      expect(find.text('+'), findsOneWidget);
      expect(find.text('-'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('keep')).style?.color,
        AppColors.light.codeText,
      );
      expect(
        tester.widget<Text>(find.text('old')).style?.color,
        AppColors.light.diffRemoveText,
      );
      expect(
        tester.widget<Text>(find.text('next')).style?.color,
        AppColors.light.diffAddText,
      );
    },
  );

  testWidgets('пустой файл и обрезанное изменение подписаны', (tester) async {
    await _pump(
      tester,
      const FileChange(
        kind: FileChangeKind.created,
        path: 'empty.txt',
        lines: [],
        added: 0,
        removed: 0,
        copyText: '',
        totalLines: 0,
      ),
    );
    expect(find.text('File is empty'), findsOneWidget);

    await _pump(
      tester,
      const FileChange(
        kind: FileChangeKind.created,
        path: 'long.txt',
        lines: [
          FileChangeLine(
            kind: FileChangeLineKind.addition,
            text: 'only',
            newNumber: 1,
          ),
        ],
        added: 4,
        removed: 0,
        copyText: 'only',
        totalLines: 4,
        hunkHeader: '@@ -0,0 +1,4 @@',
      ),
    );
    expect(find.text('Showing the first 1 of 4 lines.'), findsOneWidget);
    expect(find.text('only'), findsOneWidget);
  });
}
