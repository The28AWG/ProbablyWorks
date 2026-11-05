import 'dart:collection';

import 'package:virtual_host/src/shell/shell_arithmetic.dart';
import 'package:virtual_host/src/shell/shell_ast.dart';
import 'package:virtual_host/src/shell/shell_errors.dart';
import 'package:virtual_host/src/virtual_profile.dart';

/// Элемент литерала массива для [ShellState.setArrayLiteral]: [subscript] — раскрытый ключ `[k]=` или null
/// для обычного элемента. Ключ индексированного массива вычисляется как арифметика, ассоциативного — текст.
typedef ArrayEntry = ({String? subscript, String value});

/// Атрибуты переменной, как у `declare`: `-r` (только чтение), `-x` (экспорт), `-i` (целое число),
/// `-u` и `-l` (перевод регистра при записи).
enum VarAttr { readonly, export, integer, upper, lower }

/// Переменная оболочки: скаляр, индексированный массив (`declare -a`) или ассоциативный массив
/// (`declare -A`). Переменная может быть объявлена без значения (`export X`, `declare -i X`): тогда
/// [value] и массивы равны null, а атрибуты сохраняются.
///
/// Объект изменяемый, поэтому дочерняя область копирует его перед записью (см. [ShellState.writable]).
final class ShellVar {
  ShellVar({this.value, this.indexed, this.assoc, Set<VarAttr>? attrs})
    : attrs = attrs ?? {};

  /// Значение скаляра. У массива равно null.
  String? value;

  /// Элементы индексированного массива, отсортированные по индексу (обход — по возрастанию).
  Map<int, String>? indexed;

  /// Элементы ассоциативного массива. Порядок обхода — порядок вставки (bash выводит его по хешу,
  /// поэтому точный порядок не воспроизводится).
  Map<String, String>? assoc;

  final Set<VarAttr> attrs;

  bool get isArray => indexed != null || assoc != null;

  bool has(VarAttr attr) => attrs.contains(attr);

  /// Значение, которое видит `$NAME` без индекса: скаляр или элемент 0 массива. null — не задано.
  String? get scalar => isArray ? (indexed?[0] ?? assoc?['0']) : value;

  /// Копия для записи в дочерней области: массивы копируются поэлементно.
  ShellVar copy() => ShellVar(
    value: value,
    indexed: indexed == null ? null : SplayTreeMap.of(indexed!),
    assoc: assoc == null ? null : {...assoc!},
    attrs: {...attrs},
  );
}

/// Слоистое хранилище имён: дочерняя область хранит только свои изменения, чтение идёт вверх по цепочке.
/// Так подоболочка (`( )`, пайп, `$(...)`) создаётся за O(1), а не копированием всех переменных.
/// Удаление в дочерней области оставляет «надгробие» (null), которое скрывает значение родителя.
final class _Layer<T extends Object> {
  _Layer([this.parent]);

  /// Родительская область или null для корневой.
  final _Layer<T>? parent;

  final Map<String, T?> _own = {};

  /// Глубина цепочки. Слишком глубокую цепочку (вложенные подоболочки) сворачивают в корневую.
  int get depth => parent == null ? 0 : parent!.depth + 1;

  T? lookup(String name) {
    for (var layer = this; ; layer = layer.parent!) {
      if (layer._own.containsKey(name)) return layer._own[name];
      if (layer.parent == null) return null;
    }
  }

  /// Своя запись для изменения: если значение унаследовано, сначала копируется в эту область.
  T? writable(String name, T Function(T) copy) {
    final own = _own[name];
    if (own != null) return own;
    final inherited = lookup(name);
    if (inherited == null) return null;
    final copied = copy(inherited);
    _own[name] = copied;
    return copied;
  }

  void put(String name, T value) => _own[name] = value;

  void remove(String name) {
    if (parent == null) {
      _own.remove(name);
    } else {
      _own[name] = null;
    }
  }

