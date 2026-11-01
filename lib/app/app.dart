import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/features/hosts/presentation/widgets/host_key_prompter.dart';

class ProbablyWorksApp extends StatefulWidget {
  const ProbablyWorksApp({super.key});

  @override
  State<ProbablyWorksApp> createState() => _ProbablyWorksAppState();
}

class _ProbablyWorksAppState extends State<ProbablyWorksApp> {
  final _router = getIt<AppRouter>();
  final _locale = getIt<LocaleController>();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Locale?>(
    valueListenable: _locale,
    builder: (context, locale, _) => MaterialApp.router(
      title: 'ProbablyWorks',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      locale: locale,
      supportedLocales: LocaleController.supported,
      localizationsDelegates: appLocalizationsDelegates,
      routerConfig: _router.config(),
      builder: (context, child) => HostKeyPrompter(
        navigatorKey: _router.navigatorKey,
        child: child ?? const SizedBox.shrink(),
      ),
    ),
  );
}
