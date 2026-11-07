// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
part of '../git_repository.dart';

/// Секции remote и branch в `.git/config`.
extension GitRepositoryConfig on GitRepository {
  Future<List<GitRemote>> remotes() async {
    final document = await _readConfigDocument();
    return <GitRemote>[
      for (final section in document.sections)
        if (GitRepositoryConfig._isRemoteConfigSection(section))
          GitRepositoryConfig._remoteFromConfigSection(section),
    ]..sort((left, right) => left.name.compareTo(right.name));
  }

  Future<GitRemote?> remote(String name) async {
    final normalizedName = GitRepositoryConfig._normalizeRemoteName(name);
    final document = await _readConfigDocument();
    for (final section in document.sections) {
      if (GitRepositoryConfig._isRemoteConfigSection(section) &&
          section.subsection == normalizedName) {
        return GitRepositoryConfig._remoteFromConfigSection(section);
      }
    }
    return null;
  }

  Future<GitRemote> setRemote(GitRemote remote) async {
    final normalizedName = GitRepositoryConfig._normalizeRemoteName(
      remote.name,
    );
    final normalizedUrl = remote.url.trim();
    if (normalizedUrl.isEmpty) {
      throw ArgumentError.value(
        remote.url,
        'remote.url',
        'URL must not be empty.',
      );
    }

    final fetchRefSpecs = remote.fetchRefSpecs.isEmpty
        ? [GitRefSpec.parse('+refs/heads/*:refs/remotes/$normalizedName/*')]
        : remote.fetchRefSpecs;
    final normalizedRemote = GitRemote(
      name: normalizedName,
      url: normalizedUrl,
      fetchRefSpecs: fetchRefSpecs,
      pushUrl: remote.pushUrl?.trim().isEmpty ?? true
          ? null
          : remote.pushUrl!.trim(),
      httpHeaders: remote.httpHeaders,
      sshPrivateKeyPath: remote.sshPrivateKeyPath?.trim().isEmpty ?? true
          ? null
          : remote.sshPrivateKeyPath!.trim(),
      sshPrivateKey: remote.sshPrivateKey?.trim().isEmpty ?? true
          ? null
          : remote.sshPrivateKey,
      sshPrivateKeyPassphrase: remote.sshPrivateKeyPassphrase?.isEmpty ?? true
          ? null
          : remote.sshPrivateKeyPassphrase,
      sshPassword: remote.sshPassword?.isEmpty ?? true
          ? null
          : remote.sshPassword,
      sshKnownHostsPath: remote.sshKnownHostsPath?.trim().isEmpty ?? true
          ? null
          : remote.sshKnownHostsPath!.trim(),
      sshHostKeyFingerprints: [
        for (final fingerprint in remote.sshHostKeyFingerprints)
          if (fingerprint.trim().isNotEmpty) fingerprint.trim(),
      ],
    );

    final document = await _readConfigDocument();
    final updatedSections = <_GitConfigSection>[];
    var replaced = false;
    for (final section in document.sections) {
      if (GitRepositoryConfig._isRemoteConfigSection(section) &&
          section.subsection == normalizedName) {
        if (!replaced) {
          updatedSections.add(
            GitRepositoryConfig._buildRemoteConfigSection(normalizedRemote),
          );
          replaced = true;
        }
      } else {
        updatedSections.add(section);
      }
    }
    if (!replaced) {
      updatedSections.add(
        GitRepositoryConfig._buildRemoteConfigSection(normalizedRemote),
      );
    }

    await _writeConfigDocument(
      _GitConfigDocument(
        preamble: document.preamble,
        sections: updatedSections,
      ),
    );
    return normalizedRemote;
  }

  Future<bool> deleteRemote(String name) async {
    final normalizedName = GitRepositoryConfig._normalizeRemoteName(name);
    final document = await _readConfigDocument();
    final updatedSections = [
      for (final section in document.sections)
        if (!(GitRepositoryConfig._isRemoteConfigSection(section) &&
            section.subsection == normalizedName))
          section,
    ];
    if (updatedSections.length == document.sections.length) {
      return false;
    }

    await _writeConfigDocument(
      _GitConfigDocument(
        preamble: document.preamble,
        sections: updatedSections,
      ),
    );
    return true;
  }

  Future<GitBranchTracking?> branchTracking(String branchName) async {
    final referenceName = GitRepositoryReferences._normalizeBranchReferenceName(
      branchName,
    );
    final document = await _readConfigDocument();
    for (final section in document.sections) {
      if (GitRepositoryConfig._isBranchConfigSection(section) &&
          section.subsection ==
              GitRepositoryReferences._branchShortName(referenceName)) {
        return GitRepositoryConfig._branchTrackingFromConfigSection(section);
      }
    }
    return null;
  }