  /// Все видимые записи. Порядок: сначала корневая область, затем дочерние.
  Map<String, T> entries() {
    final chain = <_Layer<T>>[];
    for (_Layer<T>? layer = this; layer != null; layer = layer.parent) {
      chain.add(layer);
    }
    final result = <String, T>{};
    for (final layer in chain.reversed) {
      for (final MapEntry(:key, :value) in layer._own.entries) {
        if (value == null) {
          result.remove(key);
        } else {
          result[key] = value;
        }
      }
    }
    return result;
  }

  /// Копия всех записей в корневой области: для глубоких цепочек и для переноса в новую область.
  _Layer<T> flattened() {
    final root = _Layer<T>();
    for (final MapEntry(:key, :value) in entries().entries) {
      root._own[key] = value;
    }
    return root;
  }
}

/// Нарушение `readonly`: запись в переменную, помеченную `-r`. Оболочка прерывается, как в bash.
final class ShellReadonlyError implements Exception {
  const ShellReadonlyError(this.name);

  /// Имя переменной, которую нельзя менять.
  final String name;
}

/// Глубина цепочки областей, после которой она сворачивается в корневую.
const _maxLayerDepth = 24;

/// Опции `set -o` и их однобуквенные синонимы, поддержанные виртуальным shell.
const shellOptionLetters = {
  'e': 'errexit',
  'u': 'nounset',
  'x': 'xtrace',
  'E': 'errtrace',
  'T': 'functrace',
};

/// Имена опций, которые принимает `set -o NAME`. Остальные (posix, vi, emacs, ...) — явная ошибка.
const shellOptionNames = {
  'errexit',
  'nounset',
  'pipefail',
  'xtrace',
  'errtrace',
  'functrace',
};

/// Состояние оболочки одного запуска: переменные и функции (слоистые области), опции, ловушки,
/// стек вызовов, каталог и код последней команды.
///
/// Каждый запуск `run_command` начинается с чистого состояния, как отдельный `bash -c` на реальном Host:
/// `cd`, присваивания и функции не переживают запуск. Подоболочки (пайп, `( )`, `$(...)`) работают с
/// дочерней областью [fork]: их изменения родителю не видны.
final class ShellState {
  ShellState._({
    required this.cwd,
    required this._vars,
    required this._functions,
    required this.options,
    required this.traps,
    this.lastStatus = 0,
    List<String>? positional,
    List<Map<String, ShellVar?>>? localFrames,
    this.loopDepth = 0,
    this.lineNo = 0,
    this.optCursor = 0,
    List<String>? dirStack,
  }) : positional = positional ?? [],
       localFrames = localFrames ?? [],
       dirStack = dirStack ?? [];

  /// Состояние нового запуска: переменные окружения профиля Host в каталоге [cwd].
  factory ShellState.initial(VirtualProfile profile, String cwd) {
    final state = ShellState._(
      cwd: cwd,
      vars: _Layer(),
      functions: _Layer(),
      options: {},
      traps: {},
    );
    // LANG остаётся C.UTF-8 для совместимости окружения, но строки оболочка считает как в LC_ALL=C:
    // длина, срезы и образцы — в байтах (см. ShellText). Это совпадает с differential-тестами под LC_ALL=C.
    final exported = {
      'HOME': profile.home,
      'USER': profile.user,
      'LOGNAME': profile.user,
      'HOSTNAME': profile.hostname,
      'SHELL': profile.shell,
      'PATH': '/usr/local/bin:/usr/bin:/bin',
      'PWD': cwd,
      'LANG': 'C.UTF-8',
    };
    for (final MapEntry(:key, :value) in exported.entries) {
      state._vars.put(key, ShellVar(value: value, attrs: {VarAttr.export}));
    }
    state._vars
      ..put('OPTIND', ShellVar(value: '1'))
      ..put('UID', ShellVar(value: '1000', attrs: {VarAttr.readonly}))
      ..put('EUID', ShellVar(value: '1000', attrs: {VarAttr.readonly}))
      ..put('PPID', ShellVar(value: '1', attrs: {VarAttr.readonly}));
    _exportProfileEnvironment(state, profile.environment);
    return state;
  }

