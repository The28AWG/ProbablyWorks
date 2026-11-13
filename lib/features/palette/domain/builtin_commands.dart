import 'package:material_ui/material_ui.dart';
import 'package:probably_works/features/palette/domain/palette_command.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Идентификаторы встроенных действий палитры.
abstract final class BuiltinPaletteActions {
  static const newChat = 'new_chat';
  static const chatsTab = 'chats_tab';
  static const projectsTab = 'projects_tab';
  static const hostsTab = 'hosts_tab';
  static const settings = 'settings';
  static const projectMemory = 'project_memory';
  static const refreshModels = 'refresh_models';
}

/// Встроенные команды. Группы имеют `action == null`.
List<PaletteCommand> builtinPaletteCommands(
  AppLocalizations en,
  AppLocalizations ru, {
  required bool hasProject,
}) => [
  PaletteCommand(
    id: 'new_chat',
    titles: LocalizedText(
      ru: ru.paletteCommandNewChat,
      en: en.paletteCommandNewChat,
    ),
    keywords: const LocalizedText(
      ru: 'создать чат новый начать',
      en: 'create chat new start',
    ),
    icon: Icons.add_comment_outlined,
    action: const BuiltinPaletteAction(BuiltinPaletteActions.newChat),
    order: 0,
  ),
  PaletteCommand(
    id: 'nav',
    titles: LocalizedText(
      ru: ru.paletteGroupNavigation,
      en: en.paletteGroupNavigation,
    ),
    keywords: const LocalizedText(
      ru: 'разделы перейти навигация',
      en: 'sections go navigation',
    ),
    icon: Icons.explore_outlined,
    order: 10,
  ),
  PaletteCommand(
    id: 'nav.chats',
    parentId: 'nav',
    titles: LocalizedText(
      ru: ru.paletteCommandChats,
      en: en.paletteCommandChats,
    ),
    keywords: const LocalizedText(ru: 'чаты диалоги', en: 'chats dialogs'),
    icon: Icons.chat_bubble_outline,
    action: const BuiltinPaletteAction(BuiltinPaletteActions.chatsTab),
    requiresBackend: false,
    order: 0,
  ),
  PaletteCommand(
    id: 'nav.projects',
    parentId: 'nav',
    titles: LocalizedText(
      ru: ru.paletteCommandProjects,
      en: en.paletteCommandProjects,
    ),
    keywords: const LocalizedText(ru: 'проекты папки', en: 'projects folders'),
    icon: Icons.workspaces_outline,
    action: const BuiltinPaletteAction(BuiltinPaletteActions.projectsTab),
    requiresBackend: false,
    order: 1,
  ),
  PaletteCommand(
    id: 'nav.hosts',
    parentId: 'nav',
    titles: LocalizedText(
      ru: ru.paletteCommandHosts,
      en: en.paletteCommandHosts,
    ),
    keywords: const LocalizedText(
      ru: 'хосты серверы ssh',
      en: 'hosts servers ssh',
    ),
    icon: Icons.dns_outlined,
    action: const BuiltinPaletteAction(BuiltinPaletteActions.hostsTab),
    requiresBackend: false,
    order: 2,
  ),
  PaletteCommand(
    id: 'nav.settings',
    parentId: 'nav',
    titles: LocalizedText(
      ru: ru.paletteCommandSettings,
      en: en.paletteCommandSettings,
    ),
    keywords: const LocalizedText(
      ru: 'настройки параметры конфигурация',
      en: 'settings preferences configuration',
    ),
    icon: Icons.settings_outlined,
    action: const BuiltinPaletteAction(BuiltinPaletteActions.settings),
    requiresBackend: false,
    order: 3,
  ),
  PaletteCommand(
    id: 'project',
    titles: LocalizedText(
      ru: ru.paletteGroupProject,
      en: en.paletteGroupProject,
    ),
    keywords: const LocalizedText(ru: 'проект', en: 'project'),
    icon: Icons.workspaces_outline,
    order: 20,
  ),
  PaletteCommand(
    id: 'project.memory',
    parentId: 'project',
    titles: LocalizedText(
      ru: ru.paletteCommandProjectMemory,
      en: en.paletteCommandProjectMemory,
    ),
    keywords: const LocalizedText(
      ru: 'память саммари проект',
      en: 'memory summary project',
    ),
    icon: Icons.psychology_outlined,
    action: const BuiltinPaletteAction(BuiltinPaletteActions.projectMemory),
    enabled: hasProject,
    order: 0,
  ),
  PaletteCommand(
    id: 'refresh_models',
    titles: LocalizedText(
      ru: ru.paletteCommandRefreshModels,
      en: en.paletteCommandRefreshModels,
    ),
    keywords: const LocalizedText(
      ru: 'модели каталог обновить',
      en: 'models catalog refresh',
    ),
    icon: Icons.refresh,
    action: const BuiltinPaletteAction(BuiltinPaletteActions.refreshModels),
    order: 30,
  ),
];
