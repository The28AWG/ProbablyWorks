import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:app_ui/app_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/background/background_run_guard.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/app/profiles/profile_service.dart';
import 'package:probably_works/app/profiles/profiles_cubit.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/app/theme/theme_controller.dart';
import 'package:probably_works/features/hosts/presentation/widgets/host_key_prompter.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/core/data/chat_draft_store.dart';

class ProbablyWorksApp extends StatefulWidget {
  const ProbablyWorksApp({super.key});

  @override
  State<ProbablyWorksApp> createState() => _ProbablyWorksAppState();
}

class _ProbablyWorksAppState extends State<ProbablyWorksApp> {
  final _router = getIt<AppRouter>();
  final _locale = getIt<LocaleController>();
  final _theme = getIt<ThemeController>();
  final _drafts = getIt<ChatDraftStore>();
  late final AppLifecycleListener _lifecycle;
  late final BackgroundRunGuard _runGuard;

  @override
  void initState() {
    super.initState();
    // Android: сервис на время ходов. iOS: ходы останавливаются при сворачивании (см. BackgroundRunGuard).
    _runGuard = BackgroundRunGuard(getIt<AgentApi>(), _locale)..start();
    // Черновики пишутся в БД с задержкой: при сворачивании и выходе из приложения сохраняем их сразу.
    _lifecycle = AppLifecycleListener(
      onInactive: _saveDrafts,
      onHide: () {
        _saveDrafts();
        unawaited(_runGuard.onHidden());
      },
      onDetach: _saveDrafts,
      onExitRequested: () async {
        await _drafts.flush();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _runGuard.dispose();
    _lifecycle.dispose();
    super.dispose();
  }

  void _saveDrafts() => unawaited(_drafts.flush());

  @override
  Widget build(BuildContext context) => BlocProvider<ProfilesCubit>(
    create: (_) => ProfilesCubit(getIt<ProfileService>()),
    child: ValueListenableBuilder<ThemeMode>(
      valueListenable: _theme,
      builder: (context, themeMode, _) => ValueListenableBuilder<Locale?>(
        valueListenable: _locale,
        builder: (context, locale, _) => MaterialApp.router(
          title: 'ProbablyWorks',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: themeMode,
          locale: locale,
          supportedLocales: LocaleController.supported,
          localizationsDelegates: appLocalizationsDelegates,
          routerConfig: _router.config(),
          builder: (context, child) => HostKeyPrompter(
            navigatorKey: _router.navigatorKey,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );
}
