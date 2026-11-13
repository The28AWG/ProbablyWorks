import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/policy/sensitive_paths.dart';

void main() {
  SensitivePaths local({String home = '/home/alice'}) =>
      SensitivePaths(home: home, windows: false, remote: false);

  SensitivePaths remote({String home = '/home/alice'}) =>
      SensitivePaths(home: home, windows: false, remote: true);

  test('detects SSH keys and cloud credentials in the home directory', () {
    final paths = local();

    expect(paths.sensitiveReason('~/.ssh/id_rsa'), isNotNull);
    expect(paths.sensitiveReason('~/.aws/credentials'), isNotNull);
    expect(
      paths.sensitiveReason(
        '~/.config/gcloud/application_default_credentials.json',
      ),
      isNotNull,
    );
    expect(paths.sensitiveReason('~/.kube/config'), isNotNull);
    expect(paths.sensitiveReason('/home/alice/.ssh/config'), isNotNull);
    expect(paths.sensitiveReason('/home/bob/.aws/credentials'), isNotNull);
    expect(paths.sensitiveReason('/etc/shadow'), isNotNull);
  });

  test('detects token files and environment files by name', () {
    final paths = local();

    expect(paths.sensitiveReason('~/.git-credentials'), isNotNull);
    expect(paths.sensitiveReason('~/.npmrc'), isNotNull);
    expect(paths.sensitiveReason('/home/alice/project/.env'), isNotNull);
    expect(paths.sensitiveReason('/home/alice/project/.env.local'), isNotNull);
    expect(paths.sensitiveReason('/home/alice/project/src/main.dart'), isNull);
  });

  test(
    'recursive search asks when the root contains sensitive directories',
    () {
      final paths = local();

      expect(paths.sensitiveReason('~', recursive: true), isNotNull);
      expect(paths.sensitiveReason('~/project', recursive: true), isNull);
    },
  );

  test('workspace check expands a local home but not a remote one', () {
    expect(
      local().isInsideWorkspace(
        '/home/alice/project/src/main.dart',
        '~/project',
      ),
      isTrue,
    );
    expect(
      local().isInsideWorkspace('~/project/src/main.dart', '~/project'),
      isTrue,
    );
    expect(local().isInsideWorkspace('/etc/os-release', '~/project'), isFalse);

    expect(
      remote().isInsideWorkspace('~/project/src/main.dart', '~/project'),
      isTrue,
    );
    expect(
      remote().isInsideWorkspace(
        '/home/bob/project/src/main.dart',
        '~/project',
      ),
      isFalse,
    );
  });

  test('detects Windows credential directories', () {
    final paths = SensitivePaths(
      home: r'C:\Users\Alice',
      windows: true,
      remote: false,
    );

    expect(
      paths.sensitiveReason(r'~\AppData\Roaming\gcloud\credentials.db'),
      isNotNull,
    );
    expect(
      paths.sensitiveReason(
        'C:/Users/Alice/AppData/Local/Microsoft/Credentials/cred',
      ),
      isNotNull,
    );
    expect(paths.sensitiveReason(r'C:\Users\Alice\project\main.dart'), isNull);
  });
}
