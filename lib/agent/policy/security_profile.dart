/// Настраиваемые уровни риска команд.
///
/// Три слоя, от общего к частному: категория базы знаний, команда, аргумент.
/// Более частный слой заменяет общий, а не складывается с ним: `sort` может
/// выполняться сам, а `sort -o` — спрашивать. Несколько подошедших аргументов
/// дают самый строгий из них.
///
/// Жёсткий пол классификатора этим профилем не опускается: эскалация,
/// критическая находка, denylist, оборванная команда, пайп и присваивание
/// в параметре остаются как минимум на своём прежнем уровне.
library;

import 'dart:convert';

import 'package:command_shield/command_shield.dart';
import 'package:equatable/equatable.dart';
import 'package:probably_works/agent/policy/command_risk.dart';

/// Как именно аргумент выбирает вызов.
enum ArgumentMatchKind {
  /// Токен совпал с аргументом: `-o`, `-oфайл`, `--output`, `--output=файл`.
  flag,

  /// Первый аргумент без дефиса, подкоманда (`git status`).
  subcommand,

  /// У команды есть хотя бы один аргумент (`hostname box`).
  anyArgument,
}

/// Правило аргумента: для одной команды и одного способа совпадения.
class ArgumentRuleConfig extends Equatable {
  /// Создаёт правило. [token] пустой только у [ArgumentMatchKind.anyArgument].
  const ArgumentRuleConfig({
    required this.executable,
    required this.kind,
    required this.token,
    required this.risk,
  });

  /// Имя программы после нормализации, в нижнем регистре.
  final String executable;

  /// Каким способом аргумент узнаётся.
  final ArgumentMatchKind kind;

  /// Флаг или подкоманда. Для [ArgumentMatchKind.anyArgument] не используется.
  final String token;

  /// Уровень, который заменяет уровень команды, когда правило подошло.
  final CommandRisk risk;

  /// Подходит ли правило к аргументам одного вызова.
  bool matches(List<String> args) {
    switch (kind) {
      case ArgumentMatchKind.flag:
        final needle = token.toLowerCase();
        for (final arg in args) {
          final value = arg.toLowerCase();
          if (value == needle) return true;
          if (needle.startsWith('--') && value.startsWith('$needle=')) {
            return true;
          }
          // Короткий флаг склеивается со значением: `-oфайл`.
          if (_isShortFlag(needle) &&
              value.startsWith(needle) &&
              value.length > needle.length) {
            return true;
          }
        }
        return false;
      case ArgumentMatchKind.subcommand:
        return _firstPositional(args)?.toLowerCase() == token.toLowerCase();
      case ArgumentMatchKind.anyArgument:
        return args.isNotEmpty;
    }
  }

  /// Тот же слот настройки: одна команда, один способ, один токен.
  bool sameSlot(ArgumentRuleConfig other) =>
      executable == other.executable &&
      kind == other.kind &&
      (kind == ArgumentMatchKind.anyArgument || token == other.token);

  @override
  List<Object?> get props => [executable, kind, token, risk];
}

/// Профиль уровней. Константа без аргументов — встроенные уровни.
class SecurityProfile extends Equatable {
  /// Создаёт профиль. Пропущенные карты — встроенные уровни.
  const SecurityProfile({
    this.categories = _baselineCategories,
    this.commands = _baselineCommands,
    this.arguments = _baselineArguments,
  });

