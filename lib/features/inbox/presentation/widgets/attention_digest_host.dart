import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/profiles/profile_scope.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/features/inbox/presentation/bloc/attention_digest_clock.dart';
import 'package:probably_works/features/inbox/presentation/widgets/attention_digest_banner.dart';
import 'package:probably_works/features/workspace/presentation/navigation/workspace_navigation.dart';

/// Показывает дайджест после возврата в приложение.
///
/// Виджет живёт в оболочке рабочей области и поэтому виден на всех вкладках.
/// Он сам решает, было ли отсутствие достаточно долгим, а счётчики берёт у
/// [ChatListCubit] — так карточка не дублирует запросы и не расходится со
/// входящими.
class AttentionDigestHost extends StatefulWidget {
  const AttentionDigestHost({this.settings, this.now, super.key});

  /// Клиентские настройки. В приложении берутся из DI, в тестах передаются
  /// явно, чтобы не поднимать весь граф зависимостей.
  final ClientSettings? settings;

  /// Часы для проверки порога отсутствия.
  final DateTime Function()? now;

  @override
  State<AttentionDigestHost> createState() => _AttentionDigestHostState();
}

class _AttentionDigestHostState extends State<AttentionDigestHost> {
  late final AppLifecycleListener _listener;
  AttentionDigestClock? _clock;
  ClientSettings? _settings;
  String? _profileId;
  var _checking = false;

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(onStateChange: _onLifecycle);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final profileId = ProfileScope.maybeOf(context)?.profile.id ?? 'default';
    if (profileId == _profileId) return;
    _profileId = profileId;
    final settings = widget.settings ?? getIt<ClientSettings>();
    _settings = settings;
    _clock = AttentionDigestClock(
      settings,
      profileId: profileId,
      now: widget.now,
    );
    // Смена профиля — это тоже возврат к другому агенту: дайджест у него свой.
    unawaited(_check());
  }

  @override
  void dispose() {
    _listener.dispose();
    // Закрытие окна не всегда сопровождается lifecycle-событием паузы.
    final clock = _clock;
    if (clock != null) unawaited(clock.rememberActive());
    super.dispose();
  }

  void _onLifecycle(AppLifecycleState state) {
    final clock = _clock;
    if (clock == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_check());
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // Отмечаем момент ухода, а не прихода: иначе длинный фон между
        // событиями выглядел бы как короткое отсутствие.
        unawaited(clock.rememberActive());
    }
  }

  /// Проверяет отсутствие и загружает дайджест, если порог пройден.
  ///
  /// Повторные события жизни приложения могут наложиться друг на друга;
  /// проверка защищена от параллельного запуска, а сам запрос дедуплицирует
  /// [ChatListCubit.loadDigest].
  Future<void> _check() async {
    if (_checking) return;
    final clock = _clock;
    if (clock == null) return;
    _checking = true;
    try {
      final settings = _settings;
      final enabled =
          settings == null ||
          await settings.read(ClientSettingsKeys.attentionDigestEnabled) !=
              'false';
      final shouldShow = await clock.shouldShow();
      if (!mounted) return;
      if (!enabled) {
        // Отметка нужна и при выключенном дайджесте: после включения отсчёт
        // отсутствия должен начаться заново, а не с прошлого запуска.
        await clock.rememberActive();
        return;
      }
      if (shouldShow) {
        await context.read<ChatListCubit>().loadDigest();
        if (!mounted) return;
      }
      await clock.rememberActive();
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<ChatListCubit, ChatListState>(
        buildWhen: (previous, current) => previous.digest != current.digest,
        builder: (context, state) {
          final digest = state.digest;
          if (digest == null || digest.isEmpty) return const SizedBox.shrink();
          return AttentionDigestBanner(
            digest: digest,
            onDismiss: () => _dismiss(context),
            onReview: () => _review(context),
          );
        },
      );

  void _dismiss(BuildContext context) {
    context.read<ChatListCubit>().dismissDigest();
  }

  void _review(BuildContext context) {
    context.read<ChatListCubit>().dismissDigest();
    showWorkspaceTab(context, WorkspaceTab.inbox);
  }
}
