// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
part of '../git_repository.dart';

/// Ссылки, теги, reflog и короткие имена ref.
extension GitRepositoryReferences on GitRepository {
  Future<GitReference?> readReference(String referenceName) async {
    final referenceFile = File(resolveReferencePath(referenceName));
    if (!await referenceFile.exists()) {
      return null;
    }

    final contents = await referenceFile.readAsString();
    return GitReference.fromStorageValue(referenceName, contents);
  }

  Future<void> writeReference(GitReference reference) async {
    final referenceFile = File(resolveReferencePath(reference.name));
    await referenceFile.parent.create(recursive: true);
    await referenceFile.writeAsString(
      '${reference.storageValue}\n',
      flush: true,
    );
  }

  Future<bool> deleteReference(String referenceName) async {
    final referenceFile = File(resolveReferencePath(referenceName));
    if (!await referenceFile.exists()) {
      return false;
    }

    await referenceFile.delete();
    return true;
  }

  Future<List<GitReferenceInfo>> references({
    String prefix = 'refs',
    bool peelTags = false,
    GitTagCodec tagCodec = const GitTagCodec(),
  }) async {
    final referenceNames = await _listReferenceNames(prefix);
    final references = <GitReferenceInfo>[];

    for (final referenceName in referenceNames) {
      final objectId = await resolveReferenceObjectId(referenceName);
      if (objectId == null) {
        continue;
      }

      references.add(
        GitReferenceInfo(
          referenceName: referenceName,
          name: GitRepositoryReferences._referenceShortName(referenceName),
          objectId: objectId,
          peeledObjectId: peelTags
              ? await _peelTagObjectId(objectId, tagCodec: tagCodec)
              : null,
        ),
      );
    }

    references.sort(
      (left, right) => left.referenceName.compareTo(right.referenceName),
    );
    return references;
  }

  Future<List<GitTag>> tags({GitTagCodec codec = const GitTagCodec()}) async {
    final tagReferences = await references(
      prefix: 'refs/tags',
      peelTags: true,
      tagCodec: codec,
    );
    final tags = <GitTag>[];

    for (final reference in tagReferences) {
      final object = await readObject(reference.objectId);
      if (object == null) {
        continue;
      }

      if (object.type == GitObjectType.tag) {
        final tagObject = codec.decode(object.bytes);
        tags.add(
          GitTag(
            name: reference.name,
            referenceName: reference.referenceName,
            objectId: reference.objectId,
            targetObjectId: tagObject.targetObjectId,
            targetType: tagObject.targetType,
            tagger: tagObject.tagger,
            message: tagObject.message,
            annotated: true,
          ),
        );
      } else {
        tags.add(
          GitTag(
            name: reference.name,
            referenceName: reference.referenceName,
            objectId: reference.objectId,
            targetObjectId: reference.objectId,
            targetType: object.type,
          ),
        );
      }
    }

    tags.sort((left, right) => left.name.compareTo(right.name));
    return tags;
  }

  Future<List<GitConflictEntry>> conflicts({
    GitIndex? index,
    Iterable<String>? pathspecs,
  }) async {
    final effectiveIndex = index ?? await readIndex() ?? const GitIndex();
    final grouped = <String, List<GitIndexEntry>>{};
    for (final entry in effectiveIndex.entries) {
      if (entry.stage == 0 ||
          !GitRepositoryStatus._pathMatchesAnyPathspec(entry.path, pathspecs)) {
        continue;
      }
      grouped.putIfAbsent(entry.path, () => []).add(entry);
    }

    return <GitConflictEntry>[
      for (final path in grouped.keys.toList()..sort())
        GitConflictEntry(
          path: path,
          base: GitRepositoryIndex._toConflictStageEntry(grouped[path], 1),
          ours: GitRepositoryIndex._toConflictStageEntry(grouped[path], 2),
          theirs: GitRepositoryIndex._toConflictStageEntry(grouped[path], 3),
        ),
    ];
  }

