import 'dart:convert';

import 'package:probably_works/agent/policy/command_classifier.dart';
import 'package:probably_works/agent/policy/policy_engine.dart';
import 'package:probably_works/agent/tools/tool_catalog.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// Что вызов читает и пишет. Планировщик батча запускает параллельно только те
/// вызовы, чьи эффекты не пересекаются: запись и следующее чтение того же пути
/// остаются в порядке модели, а два чтения — нет.
///
/// Пути сравниваются лексически, без обращения к Host: `a/../b` и `b` — один
/// файл. Симлинки и `~` не раскрываются, поэтому `~/a` и абсолютный домашний
/// путь планировщик считает разными. Это тот же предел, что у записи: Host
/// тоже получает путь как его прислала модель.
class ToolEffect {
  const ToolEffect({
    this.fileReads = const {},
    this.treeReads = const {},
    this.dirReads = const {},
    this.fileWrites = const {},
    this.hostRead = false,
    this.hostWrite = false,
    this.sessionRead = false,
    this.sessionWrite = false,
    this.hostsRead = false,
    this.hostsWrite = false,
    this.settingsRead = false,
    this.settingsWrite = false,
    this.transcriptRead = false,
  });

  /// Точные файлы, содержимое которых вызов читает.
  final Set<String> fileReads;

  /// Корни деревьев: чтение видит любой файл внутри (grep, каталог skills).
  final Set<String> treeReads;

  /// Каталоги, чей список имён вызов читает. Запись файла задевает только
  /// непосредственного родителя, не всех предков.
  final Set<String> dirReads;

  /// Файлы, которые вызов перезаписывает. Две записи разных файлов не
  /// конфликтуют, даже если у них общий родитель: список каталога меняется
  /// у обоих, но читателя этого списка между ними нет.
  final Set<String> fileWrites;

  /// Команда читает хост, но не сообщает какие файлы. Конфликтует с любой записью.
  final bool hostRead;

  /// Команда может изменить хост. Барьер для остальных операций этого хоста.
  final bool hostWrite;

  /// Чтение запечатанных ревизий состояния задачи.
  final bool sessionRead;

  /// Запись текущей ревизии. `mutate` читает и сохраняет её без своего замка.
  final bool sessionWrite;

  /// Реестр хостов приложения.
  final bool hostsRead;

  /// Запись реестра. Проверка подключения тоже пишет сюда время и ошибку
  /// последней проверки, хотя политика её не спрашивает.
  final bool hostsWrite;

  /// Настройки приложения.
  final bool settingsRead;
  final bool settingsWrite;

  /// Поиск по уже записанным сообщениям чата. Сам по себе ни с чем не
  /// пересекается: планировщик ждёт, пока предыдущие результаты лягут в ленту.
  final bool transcriptRead;

  /// Есть ли пересечение записи одной стороны с чтением или записью другой.
  bool conflictsWith(ToolEffect other) =>
      _hits(this, other) || _hits(other, this);
}

/// Путь так, как его получит Host. Относительный считается от workspace,
/// абсолютный и `~` не переписываются.
String hostToolPath(String? workspace, String path) {
  if (path.startsWith('/') ||
      path.startsWith('~') ||
      _windowsDrive.hasMatch(path)) {
    return path;
  }
  if (workspace == null || workspace.isEmpty) return path;
  return '$workspace/$path';
}

/// Ключ конфликта: [hostToolPath], затем лексическая нормализация.
String toolPathKey(String? workspace, String path) =>
    _lexical(hostToolPath(workspace, path.trim()));

/// Эффект вызова до запуска. Битый JSON эффекта не даёт: исполнитель отвергнет
/// аргументы, не трогая Host. Неизвестная команда с риском deny тоже ничего не
/// меняет. Команда с риском ask — запись всего хоста, даже если политика ещё
/// спросит: карточку можно показать сразу, а зависимый вызов подождёт решение.
ToolEffect toolEffectFor(
  LlmToolCall call, {
  required String? workspace,
  required PolicyEngine policy,
  required HostKind hostKind,
}) {
  final args = _decodeArgs(call.arguments);
  if (args == null) return const ToolEffect();
  return switch (call.name) {
    ToolNames.readFile => _fileRead(workspace, args),
    ToolNames.listDir => _dirRead(workspace, args),
    ToolNames.grep => _treeRead(workspace, args),
    ToolNames.writeFile || ToolNames.editFile => _fileWrite(workspace, args),
    ToolNames.runCommand => _command(args, policy, hostKind),
    ToolNames.setGoal ||
    ToolNames.updatePlan ||
    ToolNames.pinFact ||
    ToolNames.unpinFact => const ToolEffect(sessionWrite: true),
    ToolNames.listStateRevisions ||
    ToolNames.getStateRevision => const ToolEffect(sessionRead: true),
    ToolNames.chatHistorySearch => const ToolEffect(transcriptRead: true),
    ToolNames.listSkills || ToolNames.loadSkill => _skills(workspace),
    ToolNames.hostList => const ToolEffect(hostsRead: true),
    ToolNames.hostTest ||
    ToolNames.hostDiagnose ||
    ToolNames.hostAdd ||
    ToolNames.hostUpdate => const ToolEffect(hostsWrite: true),
    ToolNames.settingsRead => const ToolEffect(settingsRead: true),
    ToolNames.settingsUpdate => const ToolEffect(settingsWrite: true),
    _ => const ToolEffect(),
  };
}

