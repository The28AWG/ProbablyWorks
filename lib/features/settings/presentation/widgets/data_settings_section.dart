import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/profiles/profile_scope.dart';
import 'package:probably_works/app/shortcuts/keybinding_service.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/settings/presentation/bloc/data_cubit.dart';
import 'package:probably_works/features/settings/presentation/bloc/settings_cubit.dart';
import 'package:probably_works/features/workspace/presentation/bloc/sidebar_cubit.dart';
import 'package:probably_works/features/workspace/presentation/navigation/workspace_navigation.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/data_api.dart';
import 'package:pw_agent/core/util/byte_size.dart';

/// Что удаляет очистка истории.
enum _ClearScope { all, days30, days90, days365 }

extension on _ClearScope {
  int? get days => switch (this) {
    _ClearScope.all => null,
    _ClearScope.days30 => 30,
    _ClearScope.days90 => 90,
    _ClearScope.days365 => 365,
  };
}

/// Что сбрасывает кнопка настроек.
enum _ResetScope { all, agent, client }

extension on _ResetScope {
  bool get agent => this != _ResetScope.client;
  bool get client => this != _ResetScope.agent;
}

/// Раздел «Данные»: занятое место, очистка истории и сброс настроек.
///
/// Опасные операции подтверждаются диалогом с выбором области. Секреты,
/// хосты, чаты, MCP и профили политики не затрагиваются — это прямо написано
/// в описании, чтобы кнопка не обещала больше, чем делает.
class DataSettingsSection extends StatefulWidget {
  const DataSettingsSection({
    required this.api,
    required this.onReset,
    this.offline = false,
    super.key,
  });

  /// API профиля: локальный сервис или удалённый агент.
  final DataApi api;

  /// Агент недоступен: историю не читаем и не чистим, но настройки
  /// интерфейса сбросить можно.
  final bool offline;

  /// Вызывается после сброса настроек агента: страница перечитывает поля,
  /// которые хранят текст в контроллерах.
  final VoidCallback onReset;

  @override
  State<DataSettingsSection> createState() => _DataSettingsSectionState();
}