  Future<GitTag> tag(
    String name, {
    String target = 'HEAD',
    String? message,
    bool force = false,
    GitCommitSignature? tagger,
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTagCodec tagCodec = const GitTagCodec(),
  }) async {
    final referenceName = GitRepositoryReferences._normalizeTagReferenceName(
      name,
    );
    if (!force && await readReference(referenceName) != null) {
      throw StateError(
        'Tag already exists: ${GitRepositoryReferences._tagShortName(referenceName)}.',
      );
    }

    final targetObjectId = await revParse(target, commitCodec: commitCodec);
    if (targetObjectId == null) {
      throw StateError('Could not resolve tag target: $target.');
    }

    final targetObject = await readObject(targetObjectId);
    if (targetObject == null) {
      throw StateError('Could not read tag target object: $targetObjectId.');
    }

    var objectId = targetObjectId;
    GitCommitSignature? effectiveTagger;
    if (message != null) {
      effectiveTagger = tagger ?? _resolveReflogActor(null);
      final tagObject = GitTagObject(
        targetObjectId: targetObjectId,
        targetType: targetObject.type,
        name: GitRepositoryReferences._tagShortName(referenceName),
        tagger: effectiveTagger,
        message: message,
      );
      objectId = await writeLooseObject(
        GitObject.tag(tagCodec.encode(tagObject)),
        algorithm: targetObjectId.algorithm,
      );
    }

    await writeReference(GitReference.direct(referenceName, objectId));

    return GitTag(
      name: GitRepositoryReferences._tagShortName(referenceName),
      referenceName: referenceName,
      objectId: objectId,
      targetObjectId: targetObjectId,
      targetType: targetObject.type,
      tagger: effectiveTagger,
      message: message,
      annotated: message != null,
    );
  }

  Future<List<GitReflogEntry>> reflog({
    String referenceName = 'HEAD',
    bool newestFirst = true,
    GitReflogCodec codec = const GitReflogCodec(),
  }) async {
    final normalizedReferenceName =
        GitRepositoryReferences._normalizeReflogReferenceName(referenceName);
    final reflogFile = File(resolveReflogPath(normalizedReferenceName));
    if (!await reflogFile.exists()) {
      return const <GitReflogEntry>[];
    }

    final entries = codec.decode(await reflogFile.readAsString());
    if (!newestFirst) {
      return entries;
    }
    return entries.reversed.toList();
  }

  Future<GitObjectId?> resolveReferenceObjectId(String referenceName) =>
      _resolveReferenceObjectId(referenceName, <String>{});