  /// Имена, которые профиль не может подменить: иначе секрет с ключом `PATH`
  /// увёл бы команды в другой каталог.
  static const _reservedEnvironment = {
    'HOME',
    'USER',
    'LOGNAME',
    'HOSTNAME',
    'SHELL',
    'PATH',
    'PWD',
    'LANG',
    'UID',
    'EUID',
    'PPID',
    'OPTIND',
  };

  static final _environmentName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  /// Дописывает карту профиля как экспортируемые переменные. Недопустимое имя
  /// — ошибка до запуска команд, а не тихий пропуск.
  static void _exportProfileEnvironment(
    ShellState state,
    Map<String, String> environment,
  ) {
    for (final key in environment.keys) {
      if (!_environmentName.hasMatch(key)) {
        throw ArgumentError.value(
          key,
          'environment',
          'Имя переменной должно совпадать с [A-Za-z_][A-Za-z0-9_]*.',
        );
      }
    }
    for (final MapEntry(:key, :value) in environment.entries) {
      if (_reservedEnvironment.contains(key)) continue;
      state._vars.put(key, ShellVar(value: value, attrs: {VarAttr.export}));
    }
  }

  /// Текущий каталог в каноническом виде ([VfsPath]).
  String cwd;

  _Layer<ShellVar> _vars;
  _Layer<FunctionDefinition> _functions;

  /// Включённые опции `set -o` по полным именам (см. [shellOptionNames]).
  final Set<String> options;

  /// Ловушки по имени сигнала (`EXIT`, `ERR`, `RETURN`, `INT`, `TERM`) и текст команды.
  /// Подоболочка получает пустой набор: EXIT и прочие ловушки в ней не наследуются.
  final Map<String, String> traps;

  /// Код последней завершённой команды или конвейера: значение `$?`.
  int lastStatus;

  /// Позиционные параметры `$1`, `$2`, ... `$#`. В функции — её аргументы; на верхнем уровне пусты,
  /// как у `bash -c` без аргументов.
  List<String> positional;

  /// Значения переменных до `local` в каждом вызове функции: при выходе восстанавливаются. null — не
  /// было. Глубина стека совпадает с числом активных вызовов функций.
  final List<Map<String, ShellVar?>> localFrames;

  /// Число вложенных циклов. `break` и `continue` вне цикла — no-op с сообщением, как в bash.
  int loopDepth;

  /// Строка, которая отдаётся как `$LINENO`: строка текущей команды относительно своего скрипта.
  int lineNo;

  /// Стек `pushd`: каталоги сверх текущего, ближайший — первым.
  final List<String> dirStack;

  /// Позиция внутри текущего аргумента `getopts` (`-abc` разбирается по одной букве).
  int optCursor;

  /// Число активных вызовов функций.
  int get functionDepth => localFrames.length;

  /// Копия для подоболочки: изменения в ней не видны родителю, ловушки не наследуются.
  ShellState fork() {
    if (_vars.depth > _maxLayerDepth) _vars = _vars.flattened();
    if (_functions.depth > _maxLayerDepth) _functions = _functions.flattened();
    return ShellState._(
      cwd: cwd,
      vars: _Layer(_vars),
      functions: _Layer(_functions),
      options: {...options},
      // EXIT в подоболочку не входит. ERR и RETURN — только при `set -E` и `set -T`.
      traps: {
        if (options.contains('errtrace') && traps['ERR'] != null)
          'ERR': traps['ERR']!,
        if (options.contains('functrace') && traps['RETURN'] != null)
          'RETURN': traps['RETURN']!,
      },
      lastStatus: lastStatus,
      positional: [...positional],
      localFrames: [
        for (final frame in localFrames) {...frame},
      ],
      loopDepth: loopDepth,
      lineNo: lineNo,
      optCursor: optCursor,
      dirStack: [...dirStack],
    );
  }

