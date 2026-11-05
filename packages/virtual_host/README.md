# virtual_host

Ядро виртуального хоста: файловая система, ограниченная оболочка и апплеты.
Пакет не знает про приложение, базу и политику запуска. Это чистый Dart, без Flutter.

Публичный вход — `package:virtual_host/virtual_host.dart`.

## Апплет

```dart
import 'package:virtual_host/virtual_host.dart';

final class Hello implements Applet {
  const Hello();

  @override
  String get name => 'hello';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    io.stdout.writeText('hello\n');
    return 0;
  }
}
```

Имя команды уникально: повтор при сборке `AppletRegistry` бросает `StateError`.
Аргументы в стиле getopt разбирает `parseArgs`. Файлы читаются и пишутся через `io.fs`
(`VirtualFs`): ошибки POSIX приходят как `VfsException`.

Апплету доступны stdin, stdout, stderr, текущий каталог, переменные, профиль и реестр.
Сети, процессов и секретов у него нет.

## Проверка без приложения

`ShellInterpreter` и `InMemoryVfsStore` выполняют скрипт так же, как хост в приложении:
пайпы, редиректы и код выхода. События — `ShellStdout`, `ShellStderr` и `ShellDone`.

```dart
final fs = VirtualFs(InMemoryVfsStore());
final interpreter = ShellInterpreter(
  fs: fs,
  applets: AppletRegistry([const Hello()]),
  profile: const VirtualProfile(),
);
final events = await interpreter.run('hello').toList();
```

Стандартный набор команд — `standardApplets`. Свой реестр можно собрать рядом с ним:
одинаковое имя в двух списках не сольётся молча, конструктор реестра упадёт.

## Команды

```bash
dart format lib test
dart analyze
dcm analyze lib test
dart test
```

`dart test` сравнивает часть апплетов с настоящим bash, поэтому bash должен быть в `PATH`.