  /// Разбирает [raw]. При ошибке или другой версии возвращает встроенный профиль:
  /// полупонятый документ не должен ослабить уровни молча.
  factory SecurityProfile.decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['version'] != 1) return const SecurityProfile();
      return SecurityProfile(
        categories: _readCategories(json['categories']),
        commands: _readCommands(json['commands']),
        arguments: _readArguments(json['arguments']),
      );
    } on FormatException {
      return const SecurityProfile();
    }
  }

  /// Уровень категории, если у команды нет своего.
  final Map<KnowledgeCategory, CommandRisk> categories;

  /// Свой уровень команды. Ключ — нормализованное имя.
  final Map<String, CommandRisk> commands;

  /// Правила аргументов. Заменяют уровень команды, когда подходят.
  final List<ArgumentRuleConfig> arguments;

  /// Уровень одного вызова до жёсткого пола классификатора.
  ///
  /// Неизвестная команда без своей записи спрашивает подтверждение.
  CommandRisk levelFor({
    required String executable,
    required List<String> args,
    required KnowledgeCategory? category,
  }) {
    var level = commands[executable];
    level ??= category == null
        ? CommandRisk.ask
        : (categories[category] ?? CommandRisk.ask);
    CommandRisk? fromArgument;
    for (final rule in arguments) {
      if (rule.executable != executable || !rule.matches(args)) continue;
      final risk = rule.risk;
      if (fromArgument == null || risk.index > fromArgument.index) {
        fromArgument = risk;
      }
    }
    return fromArgument ?? level;
  }

  /// Заменяет уровень категории.
  SecurityProfile withCategory(KnowledgeCategory category, CommandRisk risk) =>
      SecurityProfile(
        categories: {...categories, category: risk},
        commands: commands,
        arguments: arguments,
      );

  /// Задаёт свой уровень команде.
  SecurityProfile withCommand(String executable, CommandRisk risk) =>
      SecurityProfile(
        categories: categories,
        commands: {...commands, executable: risk},
        arguments: arguments,
      );

  /// Убирает свой уровень: команда снова берёт уровень категории.
  SecurityProfile withoutCommand(String executable) {
    final next = Map<String, CommandRisk>.of(commands)..remove(executable);
    return SecurityProfile(
      categories: categories,
      commands: next,
      arguments: arguments,
    );
  }

  /// Добавляет или заменяет правило в том же слоте.
  SecurityProfile withArgument(ArgumentRuleConfig rule) => SecurityProfile(
    categories: categories,
    commands: commands,
    arguments: [
      for (final current in arguments)
        if (!current.sameSlot(rule)) current,
      rule,
    ],
  );

  /// Удаляет правило того же слота.
  SecurityProfile withoutArgument(ArgumentRuleConfig rule) => SecurityProfile(
    categories: categories,
    commands: commands,
    arguments: [
      for (final current in arguments)
        if (!current.sameSlot(rule)) current,
    ],
  );

  /// Возвращает категории, командам и аргументам этой категории встроенные уровни.
  SecurityProfile restoreCategory(
    KnowledgeCategory category,
    Set<String> names,
  ) {
    const baseline = SecurityProfile();
    return SecurityProfile(
      categories: {...categories, category: CommandRisk.ask},
      commands: {
        for (final entry in commands.entries)
          if (!names.contains(entry.key)) entry.key: entry.value,
        for (final entry in baseline.commands.entries)
          if (names.contains(entry.key)) entry.key: entry.value,
      },
      arguments: [
        for (final rule in arguments)
          if (!names.contains(rule.executable)) rule,
        for (final rule in baseline.arguments)
          if (names.contains(rule.executable)) rule,
      ],
    );
  }

  /// JSON для kv-настройки. Неполный или чужой документ читается как встроенный профиль.
  String encode() => jsonEncode({
    'version': 1,
    'categories': {
      for (final entry in categories.entries) entry.key.name: entry.value.name,
    },
    'commands': {
      for (final entry in commands.entries) entry.key: entry.value.name,
    },
    'arguments': [
      for (final rule in arguments)
        {
          'executable': rule.executable,
          'kind': rule.kind.name,
          'token': rule.token,
          'risk': rule.risk.name,
        },
    ],
  });

  @override
  List<Object?> get props => [categories, commands, arguments];
}

const _baselineCategories = {
  KnowledgeCategory.versionControl: CommandRisk.ask,
  KnowledgeCategory.filesystem: CommandRisk.ask,
  KnowledgeCategory.archive: CommandRisk.ask,
  KnowledgeCategory.compression: CommandRisk.ask,
  KnowledgeCategory.hash: CommandRisk.ask,
  KnowledgeCategory.crypto: CommandRisk.ask,
  KnowledgeCategory.database: CommandRisk.ask,
  KnowledgeCategory.editor: CommandRisk.ask,
  KnowledgeCategory.packageManager: CommandRisk.ask,
  KnowledgeCategory.container: CommandRisk.ask,
  KnowledgeCategory.infrastructure: CommandRisk.ask,
  KnowledgeCategory.network: CommandRisk.ask,
  KnowledgeCategory.shell: CommandRisk.ask,
  KnowledgeCategory.interpreter: CommandRisk.ask,
  KnowledgeCategory.process: CommandRisk.ask,
  KnowledgeCategory.system: CommandRisk.ask,
  KnowledgeCategory.environment: CommandRisk.ask,
  KnowledgeCategory.other: CommandRisk.ask,
};

const _baselineCommands = {
  'basename': CommandRisk.auto,
  'cat': CommandRisk.auto,
  'date': CommandRisk.auto,
  'df': CommandRisk.auto,
  'dirname': CommandRisk.auto,
  'du': CommandRisk.auto,
  'echo': CommandRisk.auto,
  'file': CommandRisk.auto,
  'free': CommandRisk.auto,
  'grep': CommandRisk.auto,
  'head': CommandRisk.auto,
  'hostname': CommandRisk.auto,
  'id': CommandRisk.auto,
  'ls': CommandRisk.auto,
  'lscpu': CommandRisk.auto,
  'md5sum': CommandRisk.auto,
  'nproc': CommandRisk.auto,
  'printenv': CommandRisk.auto,
  'ps': CommandRisk.auto,
  'pwd': CommandRisk.auto,
  'readlink': CommandRisk.auto,
  'realpath': CommandRisk.auto,
  'rg': CommandRisk.auto,
  'sha256sum': CommandRisk.auto,
  'sort': CommandRisk.auto,
  'stat': CommandRisk.auto,
  'tail': CommandRisk.auto,
  'tree': CommandRisk.auto,
  'uname': CommandRisk.auto,
  'uniq': CommandRisk.auto,
  'uptime': CommandRisk.auto,
  'wc': CommandRisk.auto,
  'which': CommandRisk.auto,
  'whoami': CommandRisk.auto,
};