  /// Переменная или null, если не задана (даже как пустое объявление).
  ShellVar? variable(String name) => _vars.lookup(name);

  /// Значение `$NAME` (скаляр или элемент 0). null — переменная не задана.
  String? get(String name) => _vars.lookup(name)?.scalar;

  /// Все видимые переменные, включая объявленные без значения.
  Map<String, ShellVar> variables() => _vars.entries();

  /// Изменяемая запись для записи в переменную. Создаёт пустую переменную, если её не было; копирует
  /// унаследованную. Для `readonly` бросает [ShellReadonlyError].
  ShellVar _writable(String name) {
    _checkWritable(name);
    return _mutable(name);
  }

  /// Бросает [ShellReadonlyError], если переменная помечена `-r`. Проверка идёт до вычисления индексов и
  /// значений, чтобы побочные эффекты арифметики не случились у защищённой переменной.
  void _checkWritable(String name) {
    if (_vars.lookup(name)?.has(VarAttr.readonly) ?? false) {
      throw ShellReadonlyError(name);
    }
  }

  /// Изменяемая запись без проверки readonly: для смены атрибутов, которые разрешены и у readonly.
  ShellVar _mutable(String name) {
    final copied = _vars.writable(name, (v) => v.copy());
    if (copied != null) return copied;
    final created = ShellVar();
    _vars.put(name, created);
    return created;
  }

  /// Записывает скаляр. Применяет атрибуты: `-i` вычисляет арифметику, `-u`/`-l` меняют регистр.
  /// Для массива записывает элемент 0, как `x=value` в bash. С [append] (`x+=value`) дописывает к прежнему.
  void set(String name, String value, {bool append = false}) {
    final variable = _writable(name);
    final text = _compose(variable, variable.scalar, value, append: append);
    if (variable.assoc != null) {
      variable.assoc!['0'] = text;
    } else if (variable.indexed != null) {
      variable.indexed![0] = text;
    } else {
      variable.value = text;
    }
  }

  /// Записывает элемент массива: `name[subscript]=value`. Для ассоциативного массива [subscript] — ключ как
  /// есть; для индексированного — арифметическое выражение (`a[i+1]`), отрицательное считается от конца.
  /// Скаляр превращается в массив, а его значение становится элементом 0, как в bash.
  void setElement(
    String name,
    String subscript,
    String value, {
    bool append = false,
  }) {
    _checkWritable(name);
    final current = _vars.lookup(name);
    if (current?.assoc != null) {
      final variable = _writable(name);
      final assoc = variable.assoc!;
      assoc[subscript] = _compose(
        variable,
        assoc[subscript],
        value,
        append: append,
      );
      return;
    }
    final index = _indexFor(name, current, subscript);
    final variable = _writable(name);
    _ensureIndexed(variable);
    final indexed = variable.indexed!;
    indexed[index] = _compose(variable, indexed[index], value, append: append);
  }

  /// Литерал `name=(...)` или `name+=(...)`. Без [append] массив заменяется целиком; с ним элементы
  /// дописываются после последнего индекса. Ассоциативный массив берёт обычные элементы парами «ключ, значение».
  ///
  /// Все индексы вычисляются до записи, поэтому ошибка арифметики в элементе не оставляет массив
  /// наполовину изменённым. Нечётный хвост ассоциативного литерала становится ключом с пустым значением.
  void setArrayLiteral(
    String name,
    List<ArrayEntry> entries, {
    bool append = false,
  }) {
    _checkWritable(name);
    final current = _vars.lookup(name);
    if (current?.assoc != null) {
      final pairs = <(String, String)>[];
      String? pendingKey;
      for (final (:subscript, :value) in entries) {
        if (subscript != null) {
          pairs.add((subscript, value));
        } else if (pendingKey == null) {
          pendingKey = value;
        } else {
          pairs.add((pendingKey, value));
          pendingKey = null;
        }
      }
      // Нечётный хвост bash записывает ключом с пустым значением и не считает ошибкой.
      if (pendingKey != null) pairs.add((pendingKey, ''));
      final variable = _writable(name);
      final assoc = variable.assoc!;
      if (!append) assoc.clear();
      for (final (key, value) in pairs) {
        assoc[key] = _transform(variable, value);
      }
      return;
    }
    final base = append ? current : null;
    final resolved = <(int, String)>[];
    var next = append ? _nextIndex(current) : 0;
    for (final (:subscript, :value) in entries) {
      final index = subscript == null ? next : _indexFor(name, base, subscript);
      resolved.add((index, value));
      next = index + 1;
    }
    final variable = _writable(name);
    if (append) {
      _ensureIndexed(variable);
    } else {
      variable
        ..value = null
        ..indexed = SplayTreeMap();
    }
    for (final (index, value) in resolved) {
      variable.indexed![index] = _transform(variable, value);
    }
  }

