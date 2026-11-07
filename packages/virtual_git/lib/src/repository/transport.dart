// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
part of '../git_repository.dart';

/// Remote через каталог виртуальной ФС и smart HTTP. SSH не открывается.
final class _GitRemoteTransport {
  _GitRemoteTransport._filesystem({
    required this.remoteUrl,
    required this.repository,
  }) : httpBaseUri = null,
       httpHeaders = const <String, String>{},
       sshRemote = null;

  _GitRemoteTransport._http({
    required this.remoteUrl,
    required this.httpBaseUri,
    required this.httpHeaders,
  }) : repository = null,
       sshRemote = null;

  static Future<_GitRemoteTransport> open(
    String remoteUrl, {
    required String basePath,
    required String operation,
    Map<String, String> httpHeaders = const {},
    String? sshPrivateKeyPath,
    String? sshPrivateKey,
    String? sshPrivateKeyPassphrase,
    String? sshPassword,
    String? sshKnownHostsPath,
    Iterable<String> sshHostKeyFingerprints = const <String>[],
  }) async {
    final trimmedUrl = remoteUrl.trim();
    if (trimmedUrl.isEmpty) {
      throw StateError('Remote URL must not be empty.');
    }

    if (trimmedUrl.startsWith('file://')) {
      final fileUri = Uri.parse(trimmedUrl);
      return _openFilesystem(trimmedUrl, fileUri.toFilePath());
    }

    final parsedUri = Uri.tryParse(trimmedUrl);
    if (parsedUri != null &&
        (parsedUri.scheme == 'http' || parsedUri.scheme == 'https')) {
      return _GitRemoteTransport._http(
        remoteUrl: trimmedUrl,
        httpBaseUri: _normalizeHttpBaseUri(parsedUri),
        httpHeaders: httpHeaders,
      );
    }

    final sshRemote = _tryParseSshRemote(
      trimmedUrl,
      sshPrivateKeyPath: sshPrivateKeyPath,
      sshPrivateKey: sshPrivateKey,
      sshPrivateKeyPassphrase: sshPrivateKeyPassphrase,
      sshPassword: sshPassword,
      sshKnownHostsPath: sshKnownHostsPath,
      sshHostKeyFingerprints: sshHostKeyFingerprints,
    );
    if (sshRemote != null) {
      throw UnsupportedError(
        'Unsupported remote transport for $operation: $trimmedUrl.',
      );
    }

    if (trimmedUrl.contains('://')) {
      throw UnsupportedError(
        'Unsupported remote transport for $operation: $trimmedUrl.',
      );
    }

    final remotePath = p.isAbsolute(trimmedUrl)
        ? trimmedUrl
        : p.join(basePath, trimmedUrl);
    return _openFilesystem(trimmedUrl, remotePath);
  }

  static Future<_GitRemoteTransport> _openFilesystem(
    String remoteUrl,
    String remotePath,
  ) async {
    final repository = await GitRepository.discover(remotePath);
    if (repository == null) {
      throw StateError('Could not discover remote repository at $remoteUrl.');
    }

    return _GitRemoteTransport._filesystem(
      remoteUrl: remoteUrl,
      repository: repository,
    );
  }

  static _GitSshRemoteConfig? _tryParseSshRemote(
    String remoteUrl, {
    String? sshPrivateKeyPath,
    String? sshPrivateKey,
    String? sshPrivateKeyPassphrase,
    String? sshPassword,
    String? sshKnownHostsPath,
    Iterable<String> sshHostKeyFingerprints = const <String>[],
  }) {
    final parsedUri = Uri.tryParse(remoteUrl);
    if (parsedUri != null && parsedUri.scheme == 'ssh') {
      final host = parsedUri.host;
      if (host.isEmpty) {
        return null;
      }
      final path = parsedUri.path.isEmpty ? '/' : parsedUri.path;
      return _GitSshRemoteConfig(
        host: host,
        port: parsedUri.hasPort ? parsedUri.port : 22,
        username: parsedUri.userInfo.isEmpty
            ? Platform.environment['USER'] ??
                  Platform.environment['USERNAME'] ??
                  'git'
            : parsedUri.userInfo,
        repositoryPath: path,
        privateKeyPath: sshPrivateKeyPath,
        privateKey: sshPrivateKey,
        privateKeyPassphrase: sshPrivateKeyPassphrase,
        password: sshPassword,
        knownHostsPath: sshKnownHostsPath,
        hostKeyFingerprints: sshHostKeyFingerprints.toList(),
      );
    }

    final scpMatch = RegExp(r'^([^@]+)@([^:]+):(.+)$').firstMatch(remoteUrl);
    if (scpMatch == null) {
      return null;
    }
    return _GitSshRemoteConfig(
      host: scpMatch.group(2)!,
      port: 22,
      username: scpMatch.group(1)!,
      repositoryPath: scpMatch.group(3)!,
      privateKeyPath: sshPrivateKeyPath,
      privateKey: sshPrivateKey,
      privateKeyPassphrase: sshPrivateKeyPassphrase,
      password: sshPassword,
      knownHostsPath: sshKnownHostsPath,
      hostKeyFingerprints: sshHostKeyFingerprints.toList(),
    );
  }

  static Uri _normalizeHttpBaseUri(Uri uri) {
    final sanitized = uri.replace(query: null, fragment: null);
    final normalizedPath = sanitized.path.endsWith('/')
        ? sanitized.path
        : '${sanitized.path}/';
    return sanitized.replace(path: normalizedPath);
  }

  /// Глубина upload-pack. null — полная история.
  int? uploadPackDepth;

  /// Фильтр partial clone, например `blob:none`. Уходит строкой `filter`.
  String? uploadPackFilter;

  final String remoteUrl;
  final GitRepository? repository;
  final Uri? httpBaseUri;
  final Map<String, String> httpHeaders;
  final _GitSshRemoteConfig? sshRemote;

