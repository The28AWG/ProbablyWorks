import 'dart:convert';

import 'package:probably_works/agent/policy/command_classifier.dart';
import 'package:probably_works/agent/policy/policy_engine.dart';
import 'package:probably_works/agent/skills/skill_locations.dart';
import 'package:probably_works/agent/tools/tool_catalog.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// Что вызов читает и пишет. Планировщик батча запускает параллельно только те
/// вызовы, чьи эффекты не пересекаются: запись и следующее чтение того же пути
/// остаются в порядке модели, а два чтения — нет.
///
/// До [bindPaths] путь лексический: `a/../b` и `b` — один файл, но `~/a`,
/// абсолютный домашний путь и симлинк — разные строки. Host так не считает:
/// он раскрывает `~` и идёт по симлинку. Планировщик вызывает [bindPaths]
/// до графа и снова после команды, которая могла создать ссылку. Путь, который
/// не удалось сопоставить одному файлу, поднимает эффект до всего хоста.
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
    this.projectWrite = false,
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

  /// Каталоги, чей список имён вызов читает. Запись файла задевает любой
  /// предок: `ls -la` показывает mtime дочернего каталога, а `mkdir -p`
  /// добавляет имя на каждом созданном уровне.
  final Set<String> dirReads;

  /// Файлы, которые вызов перезаписывает. Две записи разных файлов не
  /// конфликтуют, даже если у них общий родитель: список каталога меняется
  /// у обоих, но читателя этого списка между ними нет.
  final Set<String> fileWrites;

  /// Чтение хоста без конкретного файла: `which`, `host_info` или путь,
  /// который не удалось канонизировать. Конфликтует с любой записью хоста.
  final bool hostRead;

  /// Может изменить хост. Барьер для остальных операций этого хоста.
  /// Сюда же попадает `run_command`, даже если классификатор сказал auto:
  /// ошибка классификатора иначе стала бы гонкой с чтением.
  final bool hostWrite;

  /// Чтение запечатанных ревизий состояния задачи.
  final bool sessionRead;

  /// Запись текущей ревизии. `mutate` читает и сохраняет её без своего замка.
  final bool sessionWrite;

  /// Общие факты проекта. Две записи упорядочиваются между собой и не
  /// занимают файлы хоста.
  final bool projectWrite;

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

  /// Подменяет пути на канонические. [canonicalize] возвращает абсолютный путь
  /// одного файла или null, если сопоставить нельзя (`~` без дома, оборванный
  /// симлинк, хост не ответил). null у чтения включает [hostRead], у записи —
  /// [hostWrite]: лучше ждать весь хост, чем пропустить тот же файл под другим именем.
  Future<ToolEffect> bindPaths(PathCanonicalizer canonicalize) async {
    final reads = await _bindPaths(fileReads, canonicalize);
    final trees = await _bindPaths(treeReads, canonicalize);
    final dirs = await _bindPaths(dirReads, canonicalize);
    final writes = await _bindPaths(fileWrites, canonicalize);
    return ToolEffect(
      fileReads: reads.paths,
      treeReads: trees.paths,
      dirReads: dirs.paths,
      fileWrites: writes.paths,
      hostRead:
          hostRead || reads.ambiguous || trees.ambiguous || dirs.ambiguous,
      hostWrite: hostWrite || writes.ambiguous,
      sessionRead: sessionRead,
      sessionWrite: sessionWrite,
      projectWrite: projectWrite,
      hostsRead: hostsRead,
      hostsWrite: hostsWrite,
      settingsRead: settingsRead,
      settingsWrite: settingsWrite,
      transcriptRead: transcriptRead,
    );
  }
}

/// Канонический абсолютный путь для [ToolEffect.bindPaths]. null — путь
/// нельзя считать одним файлом.
typedef PathCanonicalizer = Future<String?> Function(String path);

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
/// аргументы, не трогая Host. Неизвестное имя тоже ничего не делает: исполнитель
/// ответит ошибкой. Команда, которая дойдёт до Host, — запись всего хоста,
/// включая риск auto. Deny до Host не доходит. Карточку ask можно показать
/// сразу, а зависимый вызов подождёт решение.
ToolEffect toolEffectFor(
  LlmToolCall call, {
  required String? workspace,
  required PolicyEngine policy,
  required HostKind hostKind,
}) {
  final args = _decodeArgs(call.arguments);
  if (args == null) return const ToolEffect();
  return switch (call.name) {
    ToolNames.hostInfo || ToolNames.which => const ToolEffect(hostRead: true),
    ToolNames.readFile => _fileRead(workspace, args),
    ToolNames.listDir => _dirRead(workspace, args),
    ToolNames.grep => _treeRead(workspace, args),
    ToolNames.writeFile || ToolNames.editFile => _fileWrite(workspace, args),
    ToolNames.runCommand => _command(args, policy, hostKind),
    ToolNames.setGoal ||
    ToolNames.updatePlan ||
    ToolNames.pinFact ||
    ToolNames.unpinFact => const ToolEffect(sessionWrite: true),
    ToolNames.pinProjectFact ||
    ToolNames.unpinProjectFact => const ToolEffect(projectWrite: true),
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

/// Виртуальный Host отвергает фон до запуска: эффекта нет. Deny тоже не
/// запускается. Всё, что дойдёт до процесса, — запись хоста. Классификатор
/// называет auto только для решения политики; для графа этого мало, потому
/// что ложный auto выполнился бы рядом с чтением того же файла.
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
    CommandRisk.deny => const ToolEffect(),
    CommandRisk.auto || CommandRisk.ask => const ToolEffect(hostWrite: true),
  };
}

ToolEffect _skills(String? workspace) {
  if (workspace == null || workspace.isEmpty) return const ToolEffect();
  return ToolEffect(
    fileReads: {toolPathKey(workspace, 'AGENTS.md')},
    treeReads: {
      for (final path in SkillLocations.forWorkspace(workspace))
        toolPathKey(null, path),
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
  if (writer.projectWrite && other.projectWrite) return true;
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
    for (final dir in other.dirReads) {
      if (_covers(dir, path)) return true;
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

/// Пути одного множества после канонизации. [ambiguous] — хотя бы один путь
/// не удалось связать с файлом, и набор его больше не содержит.
Future<_BoundPaths> _bindPaths(
  Set<String> paths,
  PathCanonicalizer canonicalize,
) async {
  final bound = <String>{};
  var ambiguous = false;
  for (final path in paths) {
    final key = _absoluteKey(await canonicalize(path));
    if (key == null) {
      ambiguous = true;
      continue;
    }
    bound.add(key);
  }
  return _BoundPaths(bound, ambiguous: ambiguous);
}

/// Абсолютный ключ. Относительный ответ и нераскрытый `~` не принимают:
/// их нельзя сравнить с уже раскрытым путём.
String? _absoluteKey(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed.contains('\n') || trimmed.startsWith('~')) {
    return null;
  }
  final key = toolPathKey(null, trimmed);
  if (key.startsWith('~') || key == '.') return null;
  if (key.startsWith('/') || _windowsDrive.hasMatch(key)) return key;
  return null;
}

class _BoundPaths {
  const _BoundPaths(this.paths, {required this.ambiguous});

  final Set<String> paths;
  final bool ambiguous;
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
