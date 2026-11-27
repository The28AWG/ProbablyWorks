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
  static const pauseFocus = 'pause_focus';
  static const pauseMeeting = 'pause_meeting';
  static const pauseOvernight = 'pause_overnight';
  static const resumeNotifications = 'resume_notifications';
}

/// Встроенные команды. Группы имеют `action == null`.
List<PaletteCommand> builtinPaletteCommands(
  AppLocalizations en,
  AppLocalizations ru, {
  required bool hasProject,
  required bool pauseSupported,
  required bool notificationsPaused,
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
  if (pauseSupported) ...[
    PaletteCommand(
      id: 'notifications',
      titles: LocalizedText(
        ru: ru.paletteGroupNotifications,
        en: en.paletteGroupNotifications,
      ),
      keywords: const LocalizedText(
        ru: 'уведомления пауза тишина не беспокоить focus quiet dnd',
        en: 'notifications pause quiet focus silence dnd',
      ),
      icon: notificationsPaused
          ? Icons.notifications_off_outlined
          : Icons.notifications_outlined,
      order: 25,
    ),
    PaletteCommand(
      id: 'notifications.focus',
      parentId: 'notifications',
      titles: LocalizedText(
        ru: ru.settingsPauseFocus,
        en: en.settingsPauseFocus,
      ),
      keywords: const LocalizedText(
        ru: 'уведомления пауза фокус 30 минут тишина',
        en: 'notifications pause focus 30 minutes quiet',
      ),
      icon: Icons.notifications_off_outlined,
      action: const BuiltinPaletteAction(BuiltinPaletteActions.pauseFocus),
      order: 0,
    ),
    PaletteCommand(
      id: 'notifications.meeting',
      parentId: 'notifications',
      titles: LocalizedText(
        ru: ru.settingsPauseMeeting,
        en: en.settingsPauseMeeting,
      ),
      keywords: const LocalizedText(
        ru: 'уведомления пауза встреча час',
        en: 'notifications pause meeting hour',
      ),
      icon: Icons.notifications_off_outlined,
      action: const BuiltinPaletteAction(BuiltinPaletteActions.pauseMeeting),
      order: 1,
    ),
    PaletteCommand(
      id: 'notifications.overnight',
      parentId: 'notifications',
      titles: LocalizedText(
        ru: ru.settingsPauseOvernight,
        en: en.settingsPauseOvernight,
      ),
      keywords: const LocalizedText(
        ru: 'уведомления пауза до утра ночь',
        en: 'notifications pause until morning night',
      ),
      icon: Icons.bedtime_outlined,
      action: const BuiltinPaletteAction(BuiltinPaletteActions.pauseOvernight),
      order: 2,
    ),
    PaletteCommand(
      id: 'notifications.resume',
      parentId: 'notifications',
      titles: LocalizedText(
        ru: ru.notificationPauseResume,
        en: en.notificationPauseResume,
      ),
      keywords: const LocalizedText(
        ru: 'уведомления включить снять паузу',
        en: 'notifications resume enable pause off',
      ),
      icon: Icons.notifications_active_outlined,
      action: const BuiltinPaletteAction(
        BuiltinPaletteActions.resumeNotifications,
      ),
      enabled: notificationsPaused,
      order: 3,
    ),
  ],
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