  String resolveReferencePath(String referenceName) {
    final normalized = referenceName.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        referenceName,
        'referenceName',
        'Reference name must not be empty.',
      );
    }
    return normalized == 'HEAD'
        ? headFilePath
        : p.join(commonDirectoryPath, normalized);
  }

  String resolveReflogPath(String referenceName) {
    final normalized = GitRepositoryReferences._normalizeReflogReferenceName(
      referenceName,
    );
    return normalized == 'HEAD'
        ? p.join(gitDirectoryPath, 'logs', 'HEAD')
        : p.join(commonDirectoryPath, 'logs', normalized);
  }

  Future<void> _writeReferenceWithReflog(
    GitReference reference, {
    required GitCommitSignature actor,
    required String message,
    GitReflogCodec codec = const GitReflogCodec(),
  }) async {
    final headReference = await readReference('HEAD');
    final headTargetReferenceName = headReference?.targetReferenceName;
    final oldReferenceObjectId = await resolveReferenceObjectId(reference.name);
    final oldHeadObjectId =
        reference.name == 'HEAD' || headTargetReferenceName == reference.name
        ? await resolveReferenceObjectId('HEAD')
        : null;

    await writeReference(reference);

    final newReferenceObjectId = await resolveReferenceObjectId(reference.name);
    await _appendReflogEntry(
      reference.name,
      GitReflogEntry(
        previousObjectId: oldReferenceObjectId,
        newObjectId: newReferenceObjectId,
        actor: actor,
        message: message,
      ),
      codec: codec,
    );
    if (reference.name != 'HEAD' && headTargetReferenceName == reference.name) {
      await _appendReflogEntry(
        'HEAD',
        GitReflogEntry(
          previousObjectId: oldHeadObjectId,
          newObjectId: newReferenceObjectId,
          actor: actor,
          message: message,
        ),
        codec: codec,
      );
    }
  }

  Future<void> _appendReflogEntry(
    String referenceName,
    GitReflogEntry entry, {
    GitReflogCodec codec = const GitReflogCodec(),
  }) async {
    final normalized = GitRepositoryReferences._normalizeReflogReferenceName(
      referenceName,
    );
    if (!GitRepositoryReferences._shouldWriteReflogForReference(normalized)) {
      return;
    }

    final reflogFile = File(resolveReflogPath(normalized));
    await reflogFile.parent.create(recursive: true);
    await reflogFile.writeAsString(
      codec.encodeLine(entry),
      mode: FileMode.writeOnlyAppend,
      flush: true,
    );
  }

  Future<void> _writeReflogEntries(
    String referenceName,
    List<GitReflogEntry> entries, {
    GitReflogCodec codec = const GitReflogCodec(),
  }) async {
    final normalized = GitRepositoryReferences._normalizeReflogReferenceName(
      referenceName,
    );
    if (!GitRepositoryReferences._shouldWriteReflogForReference(normalized)) {
      return;
    }

    final reflogFile = File(resolveReflogPath(normalized));
    if (entries.isEmpty) {
      if (await reflogFile.exists()) {
        await reflogFile.delete();
      }
      return;
    }

    await reflogFile.parent.create(recursive: true);
    await reflogFile.writeAsString(codec.encode(entries), flush: true);
  }

  static String _describeReflogLocation(
    GitReference? headReference,
    GitObjectId? objectId,
  ) {
    final targetReferenceName = headReference?.targetReferenceName;
    if (targetReferenceName != null &&
        targetReferenceName.startsWith('refs/heads/')) {
      return GitRepositoryReferences._branchShortName(targetReferenceName);
    }
    return objectId?.hex ?? 'unborn';
  }

  static String _summarizeReflogMessage(String message) {
    final trimmed = message.trimRight();
    if (trimmed.isEmpty) {
      return 'update';
    }
    return LineSplitter.split(trimmed).first.trim();
  }

  static bool _shouldWriteReflogForReference(String referenceName) =>
      referenceName == 'HEAD' ||
      referenceName == 'refs/stash' ||
      referenceName.startsWith('refs/heads/');

  static String _normalizeReflogReferenceName(String referenceName) {
    final trimmed = referenceName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        referenceName,
        'referenceName',
        'Reflog reference name must not be empty.',
      );
    }
    if (trimmed == 'HEAD') {
      return 'HEAD';
    }
    if (trimmed == 'stash') {
      return 'refs/stash';
    }
    return trimmed.startsWith('refs/') ? trimmed : 'refs/heads/$trimmed';
  }

  /// Суффикс `rev^{tree}` / `rev^{commit}` после разыменования тегов.
  Future<GitObjectId?> _revParseBraceSuffix(
    GitObjectId objectId,
    String suffixName, {
    required GitCommitCodec codec,
  }) async {
    final peeled = await _peelTagObjectId(objectId);
    final object = await readObject(peeled);
    if (object == null) {
      return null;
    }
    switch (suffixName) {
      case 'tree':
        if (object.type == GitObjectType.commit) {
          return codec.decode(object.bytes).tree;
        }
        if (object.type == GitObjectType.tree) {
          return peeled;
        }
        return null;
      case 'commit':
        return object.type == GitObjectType.commit ? peeled : null;
      default:
        throw FormatException('Unsupported revision suffix: ^{$suffixName}');
    }
  }

  Future<GitObjectId> _peelTagObjectId(
    GitObjectId objectId, {
    GitTagCodec tagCodec = const GitTagCodec(),
  }) async {
    var currentObjectId = objectId;
    while (true) {
      final object = await readObject(currentObjectId);
      if (object == null || object.type != GitObjectType.tag) {
        return currentObjectId;
      }

      currentObjectId = tagCodec.decode(object.bytes).targetObjectId;
    }
  }

  Future<List<String>> _listReferenceNamesUnder(
    String baseReferenceName,
  ) async {
    final referenceDirectory = Directory(
      resolveReferencePath(baseReferenceName),
    );
    if (!await referenceDirectory.exists()) {
      return const <String>[];
    }

    final referenceNames = <String>[];
    await for (final entity in referenceDirectory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }
      final listedName = p.posix.joinAll(
        p.split(p.relative(entity.path, from: commonDirectoryPath)),
      );
      referenceNames.add(listedName);
    }
    referenceNames.sort();
    return referenceNames;
  }

  Future<List<String>> _listReferenceNames(String prefix) async {
    final trimmed = prefix.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        prefix,
        'prefix',
        'Reference prefix must not be empty.',
      );
    }

    final normalized = trimmed == 'HEAD' || trimmed.startsWith('refs')
        ? trimmed
        : 'refs/$trimmed';
    final exactFile = File(resolveReferencePath(normalized));
    if (await exactFile.exists()) {
      return [normalized];
    }

    return _listReferenceNamesUnder(normalized);
  }

  static String _referenceShortName(String referenceName) {
    if (referenceName == 'HEAD') {
      return 'HEAD';
    }
    if (referenceName.startsWith('refs/heads/')) {
      return referenceName.substring('refs/heads/'.length);
    }
    if (referenceName.startsWith('refs/tags/')) {
      return referenceName.substring('refs/tags/'.length);
    }
    if (referenceName.startsWith('refs/remotes/')) {
      return referenceName.substring('refs/remotes/'.length);
    }
    return referenceName.startsWith('refs/')
        ? referenceName.substring('refs/'.length)
        : referenceName;
  }

  static GitObjectId _readTagTargetObjectId(List<int> bytes) {
    final text = utf8.decode(bytes);
    for (final line in const LineSplitter().convert(text)) {
      if (line.isEmpty) {
        break;
      }
      if (line.startsWith('object ')) {
        return GitObjectId.fromHex(line.substring('object '.length).trim());
      }
    }
    throw const FormatException(
      'Tag object is missing the target object line.',
    );
  }

  Future<GitObjectId?> _resolveReferenceObjectId(
    String referenceName,
    Set<String> visitedReferences,
  ) async {
    final normalizedReferenceName = referenceName.trim();
    if (!visitedReferences.add(normalizedReferenceName)) {
      throw StateError(
        'Detected a symbolic reference cycle at $normalizedReferenceName.',
      );
    }

    final reference = await readReference(normalizedReferenceName);
    if (reference == null) {
      return null;
    }

    switch (reference.target) {
      case GitDirectReferenceTarget(:final objectId):
        return objectId;
      case GitSymbolicReferenceTarget(:final referenceName):
        return _resolveReferenceObjectId(referenceName, visitedReferences);
    }
  }

  Future<String> _resolveWritableReferenceName(String referenceName) async {
    final reference = await readReference(referenceName);
    if (reference == null) {
      return referenceName;
    }

    return switch (reference.target) {
      GitSymbolicReferenceTarget(:final referenceName) => referenceName,
      _ => reference.name,
    };
  }

  static String _normalizeBranchReferenceName(String branchName) {
    final trimmed = branchName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        branchName,
        'branchName',
        'Branch name must not be empty.',
      );
    }

    final referenceName = trimmed.startsWith('refs/heads/')
        ? trimmed
        : 'refs/heads/$trimmed';
    return GitReference.symbolic('HEAD', referenceName).targetReferenceName!;
  }

  static String _normalizeTagReferenceName(String tagName) {
    final trimmed = tagName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        tagName,
        'tagName',
        'Tag name must not be empty.',
      );
    }

    final referenceName = trimmed.startsWith('refs/tags/')
        ? trimmed
        : 'refs/tags/$trimmed';
    return GitReference.symbolic('HEAD', referenceName).targetReferenceName!;
  }

  static String _branchShortName(String referenceName) =>
      referenceName.startsWith('refs/heads/')
      ? referenceName.substring('refs/heads/'.length)
      : referenceName;

  static String _tagShortName(String referenceName) =>
      referenceName.startsWith('refs/tags/')
      ? referenceName.substring('refs/tags/'.length)
      : referenceName;
}
