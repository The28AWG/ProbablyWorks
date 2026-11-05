import 'dart:convert';

import 'package:test/test.dart';
import 'package:virtual_host/src/in_memory_vfs_store.dart';
import 'package:virtual_host/src/shell/applets/standard_applets.dart';
import 'package:virtual_host/src/shell/shell_interpreter.dart';
import 'package:virtual_host/src/shell/shell_io.dart';
import 'package:virtual_host/src/shell/shell_state.dart';
import 'package:virtual_host/src/virtual_fs.dart';
import 'package:virtual_host/src/virtual_profile.dart';

void main() {
  test('переменная профиля видна printenv и не затирает PATH', () async {
    const profile = VirtualProfile(
      home: '/work',
      environment: {'TOKEN': 'secret-value', 'PATH': '/evil'},
    );
    final fs = VirtualFs(InMemoryVfsStore());
    await fs.mkdir('/work', recursive: true);
    final interpreter = ShellInterpreter(
      fs: fs,
      applets: standardApplets,
      profile: profile,
    );
    final events = await interpreter
        .run('printenv TOKEN; printenv PATH', cwd: '/work')
        .toList();
    final stdout = StringBuffer();
    var code = -1;
    for (final event in events) {
      switch (event) {
        case ShellStdout(:final bytes):
          stdout.write(utf8.decode(bytes));
        case ShellStderr():
          break;
        case ShellDone(:final exitCode):
          code = exitCode ?? -1;
      }
    }

    expect(code, 0);
    expect(stdout.toString(), 'secret-value\n/usr/local/bin:/usr/bin:/bin\n');
  });

  test('недопустимое имя переменной профиля — ошибка', () {
    expect(
      () => ShellState.initial(
        const VirtualProfile(environment: {'1TOKEN': 'x'}),
        '/',
      ),
      throwsArgumentError,
    );
  });
}