  /// Чтение переменной для арифметики: `name` или `name[subscript]`. null — не задано (арифметика даст 0).
  ///
  /// Для индексированного массива [subscript] вычисляется как арифметика, для ассоциативного — ключ как
  /// текст. Скаляр считается массивом из одного элемента 0.
  String? readForArithmetic(String name, String? subscript) {
    final variable = _vars.lookup(name);
    if (variable == null) return null;
    if (subscript == null) return variable.scalar;
    if (variable.assoc != null) return variable.assoc![subscript];
    final index = _indexFor(name, variable, subscript, forRead: true);
    if (variable.indexed != null) return variable.indexed![index];
    return index == 0 ? variable.value : null;
  }

  /// Запись результата арифметики: `name = value` или `name[subscript] = value`. Значение уже вычислено,
  /// поэтому `+=` здесь не дописывает. Нарушение `readonly` — [ShellRuntimeError]: bash печатает сообщение
  /// и продолжает скрипт, в отличие от обычного присваивания.
  void writeForArithmetic(String name, String? subscript, String value) {
    try {
      if (subscript == null) {
        set(name, value);
      } else {
        setElement(name, subscript, value);
      }
    } on ShellReadonlyError catch (_, stack) {
      Error.throwWithStackTrace(
        ShellRuntimeError('$name: readonly variable'),
        stack,
      );
    }
  }

  /// Итоговый текст записи. С [append] к прежнему значению [previous] дописывается новое; для `-i` сложение
  /// идёт арифметически, как в bash (`x=5; x+=3` даёт 8). Атрибуты регистра применяются ко всей строке.
  String _compose(
    ShellVar variable,
    String? previous,
    String value, {
    required bool append,
  }) {
    if (!append) return _transform(variable, value);
    final text = variable.has(VarAttr.integer)
        ? '(${previous ?? '0'})+($value)'
        : '${previous ?? ''}$value';
    return _transform(variable, text);
  }

  /// Индекс элемента индексированного массива для записи или чтения. Отрицательный индекс отсчитывается от
  /// следующего за последним: `-1` — последний элемент. Выход за начало — `bad array subscript`.
  ///
  /// У скаляра, как и в bash, единственный элемент имеет индекс 0. Для записи [forRead] не нужен: при
  /// выходе за границы массив просто растёт.
  int _indexFor(
    String name,
    ShellVar? current,
    String subscript, {
    bool forRead = false,
  }) {
    final index = ShellArithmetic.evaluate(
      subscript,
      readForArithmetic,
      writeForArithmetic,
    );
    if (index >= 0) return index;
    final last = _lastIndex(current);
    final resolved = (last ?? -1) + 1 + index;
    if (last == null || resolved < 0) {
      if (forRead) return -1;
      throw ShellRuntimeError('$name[$subscript]: bad array subscript');
    }
    return resolved;
  }

  /// Наибольший индекс переменной или null, если элементов нет. У скаляра с значением это 0.
  int? _lastIndex(ShellVar? variable) {
    if (variable == null) return null;
    return variable.indexed?.keys.lastOrNull ??
        (variable.value == null ? null : 0);
  }