  final Map<String, GitObjectId> _httpReferenceObjectIdsCache = {};
  GitReference? _httpHeadReferenceCache;
  List<String>? _httpPackNamesCache;
  final Map<String, List<int>> _httpPackIndexBytesCache = {};
  final Map<String, List<int>> _httpPackBytesCache = {};
  final Map<GitObjectId, GitObject> _httpSmartObjectCache = {};
  _GitSmartHttpAdvertisement? _httpUploadPackAdvertisementCache;
  _GitSmartHttpAdvertisement? _httpReceivePackAdvertisementCache;
  bool _didProbeHttpUploadPackAdvertisement = false;
  bool _didProbeHttpReceivePackAdvertisement = false;
  bool _didPopulateHttpReachableObjectCache = false;
  final Set<GitObjectId> _httpSmartFetchInFlight = {};
  List<int>? _pendingHttpReceivePackBytes;
  final Map<GitObjectId, GitObject> _sshSmartObjectCache = {};
  _GitSmartHttpAdvertisement? _sshUploadPackAdvertisementCache;
  _GitSmartHttpAdvertisement? _sshReceivePackAdvertisementCache;
  bool _didProbeSshUploadPackAdvertisement = false;
  bool _didProbeSshReceivePackAdvertisement = false;
  bool _didPopulateSshReachableObjectCache = false;
  List<int>? _pendingSshReceivePackBytes;

  bool get bare => repository?.bare ?? true;

  Future<GitReference?> readReference(String referenceName) async {
    if (repository case final repository?) {
      return repository.readReference(referenceName);
    }
    if (sshRemote != null) {
      return _readSshReference(referenceName);
    }

    if (referenceName == 'HEAD') {
      final cached = _httpHeadReferenceCache;
      if (cached != null) {
        return cached;
      }
      final advertisement = await _loadHttpSmartUploadPackAdvertisement();
      final smartHeadReference = advertisement?.headReference;
      if (smartHeadReference != null) {
        _httpHeadReferenceCache = smartHeadReference;
        return smartHeadReference;
      }
      final contents = await _fetchHttpText('HEAD');
      if (contents == null) {
        return null;
      }
      final reference = GitReference.fromStorageValue(
        'HEAD',
        contents.trimRight(),
      );
      _httpHeadReferenceCache = reference;
      return reference;
    }

    final advertisedObjectId = (await _loadHttpSmartUploadPackAdvertisement())
        ?.references[referenceName];
    if (advertisedObjectId != null) {
      return GitReference.direct(referenceName, advertisedObjectId);
    }

    final contents = await _fetchHttpText(referenceName);
    if (contents != null) {
      return GitReference.fromStorageValue(referenceName, contents.trimRight());
    }

    final objectId = await resolveReferenceObjectId(referenceName);
    if (objectId == null) {
      return null;
    }
    return GitReference.direct(referenceName, objectId);
  }

  Future<GitObjectId?> resolveReferenceObjectId(String referenceName) async {
    if (repository case final repository?) {
      return repository.resolveReferenceObjectId(referenceName);
    }
    if (sshRemote != null) {
      return _resolveSshReferenceObjectId(referenceName);
    }

    if (referenceName == 'HEAD') {
      final headReference = await readReference('HEAD');
      if (headReference == null) {
        return null;
      }
      return switch (headReference.target) {
        GitDirectReferenceTarget(:final objectId) => objectId,
        GitSymbolicReferenceTarget(:final referenceName) =>
          await resolveReferenceObjectId(referenceName),
      };
    }

    final references = await _loadHttpReferenceObjectIds();
    final cachedObjectId = references[referenceName];
    if (cachedObjectId != null) {
      return cachedObjectId;
    }

    final contents = await _fetchHttpText(referenceName);
    if (contents == null) {
      return null;
    }
    final reference = GitReference.fromStorageValue(
      referenceName,
      contents.trimRight(),
    );
    return switch (reference.target) {
      GitDirectReferenceTarget(:final objectId) => objectId,
      GitSymbolicReferenceTarget(:final referenceName) =>
        await resolveReferenceObjectId(referenceName),
    };
  }

  Future<List<String>> listReferenceNamesUnder(String baseReferenceName) async {
    if (repository case final repository?) {
      return repository._listReferenceNamesUnder(baseReferenceName);
    }
    if (sshRemote != null) {
      return _listSshReferenceNamesUnder(baseReferenceName);
    }

    final prefix = '$baseReferenceName/';
    final references = await _loadHttpReferenceObjectIds();
    final names = <String>[
      for (final referenceName in references.keys)
        if (referenceName.startsWith(prefix)) referenceName,
    ];
    final headReference = await readReference('HEAD');
    final headTargetReferenceName = headReference?.targetReferenceName;
    if (headTargetReferenceName != null &&
        headTargetReferenceName.startsWith(prefix) &&
        !names.contains(headTargetReferenceName)) {
      names.add(headTargetReferenceName);
    }
    names.sort();
    return names;
  }

  Future<GitObject?> readObject(GitObjectId objectId) async {
    if (repository case final repository?) {
      return repository.readObject(objectId);
    }
    if (sshRemote != null) {
      final cached = _sshSmartObjectCache[objectId];
      if (cached != null) {
        return cached;
      }
      return _readSshObject(objectId);
    }
    final cached = _httpSmartObjectCache[objectId];
    if (cached != null) {
      return cached;
    }
    return _readHttpObject(objectId, activePackNames: const <String>{});
  }