/// Аргументы вызова. null — JSON не объект: исполнитель завершится ошибкой.
Map<String, dynamic>? _decodeArgs(String raw) {
  if (raw.trim().isEmpty) return {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return decoded.cast<String, dynamic>();
  } on FormatException {
    return null;
  }
}

final _windowsDrive = RegExp(r'^[A-Za-z]:[\\/]');
final _driveSegment = RegExp(r'^[A-Za-z]:$');

ToolEffect _fileRead(String? workspace, Map<String, dynamic> args) {
  final path = _path(workspace, args);
  if (path == null) return const ToolEffect(hostRead: true);
  return ToolEffect(fileReads: {path});
}

ToolEffect _dirRead(String? workspace, Map<String, dynamic> args) {
  final path = _path(workspace, args);
  if (path == null) return const ToolEffect(hostRead: true);
  return ToolEffect(dirReads: {path});
}

ToolEffect _treeRead(String? workspace, Map<String, dynamic> args) {
  final path = _path(workspace, args);
  if (path == null) return const ToolEffect(hostRead: true);
  return ToolEffect(treeReads: {path});
}

ToolEffect _fileWrite(String? workspace, Map<String, dynamic> args) {
  final path = _path(workspace, args);
  if (path == null) return const ToolEffect(hostWrite: true);
  return ToolEffect(fileWrites: {path});
}

/// Виртуальный Host отвергает фон до запуска: эффекта нет. Deny-команда тоже
/// не запускается. Остальной фон и обычная мутирующая команда — запись хоста.
ToolEffect _command(
  Map<String, dynamic> args,
  PolicyEngine policy,
  HostKind hostKind,
) {
  final background = args['background'] == true;
  if (background && hostKind == HostKind.virtual) return const ToolEffect();
  final command = args['command'];
  final text = command is String ? command : '';
  return switch (policy.classifier.classify(text).risk) {
    CommandRisk.auto => const ToolEffect(hostRead: true),
    CommandRisk.ask => const ToolEffect(hostWrite: true),
    CommandRisk.deny => const ToolEffect(),
  };
}

ToolEffect _skills(String? workspace) {
  if (workspace == null || workspace.isEmpty) return const ToolEffect();
  return ToolEffect(
    fileReads: {toolPathKey(workspace, 'AGENTS.md')},
    treeReads: {
      toolPathKey(workspace, '.probablyworks/skills'),
      toolPathKey(workspace, '.cursor/skills'),
    },
  );
}

String? _path(String? workspace, Map<String, dynamic> args) {
  final value = args['path'];
  if (value is! String || value.isEmpty) return null;
  return toolPathKey(workspace, value);
}

bool _hits(ToolEffect writer, ToolEffect other) {
  if (writer.hostWrite && _touchesHost(other)) return true;
  if (writer.sessionWrite && (other.sessionRead || other.sessionWrite)) {
    return true;
  }
  if (writer.hostsWrite && (other.hostsRead || other.hostsWrite)) return true;
  if (writer.settingsWrite && (other.settingsRead || other.settingsWrite)) {
    return true;
  }
  for (final path in writer.fileWrites) {
    if (other.hostRead || other.hostWrite) return true;
    if (other.fileReads.contains(path) || other.fileWrites.contains(path)) {
      return true;
    }
    for (final tree in other.treeReads) {
      if (_covers(tree, path)) return true;
    }
    final parent = _parent(path);
    for (final dir in other.dirReads) {
      if (dir == path || parent != null && dir == parent) return true;
    }
  }
  return false;
}

bool _touchesHost(ToolEffect effect) =>
    effect.hostRead ||
    effect.hostWrite ||
    effect.fileReads.isNotEmpty ||
    effect.fileWrites.isNotEmpty ||
    effect.treeReads.isNotEmpty ||
    effect.dirReads.isNotEmpty;

bool _covers(String root, String child) {
  if (root == '/') return child.startsWith('/');
  return child == root || child.startsWith('$root/');
}

String? _parent(String path) {
  if (path == '/' || path == '.' || path.isEmpty) return null;
  final parts = path.split('/');
  if (parts.length < 2) return null;
  parts.removeLast();
  if (parts.length == 1 && parts.single.isEmpty) return '/';
  final parent = parts.join('/');
  if (parent.isEmpty) return null;
  return parent;
}

String _lexical(String path) {
  final unified = path.replaceAll('\\', '/');
  final absolute = unified.startsWith('/');
  final parts = <String>[];
  for (final part in unified.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty &&
          parts.last != '..' &&
          !_driveSegment.hasMatch(parts.last)) {
        parts.removeLast();
        continue;
      }
      if (!absolute) parts.add('..');
      continue;
    }
    parts.add(part);
  }
  if (absolute) return parts.isEmpty ? '/' : '/${parts.join('/')}';
  if (parts.isEmpty) return '.';
  return parts.join('/');
}
