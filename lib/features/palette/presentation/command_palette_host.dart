import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/profiles/profile_scope.dart';
import 'package:probably_works/app/shortcuts/keybinding_service.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/features/palette/domain/builtin_commands.dart';
import 'package:probably_works/features/palette/domain/command_plugin_registry.dart';
import 'package:probably_works/features/palette/domain/command_registry.dart';
import 'package:probably_works/features/palette/domain/palette_command.dart';
import 'package:probably_works/features/palette/presentation/command_palette.dart';
import 'package:probably_works/features/palette/presentation/palette_controller.dart';
import 'package:probably_works/features/projects/presentation/bloc/projects_cubit.dart';
import 'package:probably_works/features/settings/presentation/settings_navigation.dart';
import 'package:probably_works/features/workspace/presentation/navigation/workspace_navigation.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/domain/search.dart';

/// Перехватывает глобальную горячую клавишу и показывает единую палитру.
///
/// Живёт внутри [AutoTabsRouter] и [ProfileScope]: отсюда доступны навигация,
/// активный чат/проект и API профиля.
class CommandPaletteHost extends StatefulWidget {
  const CommandPaletteHost({required this.child, super.key});

  final Widget child;

  @override
  State<CommandPaletteHost> createState() => _CommandPaletteHostState();
}

class _CommandPaletteHostState extends State<CommandPaletteHost> {
  var _open = false;
  final _pluginCommands = <String, PluginCommand>{};
  late final KeybindingService _keybindings;

  @override
  void initState() {
    super.initState();
    _keybindings = getIt<KeybindingService>();
    unawaited(_keybindings.load());
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (_open) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    final action = _keybindings.actionFor(event);
    if (action == null) return false;
    switch (action) {
      case KeybindingActions.paletteOpen:
        unawaited(_showPalette());
      case KeybindingActions.chatNew:
        openNewChat(context);
      case KeybindingActions.settingsOpen:
        openSettingsTab();
    }
    return true;
  }

  Future<void> _showPalette() async {
    if (_open) return;
    _open = true;
    try {
      await _openPalette();
    } on Object {
      _open = false;
      rethrow;
    }
  }

