/// Типизированные операции над Host. Через них выражаются все файловые и служебные действия инструментов.
///
/// Реальный Host компилирует операцию в команду ([ShellAdapter.compile]), виртуальный выполняет её напрямую.
/// Инструменты не знают, какой shell стоит за Host: они передают операцию и разбирают результат.
/// Новая операция — это новый класс в этой иерархии. Исчерпывающий `switch` в каждом рантайме
/// не даст её пропустить.
sealed class HostOp {
  const HostOp();

  /// Короткая подпись для журнала и шага в чате. Это не скрипт и не команда.
  String get label;
}

/// Сведения о Host: ОС, пользователь, каталог, shell.
final class HostInfoOp extends HostOp {
  const HostInfoOp();

  @override
  String get label => 'host info';
}

/// Содержимое каталога.
final class ListDirOp extends HostOp {
  const ListDirOp(this.path);

  final String path;

  @override
  String get label => 'list $path';
}

/// Чтение текстового файла по строкам с курсором. Формат вывода задаёт [ReadFileOutput] (см. `read_file_output.dart`).
final class ReadFileOp extends HostOp {
  const ReadFileOp(
    this.path, {
    required this.offset,
    required this.byteOffset,
    required this.limit,
    required this.chunkBytes,
    required this.lineBytes,
  });

  final String path;

  /// Первая строка, с 1.
  final int offset;

  /// Байтовое смещение внутри строки [offset] (для продолжения разрезанной строки).
  final int byteOffset;

  /// Максимум строк за вызов.
  final int limit;

  /// Максимум байтов за вызов.
  final int chunkBytes;

  /// Максимум байтов одной строки; длиннее — режется и продолжается через [byteOffset].
  final int lineBytes;

  @override
  String get label => 'read $path';
}

/// Весь файл как есть. При ошибке вывод пуст, а код выхода сообщает о ней.
final class ReadRawOp extends HostOp {
  const ReadRawOp(this.path);

  final String path;

  @override
  String get label => 'cat $path';
}

/// Первые [maxBytes] байт файла.
final class ReadHeadOp extends HostOp {
  const ReadHeadOp(this.path, {required this.maxBytes});

  final String path;
  final int maxBytes;

  @override
  String get label => 'head $path';
}

/// Тела `SKILL.md` из подкаталогов переданных каталогов. Формат вывода: `@@@ <путь>` и затем текст.
final class ScanSkillsOp extends HostOp {
  const ScanSkillsOp(this.dirs, {required this.maxBytes});

  final List<String> dirs;
  final int maxBytes;

  @override
  String get label => 'scan skills';
}

/// Поиск регулярного выражения по содержимому каталога.
final class GrepOp extends HostOp {
  const GrepOp(this.pattern, this.path);

  final String pattern;
  final String path;

  @override
  String get label => 'grep $pattern $path';
}

/// Где лежит исполняемый файл. Нет — ненулевой код выхода.
final class WhichOp extends HostOp {
  const WhichOp(this.name);

  final String name;

  @override
  String get label => 'which $name';
}

/// Тип пути и mtime. Вывод разбирает [StatResult]. Пути нет — ненулевой код выхода.
final class StatOp extends HostOp {
  const StatOp(this.path);

  final String path;

  @override
  String get label => 'stat $path';
}

/// Канонический путь: раскрывает `~`, симлинки и `..` силами Host.
/// Нужен ключу проекта, чтобы `~/repo` и `/home/user/repo` были одной папкой.
final class RealpathOp extends HostOp {
  const RealpathOp(this.path);

  final String path;

  @override
  String get label => 'realpath $path';
}

/// Канонический путь файла для графа инструментов.
///
/// В отличие от [RealpathOp], последний компонент и ещё не созданные каталоги
/// могут отсутствовать: запись делает `mkdir -p`, а ключ конфликта нужен раньше.
/// Существующие симлинки раскрываются, `~` тоже. Ошибка — ненулевой код:
/// планировщик тогда считает путь всем хостом, а не чужим файлом.
final class CanonicalPathOp extends HostOp {
  const CanonicalPathOp(this.path);

  final String path;

  @override
  String get label => 'canonical $path';
}

/// Первый существующий файл из списка путей, в порядке списка. Вывод — путь найденного файла.
final class FirstFileOp extends HostOp {
  const FirstFileOp(this.paths);

  final List<String> paths;

  @override
  String get label => 'find file';
}

/// Атомарная запись файла. Содержимое передаётся на stdin.
///
/// [expectedMtime] — значение [StatResult.mtime], снятое до чтения файла. Если файл изменился,
/// запись не выполняется. null означает, что файла быть не должно. Старая версия копируется в [backupPath].
final class WriteFileOp extends HostOp {
  const WriteFileOp(this.path, {required this.backupPath, this.expectedMtime});

  final String path;
  final String backupPath;
  final String? expectedMtime;

  @override
  String get label => 'write $path';
}

/// Разбор вывода [StatOp]: `file <mtime>` или `dir <mtime>`.
final class StatResult {
  const StatResult({required this.isDir, required this.mtime});

  /// Разбирает вывод [StatOp]. Возвращает null, если формат не совпал.
  static StatResult? parse(String text) {
    final parts = text.trim().split(' ');
    if (parts.length != 2 || parts.last.isEmpty) return null;
    final kind = parts.first;
    if (kind != 'dir' && kind != 'file') return null;
    return StatResult(isDir: kind == 'dir', mtime: parts.last);
  }

  final bool isDir;

  /// mtime в тех же единицах, что и `stat -c %Y` (секунды) на POSIX и тики на Windows.
  /// Строка сравнивается без преобразования: её же использует защита [WriteFileOp].
  final String mtime;
}
