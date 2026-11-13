import 'dart:async';

import 'package:app_ui/app_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/profiles/profile_scope.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/agent_api.dart';

/// Строит интерфейс по статусу соединения с агентом.
///
/// Вне workspace (тесты, онбординг) профиля нет: считаем соединение живым,
/// чтобы не менять поведение старых экранов.
class BackendStatusBuilder extends StatelessWidget {
  const BackendStatusBuilder({required this.builder, super.key});

  final Widget Function(BuildContext context, AgentStatus status) builder;

  @override
  Widget build(BuildContext context) {
    final scope = ProfileScope.maybeOf(context);
    if (scope == null) return builder(context, AgentStatus.online);
    return StreamBuilder<AgentStatus>(
      stream: scope.agentApi.statusChanges,
      initialData: scope.agentApi.status,
      builder: (context, snapshot) =>
          builder(context, snapshot.data ?? AgentStatus.connecting),
    );
  }
}

/// Заглушка вместо рабочего содержимого, когда сервер агента недоступен.
class BackendOfflineView extends StatelessWidget {
  const BackendOfflineView({this.compact = false, super.key});

  /// Компактный вариант для боковой панели: без большого вертикального отступа.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scope = ProfileScope.maybeOf(context);
    final retry = scope == null
        ? null
        : FilledButton.icon(
            onPressed: () => unawaited(scope.agentApi.checkConnection()),
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(l10n.backendOfflineRetry),
          );
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? AppSpacing.sm : AppSpacing.lg,
        vertical: compact ? AppSpacing.md : AppSpacing.xl,
      ),
      child: AppEmptyState(
        icon: Icons.cloud_off_outlined,
        title: l10n.backendOfflineTitle,
        message: compact ? null : l10n.backendOfflineMessage,
        action: retry,
      ),
    );
  }
}

/// Полоса над рабочей областью: сервер пропал, но интерфейс и настройки
/// остаются доступными, чтобы выбрать или добавить другой профиль.
class BackendOfflineBanner extends StatelessWidget {
  const BackendOfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scope = ProfileScope.maybeOf(context);
    return AppBanner(
      title: l10n.backendOfflineTitle,
      message: l10n.backendOfflineMessage,
      icon: Icons.cloud_off_outlined,
      tone: AppTone.warning,
      action: scope == null
          ? null
          : TextButton(
              onPressed: () => unawaited(scope.agentApi.checkConnection()),
              child: Text(l10n.backendOfflineRetry),
            ),
    );
  }
}