  /// Индекс, который получит очередной обычный элемент литерала при [append]: следующий за последним.
  int _nextIndex(ShellVar? variable) {
    final last = _lastIndex(variable);
    return last == null ? 0 : last + 1;
  }

  /// Превращает скаляр (или пустую переменную) в индексированный массив; прежнее значение становится
  /// элементом 0, как в bash. Для уже индексированного массива ничего не делает.
  void _ensureIndexed(ShellVar variable) {
    if (variable.indexed != null) return;
    final previous = variable.value;
    variable.indexed = SplayTreeMap<int, String>();
    if (previous != null) variable.indexed![0] = previous;
    variable.value = null;
  }

  /// Заменяет весь массив: `name=(a b)`. Атрибуты переменной сохраняются.
  void setArray(
    String name,
    List<String> elements, {
    bool associative = false,
    bool append = false,
  }) {
    final variable = _writable(name);
    if (associative) {
      variable
        ..indexed = null
        ..value = null
        ..assoc ??= {};
      if (!append) variable.assoc!.clear();
      for (var i = 0; i + 1 < elements.length; i += 2) {
        variable.assoc![elements[i]] = _transform(variable, elements[i + 1]);
      }
      return;
    }
    variable
      ..assoc = null
      ..value = null;
    final array = variable.indexed ??= SplayTreeMap();
    var index = append && array.isNotEmpty ? array.keys.last + 1 : 0;
    if (!append) array.clear();
    for (final element in elements) {
      array[index++] = _transform(variable, element);
    }
  }

  /// `declare -a`: скаляр становится индексированным массивом, прежнее значение — элемент 0.
  /// Ассоциативный массив так не превращается.
  void declareIndexed(String name) {
    final existing = _vars.lookup(name);
    if (existing?.assoc != null) {
      throw ShellRuntimeError(
        '$name: cannot convert associative to indexed array',
      );
    }
    _ensureIndexed(_writable(name));
  }

  /// `declare -A`: новая переменная становится ассоциативным массивом.
  /// Скаляр и индексированный массив так не превращаются.
  void declareAssociative(String name) {
    final existing = _vars.lookup(name);
    if (existing != null &&
        (existing.indexed != null || existing.value != null)) {
      throw ShellRuntimeError(
        '$name: cannot convert indexed to associative array',
      );
    }
    final variable = _writable(name);
    // `??=` не входит в каскад: оператор слабее `..`, и анализатор видит повтор получателя.
    variable
      ..indexed = null
      ..value = null
      ..assoc = variable.assoc ?? {};
  }

  /// Объявляет переменную с атрибутами (`declare`, `readonly`, `export`) без изменения значения.
  /// У readonly-переменной разрешены только повторное `-r` и `-x` (экспорт); остальное — ошибка.
  void declare(String name, Set<VarAttr> attrs) {
    final existing = _vars.lookup(name);
    if (existing != null &&
        existing.has(VarAttr.readonly) &&
        !attrs.every((a) => a == VarAttr.readonly || a == VarAttr.export)) {
      throw ShellReadonlyError(name);
    }
    _mutable(name).attrs.addAll(attrs);
  }

  /// Снимает атрибуты (`+x`, `+i`). Снятие `readonly` не делается этим методом: вызывающий отказывает.
  void removeAttrs(String name, Set<VarAttr> attrs) {
    final existing = _vars.lookup(name);
    if (existing != null && existing.has(VarAttr.readonly)) {
      throw ShellReadonlyError(name);
    }
    _mutable(name).attrs.removeAll(attrs);
  }

  /// Удаляет переменную (`unset`). Для readonly бросает [ShellReadonlyError].
  void unset(String name) {
    final existing = _vars.lookup(name);
    if (existing == null) return;
    if (existing.has(VarAttr.readonly)) throw ShellReadonlyError(name);
    _vars.remove(name);
  }