  Future<void> writeReference(GitReference reference) async {
    if (repository case final repository?) {
      await repository.writeReference(reference);
      return;
    }
    if (sshRemote != null) {
      if (reference.target case GitDirectReferenceTarget(:final objectId)) {
        final previousObjectId = await resolveReferenceObjectId(reference.name);
        await _sendSshReceivePack([
          _GitSmartReceivePackCommand(
            referenceName: reference.name,
            previousObjectId: previousObjectId,
            nextObjectId: objectId,
          ),
        ], packBytes: _pendingSshReceivePackBytes);
        _pendingSshReceivePackBytes = null;
        _invalidateSshCaches();
        return;
      }
      throw UnsupportedError(
        'SSH remotes only support direct reference updates for ${reference.name}.',
      );
    }
    if (reference.target case GitDirectReferenceTarget(:final objectId)) {
      final previousObjectId = await resolveReferenceObjectId(reference.name);
      await _sendSmartHttpReceivePack([
        _GitSmartReceivePackCommand(
          referenceName: reference.name,
          previousObjectId: previousObjectId,
          nextObjectId: objectId,
        ),
      ], packBytes: _pendingHttpReceivePackBytes);
      _pendingHttpReceivePackBytes = null;
      _invalidateHttpCaches();
      return;
    }
    throw UnsupportedError(
      'HTTP remotes only support direct reference updates for ${reference.name}.',
    );
  }

  Future<bool> deleteReference(String referenceName) async {
    if (repository case final repository?) {
      return repository.deleteReference(referenceName);
    }
    if (sshRemote != null) {
      final previousObjectId = await resolveReferenceObjectId(referenceName);
      if (previousObjectId == null) {
        return false;
      }
      await _sendSshReceivePack([
        _GitSmartReceivePackCommand(
          referenceName: referenceName,
          previousObjectId: previousObjectId,
          nextObjectId: null,
        ),
      ], packBytes: _pendingSshReceivePackBytes);
      _pendingSshReceivePackBytes = null;
      _invalidateSshCaches();
      return true;
    }
    final previousObjectId = await resolveReferenceObjectId(referenceName);
    if (previousObjectId == null) {
      return false;
    }
    await _sendSmartHttpReceivePack([
      _GitSmartReceivePackCommand(
        referenceName: referenceName,
        previousObjectId: previousObjectId,
        nextObjectId: null,
      ),
    ], packBytes: _pendingHttpReceivePackBytes);
    _pendingHttpReceivePackBytes = null;
    _invalidateHttpCaches();
    return true;
  }

  Future<List<int>> exportPackForObjectIds(List<GitObjectId> objectIds) async {
    if (repository case final repository?) {
      return repository._exportPackForObjectIds(
        objectIds,
        objectReader: (objectId) => repository.readObject(objectId),
      );
    }
    if (objectIds.isEmpty) {
      return const <int>[];
    }

    if (httpBaseUri != null && !_httpSmartCacheCovers(objectIds)) {
      final smartPackBytes = await _fetchSmartHttpPackBytes(objectIds);
      if (smartPackBytes != null) {
        return smartPackBytes;
      }
    }

    final algorithm = objectIds.first.algorithm;
    final entries = <GitPackObjectEntry>[];
    for (final objectId in objectIds) {
      if (objectId.algorithm != algorithm) {
        throw StateError(
          'Pack export requires all object ids to use the same algorithm.',
        );
      }
      final object = await readObject(objectId);
      if (object == null) {
        throw StateError('Missing object for pack export: $objectId.');
      }
      entries.add(GitPackObjectEntry(object));
    }

    return GitPackCodec(checksumAlgorithm: algorithm)
        .encode(GitPack(checksumAlgorithm: algorithm, entries: entries));
  }

  Future<int> importPackBytes(List<int> packBytes) async {
    if (repository case final repository?) {
      return repository._importPackBytes(packBytes);
    }
    if (sshRemote != null) {
      if (packBytes.isEmpty) {
        _pendingSshReceivePackBytes = null;
        return 0;
      }
      final algorithm = GitRepositoryObjects._detectPackChecksumAlgorithm(
        packBytes,
      );
      final entries = GitPackCodec(checksumAlgorithm: algorithm)
          .decode(packBytes)
          .entries;
      _pendingSshReceivePackBytes = List<int>.unmodifiable(packBytes);
      return entries.length;
    }
    if (packBytes.isEmpty) {
      _pendingHttpReceivePackBytes = null;
      return 0;
    }
    final algorithm = GitRepositoryObjects._detectPackChecksumAlgorithm(
      packBytes,
    );
    final entries = GitPackCodec(checksumAlgorithm: algorithm)
        .decode(packBytes)
        .entries;
    _pendingHttpReceivePackBytes = List<int>.unmodifiable(packBytes);
    return entries.length;
  }