  Future<GitBranchTracking> setBranchTracking(
    GitBranchTracking tracking,
  ) async {
    final referenceName = GitRepositoryReferences._normalizeBranchReferenceName(
      tracking.branchName,
    );
    final normalizedRemoteName = GitRepositoryConfig._normalizeRemoteName(
      tracking.remoteName,
    );
    final normalizedMergeReferenceName =
        tracking.mergeReferenceName.trim().startsWith('refs/')
        ? tracking.mergeReferenceName.trim()
        : GitRepositoryReferences._normalizeBranchReferenceName(
            tracking.mergeReferenceName,
          );
    final normalizedTracking = GitBranchTracking(
      branchName: GitRepositoryReferences._branchShortName(referenceName),
      referenceName: referenceName,
      remoteName: normalizedRemoteName,
      mergeReferenceName: normalizedMergeReferenceName,
    );

    final document = await _readConfigDocument();
    final updatedSections = <_GitConfigSection>[];
    var replaced = false;
    for (final section in document.sections) {
      if (GitRepositoryConfig._isBranchConfigSection(section) &&
          section.subsection == normalizedTracking.branchName) {
        if (!replaced) {
          updatedSections.add(
            GitRepositoryConfig._buildBranchConfigSection(normalizedTracking),
          );
          replaced = true;
        }
      } else {
        updatedSections.add(section);
      }
    }
    if (!replaced) {
      updatedSections.add(
        GitRepositoryConfig._buildBranchConfigSection(normalizedTracking),
      );
    }

    await _writeConfigDocument(
      _GitConfigDocument(
        preamble: document.preamble,
        sections: updatedSections,
      ),
    );
    return normalizedTracking;
  }

  Future<bool> deleteBranchTracking(String branchName) async {
    final normalizedBranchName = GitRepositoryReferences._branchShortName(
      GitRepositoryReferences._normalizeBranchReferenceName(branchName),
    );
    final document = await _readConfigDocument();
    final updatedSections = [
      for (final section in document.sections)
        if (!(GitRepositoryConfig._isBranchConfigSection(section) &&
            section.subsection == normalizedBranchName))
          section,
    ];
    if (updatedSections.length == document.sections.length) {
      return false;
    }

    await _writeConfigDocument(
      _GitConfigDocument(
        preamble: document.preamble,
        sections: updatedSections,
      ),
    );
    return true;
  }

  Future<List<GitRemoteReference>> remoteReferences([
    String? remoteName,
  ]) async {
    final remotesDirectory = Directory(
      p.join(referenceDirectoryPath, 'remotes'),
    );
    if (!await remotesDirectory.exists()) {
      return const <GitRemoteReference>[];
    }

    final normalizedRemoteName = remoteName == null
        ? null
        : GitRepositoryConfig._normalizeRemoteName(remoteName);
    final targetDirectoryPath = normalizedRemoteName == null
        ? remotesDirectory.path
        : p.join(remotesDirectory.path, normalizedRemoteName);
    final targetDirectory = Directory(targetDirectoryPath);
    if (!await targetDirectory.exists()) {
      return const <GitRemoteReference>[];
    }

    final references = <GitRemoteReference>[];
    await for (final entity in targetDirectory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }

      final relativePath = p.posix.joinAll(
        p.split(p.relative(entity.path, from: remotesDirectory.path)),
      );
      final parts = p.posix.split(relativePath);
      if (parts.length < 2) {
        continue;
      }
      final resolvedRemoteName = parts.first;
      final name = p.posix.joinAll(parts.skip(1));
      final referenceName = 'refs/remotes/$resolvedRemoteName/$name';
      final objectId = await resolveReferenceObjectId(referenceName);
      if (objectId == null) {
        continue;
      }
      references.add(
        GitRemoteReference(
          remoteName: resolvedRemoteName,
          name: name,
          referenceName: referenceName,
          objectId: objectId,
        ),
      );
    }

