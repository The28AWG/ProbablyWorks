import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:probably_works/host/host_op.dart';
import 'package:probably_works/host/shell_adapter.dart';
import 'package:probably_works/host/virtual/read_file_pager.dart';
import 'package:virtual_host/virtual_host.dart';

/// Итог операции: код выхода и два потока. Тот же контракт, что у команды на реальном Host.
final class VirtualOpResult {
  VirtualOpResult({
    required this.exitCode,
    Uint8List? stdout,
    Uint8List? stderr,
  }) : stdout = stdout ?? Uint8List(0),
       stderr = stderr ?? Uint8List(0);

  /// Успешный вывод с текстом [text].
  VirtualOpResult.text(String text)
    : this(exitCode: 0, stdout: utf8.encode(text));

  /// Ошибка: текст уходит в stderr с переводом строки, как у `echo ... >&2`.
  VirtualOpResult.fail(String message, {int code = 1})
    : this(exitCode: code, stderr: utf8.encode('$message\n'));

  final int exitCode;
  final Uint8List stdout;
  final Uint8List stderr;
}

/// Исполнитель типизированных операций [HostOp] поверх [VirtualFs].
///
/// Вывод повторяет то, что дала бы команда [ShellAdapter] на POSIX: инструменты разбирают его одинаково
/// на реальном и на виртуальном Host. Там, где реальная команда прячет stderr (`2>/dev/null`), здесь
/// stderr тоже пуст. Это сохраняет поведение, а не делает его «лучше».
final class VirtualOpExecutor {
  const VirtualOpExecutor(this._fs, this._profile, {this.commands = const {}});

  final VirtualFs _fs;
  final VirtualProfile _profile;

  /// Имена апплетов, которые видит `which`. Наполняет реестр апплетов (этап 5).
  final Set<String> commands;

  /// Выполняет операцию. [cwd] — каталог процесса (по умолчанию домашний). Ошибка ФС становится
  /// ненулевым кодом выхода и текстом в stderr, исключение наружу не уходит.
  Future<VirtualOpResult> execute(
    HostOp op, {
    String? cwd,
    Uint8List? stdin,
  }) async {
    final dir = VfsPath.normalize(cwd ?? _profile.home);
    try {
      return await switch (op) {
        HostInfoOp() => _hostInfo(dir),
        ListDirOp(:final path) => _listDir(path, dir),
        ReadFileOp(
          :final path,
          :final offset,
          :final byteOffset,
          :final limit,
          :final chunkBytes,
          :final lineBytes,
        ) =>
          _readFile(
            path,
            dir,
            offset: offset,
            byteOffset: byteOffset,
            limit: limit,
            chunkBytes: chunkBytes,
            lineBytes: lineBytes,
          ),
        ReadRawOp(:final path) => _readRaw(path, dir),
        ReadHeadOp(:final path, :final maxBytes) => _readHead(
          path,
          dir,
          maxBytes,
        ),
        ScanSkillsOp(:final dirs, :final maxBytes) => _scanSkills(
          dirs,
          dir,
          maxBytes,
        ),
        GrepOp(:final pattern, :final path) => _grep(pattern, path, dir),
        WhichOp(:final name) => _which(name),
        StatOp(:final path) => _stat(path, dir),
        DeleteFileOp(:final path) => _deleteFile(path, dir),
        MovePathOp(:final from, :final to, :final overwrite) => _movePath(
          from,
          to,
          dir,
          overwrite: overwrite,
        ),
        CopyPathOp(:final from, :final to, :final overwrite) => _copyPath(
          from,
          to,
          dir,
          overwrite: overwrite,
        ),
        MakeDirOp(:final path) => _makeDir(path, dir),
        GlobOp(:final pattern, :final root) => _glob(pattern, root, dir),
        RealpathOp(:final path) => _realpath(path, dir),
        CanonicalPathOp(:final path) => _canonical(path, dir),
        FirstFileOp(:final paths) => _firstFile(paths, dir),
        WriteFileOp(:final path, :final backupPath, :final expectedMtime) =>
          _writeFile(
            path,
            dir,
            backupPath: backupPath,
            expectedMtime: expectedMtime,
            stdin: stdin ?? Uint8List(0),
          ),
      };
    } on VfsException catch (e) {
      return VirtualOpResult.fail(e.message);
    }
  }

  /// `~` и `~/...` раскрываются в домашний каталог, как это делает shell.
  String _expand(String path) => (path == '~' || path.startsWith('~/'))
      ? path.replaceFirst('~', _profile.home)
      : path;