  Future<Map<String, GitObjectId>> _loadHttpReferenceObjectIds() async {
    if (_httpReferenceObjectIdsCache.isNotEmpty) {
      return _httpReferenceObjectIdsCache;
    }

    final advertisement = await _loadHttpSmartUploadPackAdvertisement();
    if (advertisement != null) {
      _httpReferenceObjectIdsCache.addAll(advertisement.references);
      if (advertisement.headReference != null) {
        _httpHeadReferenceCache ??= advertisement.headReference;
      }
      if (_httpReferenceObjectIdsCache.isNotEmpty) {
        return _httpReferenceObjectIdsCache;
      }
    }

    final infoRefsText = await _fetchHttpText('info/refs');
    if (infoRefsText == null) {
      return _httpReferenceObjectIdsCache;
    }

    for (final line in const LineSplitter().convert(infoRefsText)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        continue;
      }
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 2 || !GitObjectId.isValidHex(parts.first)) {
        continue;
      }
      _httpReferenceObjectIdsCache[parts[1]] = GitObjectId.fromHex(parts.first);
    }
    return _httpReferenceObjectIdsCache;
  }

  Future<List<String>> _loadHttpPackNames() async {
    final cached = _httpPackNamesCache;
    if (cached != null) {
      return cached;
    }

    final infoPacksText = await _fetchHttpText('objects/info/packs');
    if (infoPacksText == null) {
      _httpPackNamesCache = const <String>[];
      return _httpPackNamesCache!;
    }

    final packNames = <String>[
      for (final line in const LineSplitter().convert(infoPacksText))
        if (line.startsWith('P ')) line.substring(2).trim(),
    ]..sort();
    _httpPackNamesCache = packNames;
    return packNames;
  }

  /// Проверяет, что каждый запрошенный объект уже лежит в кэше smart HTTP.
  bool _httpSmartCacheCovers(List<GitObjectId> objectIds) {
    for (final objectId in objectIds) {
      if (!_httpSmartObjectCache.containsKey(objectId)) {
        return false;
      }
    }
    return true;
  }

  /// Забирает один pack через git-upload-pack, если сервер его объявляет.
  ///
  /// GitHub на GET objects/ab/хеш отвечает 403 и тем самым обрывает clone,
  /// fetch и pull. Пока объявление есть, отдельные объекты по dumb HTTP не
  /// запрашиваются. Без объявления остаётся чтение loose-объектов и pack-файлов.
  Future<void> _ensureHttpReachableObjectCacheLoaded() async {
    if (_didPopulateHttpReachableObjectCache) {
      return;
    }
    _didPopulateHttpReachableObjectCache = true;
    final advertisement = await _loadHttpSmartUploadPackAdvertisement();
    if (advertisement == null) {
      return;
    }
    final wantObjectIds = advertisement.references.values.toSet().toList();
    if (wantObjectIds.isEmpty) {
      return;
    }
    final packBytes = await _fetchSmartHttpPackBytes(wantObjectIds);
    if (packBytes == null) {
      return;
    }
    await _cacheSmartHttpPack(
      packBytes,
      algorithm: wantObjectIds.first.algorithm,
    );
  }

  Future<GitObject?> _readHttpObject(
    GitObjectId objectId, {
    required Set<String> activePackNames,
  }) async {
    final cachedObject = _httpSmartObjectCache[objectId];
    if (cachedObject != null) {
      return cachedObject;
    }

    await _ensureHttpReachableObjectCacheLoaded();
    final populated = _httpSmartObjectCache[objectId];
    if (populated != null) {
      return populated;
    }

    final advertisement = _httpUploadPackAdvertisementCache;
    if (advertisement != null) {
      if (_httpSmartFetchInFlight.contains(objectId)) {
        return null;
      }
      _httpSmartFetchInFlight.add(objectId);
      try {
        final smartPackBytes = await _fetchSmartHttpPackBytes([objectId]);
        if (smartPackBytes != null) {
          await _cacheSmartHttpPack(
            smartPackBytes,
            algorithm: objectId.algorithm,
          );
        }
      } finally {
        _httpSmartFetchInFlight.remove(objectId);
      }
      return _httpSmartObjectCache[objectId];
    }

    final looseObjectBytes = await _fetchHttpBytes(
      'objects/${objectId.hex.substring(0, 2)}/${objectId.hex.substring(2)}',
    );
    if (looseObjectBytes != null) {
      final object = const GitLooseObjectCodec().decode(
        zlib.decode(looseObjectBytes),
      );
      _httpSmartObjectCache[objectId] = object;
      return object;
    }

    final packNames = await _loadHttpPackNames();
    if (packNames.isNotEmpty) {
      final packCodec = GitPackCodec(checksumAlgorithm: objectId.algorithm);
      final packIndexCodec = GitPackIndexCodec(
        checksumAlgorithm: objectId.algorithm,
      );
      final packResolver = GitPackResolver(
        objectIdAlgorithm: objectId.algorithm,
      );

      for (final packName in packNames) {
        if (activePackNames.contains(packName)) {
          continue;
        }

        final indexBytes = await _fetchCachedHttpPackIndexBytes(packName);
        if (indexBytes == null) {
          continue;
        }
        final index = packIndexCodec.decode(indexBytes);
        if (index.entryForObjectId(objectId) == null) {
          continue;
        }

        final packBytes = await _fetchCachedHttpPackBytes(packName);
        if (packBytes == null) {
          continue;
        }
        final pack = packCodec.decode(packBytes);
        final resolvedEntries = await packResolver.resolve(
          pack,
          externalBaseResolver: (baseObjectId) => _readHttpObject(
            baseObjectId,
            activePackNames: {...activePackNames, packName},
          ),
        );
        for (final resolvedEntry in resolvedEntries) {
          _httpSmartObjectCache[resolvedEntry.objectId] = resolvedEntry.object;
          if (resolvedEntry.objectId == objectId) {
            return resolvedEntry.object;
          }
        }
      }
    }

    return null;
  }

  Future<void> _cacheSmartHttpPack(
    List<int> packBytes, {
    required GitHashAlgorithm algorithm,
  }) async {
    if (packBytes.isEmpty) {
      return;
    }
    final pack = GitPackCodec(checksumAlgorithm: algorithm).decode(packBytes);
    final resolvedEntries = await GitPackResolver(objectIdAlgorithm: algorithm)
        .resolve(
          pack,
          externalBaseResolver: (baseObjectId) async {
            final cached = _httpSmartObjectCache[baseObjectId];
            if (cached != null) {
              return cached;
            }
            return _readHttpObject(
              baseObjectId,
              activePackNames: const <String>{},
            );
          },
        );
    for (final entry in resolvedEntries) {
      _httpSmartObjectCache[entry.objectId] = entry.object;
    }
  }

  Future<_GitSmartHttpAdvertisement?>
  _loadHttpSmartUploadPackAdvertisement() async {
    if (_didProbeHttpUploadPackAdvertisement) {
      return _httpUploadPackAdvertisementCache;
    }
    _didProbeHttpUploadPackAdvertisement = true;
    try {
      _httpUploadPackAdvertisementCache = await _loadHttpSmartAdvertisement(
        'git-upload-pack',
      );
      return _httpUploadPackAdvertisementCache;
    } catch (_) {
      _didProbeHttpUploadPackAdvertisement = false;
      rethrow;
    }
  }

  Future<_GitSmartHttpAdvertisement?>
  _loadHttpSmartReceivePackAdvertisement() async {
    if (_didProbeHttpReceivePackAdvertisement) {
      return _httpReceivePackAdvertisementCache;
    }
    _didProbeHttpReceivePackAdvertisement = true;
    try {
      _httpReceivePackAdvertisementCache = await _loadHttpSmartAdvertisement(
        'git-receive-pack',
      );
      return _httpReceivePackAdvertisementCache;
    } catch (_) {
      _didProbeHttpReceivePackAdvertisement = false;
      rethrow;
    }
  }

  Future<_GitSmartHttpAdvertisement?> _loadHttpSmartAdvertisement(
    String service,
  ) async {
    final responseBytes = await _fetchHttpBytes('info/refs?service=$service');
    return _parseSmartAdvertisementBytes(service, responseBytes);
  }

  static _GitSmartHttpAdvertisement? _parseSmartAdvertisementBytes(
    String service,
    List<int>? responseBytes, {
    bool expectServiceHeader = true,
  }) {
    if (responseBytes == null || responseBytes.isEmpty) {
      return null;
    }

    try {
      var offset = 0;
      final references = <String, GitObjectId>{};
      GitReference? headReference;
      var sawServiceHeader = !expectServiceHeader;
      var firstReferenceLine = true;

      while (offset + 4 <= responseBytes.length) {
        final length = _GitPktLine.decodeLength(responseBytes, offset);
        if (length == null) {
          break;
        }
        offset += 4;
        if (length == 0) {
          continue;
        }
        final payloadLength = length - 4;
        if (payloadLength < 0 ||
            offset + payloadLength > responseBytes.length) {
          break;
        }
        final payload = responseBytes.sublist(offset, offset + payloadLength);
        offset += payloadLength;

        final payloadText = utf8.decode(payload, allowMalformed: true);
        if (!sawServiceHeader && payloadText == '# service=$service\n') {
          sawServiceHeader = true;
          continue;
        }

        final nulIndex = payload.indexOf(0);
        final referenceText = utf8
            .decode(
              nulIndex == -1 ? payload : payload.sublist(0, nulIndex),
              allowMalformed: true,
            )
            .trimRight();
        if (referenceText.isEmpty) {
          continue;
        }
        final separatorIndex = referenceText.indexOf(' ');
        if (separatorIndex <= 0) {
          continue;
        }
        final objectIdText = referenceText.substring(0, separatorIndex);
        final referenceName = referenceText.substring(separatorIndex + 1);
        if (!GitObjectId.isValidHex(objectIdText) ||
            referenceName.endsWith('^{}')) {
          firstReferenceLine = false;
          continue;
        }
        final objectId = GitObjectId.fromHex(objectIdText);
        references[referenceName] = objectId;

        if (firstReferenceLine && nulIndex != -1) {
          final capabilityText = utf8.decode(
            payload.sublist(nulIndex + 1),
            allowMalformed: true,
          );
          for (final capability in capabilityText.trim().split(' ')) {
            if (capability.startsWith('symref=HEAD:')) {
              final targetReferenceName = capability
                  .substring('symref=HEAD:'.length)
                  .trim();
              if (targetReferenceName.isNotEmpty) {
                headReference = GitReference.symbolic(
                  'HEAD',
                  targetReferenceName,
                );
              }
            }
          }
        }
        firstReferenceLine = false;
      }

      if (!sawServiceHeader) {
        return null;
      }
      return _GitSmartHttpAdvertisement(
        service: service,
        references: references,
        headReference: headReference,
      );
    } on FormatException {
      return null;
    }
  }

  Future<GitReference?> _readSshReference(String referenceName) async {
    if (referenceName == 'HEAD') {
      final advertisement = await _loadSshUploadPackAdvertisement();
      return advertisement?.headReference;
    }
    final objectId = await _resolveSshReferenceObjectId(referenceName);
    if (objectId == null) {
      return null;
    }
    return GitReference.direct(referenceName, objectId);
  }

  Future<GitObjectId?> _resolveSshReferenceObjectId(
    String referenceName,
  ) async {
    if (referenceName == 'HEAD') {
      final headReference = await _readSshReference('HEAD');
      if (headReference == null) {
        return null;
      }
      return switch (headReference.target) {
        GitDirectReferenceTarget(:final objectId) => objectId,
        GitSymbolicReferenceTarget(:final referenceName) =>
          await _resolveSshReferenceObjectId(referenceName),
      };
    }
    final advertisement = await _loadSshUploadPackAdvertisement();
    return advertisement?.references[referenceName];
  }

  Future<List<String>> _listSshReferenceNamesUnder(
    String baseReferenceName,
  ) async {
    final advertisement = await _loadSshUploadPackAdvertisement();
    final prefix = '$baseReferenceName/';
    final names = <String>[
      for (final referenceName
          in advertisement?.references.keys ?? const <String>[])
        if (referenceName.startsWith(prefix)) referenceName,
    ];
    final headTargetReferenceName =
        advertisement?.headReference?.targetReferenceName;
    if (headTargetReferenceName != null &&
        headTargetReferenceName.startsWith(prefix) &&
        !names.contains(headTargetReferenceName)) {
      names.add(headTargetReferenceName);
    }
    names.sort();
    return names;
  }

  Future<GitObject?> _readSshObject(GitObjectId objectId) async {
    final cached = _sshSmartObjectCache[objectId];
    if (cached != null) {
      return cached;
    }
    await _ensureSshReachableObjectCacheLoaded();
    return _sshSmartObjectCache[objectId];
  }

  Future<void> _ensureSshReachableObjectCacheLoaded() async {
    if (_didPopulateSshReachableObjectCache) {
      return;
    }
    _didPopulateSshReachableObjectCache = true;
    final advertisement = await _loadSshUploadPackAdvertisement();
    final wantObjectIds = {
      for (final objectId
          in advertisement?.references.values ?? const <GitObjectId>[])
        objectId,
    }.toList();
    if (wantObjectIds.isEmpty) {
      return;
    }
    final packBytes = await _fetchSshPackBytes(wantObjectIds);
    if (packBytes == null) {
      return;
    }
    await _cacheSshPack(packBytes, algorithm: wantObjectIds.first.algorithm);
  }

  Future<void> _cacheSshPack(
    List<int> packBytes, {
    required GitHashAlgorithm algorithm,
  }) async {
    if (packBytes.isEmpty) {
      return;
    }
    final pack = GitPackCodec(checksumAlgorithm: algorithm).decode(packBytes);
    final resolvedEntries = await GitPackResolver(objectIdAlgorithm: algorithm)
        .resolve(
          pack,
          externalBaseResolver: (baseObjectId) async {
            final cached = _sshSmartObjectCache[baseObjectId];
            if (cached != null) {
              return cached;
            }
            return _readSshObject(baseObjectId);
          },
        );
    for (final entry in resolvedEntries) {
      _sshSmartObjectCache[entry.objectId] = entry.object;
    }
  }

  Future<_GitSmartHttpAdvertisement?> _loadSshUploadPackAdvertisement() async {
    if (_didProbeSshUploadPackAdvertisement) {
      return _sshUploadPackAdvertisementCache;
    }
    _didProbeSshUploadPackAdvertisement = true;
    try {
      _sshUploadPackAdvertisementCache = _parseSmartAdvertisementBytes(
        'git-upload-pack',
        await _runSshService('git-upload-pack', advertiseRefs: true),
        expectServiceHeader: false,
      );
      return _sshUploadPackAdvertisementCache;
    } catch (_) {
      _didProbeSshUploadPackAdvertisement = false;
      rethrow;
    }
  }

  Future<_GitSmartHttpAdvertisement?> _loadSshReceivePackAdvertisement() async {
    if (_didProbeSshReceivePackAdvertisement) {
      return _sshReceivePackAdvertisementCache;
    }
    _didProbeSshReceivePackAdvertisement = true;
    try {
      _sshReceivePackAdvertisementCache = _parseSmartAdvertisementBytes(
        'git-receive-pack',
        await _runSshService('git-receive-pack', advertiseRefs: true),
        expectServiceHeader: false,
      );
      return _sshReceivePackAdvertisementCache;
    } catch (_) {
      _didProbeSshReceivePackAdvertisement = false;
      rethrow;
    }
  }

  Future<List<int>?> _fetchSshPackBytes(
    List<GitObjectId> wantObjectIds, {
    Iterable<GitObjectId> haveObjectIds = const <GitObjectId>[],
  }) async {
    final advertisement = await _loadSshUploadPackAdvertisement();
    if (advertisement == null || wantObjectIds.isEmpty) {
      return null;
    }

    final algorithm = wantObjectIds.first.algorithm;
    final requestBytes = <int>[];
    for (final objectId in wantObjectIds) {
      if (objectId.algorithm != algorithm) {
        throw StateError(
          'SSH pack requests require a consistent hash algorithm.',
        );
      }
      requestBytes.addAll(_GitPktLine.encodeText('want ${objectId.hex}\n'));
    }
    requestBytes.addAll(_GitPktLine.flushBytes);
    for (final objectId in haveObjectIds) {
      if (objectId.algorithm == algorithm) {
        requestBytes.addAll(_GitPktLine.encodeText('have ${objectId.hex}\n'));
      }
    }
    requestBytes.addAll(_GitPktLine.encodeText('done\n'));

    final responseBytes = await _runSshService(
      'git-upload-pack',
      requestBytes: requestBytes,
    );
    final packOffset = _GitPktLine.findPackOffset(responseBytes);
    if (packOffset == null) {
      return null;
    }
    return responseBytes.sublist(packOffset);
  }

  Future<void> _sendSshReceivePack(
    List<_GitSmartReceivePackCommand> commands, {
    List<int>? packBytes,
  }) async {
    final advertisement = await _loadSshReceivePackAdvertisement();
    if (advertisement == null) {
      throw UnsupportedError(
        'SSH remote does not advertise git-receive-pack support.',
      );
    }
    if (commands.isEmpty) {
      return;
    }

    final requestBytes = <int>[];
    for (var index = 0; index < commands.length; index++) {
      final command = commands[index];
      final previousObjectIdText =
          command.previousObjectId?.hex ??
          _zeroObjectIdHex(command.zeroAlgorithm);
      final nextObjectIdText =
          command.nextObjectId?.hex ?? _zeroObjectIdHex(command.zeroAlgorithm);
      final line =
          '$previousObjectIdText $nextObjectIdText ${command.referenceName}';
      requestBytes.addAll(
        _GitPktLine.encodeText(
          index == 0 ? '$line\u0000report-status\n' : '$line\n',
        ),
      );
    }
    requestBytes.addAll(_GitPktLine.flushBytes);
    if (packBytes != null && packBytes.isNotEmpty) {
      requestBytes.addAll(packBytes);
    }

    final responseBytes = await _runSshService(
      'git-receive-pack',
      requestBytes: requestBytes,
    );
    final responseLines = _GitPktLine.decodePayloadTexts(responseBytes);
    final unpackStatus = responseLines
        .where((line) => line.startsWith('unpack '))
        .map((line) => line.trim())
        .firstWhere((_) => true, orElse: () => '');
    if (unpackStatus.isNotEmpty && unpackStatus != 'unpack ok') {
      throw StateError('SSH push failed during unpack: $unpackStatus');
    }
    final rejectedLine = responseLines
        .where((line) => line.startsWith('ng '))
        .map((line) => line.trim())
        .firstWhere((_) => true, orElse: () => '');
    if (rejectedLine.isNotEmpty) {
      throw StateError('SSH push rejected: $rejectedLine');
    }
  }

  Future<List<int>> _runSshService(
    String service, {
    List<int>? requestBytes,
    bool advertiseRefs = false,
  }) {
    throw UnsupportedError(
      'SSH remotes are not available on the virtual host '
      '($service, advertiseRefs=$advertiseRefs, bytes=${requestBytes?.length ?? 0}).',
    );
  }

  void _invalidateSshCaches() {
    _sshSmartObjectCache.clear();
    _sshUploadPackAdvertisementCache = null;
    _sshReceivePackAdvertisementCache = null;
    _didProbeSshUploadPackAdvertisement = false;
    _didProbeSshReceivePackAdvertisement = false;
    _didPopulateSshReachableObjectCache = false;
  }

  Future<List<int>?> _fetchSmartHttpPackBytes(
    List<GitObjectId> wantObjectIds, {
    Iterable<GitObjectId> haveObjectIds = const <GitObjectId>[],
  }) async {
    final advertisement = await _loadHttpSmartUploadPackAdvertisement();
    if (advertisement == null || wantObjectIds.isEmpty) {
      return null;
    }

    final algorithm = wantObjectIds.first.algorithm;
    final requestBytes = <int>[];
    for (final objectId in wantObjectIds) {
      if (objectId.algorithm != algorithm) {
        throw StateError(
          'Smart HTTP pack requests require a consistent hash algorithm.',
        );
      }
      requestBytes.addAll(_GitPktLine.encodeText('want ${objectId.hex}\n'));
    }
    final depth = uploadPackDepth;
    if (depth != null) {
      requestBytes.addAll(_GitPktLine.encodeText('deepen $depth\n'));
    }
    final filter = uploadPackFilter;
    if (filter != null) {
      requestBytes.addAll(_GitPktLine.encodeText('filter $filter\n'));
    }
    requestBytes.addAll(_GitPktLine.flushBytes);
    for (final objectId in haveObjectIds) {
      if (objectId.algorithm == algorithm) {
        requestBytes.addAll(_GitPktLine.encodeText('have ${objectId.hex}\n'));
      }
    }
    requestBytes.addAll(_GitPktLine.encodeText('done\n'));

    final responseBytes = await _fetchHttpBytes(
      'git-upload-pack',
      method: 'POST',
      body: requestBytes,
      extraHeaders: const {
        'Accept': 'application/x-git-upload-pack-result',
        'Content-Type': 'application/x-git-upload-pack-request',
      },
    );
    if (responseBytes == null || responseBytes.isEmpty) {
      return null;
    }

    final packOffset = _GitPktLine.findPackOffset(responseBytes);
    if (packOffset == null) {
      final packetTexts = _GitPktLine.decodePayloadTexts(responseBytes);
      if (packetTexts.any((line) => line.startsWith('ERR '))) {
        throw StateError(
          packetTexts.firstWhere((line) => line.startsWith('ERR ')).trim(),
        );
      }
      return null;
    }
    return responseBytes.sublist(packOffset);
  }

  Future<void> _sendSmartHttpReceivePack(
    List<_GitSmartReceivePackCommand> commands, {
    List<int>? packBytes,
  }) async {
    final advertisement = await _loadHttpSmartReceivePackAdvertisement();
    if (advertisement == null) {
      throw UnsupportedError(
        'HTTP remote does not advertise git-receive-pack support.',
      );
    }
    if (commands.isEmpty) {
      return;
    }

    final requestBytes = <int>[];
    for (var index = 0; index < commands.length; index++) {
      final command = commands[index];
      final previousObjectIdText =
          command.previousObjectId?.hex ??
          _zeroObjectIdHex(command.zeroAlgorithm);
      final nextObjectIdText =
          command.nextObjectId?.hex ?? _zeroObjectIdHex(command.zeroAlgorithm);
      final line =
          '$previousObjectIdText $nextObjectIdText ${command.referenceName}';
      requestBytes.addAll(
        _GitPktLine.encodeText(
          index == 0 ? '$line\u0000report-status\n' : '$line\n',
        ),
      );
    }
    requestBytes.addAll(_GitPktLine.flushBytes);
    if (packBytes != null && packBytes.isNotEmpty) {
      requestBytes.addAll(packBytes);
    }

    final responseBytes = await _fetchHttpBytes(
      'git-receive-pack',
      method: 'POST',
      body: requestBytes,
      extraHeaders: const {
        'Accept': 'application/x-git-receive-pack-result',
        'Content-Type': 'application/x-git-receive-pack-request',
      },
    );
    if (responseBytes == null) {
      throw StateError('Smart HTTP push did not return a receive-pack result.');
    }

    final responseLines = _GitPktLine.decodePayloadTexts(responseBytes);
    final unpackStatus = responseLines
        .where((line) => line.startsWith('unpack '))
        .map((line) => line.trim())
        .firstWhere((_) => true, orElse: () => '');
    if (unpackStatus.isNotEmpty && unpackStatus != 'unpack ok') {
      throw StateError('Smart HTTP push failed during unpack: $unpackStatus');
    }
    final rejectedLine = responseLines
        .where((line) => line.startsWith('ng '))
        .map((line) => line.trim())
        .firstWhere((_) => true, orElse: () => '');
    if (rejectedLine.isNotEmpty) {
      throw StateError('Smart HTTP push rejected: $rejectedLine');
    }
  }

  void _invalidateHttpCaches() {
    _httpReferenceObjectIdsCache.clear();
    _httpHeadReferenceCache = null;
    _httpPackNamesCache = null;
    _httpPackIndexBytesCache.clear();
    _httpPackBytesCache.clear();
    _httpSmartObjectCache.clear();
    _httpUploadPackAdvertisementCache = null;
    _httpReceivePackAdvertisementCache = null;
    _didProbeHttpUploadPackAdvertisement = false;
    _didProbeHttpReceivePackAdvertisement = false;
    _didPopulateHttpReachableObjectCache = false;
    _httpSmartFetchInFlight.clear();
  }

  Future<List<int>?> _fetchCachedHttpPackIndexBytes(String packName) async {
    final cached = _httpPackIndexBytesCache[packName];
    if (cached != null) {
      return cached;
    }

    final indexName = p.setExtension(packName, '.idx');
    final bytes = await _fetchHttpBytes('objects/pack/$indexName');
    if (bytes != null) {
      _httpPackIndexBytesCache[packName] = bytes;
    }
    return bytes;
  }

  Future<List<int>?> _fetchCachedHttpPackBytes(String packName) async {
    final cached = _httpPackBytesCache[packName];
    if (cached != null) {
      return cached;
    }

    final bytes = await _fetchHttpBytes('objects/pack/$packName');
    if (bytes != null) {
      _httpPackBytesCache[packName] = bytes;
    }
    return bytes;
  }

  Future<List<int>?> _fetchHttpBytes(
    String relativePath, {
    String method = 'GET',
    List<int>? body,
    Map<String, String> extraHeaders = const {},
    Set<int> missingStatusCodes = const {HttpStatus.notFound},
  }) async {
    final requestUri = httpBaseUri!.resolve(relativePath);
    final client = gitHttp ?? PackageGitHttp(timeout: gitFs.limits.runTimeout);
    final response = await client.send(
      method: method,
      uri: requestUri,
      headers: {...httpHeaders, ...extraHeaders},
      body: body,
    );
    if (missingStatusCodes.contains(response.statusCode)) {
      return null;
    }
    if (response.statusCode != HttpStatus.ok) {
      throw StateError(
        'Remote HTTP request failed for $requestUri: '
                '${response.statusCode} ${response.reasonPhrase} '
                '${gitHttpBodyText(response.body).trim()}'
            .trim(),
      );
    }
    return response.body;
  }

  Future<String?> _fetchHttpText(String relativePath) async {
    final bytes = await _fetchHttpBytes(relativePath);
    if (bytes == null) {
      return null;
    }
    return utf8.decode(bytes);
  }
}

