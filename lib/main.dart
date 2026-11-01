import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/app.dart';
import 'package:probably_works/app/bootstrap/bootstrap.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

Future<void> main() async {
  final started = await bootstrap();
  runApp(started ? const ProbablyWorksApp() : const _AlreadyRunningApp());
}

/// Вторая копия приложения не открывает общую базу: показываем причину и выходим.
class _AlreadyRunningApp extends StatelessWidget {
  const _AlreadyRunningApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(child: Text(AppLocalizations.of(context).alreadyRunning)),
      ),
    ),
  );
}