  /// Преобразование значения по атрибутам переменной перед записью. `-i` вычисляет значение как арифметику
  /// (с чтением и записью переменных оболочки), `-u`/`-l` меняют регистр.
  String _transform(ShellVar variable, String value) {
    var text = value;
    if (variable.has(VarAttr.integer)) {
      text =
          '${ShellArithmetic.evaluate(value, readForArithmetic, writeForArithmetic)}';
    }
    if (variable.has(VarAttr.upper)) text = text.toUpperCase();
    if (variable.has(VarAttr.lower)) text = text.toLowerCase();
    return text;
  }

  /// Функция по имени или null.
  FunctionDefinition? function(String name) => _functions.lookup(name);

  /// Записывает функцию. Переопределение заменяет прежнее определение.
  void defineFunction(String name, FunctionDefinition definition) =>
      _functions.put(name, definition);

  /// Удаляет функцию (`unset -f`).
  void removeFunction(String name) => _functions.remove(name);

  /// Все видимые функции по имени.
  Map<String, FunctionDefinition> functions() => _functions.entries();

  /// Вход в функцию: новые позиционные параметры, пустая запись для `local` и `FUNCNAME` с именем вызова.
  /// Возвращает прежние параметры, которые [leaveFunction] вернёт на место.
  List<String> enterFunction(String name, List<String> args) {
    final saved = positional;
    positional = args;
    localFrames.add({});
    _pushFuncName(name);
    return saved;
  }

  /// Выход из функции: переменные, перекрытые `local`, возвращаются к прежним значениям, параметры — к
  /// [savedPositional], `FUNCNAME` — к вызывающему.
  void leaveFunction(List<String> savedPositional) {
    final frame = localFrames.removeLast();
    for (final MapEntry(:key, :value) in frame.entries) {
      _restore(key, value);
    }
    positional = savedPositional;
  }

  /// Стек `FUNCNAME`: собственная переменная, пересоздаётся на входе и выходе из функции.
  /// Хранится в локальном кадре, поэтому `local FUNCNAME` внутри функции не портит стек.
  void _pushFuncName(String name) {
    final previous = _vars.lookup('FUNCNAME');
    localFrames.last.putIfAbsent('FUNCNAME', () => previous);
    final names = <int, String>{0: name};
    if (previous != null && previous.indexed != null) {
      var index = 1;
      for (final value in previous.indexed!.values) {
        names[index++] = value;
      }
    }
    _vars.put('FUNCNAME', ShellVar(indexed: SplayTreeMap.of(names)));
  }

  void _restore(String name, ShellVar? previous) {
    if (previous == null) {
      _vars.remove(name);
    } else {
      _vars.put(name, previous);
    }
  }

  /// `local NAME[=VALUE]`: переменная видна только внутри текущего вызова функции. Прежнее значение
  /// запоминается при первом `local` для имени в этом вызове. Вне функции — ошибка на стороне вызывающего.
  void declareLocal(String name, {Set<VarAttr> attrs = const {}}) {
    final frame = localFrames.last;
    if (!frame.containsKey(name)) frame[name] = _vars.lookup(name);
    _vars.put(name, ShellVar(attrs: {...attrs}));
  }

  /// Окружение для апплета: только экспортируемые переменные, которые заданы.
  Map<String, String> environment() => {
    for (final MapEntry(:key, :value) in _vars.entries().entries)
      if (value.has(VarAttr.export) && value.scalar != null) key: value.scalar!,
  };

  /// Флаги `$-` в порядке bash. `h`, `B` и `c` включены всегда: виртуальный запуск — это `bash -c`
  /// с hashall и braceexpand. Остальные буквы появляются после `set`.
  String get dollarFlags {
    const order = ['e', 'h', 'u', 'x', 'B', 'E', 'T', 'c'];
    final enabled = {
      'h',
      'B',
      'c',
      if (options.contains('errexit')) 'e',
      if (options.contains('nounset')) 'u',
      if (options.contains('xtrace')) 'x',
      if (options.contains('errtrace')) 'E',
      if (options.contains('functrace')) 'T',
    };
    return [
      for (final flag in order)
        if (enabled.contains(flag)) flag,
    ].join();
  }
}