final class _GitFetchMapping {
  const _GitFetchMapping({
    required this.sourceReferenceName,
    required this.destinationReferenceName,
    required this.objectId,
    required this.force,
  });

  final String sourceReferenceName;
  final String destinationReferenceName;
  final GitObjectId objectId;
  final bool force;
}

final class _GitPushMapping {
  const _GitPushMapping({
    required this.sourceReferenceName,
    required this.destinationReferenceName,
    required this.objectId,
    required this.force,
  });

  final String? sourceReferenceName;
  final String destinationReferenceName;
  final GitObjectId? objectId;
  final bool force;

  bool get isDeletion => objectId == null;
}

final class _GitSmartHttpAdvertisement {
  const _GitSmartHttpAdvertisement({
    required this.service,
    required this.references,
    this.headReference,
  });

  final String service;
  final Map<String, GitObjectId> references;
  final GitReference? headReference;
}

final class _GitSmartReceivePackCommand {
  const _GitSmartReceivePackCommand({
    required this.referenceName,
    required this.previousObjectId,
    required this.nextObjectId,
  });

  final String referenceName;
  final GitObjectId? previousObjectId;
  final GitObjectId? nextObjectId;

  GitHashAlgorithm get zeroAlgorithm =>
      previousObjectId?.algorithm ??
      nextObjectId?.algorithm ??
      GitHashAlgorithm.sha1;
}