class _DataSettingsSectionState extends State<DataSettingsSection> {
  late DataCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = DataCubit(widget.api);
    if (!widget.offline) _cubit.load();
  }

  @override
  void didUpdateWidget(covariant DataSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      _cubit.close();
      _cubit = DataCubit(widget.api);
      if (!widget.offline) _cubit.load();
      return;
    }
    // Агент мог снова стать доступным, когда раздел уже открыт офлайн.
    if (oldWidget.offline && !widget.offline) _cubit.load();
  }

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    // Обе необратимые операции выглядят одинаково: красная обводка и текст.
    final destructiveStyle = OutlinedButton.styleFrom(
      foregroundColor: scheme.error,
      side: BorderSide(color: scheme.error),
    );
    if (widget.offline) {
      return _OfflineDataBody(
        onReset: () => _reset(context, interfaceOnly: true),
      );
    }
    return BlocProvider.value(
      value: _cubit,
      child: BlocBuilder<DataCubit, DataState>(
        builder: (context, state) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.error case final error?)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: AppBanner(
                  message: l10n.commonError(error),
                  tone: AppTone.danger,
                ),
              ),
            AppSection(
              title: l10n.dataUsageTitle,
              description: l10n.dataUsageDescription,
              children: [
                AppCard(
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(
                          // Место под кнопку обновления в правом верхнем углу
                          // карточки: она не должна раздвигать заголовок и описание
                          // и не должна налезать на заглушку загрузки/ошибки.
                          right: AppSpacing.xxl + AppSpacing.lg,
                        ),
                        child: _usageBody(l10n, state),
                      ),
                      Positioned(
                        top: 0,
                        right: 0,
                        child: IconButton(
                          tooltip: l10n.dataUsageRefresh,
                          onPressed: state.busy ? null : _cubit.load,
                          icon: state.loading && state.usage != null
                              ? const SizedBox.square(
                                  dimension: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.refresh),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            AppSection(
              title: l10n.dataClearTitle,
              description: l10n.dataClearDescription,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    style: destructiveStyle,
                    onPressed: state.busy ? null : () => _clearHistory(context),
                    icon: state.clearing
                        ? SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: scheme.error,
                            ),
                          )
                        : const Icon(Icons.delete_outline),
                    label: Text(
                      l10n.dataClearAction,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            AppSection(
              title: l10n.dataResetTitle,
              description: l10n.dataResetDescription,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    style: destructiveStyle,
                    onPressed: state.busy ? null : () => _reset(context),
                    icon: state.resetting
                        ? SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: scheme.error,
                            ),
                          )
                        : const Icon(Icons.restart_alt),
                    label: Text(
                      l10n.dataResetAction,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _usageBody(AppLocalizations l10n, DataState state) {
    final usage = state.usage;
    if (usage == null) {
      return SizedBox(
        height: AppSpacing.xxl * 3,
        child: Center(
          child: state.loading
              ? const CircularProgressIndicator()
              : Text(l10n.dataUsageDescription),
        ),
      );
    }
    return Column(
      children: [
        _UsageLine(
          icon: Icons.forum_outlined,
          text: l10n.dataUsageChats(usage.chats),
        ),
        if (usage.subagentChats > 0)
          _UsageLine(
            icon: Icons.account_tree_outlined,
            text: l10n.dataUsageSubagentChats(usage.subagentChats),
          ),
        _UsageLine(
          icon: Icons.chat_bubble_outline,
          text: l10n.dataUsageMessages(usage.messages),
        ),
        _UsageLine(
          icon: Icons.terminal,
          text: l10n.dataUsageRuns(usage.toolRuns),
        ),
        _UsageLine(
          icon: Icons.schedule_outlined,
          text: l10n.dataUsageScheduled(usage.scheduledTasks),
        ),
        _UsageLine(
          icon: Icons.check_circle_outline,
          text: l10n.dataUsageCompleted(usage.completedTasks),
        ),
        if (usage.failedTasks > 0)
          _UsageLine(
            icon: Icons.error_outline,
            text: l10n.dataUsageFailed(usage.failedTasks),
          ),
        if (usage.cancelledTasks > 0)
          _UsageLine(
            icon: Icons.cancel_outlined,
            text: l10n.dataUsageCancelled(usage.cancelledTasks),
          ),
        _UsageLine(
          icon: Icons.folder_outlined,
          text: l10n.dataUsageFiles(formatByteSize(usage.chatFilesBytes)),
        ),
        _UsageLine(
          icon: Icons.storage_outlined,
          text: l10n.dataUsageDatabase(formatByteSize(usage.databaseBytes)),
        ),
      ],
    );
  }

  Future<void> _clearHistory(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final usage = _cubit.state.usage;
    var scope = _ClearScope.all;
    final confirmed = await ConfirmDialog.confirm(
      context,
      title: l10n.dataClearDialogTitle,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.dataClearConfirm,
      destructive: true,
      content: StatefulBuilder(
        builder: (context, setDialogState) => SizedBox(
          width: AppLayout.dialogWidth,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (usage != null)
                  Text(
                    scope == _ClearScope.all
                        ? l10n.dataClearDialogMessage(
                            usage.chats + usage.subagentChats,
                            usage.messages,
                          )
                        : l10n.dataClearDaysMessage(scope.days!),
                  ),
                const SizedBox(height: AppSpacing.md),
                AppChoiceGroup<_ClearScope>(
                  selected: scope,
                  onChanged: (value) => setDialogState(() => scope = value),
                  options: [
                    AppChoiceOption(
                      value: _ClearScope.all,
                      title: l10n.dataClearScopeAll,
                      subtitle: l10n.dataClearScopeAllHint,
                    ),
                    AppChoiceOption(
                      value: _ClearScope.days30,
                      title: l10n.dataClearScopeDays(30),
                      subtitle: l10n.dataClearScopeDaysHint(30),
                    ),
                    AppChoiceOption(
                      value: _ClearScope.days90,
                      title: l10n.dataClearScopeDays(90),
                      subtitle: l10n.dataClearScopeDaysHint(90),
                    ),
                    AppChoiceOption(
                      value: _ClearScope.days365,
                      title: l10n.dataClearScopeDays(365),
                      subtitle: l10n.dataClearScopeDaysHint(365),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!confirmed || !context.mounted) return;
    final result = await _cubit.clearHistory(olderThanDays: scope.days);
    if (!context.mounted || result == null) return;
    await _leaveDeletedChat(context);
    if (!context.mounted) return;
    AppSnackBar.show(
      context,
      result.compacted
          ? l10n.dataClearDone(
              result.deletedChats,
              formatByteSize(result.freedBytes),
            )
          : l10n.dataClearNotCompacted(result.deletedChats),
    );
  }

  /// Уводит стек вкладки с чата, если история удалила его.
  ///
  /// Очистка из настроек не проходит через список чатов, поэтому маршрут
  /// открытого чата мог остаться. Активный раздел не переключаем: пользователь
  /// остаётся в настройках, а при возврате в чаты видит стартовый экран.
  Future<void> _leaveDeletedChat(BuildContext context) async {
    final scope = ProfileScope.maybeOf(context);
    final chatId = workspaceOpenChatId(context);
    if (scope == null || chatId == null) return;
    try {
      if (await scope.chatApi.chatStore.chat(chatId) == null) {
        if (context.mounted) resetOpenChat(context);
      }
    } on Object {
      // Профиль offline: маршрут не трогаем, список обновится после связи.
    }
  }

  Future<void> _reset(
    BuildContext context, {
    bool interfaceOnly = false,
  }) async {
    final l10n = AppLocalizations.of(context);
    var scope = interfaceOnly ? _ResetScope.client : _ResetScope.all;
    final confirmed = await ConfirmDialog.confirm(
      context,
      title: l10n.dataResetDialogTitle,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.dataResetConfirm,
      destructive: true,
      content: interfaceOnly
          ? Text(l10n.dataResetOfflineMessage)
          : StatefulBuilder(
              builder: (context, setDialogState) => SizedBox(
                width: AppLayout.dialogWidth,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(l10n.dataResetDialogMessage),
                      const SizedBox(height: AppSpacing.md),
                      AppChoiceGroup<_ResetScope>(
                        selected: scope,
                        onChanged: (value) =>
                            setDialogState(() => scope = value),
                        options: [
                          AppChoiceOption(
                            value: _ResetScope.all,
                            title: l10n.dataResetScopeAll,
                            subtitle: l10n.dataResetScopeAllHint,
                          ),
                          AppChoiceOption(
                            value: _ResetScope.agent,
                            title: l10n.dataResetScopeAgent,
                            subtitle: l10n.dataResetScopeAgentHint,
                          ),
                          AppChoiceOption(
                            value: _ResetScope.client,
                            title: l10n.dataResetScopeClient,
                            subtitle: l10n.dataResetScopeClientHint,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
    if (!confirmed || !context.mounted) return;

    final settingsCubit = context.read<SettingsCubit>();
    try {
      if (scope.client) {
        await settingsCubit.resetClientPreferences();
        await getIt<KeybindingService>().resetAll();
        if (context.mounted) await context.read<SidebarCubit>().resetWidth();
      }
    } on Object catch (error) {
      if (context.mounted) {
        AppSnackBar.show(context, l10n.commonError('$error'));
      }
      return;
    }

    if (scope.agent && !widget.offline) {
      final reset = await _cubit.resetSettings();
      if (!reset || !context.mounted) return;
      await settingsCubit.reload();
      if (!context.mounted) return;
      widget.onReset();
    }
    if (context.mounted) AppSnackBar.show(context, l10n.dataResetDone);
  }
}

class _UsageLine extends StatelessWidget {
  const _UsageLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Раздел «Данные», когда агент недоступен: история не читается, но
/// настройки интерфейса сбросить можно.
class _OfflineDataBody extends StatelessWidget {
  const _OfflineDataBody({required this.onReset});

  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppBanner(
          title: l10n.dataOfflineTitle,
          message: l10n.dataResetOfflineMessage,
          tone: AppTone.info,
        ),
        const SizedBox(height: AppSpacing.md),
        AppSection(
          title: l10n.dataResetTitle,
          description: l10n.dataResetDescription,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: scheme.error,
                  side: BorderSide(color: scheme.error),
                ),
                onPressed: onReset,
                icon: const Icon(Icons.restart_alt),
                label: Text(
                  l10n.dataResetAction,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