    references.sort(
      (left, right) => left.referenceName.compareTo(right.referenceName),
    );
    return references;
  }

  Future<GitRemoteReference> writeRemoteReference(
    String remoteName,
    String name,
    GitObjectId objectId,
  ) async {
    final normalizedRemoteName = GitRepositoryConfig._normalizeRemoteName(
      remoteName,
    );
    final normalizedName = _normalizeRemoteReferenceName(name);
    final referenceName = 'refs/remotes/$normalizedRemoteName/$normalizedName';
    await writeReference(GitReference.direct(referenceName, objectId));
    return GitRemoteReference(
      remoteName: normalizedRemoteName,
      name: normalizedName,
      referenceName: referenceName,
      objectId: objectId,
    );
  }

  Future<bool> deleteRemoteReference(String remoteName, String name) {
    final normalizedRemoteName = GitRepositoryConfig._normalizeRemoteName(
      remoteName,
    );
    final normalizedName = _normalizeRemoteReferenceName(name);
    return deleteReference(
      'refs/remotes/$normalizedRemoteName/$normalizedName',
    );
  }

  static String _normalizeRemoteName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Remote name must not be empty.');
    }
    if (trimmed.contains(RegExp(r'[\s/\\]'))) {
      throw ArgumentError.value(
        name,
        'name',
        'Remote name must not contain whitespace or path separators.',
      );
    }
    return trimmed;
  }

  String _normalizeRemoteReferenceName(String name) {
    final normalized = _normalizeRelativeWorkTreePath(name);
    if (normalized == '.' || normalized.isEmpty) {
      throw ArgumentError.value(
        name,
        'name',
        'Remote reference name must not be empty.',
      );
    }
    return normalized;
  }

  Future<_GitConfigDocument> _readConfigDocument() async {
    final configFile = File(configFilePath);
    if (!await configFile.exists()) {
      return const _GitConfigDocument(
        preamble: <String>[],
        sections: <_GitConfigSection>[],
      );
    }

    final lines = await configFile.readAsLines();
    final preamble = <String>[];
    final sections = <_GitConfigSection>[];
    _GitConfigSection? currentSection;

    for (final line in lines) {
      if (GitRepositoryConfig._parseConfigSectionHeader(line)
          case final parsedHeader?) {
        if (currentSection != null) {
          sections.add(currentSection);
        }
        currentSection = _GitConfigSection(
          headerLine: line,
          name: parsedHeader.name,
          subsection: parsedHeader.subsection,
          bodyLines: const [],
        );
        continue;
      }

      if (currentSection == null) {
        preamble.add(line);
      } else {
        currentSection = currentSection.copyWith(
          bodyLines: [...currentSection.bodyLines, line],
        );
      }
    }

    if (currentSection != null) {
      sections.add(currentSection);
    }

    return _GitConfigDocument(preamble: preamble, sections: sections);
  }

  Future<void> _writeConfigDocument(_GitConfigDocument document) async {
    final lines = <String>[...document.preamble];

    for (final section in document.sections) {
      lines.add(section.headerLine);
      lines.addAll(section.bodyLines);
    }

    final configFile = File(configFilePath);
    await configFile.parent.create(recursive: true);
    final contents = lines.isEmpty
        ? ''
        : '${lines.join('\n')}${lines.isEmpty ? '' : '\n'}';
    await configFile.writeAsString(contents, flush: true);
  }

  static ({String name, String? subsection})? _parseConfigSectionHeader(
    String line,
  ) {
    final match = RegExp(r'^\s*\[([^\s"\]]+)(?:\s+"([^"]+)")?\]\s*$')
        .firstMatch(line);
    if (match == null) {
      return null;
    }
    return (
      name: match.group(1)!.trim().toLowerCase(),
      subsection: match.group(2),
    );
  }

  static ({String key, String value})? _parseConfigKeyValue(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#') || trimmed.startsWith(';')) {
      return null;
    }

    final separatorIndex = trimmed.indexOf('=');
    if (separatorIndex == -1) {
      return (key: trimmed.toLowerCase(), value: 'true');
    }

    return (
      key: trimmed.substring(0, separatorIndex).trim().toLowerCase(),
      value: trimmed.substring(separatorIndex + 1).trim(),
    );
  }

  static bool _isRemoteConfigSection(_GitConfigSection section) =>
      section.name == 'remote' && section.subsection != null;

  static bool _isBranchConfigSection(_GitConfigSection section) =>
      section.name == 'branch' && section.subsection != null;

  static GitBranchTracking? _branchTrackingFromConfigSection(
    _GitConfigSection section,
  ) {
    String? remoteName;
    String? mergeReferenceName;

    for (final line in section.bodyLines) {
      final keyValue = GitRepositoryConfig._parseConfigKeyValue(line);
      if (keyValue == null) {
        continue;
      }
      switch (keyValue.key) {
        case 'remote':
          remoteName = keyValue.value;
        case 'merge':
          mergeReferenceName = keyValue.value;
      }
    }

    if (remoteName == null ||
        remoteName.isEmpty ||
        mergeReferenceName == null ||
        mergeReferenceName.isEmpty) {
      return null;
    }

    final referenceName = GitRepositoryReferences._normalizeBranchReferenceName(
      section.subsection!,
    );
    return GitBranchTracking(
      branchName: section.subsection!,
      referenceName: referenceName,
      remoteName: remoteName,
      mergeReferenceName: mergeReferenceName,
    );
  }

  static GitRemote _remoteFromConfigSection(_GitConfigSection section) {
    final fetchRefSpecs = <GitRefSpec>[];
    final httpHeaders = <String, String>{};
    final sshHostKeyFingerprints = <String>[];
    String? url;
    String? pushUrl;
    String? sshPrivateKeyPath;
    String? sshPrivateKey;
    String? sshPrivateKeyPassphrase;
    String? sshPassword;
    String? sshKnownHostsPath;

    for (final line in section.bodyLines) {
      final keyValue = GitRepositoryConfig._parseConfigKeyValue(line);
      if (keyValue == null) {
        continue;
      }
      switch (keyValue.key) {
        case 'url':
          url = keyValue.value;
        case 'pushurl':
          pushUrl = keyValue.value;
        case 'fetch':
          fetchRefSpecs.add(GitRefSpec.parse(keyValue.value));
        case 'httpheader':
          final headerSeparator = keyValue.value.indexOf(':');
          if (headerSeparator <= 0) {
            continue;
          }
          final name = keyValue.value.substring(0, headerSeparator).trim();
          final value = keyValue.value.substring(headerSeparator + 1).trim();
          if (name.isEmpty) {
            continue;
          }
          httpHeaders[name] = value;
        case 'sshprivatekeypath':
          sshPrivateKeyPath = keyValue.value;
        case 'sshprivatekey':
          sshPrivateKey = keyValue.value;
        case 'sshprivatekeybase64':
          sshPrivateKey = utf8.decode(base64.decode(keyValue.value));
        case 'sshprivatekeypassphrase':
          sshPrivateKeyPassphrase = keyValue.value;
        case 'sshpassword':
          sshPassword = keyValue.value;
        case 'sshknownhostspath':
          sshKnownHostsPath = keyValue.value;
        case 'sshhostkeyfingerprint':
          sshHostKeyFingerprints.add(keyValue.value);
      }
    }

    if (url == null || url.isEmpty) {
      throw FormatException(
        'Remote config section is missing a url entry.',
        section.subsection,
      );
    }

    return GitRemote(
      name: section.subsection!,
      url: url,
      fetchRefSpecs: fetchRefSpecs,
      pushUrl: pushUrl,
      httpHeaders: httpHeaders,
      sshPrivateKeyPath: sshPrivateKeyPath,
      sshPrivateKey: sshPrivateKey,
      sshPrivateKeyPassphrase: sshPrivateKeyPassphrase,
      sshPassword: sshPassword,
      sshKnownHostsPath: sshKnownHostsPath,
      sshHostKeyFingerprints: sshHostKeyFingerprints,
    );
  }

  static _GitConfigSection _buildRemoteConfigSection(
    GitRemote remote,
  ) => _GitConfigSection(
    headerLine: '[remote "${remote.name}"]',
    name: 'remote',
    subsection: remote.name,
    bodyLines: [
      '\turl = ${remote.url}',
      if (remote.pushUrl != null) '\tpushurl = ${remote.pushUrl}',
      for (final header in remote.httpHeaders.entries)
        '\thttpHeader = ${header.key}: ${header.value}',
      if (remote.sshPrivateKeyPath != null)
        '\tsshPrivateKeyPath = ${remote.sshPrivateKeyPath}',
      if (remote.sshPrivateKey != null)
        '\tsshPrivateKeyBase64 = ${base64.encode(utf8.encode(remote.sshPrivateKey!))}',
      if (remote.sshPrivateKeyPassphrase != null)
        '\tsshPrivateKeyPassphrase = ${remote.sshPrivateKeyPassphrase}',
      if (remote.sshPassword != null) '\tsshPassword = ${remote.sshPassword}',
      if (remote.sshKnownHostsPath != null)
        '\tsshKnownHostsPath = ${remote.sshKnownHostsPath}',
      for (final fingerprint in remote.sshHostKeyFingerprints)
        '\tsshHostKeyFingerprint = $fingerprint',
      for (final fetchRefSpec in remote.fetchRefSpecs)
        '\tfetch = ${fetchRefSpec.storageValue}',
    ],
  );

  static _GitConfigSection _buildBranchConfigSection(
    GitBranchTracking tracking,
  ) => _GitConfigSection(
    headerLine: '[branch "${tracking.branchName}"]',
    name: 'branch',
    subsection: tracking.branchName,
    bodyLines: [
      '\tremote = ${tracking.remoteName}',
      '\tmerge = ${tracking.mergeReferenceName}',
    ],
  );
}