  // ---- Сведения о Host ----

  /// Сводка для модели и диагностики. Строка `applets=` есть только когда реестр не пуст: модель видит, какие
  /// утилиты доступны, и не перебирает их наугад. Список отсортирован, чтобы вывод был детерминированным.
  /// Карта [VirtualProfile.environment] сюда не входит: в ней могут быть секреты.
  /// Ниже — границы виртуальной оболочки: у неё нет терминала, состояние не переживает `run_command`,
  /// и часть синтаксиса bash отвергается до запуска. Подробности — в `docs/shell.md`.
  VirtualOpResult _hostInfo(String dir) {
    final applets = commands.toList()..sort();
    return VirtualOpResult.text(
      '${_profile.unameLine}\n'
      'user=${_profile.user}\n'
      'cwd=$dir\n'
      'shell=${_profile.shell}\n'
      'pty=no\n'
      'state=does not survive run_command\n'
      'shell_subset=bash functions, if/while/for/select/case, [[ ]], (( )), arrays, traps, set -e/-u/-o pipefail\n'
      'unsupported=job control, shopt, exec, coproc, extglob, background\n'
      'divergences=\$\$ PPID RANDOM differ from a real process; declare -f is normalized; [[ =~ ]] is a translated ERE; eval nesting is limited\n'
      'filesystem=ls /bin lists commands; /etc and /proc are readable; /tmp is wiped when the app exits\n'
      '${applets.isEmpty ? '' : 'applets=${applets.join(' ')}\n'}',
    );
  }

  // ---- Каталоги и метаданные ----

  /// Вывод `ls -la`: `total`, строки `.` и `..`, затем записи по имени. Формат колонок повторяет GNU ls
  /// в локали C; владелец и группа — пользователь профиля.
  Future<VirtualOpResult> _listDir(String path, String dir) async {
    final target = _expand(path);
    final node = await _fs.stat(target, cwd: dir);
    if (node == null) {
      return VirtualOpResult.fail(
        "ls: cannot access '$path': No such file or directory",
        code: 2,
      );
    }
    final now = _fs.now();
    if (node.kind != VfsNodeKind.dir) {
      final width = VfsListing.sizeOf(node).toString().length;
      return VirtualOpResult.text('${_longLine(node, path, width, now)}\n');
    }
    final children = await _fs.list(target, cwd: dir);
    final all = [node, ...children];
    final width = all
        .map((n) => VfsListing.sizeOf(n).toString().length)
        .reduce(max);
    final total =
        all.fold<int>(0, (sum, n) => sum + VfsListing.blocksOf(n)) +
        VfsListing.blocksOf(node);
    final rows = [
      _longLine(node, '.', width, now),
      _longLine(node, '..', width, now),
      for (final child in children) _longLine(child, child.name, width, now),
    ];
    return VirtualOpResult.text('total $total\n${rows.join('\n')}\n');
  }

  String _longLine(VfsNode node, String name, int width, int now) =>
      VfsListing.longLine(
        node,
        name,
        width: width,
        now: now,
        owner: vfsAccountName(node.uid, _profile.user),
      );

  /// `stat`-подобный вывод: `dir <mtime>` или `file <mtime>`. Пути нет — код 1 без вывода.
  Future<VirtualOpResult> _stat(String path, String dir) async {
    final node = await _fs.stat(_expand(path), cwd: dir);
    if (node == null) return VirtualOpResult(exitCode: 1);
    final kind = node.kind == VfsNodeKind.dir ? 'dir' : 'file';
    return VirtualOpResult.text('$kind ${node.mtime}\n');
  }

  /// Удаление файла или симлинка; каталог без рекурсии отвергается самой ФС.
  Future<VirtualOpResult> _deleteFile(String path, String dir) async {
    await _fs.remove(_expand(path), cwd: dir);
    return VirtualOpResult(exitCode: 0);
  }

  /// Перенос пути. Проверка существующей цели повторяет защиту `mv -n`.
  Future<VirtualOpResult> _movePath(
    String from,
    String to,
    String dir, {
    required bool overwrite,
  }) async {
    final source = await _fs.stat(_expand(from), cwd: dir, followLast: false);
    if (source == null) {
      return VirtualOpResult.fail('No such file or directory');
    }
    final destination = await _fs.stat(_expand(to), cwd: dir);
    if (destination?.kind == VfsNodeKind.dir) {
      return VirtualOpResult.fail('target is a directory');
    }
    if (destination != null && !overwrite) {
      return VirtualOpResult.fail('target exists');
    }
    await _fs.rename(_expand(from), _expand(to), cwd: dir);
    return VirtualOpResult(exitCode: 0);
  }

