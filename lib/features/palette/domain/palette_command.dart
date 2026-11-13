import 'package:equatable/equatable.dart';
import 'package:flutter/widgets.dart';
import 'package:pw_agent/agent/domain/search.dart';

/// Текст команды на двух языках. Плагины могут добавить свои локали.
@immutable
class LocalizedText {
  const LocalizedText({
    required this.ru,
    required this.en,
    this.extra = const {},
  });

  final String ru;
  final String en;
  final Map<String, String> extra;

  String forLanguage(String code) => switch (code) {
    'ru' => ru,
    'en' => en,
    _ => extra[code] ?? en,
  };

  Iterable<String> get all => [ru, en, ...extra.values];
}

/// Действие команды палитры. Модель не зависит от `BuildContext`.
sealed class PaletteAction {
  const PaletteAction();
}

/// Встроенное действие приложения.
final class BuiltinPaletteAction extends PaletteAction {
  const BuiltinPaletteAction(this.id);

  final String id;

  @override
  bool operator ==(Object other) =>
      other is BuiltinPaletteAction && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Команда, которую выполняет плагин.
final class PluginPaletteAction extends PaletteAction {
  const PluginPaletteAction(this.pluginId, this.commandId);

  final String pluginId;
  final String commandId;

  @override
  bool operator ==(Object other) =>
      other is PluginPaletteAction &&
      other.pluginId == pluginId &&
      other.commandId == commandId;

  @override
  int get hashCode => Object.hash(pluginId, commandId);
}

/// Команда или группа палитры.
///
/// Группа — команда без [action]. В дереве она раскрывается, в поиске листья
/// показываются плоско с путём до корня.
class PaletteCommand extends Equatable {
  const PaletteCommand({
    required this.id,
    required this.titles,
    this.parentId,
    this.keywords = const LocalizedText(ru: '', en: ''),
    this.icon,
    this.action,
    this.order = 0,
    this.enabled = true,
    this.requiresBackend = true,
  });

  final String id;
  final String? parentId;
  final LocalizedText titles;
  final LocalizedText keywords;
  final IconData? icon;
  final PaletteAction? action;
  final int order;
  final bool enabled;

  /// Команде нужен живой сервер агента. При offline такие команды скрываются.
  final bool requiresBackend;

  bool get isGroup => action == null;

  @override
  List<Object?> get props => [
    id,
    parentId,
    titles,
    keywords,
    icon,
    action,
    order,
    enabled,
    requiresBackend,
  ];
}

/// Вид подсказки фильтра.
enum PaletteSuggestionKind { filter, project, chat, scope }

/// Строка-подсказка в общем списке палитры. Не popup: подсказки живут в том же
/// списке результатов и выбираются теми же стрелками.
class PaletteSuggestion {
  const PaletteSuggestion({
    required this.kind,
    required this.replacement,
    required this.title,
    this.subtitle,
    this.icon,
  });

  final PaletteSuggestionKind kind;

  /// Что вставить в строку поиска вместо активного @-токена.
  final String replacement;
  final String title;
  final String? subtitle;
  final IconData? icon;
}

/// Разобранный фильтр. Хранится для вычисления области поиска.
enum PaletteFilterKind {
  command,
  project,
  current,
  currentProject,
  chat,
  scope,
}

class PaletteFilter extends Equatable {
  const PaletteFilter({required this.kind, required this.raw, this.value});

  final PaletteFilterKind kind;
  final String raw;
  final String? value;

  @override
  List<Object?> get props => [kind, raw, value];
}

/// Строка поиска после разбора: текст и фильтры.
class PaletteQuery extends Equatable {
  const PaletteQuery({
    required this.text,
    this.commandsOnly = false,
    this.scope = SearchScope.all,
    this.projectId,
    this.projectName,
    this.chatId,
    this.chatName,
    this.currentChat = false,
    this.filters = const [],
  });

  final String text;
  final bool commandsOnly;
  final SearchScope scope;

  /// Разрешённый проект. Null — фильтр не задан.
  final String? projectId;

  /// Имя проекта из `@project:...`, пока не разрешено в id.
  final String? projectName;

  /// Разрешённый чат. Null — фильтр не задан.
  final String? chatId;

  /// Имя/заголовок чата из `@chat:...`, пока не разрешён в id.
  final String? chatName;
  final bool currentChat;
  final List<PaletteFilter> filters;

  @override
  List<Object?> get props => [
    text,
    commandsOnly,
    scope,
    projectId,
    projectName,
    chatId,
    chatName,
    currentChat,
    filters,
  ];
}