const _baselineArguments = [
  ArgumentRuleConfig(
    executable: 'sort',
    kind: ArgumentMatchKind.flag,
    token: '-o',
    risk: CommandRisk.ask,
  ),
  ArgumentRuleConfig(
    executable: 'sort',
    kind: ArgumentMatchKind.flag,
    token: '--output',
    risk: CommandRisk.ask,
  ),
  ArgumentRuleConfig(
    executable: 'date',
    kind: ArgumentMatchKind.flag,
    token: '-s',
    risk: CommandRisk.ask,
  ),
  ArgumentRuleConfig(
    executable: 'date',
    kind: ArgumentMatchKind.flag,
    token: '--set',
    risk: CommandRisk.ask,
  ),
  ArgumentRuleConfig(
    executable: 'hostname',
    kind: ArgumentMatchKind.anyArgument,
    token: '',
    risk: CommandRisk.ask,
  ),
  ArgumentRuleConfig(
    executable: 'git',
    kind: ArgumentMatchKind.subcommand,
    token: 'status',
    risk: CommandRisk.auto,
  ),
  ArgumentRuleConfig(
    executable: 'git',
    kind: ArgumentMatchKind.subcommand,
    token: 'diff',
    risk: CommandRisk.auto,
  ),
  ArgumentRuleConfig(
    executable: 'git',
    kind: ArgumentMatchKind.subcommand,
    token: 'log',
    risk: CommandRisk.auto,
  ),
  ArgumentRuleConfig(
    executable: 'git',
    kind: ArgumentMatchKind.subcommand,
    token: 'show',
    risk: CommandRisk.auto,
  ),
  ArgumentRuleConfig(
    executable: 'git',
    kind: ArgumentMatchKind.subcommand,
    token: 'branch',
    risk: CommandRisk.auto,
  ),
  ArgumentRuleConfig(
    executable: 'git',
    kind: ArgumentMatchKind.subcommand,
    token: 'rev-parse',
    risk: CommandRisk.auto,
  ),
  ArgumentRuleConfig(
    executable: 'git',
    kind: ArgumentMatchKind.subcommand,
    token: 'remote',
    risk: CommandRisk.auto,
  ),
  ArgumentRuleConfig(
    executable: 'git',
    kind: ArgumentMatchKind.subcommand,
    token: 'ls-files',
    risk: CommandRisk.auto,
  ),
];

bool _isShortFlag(String token) =>
    token.startsWith('-') && !token.startsWith('--') && token.length == 2;

String? _firstPositional(List<String> args) {
  for (final arg in args) {
    if (!arg.startsWith('-')) return arg;
  }
  return null;
}

Map<KnowledgeCategory, CommandRisk> _readCategories(Object? raw) {
  final levels = Map<KnowledgeCategory, CommandRisk>.of(_baselineCategories);
  if (raw is! Map) return levels;
  for (final entry in raw.entries) {
    final category = _category(entry.key);
    final risk = _risk(entry.value);
    if (category != null && risk != null) levels[category] = risk;
  }
  return levels;
}

Map<String, CommandRisk> _readCommands(Object? raw) {
  if (raw is! Map) return Map<String, CommandRisk>.of(_baselineCommands);
  final levels = <String, CommandRisk>{};
  for (final entry in raw.entries) {
    final risk = _risk(entry.value);
    if (entry.key is String && risk != null) {
      levels[(entry.key as String).toLowerCase()] = risk;
    }
  }
  return levels;
}

List<ArgumentRuleConfig> _readArguments(Object? raw) {
  if (raw is! List) return List<ArgumentRuleConfig>.of(_baselineArguments);
  final rules = <ArgumentRuleConfig>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final executable = item['executable'];
    final token = item['token'];
    final kind = _kind(item['kind']);
    final risk = _risk(item['risk']);
    if (executable is! String || token is! String) continue;
    if (kind == null || risk == null || executable.isEmpty) continue;
    rules.add(
      ArgumentRuleConfig(
        executable: executable.toLowerCase(),
        kind: kind,
        token: token,
        risk: risk,
      ),
    );
  }
  return rules;
}

KnowledgeCategory? _category(Object? name) {
  if (name is! String) return null;
  for (final category in KnowledgeCategory.values) {
    if (category.name == name) return category;
  }
  return null;
}

CommandRisk? _risk(Object? name) {
  if (name is! String) return null;
  for (final risk in CommandRisk.values) {
    if (risk.name == name) return risk;
  }
  return null;
}

ArgumentMatchKind? _kind(Object? name) {
  if (name is! String) return null;
  for (final kind in ArgumentMatchKind.values) {
    if (kind.name == name) return kind;
  }
  return null;
}