  /// Копирование обычного файла. Каталоги здесь не поддерживаются.
  Future<VirtualOpResult> _copyPath(
    String from,
    String to,
    String dir, {
    required bool overwrite,
  }) async {
    final source = await _fs.stat(_expand(from), cwd: dir);
    if (source?.kind != VfsNodeKind.file || !_readable(source!)) {
      return VirtualOpResult.fail('not a readable regular file');
    }
    final destination = await _fs.stat(_expand(to), cwd: dir);
    if (destination?.kind == VfsNodeKind.dir) {
      return VirtualOpResult.fail('target is a directory');
    }
    if (destination != null && !overwrite) {
      return VirtualOpResult.fail('target exists');
    }
    await _fs.copy(_expand(from), _expand(to), cwd: dir);
    return VirtualOpResult(exitCode: 0);
  }

  /// Создание каталога и недостающих родителей.
  Future<VirtualOpResult> _makeDir(String path, String dir) async {
    await _fs.mkdir(_expand(path), cwd: dir, recursive: true);
    return VirtualOpResult(exitCode: 0);
  }

  /// Поиск файлов по имени под каталогом. Это не поиск по содержимому.
  Future<VirtualOpResult> _glob(String pattern, String root, String dir) async {
    final matcher = _globRegExp(pattern);
    final matches = <String>[];
    for (final node in await _fs.walk(_expand(root), cwd: dir)) {
      if (node.kind != VfsNodeKind.file) continue;
      final name = node.path.split('/').last;
      if (matcher.hasMatch(name)) matches.add(node.path);
    }
    matches.sort();
    return VirtualOpResult.text(
      matches.isEmpty ? '' : '${matches.join('\n')}\n',
    );
  }

