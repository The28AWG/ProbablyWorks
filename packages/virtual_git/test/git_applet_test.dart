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
