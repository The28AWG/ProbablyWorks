part of 'git_repository.dart';

/// Операции, которые апплет собирает из уже существующих объектов и ссылок.
extension GitRepositorySurface on GitRepository {
  /// Diff двух ревизий. Пустой [pathspecs] не ограничивает пути.
  Future<List<GitDiffEntry>> diffRevisions(
    String oldRevision,
    String newRevision, {
    Iterable<String>? pathspecs,
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    final oldTree = await _readRevisionTreeEntries(
      oldRevision,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );
    final newTree = await _readRevisionTreeEntries(
      newRevision,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );
    final entries = await _buildDiffEntriesFromTreeSnapshots(
      oldTree.entries,
      newTree.entries,
    );
    if (pathspecs == null) return entries;
    final allowed = GitRepository._filterPathsByPathspecs([
      for (final entry in entries) entry.path,
    ], pathspecs).toSet();
    return [
      for (final entry in entries)
        if (allowed.contains(entry.path)) entry,
    ];
  }

  /// Запись дерева ревизии по пути. Нет пути — null.
  Future<GitTreeEntry?> treeEntry(
    String revision,
    String path, {
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    final tree = await _readRevisionTreeEntries(
      revision,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );
    final entry = tree.entries[path];
    if (entry == null) return null;
    final slash = path.lastIndexOf('/');
    final name = slash < 0 ? path : _surfaceSlice(path, slash + 1, path.length);
    return GitTreeEntry.utf8(
      mode: entry.mode,
      name: name,
      objectId: entry.objectId,
    );
  }

  /// Плоский список путей дерева. [recursive] оставляет только прямых детей [prefix].
  Future<List<({String path, GitTreeEntry entry})>> listTree(
    String revision, {
    String prefix = '',
    bool recursive = false,
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    final tree = await _readRevisionTreeEntries(
      revision,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );
    final rows = <({String path, GitTreeEntry entry})>[];
    for (final item in tree.entries.entries) {
      if (!_treePathVisible(item.key, prefix, recursive: recursive)) continue;
      final slash = item.key.lastIndexOf('/');
      final name = slash < 0
          ? item.key
          : _surfaceSlice(item.key, slash + 1, item.key.length);
      rows.add((
        path: item.key,
        entry: GitTreeEntry.utf8(
          mode: item.value.mode,
          name: name,
          objectId: item.value.objectId,
        ),
      ));
    }
    rows.sort((left, right) => left.path.compareTo(right.path));
    return rows;
  }

  /// [ancestor] достижим из [descendant], включая равенство.
  Future<bool> isAncestor(
    String ancestor,
    String descendant, {
    GitCommitCodec commitCodec = const GitCommitCodec(),
  }) async {
    final ancestorId = await revParse(ancestor, commitCodec: commitCodec);
    final descendantId = await revParse(descendant, commitCodec: commitCodec);
    if (ancestorId == null || descendantId == null) return false;
    return _isCommitAncestorOf(
      ancestorId,
      descendantId,
      codec: commitCodec,
      cache: {},
    );
  }

  /// Удаляет пути из индекса и, если [cached] ложен, из рабочего дерева.
  Future<List<String>> removePaths(
    Iterable<String> paths, {
    bool cached = false,
    bool recursive = false,
  }) async {
    var index = await readIndex() ?? const GitIndex();
    final removed = <String>[];
    for (final path in paths) {
      final matches = [
        for (final entry in index.entries)
          if (entry.path == path ||
              (recursive && (entry.path.startsWith('$path/') || path == '.')))
            entry.path,
      ];
      if (matches.isEmpty) {
        throw StateError("pathspec '$path' did not match any files");
      }
      for (final match in matches) {
        index = index.withoutPath(match);
        removed.add(match);
        if (cached) continue;
        final file = File(resolveWorkTreePath(match));
        if (await file.exists()) await file.delete();
      }
    }
    await writeIndex(index);
    return removed;
  }

  /// Переименовывает отслеживаемый путь в индексе и рабочем дереве.
  Future<void> movePath(String from, String to) async {
    final index = await readIndex() ?? const GitIndex();
    final entry = index.entryForPath(from);
    if (entry == null) {
      throw StateError('bad source, source=$from, destination=$to');
    }
    final source = File(resolveWorkTreePath(from));
    final bytes = await source.readAsBytes();
    final destination = File(resolveWorkTreePath(to));
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(bytes);
    if (await source.exists()) await source.delete();
    final moved = GitIndexEntry(
      ctimeSeconds: entry.ctimeSeconds,
      ctimeNanoseconds: entry.ctimeNanoseconds,
      mtimeSeconds: entry.mtimeSeconds,
      mtimeNanoseconds: entry.mtimeNanoseconds,
      device: entry.device,
      inode: entry.inode,
      mode: entry.mode,
      userId: entry.userId,
      groupId: entry.groupId,
      fileSize: bytes.length,
      objectId: entry.objectId,
      path: to,
      assumeValid: entry.assumeValid,
      stage: entry.stage,
      skipWorktree: entry.skipWorktree,
      intentToAdd: entry.intentToAdd,
    );
    await writeIndex(index.withoutPath(from).withEntry(moved));
  }

  /// Неотслеживаемые пути, которые `clean` удалит.
  Future<List<String>> clean({
    bool directories = false,
    bool removeIgnored = false,
    bool dryRun = false,
  }) async {
    final report = await status(includeIgnored: removeIgnored);
    final paths = [
      for (final entry in report.entries)
        if (entry.isUntracked || (removeIgnored && entry.isIgnored)) entry.path,
    ];
    if (!dryRun) {
      for (final path in paths) {
        final absolute = resolveWorkTreePath(path);
        final kind = await FileSystemEntity.type(absolute);
        if (kind == FileSystemEntityType.directory && !directories) continue;
        final file = File(absolute);
        if (await file.exists()) await file.delete();
      }
    }
    return paths;
  }

  /// Повторяет один коммит поверх HEAD. Автор коммита сохраняется.
  Future<GitObjectId> cherryPick(
    String revision, {
    required GitCommitSignature committer,
    GitCommitCodec commitCodec = const GitCommitCodec(),
  }) async {
    final commit = await _commitOf(revision, commitCodec);
    await _applyCommitDifference(
      revision,
      commit,
      reverse: false,
      commitCodec: commitCodec,
    );
    return this.commit(
      author: commit.author,
      committer: committer,
      message: commit.message,
      allowEmpty: true,
      reflogAction: 'cherry-pick',
      commitCodec: commitCodec,
    );
  }

  /// Создаёт коммит, обратный [revision].
  Future<GitObjectId> revert(
    String revision, {
    required GitCommitSignature author,
    required GitCommitSignature committer,
    GitCommitCodec commitCodec = const GitCommitCodec(),
  }) async {
    final commit = await _commitOf(revision, commitCodec);
    final reverted = await commitIdOf(revision, commitCodec);
    await _applyCommitDifference(
      revision,
      commit,
      reverse: true,
      commitCodec: commitCodec,
    );
    final subject = _surfaceSubject(commit.message);
    return this.commit(
      author: author,
      committer: committer,
      message: 'Revert "$subject"\n\nThis reverts commit $reverted.\n',
      allowEmpty: true,
      reflogAction: 'revert',
      commitCodec: commitCodec,
    );
  }

  /// Переносит коммиты `upstream..HEAD` на [onto].
  Future<void> rebase(
    String upstream, {
    String? onto,
    required GitCommitSignature committer,
    GitCommitCodec commitCodec = const GitCommitCodec(),
  }) async {
    final head = await revParse('HEAD', commitCodec: commitCodec);
    final base = await revParse(upstream, commitCodec: commitCodec);
    if (head == null || base == null) {
      throw StateError('rebase could not resolve HEAD or upstream.');
    }
    final ontoId = onto == null
        ? base
        : await revParse(onto, commitCodec: commitCodec);
    if (ontoId == null) throw StateError('rebase could not resolve onto.');
    final history = await log('HEAD', commitCodec: commitCodec);
    final replay = <GitLogEntry>[];
    for (final entry in history) {
      if (entry.objectId == base) break;
      replay.add(entry);
    }
    await reset(ontoId.hex, mode: GitResetMode.hard, reflogActor: committer);
    final pending = [for (final entry in replay.reversed) entry.objectId.hex];
    await _writeSequencer('rebase', pending);
    for (var index = 0; index < pending.length; index++) {
      try {
        await cherryPick(
          pending[index],
          committer: committer,
          commitCodec: commitCodec,
        );
      } on StateError {
        await _writeSequencer('rebase', pending.sublist(index));
        rethrow;
      }
    }
    await _clearSequencer();
  }

  /// Оставшиеся ревизии sequencer. Нет файла — null.
  Future<({String action, List<String> revisions})?> readSequencer() async {
    final file = File(p.join(gitDirectoryPath, 'sequencer'));
    if (!await file.exists()) return null;
    final lines = const LineSplitter().convert(await file.readAsString());
    if (lines.isEmpty) return null;
    return (
      action: lines.first,
      revisions: lines.sublist(1).where((line) => line.isNotEmpty).toList(),
    );
  }

  /// Продолжает rebase или cherry-pick после конфликта.
  Future<void> sequencerContinue({
    required GitCommitSignature committer,
    GitCommitCodec commitCodec = const GitCommitCodec(),
  }) async {
    final state = await readSequencer();
    if (state == null) throw StateError('no sequencer in progress');
    for (var index = 0; index < state.revisions.length; index++) {
      try {
        await cherryPick(
          state.revisions[index],
          committer: committer,
          commitCodec: commitCodec,
        );
      } on StateError {
        await _writeSequencer(state.action, state.revisions.sublist(index));
        rethrow;
      }
    }
    await _clearSequencer();
  }

  /// Сбрасывает sequencer и возвращает HEAD на ORIG_HEAD, если она есть.
  Future<void> sequencerAbort({GitCommitSignature? reflogActor}) async {
    await _clearSequencer();
    final original = await readReference('ORIG_HEAD');
    if (original?.objectId == null) return;
    await reset(
      original!.objectId!.hex,
      mode: GitResetMode.hard,
      reflogActor: reflogActor,
    );
  }

  Future<void> _writeSequencer(String action, List<String> revisions) async {
    final file = File(p.join(gitDirectoryPath, 'sequencer'));
    await file.parent.create(recursive: true);
    final body = StringBuffer('$action\n');
    for (final revision in revisions) {
      body.write('$revision\n');
    }
    await file.writeAsString(body.toString());
  }

  Future<void> _clearSequencer() async {
    final file = File(p.join(gitDirectoryPath, 'sequencer'));
    if (await file.exists()) await file.delete();
  }

  /// Значение ключа `section.key` или `section.subsection.key`.
  Future<String?> configGet(String key) async {
    final parsed = _configKey(key);
    final document = await _readConfigDocument();
    for (final section in document.sections) {
      if (section.name != parsed.section) continue;
      if (section.subsection != parsed.subsection) continue;
      for (final line in section.bodyLines) {
        final value = _configLineValue(line, parsed.name);
        if (value != null) return value;
      }
    }
    return null;
  }

  /// Пишет ключ в config репозитория.
  Future<void> configSet(String key, String value) async {
    final parsed = _configKey(key);
    final document = await _readConfigDocument();
    final sections = <_GitConfigSection>[];
    var written = false;
    for (final section in document.sections) {
      if (section.name != parsed.section ||
          section.subsection != parsed.subsection) {
        sections.add(section);
        continue;
      }
      final body = [
        for (final line in section.bodyLines)
          if (_configLineValue(line, parsed.name) == null) line,
        '\t${parsed.name} = $value',
      ];
      sections.add(section.copyWith(bodyLines: body));
      written = true;
    }
    if (!written) {
      final header = parsed.subsection == null
          ? '[${parsed.section}]'
          : '[${parsed.section} "${parsed.subsection}"]';
      sections.add(
        _GitConfigSection(
          headerLine: header,
          name: parsed.section,
          subsection: parsed.subsection,
          bodyLines: ['\t${parsed.name} = $value'],
        ),
      );
    }
    await _writeConfigDocument(
      _GitConfigDocument(preamble: document.preamble, sections: sections),
    );
  }

  /// Снимает один ключ. Пустой заголовок секции остаётся, как у git
  /// после `--unset-upstream`: в файле ещё `[branch "name"]`, значений нет.
  Future<void> configUnset(String key) async {
    final parsed = _configKey(key);
    final document = await _readConfigDocument();
    final sections = <_GitConfigSection>[];
    for (final section in document.sections) {
      if (section.name != parsed.section ||
          section.subsection != parsed.subsection) {
        sections.add(section);
        continue;
      }
      sections.add(
        section.copyWith(
          bodyLines: [
            for (final line in section.bodyLines)
              if (_configLineValue(line, parsed.name) == null) line,
          ],
        ),
      );
    }
    await _writeConfigDocument(
      _GitConfigDocument(preamble: document.preamble, sections: sections),
    );
  }

  /// Копирует тело секции `branch "from"` в `branch "to"`.
  ///
  /// `git branch -c` переносит remote/merge и описание целиком, а не только
  /// пару upstream. Нет исходной секции — цель не создаётся.
  Future<void> configCopySubsection(
    String section,
    String from,
    String to,
  ) async {
    final document = await _readConfigDocument();
    _GitConfigSection? source;
    for (final item in document.sections) {
      if (item.name == section && item.subsection == from) source = item;
    }
    if (source == null) return;
    final copy = _GitConfigSection(
      headerLine: '[$section "$to"]',
      name: section,
      subsection: to,
      bodyLines: [...source.bodyLines],
    );
    final sections = <_GitConfigSection>[];
    var replaced = false;
    for (final item in document.sections) {
      if (item.name == section && item.subsection == to) {
        if (!replaced) {
          sections.add(copy);
          replaced = true;
        }
      } else {
        sections.add(item);
      }
    }
    if (!replaced) sections.add(copy);
    await _writeConfigDocument(
      _GitConfigDocument(preamble: document.preamble, sections: sections),
    );
  }

  /// Удаляет секцию целиком. Так `git branch -d` снимает `branch.<name>`.
  Future<void> configDeleteSubsection(String section, String subsection) async {
    final document = await _readConfigDocument();
    final sections = [
      for (final item in document.sections)
        if (!(item.name == section && item.subsection == subsection)) item,
    ];
    if (sections.length == document.sections.length) return;
    await _writeConfigDocument(
      _GitConfigDocument(preamble: document.preamble, sections: sections),
    );
  }

  /// Добавляет заметку к объекту в `refs/notes/commits`.
  Future<void> addNote(
    String revision,
    String text, {
    required GitCommitSignature author,
    GitCommitCodec commitCodec = const GitCommitCodec(),
  }) async {
    final target = await revParse(revision, commitCodec: commitCodec);
    if (target == null) throw StateError('could not resolve $revision');
    final blob = await writeLooseObject(GitObject.blob(utf8.encode(text)));
    final prefix = _surfaceSlice(target.hex, 0, 2);
    final rest = _surfaceSlice(target.hex, 2, target.hex.length);
    final leaf = await writeLooseObject(
      GitObject.tree(
        GitTreeCodec(algorithm: blob.algorithm).encode([
          GitTreeEntry.utf8(mode: '100644', name: rest, objectId: blob),
        ]),
      ),
    );
    final root = await writeLooseObject(
      GitObject.tree(
        GitTreeCodec(algorithm: blob.algorithm).encode([
          GitTreeEntry.utf8(mode: '040000', name: prefix, objectId: leaf),
        ]),
      ),
    );
    final previous = await resolveReferenceObjectId('refs/notes/commits');
    final noteCommit = await writeCommitFromTree(
      root,
      author: author,
      message: 'Notes added by \'git notes add\'\n',
      parents: [?previous],
      codec: commitCodec,
    );
    await writeReference(GitReference.direct('refs/notes/commits', noteCommit));
  }

  /// Текст заметки или null.
  Future<String?> readNote(
    String revision, {
    GitCommitCodec commitCodec = const GitCommitCodec(),
  }) async {
    final target = await revParse(revision, commitCodec: commitCodec);
    final notes = await resolveReferenceObjectId('refs/notes/commits');
    if (target == null || notes == null) return null;
    final commit = await _readCommit(notes, codec: commitCodec);
    final path =
        '${_surfaceSlice(target.hex, 0, 2)}/${_surfaceSlice(target.hex, 2, target.hex.length)}';
    final entries = await _readTreeEntries(
      commit.tree,
      codec: GitTreeCodec(algorithm: commit.tree.algorithm),
    );
    final entry = entries[path];
    if (entry == null) return null;
    final object = await readObject(entry.objectId);
    if (object == null) return null;
    return utf8.decode(object.bytes);
  }

  /// Подмена объекта. Чтение [object] после этого возвращает [replacement].
  Future<void> replaceObject(
    GitObjectId object,
    GitObjectId replacement,
  ) async {
    await writeReference(
      GitReference.direct('refs/replace/${object.hex}', replacement),
    );
  }

  /// Проверяет, что каждая ссылка указывает на существующий объект.
  Future<List<String>> fsck() async {
    final problems = <String>[];
    final refs = await references();
    for (final reference in refs) {
      final object = await readObject(reference.objectId);
      if (object == null) {
        problems.add(
          'missing ${reference.objectId.hex} for ${reference.referenceName}',
        );
      }
    }
    return problems;
  }

  /// Удаляет loose-объекты, недостижимые из ссылок.
  Future<int> pruneUnreachable() async {
    final reachable = <GitObjectId>{};
    for (final reference in await references()) {
      await _markReachable(reference.objectId, reachable);
    }
    final head = await resolveReferenceObjectId('HEAD');
    if (head != null) await _markReachable(head, reachable);
    final objects = Directory(objectDirectoryPath);
    if (!await objects.exists()) return 0;
    var removed = 0;
    await for (final entity in objects.list(recursive: true)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final parent = p.basename(p.dirname(entity.path));
      if (parent.length != 2 || name.length < 38) continue;
      final hex = '$parent$name';
      if (!GitObjectId.isValidHex(hex)) continue;
      final id = GitObjectId.fromHex(hex);
      if (reachable.contains(id)) continue;
      await entity.delete();
      removed++;
    }
    return removed;
  }

  Future<GitCommit> _commitOf(String revision, GitCommitCodec codec) async {
    final id = await revParse(revision, commitCodec: codec);
    if (id == null) throw StateError('could not resolve $revision');
    return _readCommit(id, codec: codec);
  }

  Future<String> commitIdOf(String revision, GitCommitCodec codec) async {
    final id = await revParse(revision, commitCodec: codec);
    if (id == null) throw StateError('could not resolve $revision');
    return id.hex;
  }

  Future<void> _applyCommitDifference(
    String revision,
    GitCommit commit, {
    required bool reverse,
    required GitCommitCodec commitCodec,
  }) async {
    if (commit.parents.isEmpty) return;
    final parent = commit.parents.first.hex;
    final patch = reverse
        ? await diffRevisions(revision, parent, commitCodec: commitCodec)
        : await diffRevisions(parent, revision, commitCodec: commitCodec);
    if (patch.isEmpty) return;
    final applied = await applyPatch(const GitDiffCodec().encode(patch));
    if (!applied.success) {
      throw StateError('patch did not apply cleanly');
    }
    await add([for (final entry in patch) entry.path]);
  }

  Future<void> _markReachable(
    GitObjectId id,
    Set<GitObjectId> reachable,
  ) async {
    final pending = <GitObjectId>[id];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!reachable.add(current)) continue;
      final object = await readObject(current);
      if (object == null) continue;
      switch (object.type) {
        case GitObjectType.blob:
          break;
        case GitObjectType.commit:
          final commit = const GitCommitCodec().decode(object.bytes);
          pending
            ..add(commit.tree)
            ..addAll(commit.parents);
        case GitObjectType.tree:
          final entries = GitTreeCodec(algorithm: current.algorithm)
              .decode(object.bytes);
          pending.addAll(entries.map((entry) => entry.objectId));
        case GitObjectType.tag:
          break;
      }
    }
  }
}

bool _treePathVisible(String path, String prefix, {required bool recursive}) {
  if (prefix.isEmpty) {
    return recursive || !path.contains('/');
  }
  if (path == prefix) return false;
  final nested = '$prefix/';
  if (!path.startsWith(nested)) return false;
  if (recursive) return true;
  final rest = _surfaceSlice(path, nested.length, path.length);
  return !rest.contains('/');
}

({String section, String? subsection, String name}) _configKey(String key) {
  final parts = key.split('.');
  if (parts.length < 2) {
    throw ArgumentError.value(key, 'key', 'Config key must contain a section.');
  }
  if (parts.length == 2) {
    return (section: parts.first, subsection: null, name: parts[1]);
  }
  return (
    section: parts.first,
    subsection: parts[1],
    name: parts.sublist(2).join('.'),
  );
}

String? _configLineValue(String line, String name) {
  final trimmed = line.trim();
  final separator = trimmed.indexOf('=');
  if (separator < 0) return null;
  final key = _surfaceSlice(trimmed, 0, separator).trim();
  if (key != name) return null;
  return _surfaceSlice(trimmed, separator + 1, trimmed.length).trim();
}

String _surfaceSubject(String message) {
  final end = message.indexOf('\n');
  return end < 0 ? message : _surfaceSlice(message, 0, end);
}

String _surfaceSlice(String text, int start, int end) =>
    String.fromCharCodes(text.codeUnits.getRange(start, end));
