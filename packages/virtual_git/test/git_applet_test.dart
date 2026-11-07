import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:virtual_git/virtual_git.dart';
import 'package:virtual_host/virtual_host.dart';

void main() {
  test('неизвестная подкоманда завершается с кодом 1', () async {
    final result = await _git('git nope');

    expect(result.exitCode, 1);
    expect(result.stderr, contains('is not a git command'));
  });

  test('init, commit и автор из окружения', () async {
    final result = await _git(
      'git init && printf "hello\\n" > README.md && git add README.md && '
      'git commit -m "first" && git log && git rev-parse HEAD',
      environment: const {
        'GIT_AUTHOR_NAME': 'Ada',
        'GIT_AUTHOR_EMAIL': 'ada@ex.test',
      },
    );

    expect(result.exitCode, 0, reason: result.stderr);
    expect(result.stdout, contains('Author: Ada'));
    expect(result.stdout, contains('first'));
  });

  test('GIT_HTTP_EXTRA_HEADER уходит в запрос и не пишется в config', () async {
    final http = _RecordingGitHttp();
    final result = await _git(
      'git init && git remote add origin http://git.test/repo.git && '
      'git fetch origin refs/heads/main:refs/remotes/origin/main',
      environment: const {
        'GIT_HTTP_EXTRA_HEADER': 'Authorization: Bearer secret-token',
      },
      http: http,
    );

    expect(http.headers, containsPair('Authorization', 'Bearer secret-token'));
    final config = utf8.decode(
      await result.fs.readBytes('/work/.git/config'),
      allowMalformed: true,
    );
    expect(config, isNot(contains('secret-token')));
    expect(config, isNot(contains('Authorization')));
  });

  test('which git и /bin/git видят команду', () async {
    final result = await _git('which git && test -x /bin/git && echo ok');

    expect(result.exitCode, 0, reason: result.stderr);
    expect(result.stdout, contains('/bin/git'));
    expect(result.stdout, contains('ok'));
  });

  test('backfill, maintenance и scalar разбирают опции git 2.53', () async {
    final r = await _git(
      'git init -b main && '
      'git backfill --min-batch-size=10 --sparse && '
      'git maintenance run --task=gc --auto --quiet && '
      'git scalar version',
    );
    expect(r.exitCode, 0, reason: r.stderr);
    expect(r.stdout, contains('scalar 0.1.0'));
  });

  test(
    'git am: --whitespace=error отклоняет патч с trailing whitespace',
    () async {
      final r = await _git(
        'git init -b main && '
        'printf "base\\n" > a.txt && git add a.txt && git commit -m first && '
        r'{ printf "%s\n" '
        r'"From dev@test Mon Jan 1 00:00:00 2024" "" "Subject: patch" "" '
        r'"diff --git a/a.txt b/a.txt" "--- a/a.txt" "+++ b/a.txt" '
        r'"@@ -1 +1 @@" "-base" "+patched "; } > p.mbox && '
        'git am --whitespace=error p.mbox',
      );
      expect(r.exitCode, 128);
      expect(r.stderr, contains('trailing whitespace'));
    },
  );

  test('git gc отвергает флаги и лишний аргумент', () async {
    final quiet = await _git('git init -b main && git gc --quiet');
    expect(quiet.exitCode, 129);
    expect(quiet.stderr, contains("error: unknown option `quiet'"));

    final extra = await _git('git init -b main && git gc nope');
    expect(extra.exitCode, 129);
    expect(extra.stderr, contains('usage: git gc'));

    final plain = await _git(
      'git init -b main && printf "a\\n" > a.txt && git add a.txt && '
      'git commit -m first && git gc',
    );
    expect(plain.exitCode, 0, reason: plain.stderr);
  });

  test('git am: хуки и чужая кодировка не проходят молча', () async {
    const setup =
        'git init -b main && printf "base\\n" > a.txt && git add a.txt && '
        'git commit -m first && ';
    const patch =
        '"diff --git a/a.txt b/a.txt" "--- a/a.txt" "+++ b/a.txt" '
        '"@@ -1 +1 @@" "-base" "+patched"';

    final hooks = await _git(
      '$setup'
      '{ printf "%s\\n" '
      '"From dev@test Mon Jan 1 00:00:00 2024" "" "Subject: patch" "" '
      '$patch; } > p.mbox ; '
      'git am --no-verify p.mbox ; git log --oneline -1',
    );
    expect(hooks.stderr, contains('applypatch hooks'));
    expect(hooks.stdout.trim(), endsWith('first'));

    final verify = await _git(
      '$setup'
      '{ printf "%s\\n" '
      '"From dev@test Mon Jan 1 00:00:00 2024" "" "Subject: patch" "" '
      '$patch; } > p.mbox ; '
      'git am --verify p.mbox ; git log --oneline -1',
    );
    expect(verify.stderr, contains('applypatch hooks'));
    expect(verify.stdout.trim(), endsWith('first'));

    final charset = await _git(
      '$setup'
      '{ printf "%s\\n" '
      '"From dev@test Mon Jan 1 00:00:00 2024" '
      '"Content-Type: text/plain; charset=ISO-8859-1" '
      '"Subject: patch" "" '
      '$patch; } > p.mbox ; '
      'git am --utf8 p.mbox ; git log --oneline -1',
    );
    expect(charset.stderr, contains('cannot convert from ISO-8859-1'));
    expect(charset.stdout.trim(), endsWith('first'));

    final utf8Mail = await _git(
      '$setup'
      '{ printf "%s\\n" '
      '"From dev@test Mon Jan 1 00:00:00 2024" '
      '"Content-Type: text/plain; charset=UTF-8" '
      '"Subject: patch" "" '
      '$patch; } > p.mbox && '
      'git am --utf8 p.mbox && git log --oneline -1',
    );
    expect(utf8Mail.exitCode, 0, reason: utf8Mail.stderr);
    expect(utf8Mail.stdout.trim(), endsWith('patch'));
  });

  test('git am: неверное значение --whitespace даёт fatal', () async {
    final r = await _git(
      'git init -b main && '
      'printf "x\\n" > a.txt && git add a.txt && git commit -m first && '
      r'{ printf "%s\n" '
      r'"From dev@test Mon Jan 1 00:00:00 2024" "" "Subject: p" "" '
      r'"diff --git a/a.txt b/a.txt" "--- a/a.txt" "+++ b/a.txt" '
      r'"@@ -1 +1 @@" "-x" "+y"; } > p.mbox && '
      'git am --whitespace=nope p.mbox',
    );
    expect(r.exitCode, 128);
    expect(r.stderr, contains('Invalid whitespace'));
  });
}

