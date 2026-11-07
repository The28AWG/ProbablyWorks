part of '../git_applet.dart';

/// Подпись коммита, конфиг и короткий текст для stdout.
extension GitAppletText on GitApplet {
  GitCommitSignature _author(
    AppletIo io,
    List<({String key, String value})> config,
  ) => _signature(
    io,
    config,
    nameKeys: const ['GIT_AUTHOR_NAME'],
    emailKeys: const ['GIT_AUTHOR_EMAIL'],
    dateKeys: const ['GIT_AUTHOR_DATE'],
    configName: 'user.name',
    configEmail: 'user.email',
  );

  GitCommitSignature _committer(
    AppletIo io,
    List<({String key, String value})> config,
  ) => _signature(
    io,
    config,
    nameKeys: const ['GIT_COMMITTER_NAME', 'GIT_AUTHOR_NAME'],
    emailKeys: const ['GIT_COMMITTER_EMAIL', 'GIT_AUTHOR_EMAIL'],
    dateKeys: const ['GIT_COMMITTER_DATE', 'GIT_AUTHOR_DATE'],
    configName: 'user.name',
    configEmail: 'user.email',
  );

  GitCommitSignature _signature(
    AppletIo io,
    List<({String key, String value})> config, {
    required List<String> nameKeys,
    required List<String> emailKeys,
    required List<String> dateKeys,
    required String configName,
    required String configEmail,
  }) {
    final name =
        _env(io.env, nameKeys) ??
        _configValue(config, configName) ??
        io.profile.user;
    final email =
        _env(io.env, emailKeys) ??
        _configValue(config, configEmail) ??
        '$name@${io.profile.hostname}';
    final rawDate = _env(io.env, dateKeys);
    if (rawDate != null) {
      final parsed = parseGitDate(rawDate);
      if (parsed == null) {
        throw GitUsage('fatal: invalid date format: $rawDate\n', exitCode: 128);
      }
      return GitCommitSignature(
        name: name,
        email: email,
        timestampSeconds: parsed.seconds,
        timezoneOffset: parsed.zone,
      );
    }
    return GitCommitSignature.fromDateTime(
      name: name,
      email: email,
      timestamp: DateTime.now(),
    );
  }

  String? _env(Map<String, String> env, List<String> keys) {
    for (final key in keys) {
      final value = env[key];
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  String? _configValue(List<({String key, String value})> config, String key) {
    String? found;
    for (final pair in config) {
      if (pair.key == key) found = pair.value;
    }
    return found;
  }

  String _join(String cwd, String path) => path.startsWith('/')
      ? VfsPath.normalize(path)
      : VfsPath.normalize('$cwd/$path');

  bool _matches(String path, List<String> specs) {
    for (final spec in specs) {
      if (spec == '.' || spec == './') return true;
      if (path == spec || path.startsWith('$spec/')) return true;
    }
    return false;
  }

  Future<String> _abbrev(GitRepository repo, String revision) async {
    if (revision == 'HEAD') {
      final branch = _branchOf(
        (await repo.readReference('HEAD'))?.targetReferenceName,
      );
      return branch ?? 'HEAD';
    }
    if (revision.startsWith('refs/heads/')) {
      return _piece(revision, 'refs/heads/'.length, revision.length);
    }
    return revision;
  }

  /// Имя, которое git пишет в reflog при `switch --detach`.
  ///
  /// Ветка становится `refs/heads/<имя>`: список потом показывает
  /// `(HEAD detached at refs/heads/side)`, а не полный хеш.
  Future<String> _detachedLabel(GitRepository repo, String target) async {
    if (await repo.resolveReferenceObjectId('refs/heads/$target') != null) {
      return 'refs/heads/$target';
    }
    return target;
  }

  Future<({String action, String abbr})?> _sequencerHint(
    GitRepository repo,
  ) async {
    final state = await repo.readSequencer();
    if (state == null) return null;
    if (state.action != 'cherry-pick' && state.action != 'revert') return null;
    if (state.revisions.isEmpty) return null;
    return (action: state.action, abbr: _abbr(state.revisions.first));
  }

  String? _branchOf(String? reference) {
    if (reference == null || !reference.startsWith('refs/heads/')) return null;
    return _piece(reference, 'refs/heads/'.length, reference.length);
  }

  /// git печатает `Dropped refs/stash@{n} (<полный хеш>)` без точки.
  String _droppedLine(String revision, String hex) {
    final name = revision.startsWith('refs/') ? revision : 'refs/$revision';
    return 'Dropped $name ($hex)\n';
  }

  String _subject(String message) {
    final end = message.indexOf('\n');
    return end < 0 ? message : _piece(message, 0, end);
  }

  String _abbr(String hex, [int length = 7]) {
    if (length < 1) return _piece(hex, 0, 1);
    if (length >= hex.length) return hex;
    return _piece(hex, 0, length);
  }

  String _mode(int mode) => switch (mode) {
    GitIndexEntry.regularFileMode => '100644',
    GitIndexEntry.executableFileMode => '100755',
    GitIndexEntry.symbolicLinkMode => '120000',
    GitIndexEntry.gitLinkMode => '160000',
    _ => mode.toRadixString(8).padLeft(6, '0'),
  };

  String _fatalText(Object error) {
    if (error is StateError) return error.message;
    if (error is FormatException) return error.message;
    if (error is ArgumentError) {
      final message = error.message;
      return message == null ? '$error' : '$message';
    }
    return '$error';
  }

  String _gitDate(GitCommitSignature signature) {
    final zoned = RegExp(r'^([+-])(\d\d)(\d\d)$')
        .firstMatch(signature.timezoneOffset);
    var seconds = signature.timestampSeconds;
    if (zoned != null) {
      final sign = zoned.group(1) == '-' ? -1 : 1;
      final shift =
          int.parse(zoned.group(2)!) * 3600 + int.parse(zoned.group(3)!) * 60;
      seconds += sign * shift;
    }
    final date = DateTime.fromMillisecondsSinceEpoch(
      seconds * 1000,
      isUtc: true,
    );
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    final second = date.second.toString().padLeft(2, '0');
    return '${weekdays[date.weekday - 1]} ${months[date.month - 1]} '
        '${date.day} $hour:$minute:$second ${date.year} ${signature.timezoneOffset}';
  }
}