final class _GitSshRemoteConfig {
  const _GitSshRemoteConfig({
    required this.host,
    required this.port,
    required this.username,
    required this.repositoryPath,
    this.privateKeyPath,
    this.privateKey,
    this.privateKeyPassphrase,
    this.password,
    this.knownHostsPath,
    this.hostKeyFingerprints = const <String>[],
  });

  final String host;
  final int port;
  final String username;
  final String repositoryPath;
  final String? privateKeyPath;
  final String? privateKey;
  final String? privateKeyPassphrase;
  final String? password;
  final String? knownHostsPath;
  final List<String> hostKeyFingerprints;
}

// ignore: avoid_classes_with_only_static_members, набор функций pkt-line из референса
final class _GitPktLine {
  static const List<int> flushBytes = <int>[0x30, 0x30, 0x30, 0x30];

  static List<int> encodeText(String text) {
    final payload = utf8.encode(text);
    final length = payload.length + 4;
    final prefix = length.toRadixString(16).padLeft(4, '0');
    return <int>[...ascii.encode(prefix), ...payload];
  }

  static int? decodeLength(List<int> bytes, int offset) {
    if (offset + 4 > bytes.length) {
      return null;
    }
    final lengthText = ascii.decode(
      bytes.sublist(offset, offset + 4),
      allowInvalid: true,
    );
    return int.tryParse(lengthText, radix: 16);
  }

  static int? findPackOffset(List<int> bytes) {
    for (var index = 0; index <= bytes.length - 4; index++) {
      if (bytes[index] == 0x50 &&
          bytes[index + 1] == 0x41 &&
          bytes[index + 2] == 0x43 &&
          bytes[index + 3] == 0x4b) {
        return index;
      }
    }
    return null;
  }

  static List<String> decodePayloadTexts(List<int> bytes) {
    final lines = <String>[];
    var offset = 0;
    while (offset + 4 <= bytes.length) {
      final length = decodeLength(bytes, offset);
      if (length == null) {
        break;
      }
      offset += 4;
      if (length == 0) {
        continue;
      }
      final payloadLength = length - 4;
      if (payloadLength < 0 || offset + payloadLength > bytes.length) {
        break;
      }
      lines.add(
        utf8.decode(
          bytes.sublist(offset, offset + payloadLength),
          allowMalformed: true,
        ),
      );
      offset += payloadLength;
    }
    return lines;
  }
}