  /// Glob в стиле shell: `*` и `?`, остальные символы буквальные.
  static RegExp _globRegExp(String pattern) {
    final buffer = StringBuffer('^');
    for (final rune in pattern.runes) {
      switch (String.fromCharCode(rune)) {
        case '*':
          buffer.write('.*');
        case '?':
          buffer.write('.');
        default:
          buffer.write(RegExp.escape(String.fromCharCode(rune)));
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString());
  }

  /// Канонический путь виртуальной ФС. Как `realpath`: последний компонент может отсутствовать,
  /// поэтому путь ещё не созданного проекта тоже получает стабильный ключ.
  Future<VirtualOpResult> _realpath(String path, String dir) async {
    final canonical = await _fs.realpath(_expand(path), cwd: dir);
    return VirtualOpResult.text('$canonical\n');
  }

  /// Тот же путь, что [_realpath], для ключа конфликта. Недостающие каталоги
  /// не ошибка: `mkdir -p` создаст их, а симлинки уже существующих компонентов раскрыты.
  Future<VirtualOpResult> _canonical(String path, String dir) =>
      _realpath(path, dir);

  /// Первый существующий файл из списка, в порядке списка. Печатает путь как его раскрыл бы shell.
  Future<VirtualOpResult> _firstFile(List<String> paths, String dir) async {
    for (final path in paths) {
      final expanded = _expand(path);
      final node = await _fs.stat(expanded, cwd: dir);
      if (node?.kind == VfsNodeKind.file) {
        return VirtualOpResult.text('$expanded\n');
      }
    }
    return VirtualOpResult(exitCode: 1);
  }

  /// Как `command -v`: путь апплета из реестра, иначе код 1 без вывода.
  VirtualOpResult _which(String name) => commands.contains(name)
      ? VirtualOpResult.text('/bin/$name\n')
      : VirtualOpResult(exitCode: 1);

  // ---- Чтение файлов ----

  /// Агент читает файл, если его класс доступа содержит бит чтения. Root-привилегий у агента нет.
  static bool _readable(VfsNode node) => vfsAllows(node, VfsAccess.read);

  static bool _writable(VfsNode node) => vfsAllows(node, VfsAccess.write);

  /// Постраничный вывод. Ошибки и бинарные файлы — код 1 и текст в stderr, как у `ReadFileOp`.
  Future<VirtualOpResult> _readFile(
    String path,
    String dir, {
    required int offset,
    required int byteOffset,
    required int limit,
    required int chunkBytes,
    required int lineBytes,
  }) async {
    final target = _expand(path);
    final node = await _fs.stat(target, cwd: dir);
    if (node == null || node.kind != VfsNodeKind.file || !_readable(node)) {
      return VirtualOpResult.fail(ShellAdapter.readFileNotReadableMessage);
    }
    final data = await _fs.readBytes(target, cwd: dir);
    if (data.contains(0)) {
      return VirtualOpResult.fail(ShellAdapter.readFileBinaryMessage);
    }
    return VirtualOpResult(
      exitCode: 0,
      stdout: ReadFilePager.page(
        data,
        offset: offset,
        byteOffset: byteOffset,
        limit: limit,
        chunkBytes: chunkBytes,
        lineBytes: lineBytes,
      ),
    );
  }

  /// Весь файл как есть. Ошибка чтения молча даёт код 1: так работает `cat ... 2>/dev/null`.
  Future<VirtualOpResult> _readRaw(String path, String dir) async {
    final node = await _fs.stat(_expand(path), cwd: dir);
    if (node == null || node.kind != VfsNodeKind.file || !_readable(node)) {
      return VirtualOpResult(exitCode: 1);
    }
    return VirtualOpResult(
      exitCode: 0,
      stdout: await _fs.readBytes(_expand(path), cwd: dir),
    );
  }

  /// Первые [maxBytes] байт, как `head -c`. Сообщения об ошибках — как у GNU head.
  Future<VirtualOpResult> _readHead(
    String path,
    String dir,
    int maxBytes,
  ) async {
    final target = _expand(path);
    final node = await _fs.stat(target, cwd: dir);
    if (node == null) {
      return VirtualOpResult.fail(
        "head: cannot open '$path' for reading: No such file or directory",
      );
    }
    if (node.kind == VfsNodeKind.dir) {
      return VirtualOpResult.fail(
        "head: error reading '$path': Is a directory",
      );
    }
    if (!_readable(node)) {
      return VirtualOpResult.fail(
        "head: cannot open '$path' for reading: Permission denied",
      );
    }
    final data = await _fs.readBytes(target, cwd: dir);
    return VirtualOpResult(
      exitCode: 0,
      stdout: data.sublist(0, min(maxBytes, data.length)),
    );
  }

  /// Тела `SKILL.md` из подкаталогов: для каждого `dir/*/SKILL.md` печатает `@@@ путь` и текст.
  /// Скрытые каталоги пропускаются, как и шаблон `*`. Код выхода — у последнего проверенного кандидата.
  Future<VirtualOpResult> _scanSkills(
    List<String> dirs,
    String dir,
    int maxBytes,
  ) async {
    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    for (final root in dirs) {
      final base = _expand(root);
      final baseNode = await _fs.stat(base, cwd: dir);
      final children = baseNode?.kind == VfsNodeKind.dir
          ? (await _fs.list(
              base,
              cwd: dir,
            )).where((c) => !c.name.startsWith('.'))
          : const <VfsNode>[];
      // Шаблон раскрывается только в существующие пути: запись без SKILL.md кандидатом не становится.
      // Нет ни одного кандидата — шаблон остаётся буквальным, и его проверка `-f` даёт код 1.
      final candidates = <(String, VfsNode)>[];
      for (final child in children) {
        final skill = '$base/${child.name}/SKILL.md';
        final node = await _fs.stat(skill, cwd: dir);
        if (node != null) {
          candidates.add((skill, node));
        }
      }
      for (final (skill, node) in candidates) {
        if (node.kind != VfsNodeKind.file) continue;
        out.add(utf8.encode('@@@ $skill\n'));
        if (_readable(node)) {
          final data = await _fs.readBytes(skill, cwd: dir);
          out
            ..add(data.sublist(0, min(maxBytes, data.length)))
            ..addByte(10);
        } else {
          err.add(
            utf8.encode(
              "head: cannot open '$skill' for reading: Permission denied\n",
            ),
          );
        }
      }
    }
    // Скан — это обход списка каталогов, а не проверка последнего шаблона:
    // отсутствие одной папки не делает успешный обход неуспешным.
    return VirtualOpResult(
      exitCode: 0,
      stdout: out.takeBytes(),
      stderr: err.takeBytes(),
    );
  }

  // ---- Поиск ----

  /// Лимиты `grep` в ShellAdapter: до 200 совпадений на файл, до 300 строк в ответе.
  static const _maxMatchesPerFile = 200;
  static const _maxOutputLines = 300;
  static const _moreMatchesMessage =
      '[more matches not shown: narrow the pattern or path]';

  /// Поиск по регулярному выражению BRE. Пропускает бинарные файлы и каталог `.git`, симлинки внутри
  /// каталога не разворачиваются (как `grep -r`). Одиночный файл печатается без имени, каталог — с именем.
  ///
  /// Ошибки grep в реальной команде уходят в `2>/dev/null`, поэтому здесь они тоже дают пустой вывод
  /// с кодом 0: это поведение конвейера `grep | awk`, а не ошибка исполнителя.
  Future<VirtualOpResult> _grep(String pattern, String path, String dir) async {
    final target = _expand(path);
    final root = await _fs.stat(target, cwd: dir);
    if (root == null) {
      return VirtualOpResult.fail('no such file or directory', code: 1);
    }
    final RegExp regex;
    try {
      regex = PosixRegex.fromBre(pattern);
    } on FormatException {
      return VirtualOpResult(exitCode: 0);
    }

    // stat отдаёт канонический путь (симлинки раскрыты), поэтому префикс вычисляется от него.
    final isDir = root.kind == VfsNodeKind.dir;
    final files = <VfsNode>[];
    if (isDir) {
      final rootPrefix = root.path == VfsPath.root ? '/' : '${root.path}/';
      for (final node in await _fs.walk(target, cwd: dir)) {
        if (node.kind != VfsNodeKind.file) continue;
        final relative = node.path.replaceFirst(rootPrefix, '');
        if (relative.split('/').contains('.git')) continue;
        files.add(node);
      }
    } else {
      files.add(root);
    }

    final lines = <String>[];
    for (final file in files) {
      // Нечитаемый файл grep пропускает молча: его ошибка уходит в 2>/dev/null.
      if (!_readable(file)) continue;
      final data = await _fs.readBytes(file.path);
      if (data.contains(0)) continue;
      var matches = 0;
      final text = utf8.decode(data, allowMalformed: true);
      final rows = _splitLines(text);
      for (var i = 0; i < rows.length && matches < _maxMatchesPerFile; i++) {
        if (!regex.hasMatch(rows[i])) continue;
        matches++;
        lines.add(
          isDir ? '${file.path}:${i + 1}:${rows[i]}' : '${i + 1}:${rows[i]}',
        );
      }
    }

    final shown = lines.length > _maxOutputLines
        ? [...lines.take(_maxOutputLines), _moreMatchesMessage]
        : lines;
    return VirtualOpResult.text(shown.map((line) => '$line\n').join());
  }

  /// Строки текста как записи awk: завершающий перевод строки не даёт пустой последней строки.
  static List<String> _splitLines(String text) {
    if (text.isEmpty) return const [];
    final parts = text.split('\n');
    if (text.endsWith('\n')) parts.removeLast();
    return parts;
  }

  // ---- Запись ----

  /// Атомарная запись с защитами `ShellAdapter.writeFile`: проверка mtime до и после backup, бэкап
  /// старой версии, запрет записи в файл без права `w`. Каталоги цели создаются, как `mkdir -p`.
  Future<VirtualOpResult> _writeFile(
    String path,
    String dir, {
    required String backupPath,
    required String? expectedMtime,
    required Uint8List stdin,
  }) async {
    final String resolved;
    try {
      resolved = await _fs.realpath(_expand(path), cwd: dir);
    } on VfsException {
      return _writeFailure('cannot resolve the symbolic link');
    }
    try {
      await _fs.mkdir(VfsPath.parent(resolved), recursive: true);
    } on VfsException {
      return _writeFailure('cannot create the directory');
    }

    final node = await _fs.stat(resolved);
    if (expectedMtime == null) {
      if (node != null) return _writeFailure('file appeared after it was read');
    } else if (node?.kind != VfsNodeKind.file ||
        '${node!.mtime}' != expectedMtime) {
      return _writeFailure('file changed after it was read');
    }

    if (node != null) {
      if (!_writable(node)) return _writeFailure('file is not writable');
      try {
        await _fs.copy(resolved, _expand(backupPath));
      } on VfsException {
        return _writeFailure('backup failed');
      }
    }

    try {
      await _fs.writeBytes(resolved, stdin);
    } on VfsException {
      return _writeFailure(
        'cannot create the temporary file (the directory is not writable or the disk is full)',
      );
    }
    return VirtualOpResult(exitCode: 0);
  }

  /// Текст ошибки записи совпадает с `fail` в скрипте POSIX: сообщение и «nothing was written».
  static VirtualOpResult _writeFailure(String reason) =>
      VirtualOpResult.fail('$reason; nothing was written');
}
