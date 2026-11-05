# virtual_git

Git поверх файловой системы виртуального хоста. Репозиторий, индекс и объекты
живут в `VirtualFs`. Сеть — только HTTP и HTTPS через `package:http`.
Пакет не знает про приложение, базу и `SecretStore`. Это чистый Dart, без Flutter.

В стандартный набор апплетов `virtual_host` git не входит. Его регистрирует
вызывающий код рядом со `standardApplets`.

Публичный вход — `package:virtual_git/virtual_git.dart`.

Поведение команд перенесено из [git_core](https://github.com/Atrac613/git_core)
(MIT, текст лицензии — `THIRD_PARTY_LICENSE`). Зависимостью пакет не подключается:
исходник импортирует `dart:io` и SSH.

## Апплет

```dart
import 'package:virtual_git/virtual_git.dart';
import 'package:virtual_host/virtual_host.dart';

final applets = AppletRegistry([
  for (final name in standardApplets.names) standardApplets.lookup(name)!,
  const GitApplet(),
]);
final fs = VirtualFs(
  InMemoryVfsStore(),
  snapshot: OsSnapshot(
    profile: const VirtualProfile(),
    names: applets.names,
  ),
);
final interpreter = ShellInterpreter(
  fs: fs,
  applets: applets,
  profile: const VirtualProfile(),
);
final events = await interpreter.run('git init', cwd: '/work').toList();
```

Имя `git` должно быть и в реестре, и в снимке `/bin`: иначе `which git` и
`test -x /bin/git` расходятся. Неизвестная подкоманда пишет в stderr и
завершается с кодом 1.

Подкоманды: `init`, `status`, `add`, `commit`, `log`, `diff`, `show`,
`rev-parse`, `ls-files`, `branch`, `tag`, `checkout`, `switch`, `restore`,
`reset`, `merge`, `stash`, `apply`, `remote`, `clone`, `fetch`, `pull`, `push`.

## Автор и заголовок

Апплет читает окружение оболочки, а не `.git/config`:

- `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`,
  `GIT_COMMITTER_EMAIL` — подпись коммита. Если их нет, имя и почта берутся
  из пользователя и хоста `VirtualProfile`.
- `GIT_HTTP_EXTRA_HEADER` — одна строка вида `Authorization: Bearer …` на
  `clone`, `fetch`, `pull` и `push`. В конфиг репозитория она не пишется.

Карту задаёт `VirtualProfile.environment`. Встроенные имена (`PATH`, `HOME`
и остальные) она не перезаписывает.

## Библиотека

`GitRepository` работает только после `bindGitIo`. Привязка общая на изолят:
перед вызовом её включают, после — снимают. Апплет делает это сам.

```dart
bindGitIo(fs, cwd: '/work');
try {
  final repository = GitRepository.workTree('/work/repo');
  await repository.status();
} finally {
  clearGitIo();
}
```

Свой транспорт подставляют вторым аргументом `GitApplet` или через `bindGitIo`.
Без него запросы идут в `PackageGitHttp`. Относительный remote без схемы — это
другой путь в той же `VirtualFs`, не каталог машины.

## Чего нет

- SSH, `ssh://`, `git@host` и `file://`.
- Запись на диск машины, процессы и сокеты. Сторож `test/guard_no_io_test.dart`
  пускает в `lib/` только `package:http`.
- Целый pack в виртуальной файловой системе. Пакет с сети разбирается в памяти
  и пишется loose-объектами. Объект или pack больше лимита файла — ошибка git,
  а не обрезка.
- Credential helper, который запускает процесс, и linked worktree с `gitdir`
  вне этой `VirtualFs`.

## Команды

```bash
dart format lib test
dart analyze
dcm analyze lib test
dart test
```