final class _Outcome {
  const _Outcome(this.stdout, this.stderr, this.exitCode, this.fs);

  final String stdout;
  final String stderr;
  final int exitCode;
  final VirtualFs fs;
}

Future<_Outcome> _git(
  String script, {
  Map<String, String> environment = const {},
  GitHttp? http,
}) async {
  const profile = VirtualProfile(home: '/work', hostname: 'box');
  final withEnv = VirtualProfile(
    home: profile.home,
    hostname: profile.hostname,
    environment: environment,
  );
  final names = {...standardApplets.names, 'git'};
  final fs = VirtualFs(
    InMemoryVfsStore(),
    snapshot: OsSnapshot(profile: withEnv, names: names),
  );
  await fs.mkdir('/work', recursive: true);
  final applets = AppletRegistry([
    for (final name in standardApplets.names) standardApplets.lookup(name)!,
    GitApplet(http: http),
  ]);
  final interpreter = ShellInterpreter(
    fs: fs,
    applets: applets,
    profile: withEnv,
  );
  final events = await interpreter.run(script, cwd: '/work').toList();
  final stdout = BytesBuilder();
  final stderr = BytesBuilder();
  var exitCode = -1;
  for (final event in events) {
    switch (event) {
      case ShellStdout(:final bytes):
        stdout.add(bytes);
      case ShellStderr(:final bytes):
        stderr.add(bytes);
      case ShellDone(exitCode: final code):
        exitCode = code ?? -1;
    }
  }
  return _Outcome(
    utf8.decode(stdout.toBytes()),
    utf8.decode(stderr.toBytes()),
    exitCode,
    fs,
  );
}

final class _RecordingGitHttp implements GitHttp {
  Map<String, String> headers = const {};

  @override
  Future<GitHttpResponse> send({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    this.headers = headers;
    return const GitHttpResponse(statusCode: HttpStatus.notFound, body: []);
  }
}