  Future<void> _openPalette() async {
    final tabs = AutoTabsRouter.of(context);
    final currentChatId = selectedChatIdOf(tabs);
    final currentProjectId = _currentProjectId();
    final languageCode = Localizations.localeOf(context).languageCode;
    final l10n = AppLocalizations.of(context);
    final en = lookupAppLocalizations(const Locale('en'));
    final ru = lookupAppLocalizations(const Locale('ru'));
    final plugin = await _loadPluginCommands();
    if (!mounted) {
      _open = false;
      return;
    }
    _pluginCommands
      ..clear()
      ..addAll(plugin.byId);
    final registry = CommandRegistry([
      ...builtinPaletteCommands(en, ru, hasProject: currentProjectId != null),
      ...plugin.commands,
    ]);
    final projectsCubit = context.read<ProjectsCubit>();
    final agentApi = ProfileScope.of(context).agentApi;
    final controller = PaletteController(
      registry: registry,
      searchApi: agentApi,
      projects: projectsCubit.state.projects,
      chats: context.read<ChatListCubit>().state.chats,
      labels: PaletteLabels(
        command: l10n.paletteFilterCommand,
        project: l10n.paletteSuggestionProject,
        current: l10n.paletteFilterCurrentChat,
        currentProject: l10n.paletteFilterCurrentProject,
        chat: l10n.paletteSuggestionChat,
        scope: l10n.paletteSuggestionScope,
        allChats: l10n.paletteScopeAll,
        projectScope: l10n.paletteScopeProject,
        chatScope: l10n.paletteScopeChat,
      ),
      languageCode: languageCode,
      currentChatId: currentChatId,
      currentProjectId: currentProjectId,
      backendOnline: agentApi.status != AgentStatus.offline,
    );
    // Статус может измениться, пока диалог открыт: команды с серверной
    // зависимостью должны исчезнуть/появиться сразу.
    final backendSub = agentApi.statusChanges.listen(
      (status) => controller.updateBackendStatus(status != AgentStatus.offline),
    );
    // Проекты приходят потоком и могли не успеть к первому кадру палитры.
    // Подписка обновляет подсказки `@project:` без переоткрытия окна.
    final projectsSub = projectsCubit.stream.listen(
      (state) => controller.updateProjects(state.projects),
    );
    controller.updateProjects(projectsCubit.state.projects);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierColor: Theme.of(context).colorScheme.scrim
            .withValues(alpha: 0.45),
        builder: (dialogContext) => CommandPaletteDialog(
          controller: controller,
          onClose: () => Navigator.of(dialogContext).pop(),
          onCommand: (command) {
            Navigator.of(dialogContext).pop();
            _run(command, projectId: currentProjectId);
          },
          onHit: (hit) {
            Navigator.of(dialogContext).pop();
            _openHit(hit);
          },
        ),
      ).whenComplete(() {
        _open = false;
        unawaited(projectsSub.cancel());
        unawaited(backendSub.cancel());
        controller.dispose();
      }),
    );
  }

  void _run(PaletteCommand command, {String? projectId}) {
    final action = command.action;
    if (action is PluginPaletteAction) {
      final pluginCommand =
          _pluginCommands['plugin:${action.pluginId}:${action.commandId}'];
      if (pluginCommand != null) {
        unawaited(pluginCommand.run(_PluginCommandHost(this)));
      }
      return;
    }
    if (action is! BuiltinPaletteAction) return;
    switch (action.id) {
      case BuiltinPaletteActions.newChat:
        openNewChat(context);
      case BuiltinPaletteActions.chatsTab:
        showWorkspaceTab(context, WorkspaceTab.chats);
      case BuiltinPaletteActions.projectsTab:
        showWorkspaceTab(context, WorkspaceTab.projects);
      case BuiltinPaletteActions.hostsTab:
        showWorkspaceTab(context, WorkspaceTab.hosts);
      case BuiltinPaletteActions.settings:
        showWorkspaceTab(context, WorkspaceTab.settings);
      case BuiltinPaletteActions.projectMemory:
        // Берём проект, с которым палитра открывалась: за время показа
        // диалога выбранный чат мог пропасть из ещё не загруженного списка.
        final target = projectId ?? _currentProjectId();
        if (target != null) openProject(context, target);
      case BuiltinPaletteActions.refreshModels:
        unawaited(_refreshModels());
    }
  }

  Future<({List<PaletteCommand> commands, Map<String, PluginCommand> byId})>
  _loadPluginCommands() async {
    final plugins = getIt<CommandPluginRegistry>().plugins;
    final commands = <PaletteCommand>[];
    final byId = <String, PluginCommand>{};
    if (plugins.isEmpty) return (commands: commands, byId: byId);
    final pluginApi = ProfileScope.maybeOf(context)?.pluginApi;
    for (final plugin in plugins) {
      final groupId = 'plugin:${plugin.id}';
      final groupTitles = _localizedFrom(plugin.titles, plugin.id);
      commands.add(
        PaletteCommand(
          id: groupId,
          titles: groupTitles,
          icon: Icons.extension_outlined,
          order: 40,
        ),
      );
      try {
        final list = await plugin.createCommands(
          pluginApi?.settingsFor(plugin.id) ?? const _EmptyPluginSettings(),
        );
        for (final command in list) {
          final id = '$groupId:${command.id}';
          byId[id] = command;
          commands.add(
            PaletteCommand(
              id: id,
              parentId: command.parentId == null
                  ? groupId
                  : '$groupId:${command.parentId}',
              titles: _localizedFrom(command.titles, command.id),
              keywords: _localizedFrom(command.keywords, ''),
              action: PluginPaletteAction(plugin.id, command.id),
              order: commands.length,
              requiresBackend: command.requiresBackend,
            ),
          );
        }
      } on Object {
        // Сломанный плагин не должен ломать палитру.
      }
    }
    return (commands: commands, byId: byId);
  }

  static LocalizedText _localizedFrom(
    Map<String, String> values,
    String fallback,
  ) {
    final en = values['en'] ?? values['ru'] ?? fallback;
    final ru = values['ru'] ?? values['en'] ?? fallback;
    return LocalizedText(ru: ru, en: en, extra: values);
  }

  String? _currentProjectId() {
    final tabs = AutoTabsRouter.of(context);
    final direct = selectedProjectIdOf(tabs);
    if (direct != null) return direct;
    final chatId = selectedChatIdOf(tabs);
    return context
        .read<ChatListCubit>()
        .state
        .chats
        .where((chat) => chat.id == chatId)
        .firstOrNull
        ?.projectId;
  }

  Future<void> _refreshModels() async {
    final l10n = AppLocalizations.of(context);
    AppSnackBar.show(context, l10n.paletteModelsRefreshing);
    try {
      await ProfileScope.of(context).chatApi.models.refresh();
      if (!mounted) return;
      AppSnackBar.show(context, l10n.paletteModelsRefreshed);
    } on Object catch (error) {
      if (!mounted) return;
      AppSnackBar.show(context, l10n.commonError('$error'));
    }
  }

  void _openHit(SearchHit hit) {
    final chatId = hit.chatId;
    if (chatId != null) {
      openChat(context, chatId, messageId: hit.messageId);
    }
  }

  void openChatById(String chatId) => openChat(context, chatId);

  void openNewChatPage() => openNewChat(context);

  void openSettingsTab([String? category]) {
    showWorkspaceTab(context, WorkspaceTab.settings);
    if (category != null && category.isNotEmpty) {
      settingsRequestedGroup.value = category;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

final class _EmptyPluginSettings implements PluginSettings {
  const _EmptyPluginSettings();

  @override
  Future<Map<String, Object?>> read() async => const {};

  @override
  Future<void> save(Map<String, Object?> value) => Future<void>.value();
}

final class _PluginCommandHost implements PluginCommandHost {
  const _PluginCommandHost(this._host);

  final _CommandPaletteHostState _host;

  @override
  Future<void> openChat(String chatId) async {
    _host.openChatById(chatId);
  }

  @override
  Future<void> newChat() async {
    _host.openNewChatPage();
  }

  @override
  Future<void> openSettings({String? category}) async {
    _host.openSettingsTab(category);
  }

  @override
  void notify(String message) {
    AppSnackBar.show(_host.context, message);
  }
}
