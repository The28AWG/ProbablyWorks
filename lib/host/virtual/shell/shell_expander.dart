import 'dart:convert';
import 'dart:typed_data';

import 'package:probably_works/host/virtual/shell/shell_arithmetic.dart';
import 'package:probably_works/host/virtual/shell/shell_ast.dart';
import 'package:probably_works/host/virtual/shell/shell_errors.dart';
import 'package:probably_works/host/virtual/shell/shell_state.dart';
import 'package:probably_works/host/virtual/shell/shell_text.dart';
import 'package:probably_works/host/virtual/vfs_path.dart';
import 'package:probably_works/host/virtual/vfs_store.dart';
import 'package:probably_works/host/virtual/virtual_fs.dart';

/// Происхождение символа при расширении. От него зависит, что делать дальше: резать по IFS и раскрывать
/// глоб или оставить как есть. Порядок повторяет bash.
enum _Kind {
  /// В кавычках, экранирован или результат тильды: не режется и не глобится.
  quoted,

  /// Литерал вне кавычек: глобится, но не режется (разделители в нём уже выделены лексером).
  literal,

  /// Результат параметра или подстановки вне кавычек: режется по IFS и глобится.
  expanded,

  /// Граница между элементами списка (`$@`, `${a[@]}`): всегда разделяет поля, независимо от IFS. Не символ,
  /// в строку не попадает (в `text` превращается в пробел).
  boundary,
}

/// Символ поля с признаком происхождения. Пустой [ch] — маркер «поле существует, но пусто»
/// (`""`, `"$*"`), он нужен, потому что пустое поле из нерасширенного пустого значения не создаётся.
final class _Unit {
  const _Unit(this.ch, this.kind);

  final String ch;
  final _Kind kind;
}

const _marker = _Unit('', _Kind.quoted);

const _boundaryUnit = _Unit('', _Kind.boundary);

/// Значение параметра перед модификатором. Для скаляра [items] содержит одну строку или ничего (если не
/// задан). Для списка (`$@`, `$*`, массив целиком) — по элементу на каждый: элементы разделяют поля.
final class _Param {
  const _Param(
    this.items, {
    required this.isSet,
    required this.label,
    this.isList = false,
    this.star = false,
    this.indices,
  });

  /// Элементы в порядке обхода.
  final List<String> items;

  /// Задан ли параметр: у скаляра есть значение, у списка — хотя бы один элемент.
  final bool isSet;

  /// Имя для сообщений bash: `x`, `a[i]`, `$1`, `!x`.
  final String label;

  /// Ссылка на список: элементы разделяют поля, как в `"$@"`.
  final bool isList;

  /// `*`: в кавычках элементы склеиваются первым символом IFS.
  final bool star;

  /// Индексы элементов индексированного массива. По ним срез `${a[@]:N}` идёт по индексам, а не по порядку.
  final List<int>? indices;

  /// Пусто для форм с двоеточием (`:-`, `:=`, `:?`, `:+`). Список пуст, если у него нет элементов или ровно
  /// один пустой элемент. Два и более пустых элемента — не пусто: так bash проверяет `"${a[@]:-x}"`,
  /// и `"${a[*]:-x}"` при двух пустых даёт разделитель, а не значение по умолчанию.
  bool get isNull =>
      items.isEmpty || (items.length == 1 && items.first.isEmpty);

  _Param withItems(List<String> next) =>
      _Param(next, isSet: isSet, label: label, isList: isList, star: star);
}

/// Образец для `case`, глоба, `#`, `%`, `/`, `^` и `,`. Работает над байтовым представлением строки
/// ([ShellText.toByteChars]): `?` покрывает один байт, как под C-локалью. Образец без метасимволов
/// сравнивается строкой ([literal]), без регулярного выражения: это быстрый путь для `${x/foo/bar}`.
final class _Pattern {
  /// Компилирует части образца. Кавычки делают символ буквальным, `[` без закрывающей `]` — литерал.
  factory _Pattern(List<_Unit> units) {
    final regex = StringBuffer('^');
    final literal = StringBuffer();
    var isLiteral = true;
    var i = 0;
    while (i < units.length) {
      final unit = units[i];
      final ch = unit.kind == _Kind.boundary ? ' ' : unit.ch;
      if (unit.kind == _Kind.quoted || !_isMetaChar(ch)) {
        final bytes = ShellText.toByteChars(ch);
        literal.write(bytes);
        regex.write(RegExp.escape(bytes));
        i++;
        continue;
      }
      if (ch == '[') {
        final bracket = _bracket(units, i);
        if (bracket == null) {
          literal.write('[');
          regex.write(RegExp.escape('['));
          i++;
          continue;
        }
        isLiteral = false;
        regex.write(bracket.$1);
        i = bracket.$2;
        continue;
      }
      isLiteral = false;
      regex.write(ch == '*' ? '.*' : '.');
      i++;
    }
    regex.write(r'$');
    return _Pattern._(
      isLiteral ? literal.toString() : null,
      RegExp(regex.toString(), dotAll: true),
    );
  }

  _Pattern._(this.literal, this._regex);

  /// Буквальное значение в байтах или null, если в образце есть метасимволы.
  final String? literal;
  final RegExp _regex;

  /// Совпадает ли [bytes] (байтовое представление строки) с образцом целиком.
  bool matches(String bytes) =>
      literal != null ? bytes == literal : _regex.hasMatch(bytes);

  static bool _isMetaChar(String ch) => ch == '*' || ch == '?' || ch == '[';

  /// Скобочное выражение `[...]` начиная с [open]: регулярное выражение и индекс за `]`.
  /// Возвращает null, если выражение не закрыто или пусто. Не-ASCII символы в скобках сравниваются побайтно,
  /// поэтому диапазоны с ними приблизительны (известное расхождение).
  static (String, int)? _bracket(List<_Unit> segment, int open) {
    var j = open + 1;
    var negate = false;
    if (j < segment.length && (segment[j].ch == '!' || segment[j].ch == '^')) {
      negate = true;
      j++;
    }
    final content = StringBuffer();
    var first = true;
    while (j < segment.length) {
      final ch = segment[j].ch;
      if (ch == ']' && !first) break;
      first = false;
      // Дефис оставляем как есть, чтобы работали диапазоны `a-z`.
      content.write(ch == '-' ? '-' : RegExp.escape(ShellText.toByteChars(ch)));
      j++;
    }
    if (j >= segment.length || content.isEmpty) return null;
    return ('[${negate ? '^' : ''}$content]', j + 1);
  }
}

/// Раскрытие слов в порядке bash: тильда, параметры, подстановки, разбиение по IFS, глобы, удаление кавычек.
///
/// [fields] даёт поля для команды (с разбиением и глобами). [text] даёт одну строку без разбиения
/// и глобов: присваивания, цели перенаправлений для `<<<`, тело здесь-документа.
///
/// Строки считаются как в `LC_ALL=C` (см. [ShellText]): длина, срезы и образцы — в байтах. Оболочка
/// `ShellState.initial` задаёт `LANG=C.UTF-8` только для совместимости окружения; вычисления от него не зависят.
final class ShellExpander {
  ShellExpander({
    required this.state,
    required this.fs,
    required this.home,
    required this.substitute,
  });

  final ShellState state;
  final VirtualFs fs;

  /// Домашний каталог Host для `~`, если `$HOME` не задан.
  final String home;

  /// Выполняет подстановку `$(...)` и возвращает её stdout и код выхода.
  final Future<(Uint8List, int)> Function(ScriptNode script) substitute;

  /// Код выхода последней подстановки в слове. Нужен присваиванию без команды (`x=$(false)`).
  int? substitutionStatus;

  static const _defaultIfs = ' \t\n';

  /// Сколько записей прочитано глобом в этом раскрытии. Ограничивает обход больших каталогов.
  var _walked = 0;

  /// Поля слова: разбиение по IFS и раскрытие глобов для нерасширенных частей.
  Future<List<String>> fields(ShellWord word) async {
    final units = await _units(word.parts, quoted: false);
    final result = <String>[];
    for (final field in _split(units, state.get('IFS') ?? _defaultIfs)) {
      result.addAll(await _glob(field));
    }
    return result;
  }

  /// Поля и строка слова за один проход. Нужно цели перенаправления: при неоднозначности bash печатает
  /// исходный текст, а подстановку повторять нельзя (побочные эффекты).
  Future<(List<String>, String)> fieldsAndText(ShellWord word) async {
    final units = await _units(word.parts, quoted: false);
    final result = <String>[];
    for (final field in _split(units, state.get('IFS') ?? _defaultIfs)) {
      result.addAll(await _glob(field));
    }
    return (result, _plain(units));
  }

  /// Строка слова без разбиения и глобов, с удалёнными кавычками. Позиционные параметры склеиваются
  /// пробелами, как в присваивании `x=$@`.
  Future<String> text(ShellWord word) async {
    final units = await _units(word.parts, quoted: false);
    return _plain(units);
  }

  /// Текст ERE для `[[ =~ ]]`. Кавычки и экранирование делают символ буквальным, остальное остаётся
  /// выражением: `[[ a =~ "a.b" ]]` ищет `a.b`, а `[[ a =~ a.b ]]` — `a`, любой символ и `b`.
  Future<String> extendedRegex(ShellWord word) async {
    final units = await _units(word.parts, quoted: false);
    final out = StringBuffer();
    for (final unit in units) {
      final ch = unit.kind == _Kind.boundary ? ' ' : unit.ch;
      out.write(unit.kind == _Kind.quoted ? _escapeEre(ch) : ch);
    }
    return out.toString();
  }

  /// Экранирует метасимволы ERE, чтобы кавычки в `=~` давали буквальное совпадение.
  static String _escapeEre(String text) {
    final out = StringBuffer();
    for (final code in text.codeUnits) {
      final ch = String.fromCharCode(code);
      if ('. *[]^\$\\()|+?{}'.contains(ch)) out.write(r'\');
      out.write(ch);
    }
    return out.toString();
  }

  /// Совпадает ли [value] с образцом оператора `case`. Образец раскрывается без разбиения по IFS и без
  /// путей: `*` покрывает любые символы, включая `/`, как в bash.
  Future<bool> matchesPattern(ShellWord pattern, String value) async {
    final units = await _units(pattern.parts, quoted: false);
    return _Pattern(units).matches(ShellText.toByteChars(value));
  }

  static String _plain(List<_Unit> units) =>
      units.map((u) => u.kind == _Kind.boundary ? ' ' : u.ch).join();

  Future<List<_Unit>> _units(
    List<WordPart> parts, {
    required bool quoted,
  }) async {
    final out = <_Unit>[];
    for (final part in parts) {
      await _addPart(part, out, quoted: quoted);
    }
    return out;
  }

  Future<void> _addPart(
    WordPart part,
    List<_Unit> out, {
    required bool quoted,
  }) async {
    switch (part) {
      case LiteralPart(:final text, quoted: final isQuoted):
        final kind = quoted || isQuoted ? _Kind.quoted : _Kind.literal;
        if (text.isEmpty) {
          if (kind == _Kind.quoted) out.add(_marker);
          return;
        }
        _addText(text, kind, out);
      case TildePart():
        _addText(state.get('HOME') ?? home, _Kind.quoted, out);
      case ParamPart():
        out.addAll(await _param(part, quoted: quoted));
      case BadSubstitutionPart(:final text):
        throw ShellParamError('\${$text}: bad substitution', exitCode: 1);
      case ArithmeticPart(:final expression):
        // Ошибка `$((1/0))` прерывает оболочку. `((...))` и `let` зовут [arithmetic] напрямую и
        // остаются ошибкой одной команды.
        final value = await _arithmeticInWord(expression);
        _addText('$value', _kindOf(quoted), out);
      case CommandPart(:final script):
        final (bytes, status) = await substitute(script);
        substitutionStatus = status;
        // bash ставит $? по результату подстановки, поэтому `$(exit 3)$?` даёт 3.
        state.lastStatus = status;
        final output = utf8.decode(bytes, allowMalformed: true);
        _addText(
          output.replaceFirst(RegExp(r'\n+$'), ''),
          _kindOf(quoted),
          out,
        );
      case QuotedPart(:final parts):
        final before = out.length;
        for (final inner in parts) {
          await _addPart(inner, out, quoted: true);
        }
        // `"$@"` без элементов не даёт ни одного поля, а любое другое пустое `"..."` даёт одно пустое.
        if (out.length == before && !_isAtReference(parts)) out.add(_marker);
    }
  }

  /// Арифметика внутри слова. [ShellRuntimeError] здесь становится [ShellParamError]: bash не продолжает
  /// скрипт после `$((1/0))` и после ошибки в `${x:1/0}`.
  Future<int> _arithmeticInWord(ShellWord word) async {
    try {
      return await arithmetic(word);
    } on ShellRuntimeError catch (e, stack) {
      Error.throwWithStackTrace(ShellParamError(e.message, exitCode: 1), stack);
    }
  }

  /// Значение арифметического выражения: слово раскрывается (`$VAR`, подстановки), затем вычисляется.
  /// Присваивания в выражении идут через [ShellState.writeForArithmetic] и меняют оболочку, как в bash.
  ///
  /// [context] — префикс сообщений об ошибках для `((` и `let`. Ошибки разбора и деления — [ShellRuntimeError].
  Future<int> arithmetic(ShellWord word, {String? context}) async =>
      _evaluate(await text(word), context: context);

  /// Вычисляет уже раскрытую строку арифметики с общим чтением и записью переменных.
  int _evaluate(String source, {String? context}) => ShellArithmetic.evaluate(
    source,
    _readNumber,
    state.writeForArithmetic,
    context: context,
  );

  /// Чтение переменной в арифметике. Неустановленный скаляр без индекса при `set -u` — ошибка, как в bash.
  /// Элемент и ключ незаданного массива дают 0 без ошибки: `$((a[5]))` при `set -u` молча даёт 0.
  String? _readNumber(String name, String? subscript) {
    final value = state.readForArithmetic(name, subscript);
    if (value == null &&
        subscript == null &&
        state.options.contains('nounset')) {
      throw ShellParamError('$name: unbound variable', exitCode: 127);
    }
    return value;
  }

  /// Ссылка `"$@"`, `"${a[@]}"`, `"${!p@}"` и их варианты: без элементов она не даёт поля вовсе.
  /// `"$*"` и `"${a[*]}"` дают поле всегда, поэтому сюда не входят.
  static bool _isAtReference(List<WordPart> parts) {
    if (parts.length != 1) return false;
    final part = parts.single;
    if (part is! ParamPart || part.kind == ParamKind.length) return false;
    final sub = part.subscript;
    return switch (sub) {
      null => part.name == '@',
      AllElements(:final star) => !star,
      IndexElement() => false,
    };
  }

  void _addText(String text, _Kind kind, List<_Unit> out) {
    for (final rune in text.runes) {
      out.add(_Unit(String.fromCharCode(rune), kind));
    }
  }

  /// Текст значения параметра. Пустой текст в кавычках даёт маркер пустого поля, иначе `"$x"` при
  /// `x=` исчезло бы из аргументов, а в bash остаётся пустым аргументом.
  void _addQuotedText(String text, bool quoted, List<_Unit> out) {
    if (text.isNotEmpty) {
      _addText(text, _kindOf(quoted), out);
    } else if (quoted) {
      out.add(_marker);
    }
  }

  _Kind _kindOf(bool quoted) => quoted ? _Kind.quoted : _Kind.expanded;

  /// Раскрывает параметр с модификатором в единицы поля. Вызывается из [_addPart] и отвечает за порядок:
  /// сначала значение, затем проверка `set -u`, затем модификатор.
  Future<List<_Unit>> _param(ParamPart part, {required bool quoted}) async {
    final value = await _resolve(part);
    final op = part.op;
    // Формы `:-`, `-`, `:=`, `=`, `:?`, `?`, `:+`, `+` сами решают, задан ли параметр, поэтому под `set -u` не падают.
    if (op is! ParamDefaultOp) _requireSet(value);
    if (op == null) return _emit(value, quoted: quoted);
    return _modify(part, op, value, quoted: quoted);
  }

  /// Значение параметра по виду обращения: значение, длина, косвенность, ключи или имена.
  Future<_Param> _resolve(ParamPart part) {
    final name = part.name;
    final sub = part.subscript;
    return switch (part.kind) {
      ParamKind.value => _value(name, sub),
      ParamKind.length => _length(name, sub),
      ParamKind.indirect => _indirect(part),
      ParamKind.keys => Future.value(_keys(name, sub)),
      ParamKind.names => Future.value(_names(name, sub)),
    };
  }

  /// `${#x}`: длина в байтах; для списка — число элементов. `set -u` проверяется здесь, потому что
  /// результат длины всегда задан.
  Future<_Param> _length(String name, ParamSubscript? sub) async {
    final inner = await _value(name, sub);
    _requireSet(inner);
    final size = inner.isList ? inner.items.length : _scalarLength(inner);
    return _Param(['$size'], isSet: true, label: inner.label);
  }

  static int _scalarLength(_Param value) =>
      value.items.isEmpty ? 0 : ShellText.byteLength(value.items.first);

  /// Значение без модификатора: скаляр, элемент массива или весь массив.
  Future<_Param> _value(String name, ParamSubscript? sub) {
    if (sub == null) {
      if (name == '@' || name == '*') {
        final args = state.positional;
        return Future.value(
          _Param(
            args,
            isSet: args.isNotEmpty,
            label: '\$$name',
            isList: true,
            star: name == '*',
          ),
        );
      }
      final value = _special(name);
      return Future.value(
        _Param(
          value == null ? const [] : [value],
          isSet: value != null,
          label: _isPositionalOrSpecial(name) ? '\$$name' : name,
        ),
      );
    }
    final variable = state.variable(name);
    return switch (sub) {
      AllElements(:final star) => Future.value(
        _allElements(name, variable, star: star),
      ),
      IndexElement(:final index, :final source) => _element(
        name,
        variable,
        index,
        source,
      ),
    };
  }

  /// `${x[@]}` и `${x[*]}`. Для скаляра — один элемент, для неустановленной переменной — пусто.
  _Param _allElements(String name, ShellVar? variable, {required bool star}) {
    if (variable == null) {
      return _Param(
        const [],
        isSet: false,
        label: name,
        isList: true,
        star: star,
      );
    }
    final indexed = variable.indexed;
    if (indexed != null) {
      return _Param(
        indexed.values.toList(),
        isSet: indexed.isNotEmpty,
        label: name,
        isList: true,
        star: star,
        indices: indexed.keys.toList(),
      );
    }
    final assoc = variable.assoc;
    if (assoc != null) {
      return _Param(
        assoc.values.toList(),
        isSet: assoc.isNotEmpty,
        label: name,
        isList: true,
        star: star,
      );
    }
    final scalar = variable.value;
    return _Param(
      scalar == null ? const [] : [scalar],
      isSet: scalar != null,
      label: name,
      isList: true,
      star: star,
    );
  }

  /// `${x[i]}`: элемент индексированного массива (индекс — арифметика) или ассоциативного (ключ — строка).
  /// Скаляр — массив из одного элемента с индексом 0.
  Future<_Param> _element(
    String name,
    ShellVar? variable,
    ShellWord index,
    String source,
  ) async {
    final key = await text(index);
    final label = '$name[$source]';
    String? value;
    if (variable != null) {
      final assoc = variable.assoc;
      final indexed = variable.indexed;
      if (assoc != null) {
        value = assoc[key];
      } else if (indexed != null) {
        value = indexed[_arrayIndex(name, key, indexed)];
      } else if (_evaluate(key) == 0) {
        value = variable.value;
      }
    }
    return _Param(
      value == null ? const [] : [value],
      isSet: value != null,
      label: label,
    );
  }

  /// Индекс с учётом отрицательных значений: `-1` — последний элемент. Выход за начало — ошибка.
  int _arrayIndex(String name, String key, Map<int, String> indexed) {
    var index = _evaluate(key);
    if (index < 0) {
      index += indexed.isEmpty ? 0 : indexed.keys.last + 1;
      if (index < 0) throw ShellRuntimeError('$name: bad array subscript');
    }
    return index;
  }

  /// `${!x[@]}` и `${!x[*]}`: индексы массива или ключи ассоциативного. Для скаляра — `0`, если задан.
  _Param _keys(String name, ParamSubscript? sub) {
    final star = sub is AllElements && sub.star;
    final variable = state.variable(name);
    final keys = <String>[];
    if (variable != null) {
      final indexed = variable.indexed;
      final assoc = variable.assoc;
      if (indexed != null) {
        for (final key in indexed.keys) {
          keys.add('$key');
        }
      } else if (assoc != null) {
        keys.addAll(assoc.keys);
      } else if (variable.value != null) {
        keys.add('0');
      }
    }
    return _Param(
      keys,
      isSet: keys.isNotEmpty,
      label: name,
      isList: true,
      star: star,
    );
  }

  /// `${!prefix*}` и `${!prefix@}`: имена переменных с этим префиксом, по алфавиту.
  _Param _names(String prefix, ParamSubscript? sub) {
    final star = sub is AllElements && sub.star;
    final names = <String>[];
    for (final name in state.variables().keys) {
      if (name.startsWith(prefix)) names.add(name);
    }
    names.sort();
    return _Param(
      names,
      isSet: names.isNotEmpty,
      label: prefix,
      isList: true,
      star: star,
    );
  }

  /// `${!x}`: значение `x` задаёт имя переменной, а её значение и есть результат. Незаданный `x` даёт
  /// `invalid indirect expansion`, заданный, но пустой или не похожий на имя текст — `invalid variable name`;
  /// оба прерывают оболочку с кодом 1, как в bash. Имя может содержать индекс: `x='arr[1]'`.
  Future<_Param> _indirect(ParamPart part) async {
    final inner = await _value(part.name, part.subscript);
    if (!inner.isSet || inner.isList) {
      throw ShellParamError(
        '${inner.label}: invalid indirect expansion',
        exitCode: 1,
      );
    }
    final target = inner.items.first;
    final match = _refText.firstMatch(target);
    if (match == null) {
      throw ShellParamError('$target: invalid variable name', exitCode: 1);
    }
    final resolved = await _value(match[1]!, _refSubscript(match[2]));
    return _Param(
      resolved.items,
      isSet: resolved.isSet,
      label: '!${part.name}',
      isList: resolved.isList,
      star: resolved.star,
      indices: resolved.indices,
    );
  }

  /// Имя параметра для косвенности: `NAME` или `NAME[index]`. Группы: имя и текст индекса.
  static final _refText = RegExp(
    r'^([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[?$!@*#-])(?:\[(.*)\])?$',
    dotAll: true,
  );

  /// Индекс из косвенной ссылки. Текст индекса берётся буквально: bash не раскрывает в нём подстановки.
  static ParamSubscript? _refSubscript(String? raw) {
    if (raw == null) return null;
    return switch (raw) {
      '@' => const AllElements(star: false),
      '*' => const AllElements(star: true),
      _ => IndexElement(ShellWord([LiteralPart(raw, quoted: true)]), raw),
    };
  }

  /// `set -u` (nounset): неустановленный параметр — ошибка. Списки и значения с `:-`-формами сюда не
  /// попадают: `$@` и `${a[@]}` на пустом списке не падают, как в bash.
  void _requireSet(_Param value) {
    if (value.isSet || value.isList) return;
    if (!state.options.contains('nounset')) return;
    throw ShellParamError('${value.label}: unbound variable', exitCode: 127);
  }

  /// Спецпараметры и позиционные. `$?`, `$$`, `$0`, `$#`, `$-` всегда заданы, `$!` — пока нет фонового процесса.
  String? _special(String name) => switch (name) {
    '?' => '${state.lastStatus}',
    '\$' => '1',
    '0' => 'bash',
    '#' => '${state.positional.length}',
    '-' => state.dollarFlags,
    '!' => null,
    'LINENO' => '${state.lineNo}',
    _ => _isDigits(name) ? _positional(name) : state.get(name),
  };

  /// `$1`, `$2`, ... Номер за пределами списка — не задан.
  String? _positional(String name) {
    final index = int.tryParse(name);
    final args = state.positional;
    if (index == null || index < 1 || index > args.length) return null;
    return args[index - 1];
  }

  static bool _isDigits(String name) => RegExp(r'^[0-9]+$').hasMatch(name);

  /// Позиционный или спецпараметр. В сообщениях bash пишет их с `$`: `$1: unbound variable`.
  static bool _isPositionalOrSpecial(String name) =>
      _isDigits(name) || (name.length == 1 && '@*#?-\$!'.contains(name));

  /// Модификаторы `${NAME op ...}`. Формы с операндом возвращают единицы операнда целиком: в них могут
  /// быть `$@`, кавычки и подстановки, и их границы полей уже выставлены.
  Future<List<_Unit>> _modify(
    ParamPart part,
    ParamOp op,
    _Param value, {
    required bool quoted,
  }) async {
    switch (op) {
      case ParamDefaultOp():
        return _defaultOp(part, op, value, quoted: quoted);
      case ParamTrimOp(:final prefix, :final longest, :final pattern):
        final compiled = _Pattern(await _units(pattern.parts, quoted: false));
        return _emit(
          _mapItems(
            value,
            (item) => _trim(item, compiled, prefix: prefix, longest: longest),
          ),
          quoted: quoted,
        );
      case ParamReplaceOp(:final mode, :final pattern, :final replacement):
        final compiled = _Pattern(await _units(pattern.parts, quoted: false));
        final rep = await text(replacement);
        return _emit(
          _mapItems(value, (item) => _replace(item, compiled, rep, mode)),
          quoted: quoted,
        );
      case ParamCaseOp(:final mode, :final pattern):
        final compiled = pattern == null
            ? null
            : _Pattern(await _units(pattern.parts, quoted: false));
        return _emit(
          _mapItems(value, (item) => _changeCase(item, mode, compiled)),
          quoted: quoted,
        );
      case ParamTransformOp(:final letter):
        return _emit(
          _mapItems(value, (item) => _transform(item, letter)),
          quoted: quoted,
        );
      case ParamSliceOp(:final offset, :final length):
        final start = await _arithmeticInWord(offset);
        final count = length == null ? null : await _arithmeticInWord(length);
        return _emit(_slice(value, part, start, count), quoted: quoted);
    }
  }

  /// Операнд модификатора как единицы поля. Пустой операнд в кавычках всё равно даёт пустое поле, как
  /// `"${u-}"`, поэтому пустой результат заменяется маркером.
  Future<List<_Unit>> _operand(ShellWord word, {required bool quoted}) async {
    final units = await _units(word.parts, quoted: quoted);
    return units.isEmpty && quoted ? const [_marker] : units;
  }

  /// `:-`, `-`, `:=`, `=`, `:?`, `?`, `:+`, `+`. Правая часть вычисляется только при необходимости.
  Future<List<_Unit>> _defaultOp(
    ParamPart part,
    ParamDefaultOp op,
    _Param value, {
    required bool quoted,
  }) async {
    final missing = op.nullIsUnset ? value.isNull : !value.isSet;
    switch (op.kind) {
      case ParamDefaultKind.useDefault:
        if (missing) return _operand(op.word, quoted: quoted);
        return _emit(value, quoted: quoted);
      case ParamDefaultKind.alternative:
        if (!missing) return _operand(op.word, quoted: quoted);
        // Альтернатива не нужна: каждый элемент заменяется пустой строкой. Так `"${a[@]:+x}"` при одном
        // пустом элементе даёт одно пустое поле, а при пустом массиве — ни одного.
        return _emit(
          value.withItems(List.filled(value.items.length, '')),
          quoted: quoted,
        );
      case ParamDefaultKind.error:
        if (missing) {
          final message = op.word.parts.isEmpty
              ? (op.nullIsUnset
                    ? 'parameter null or not set'
                    : 'parameter not set')
              : await text(op.word);
          throw ShellParamError('${value.label}: $message', exitCode: 127);
        }
        return _emit(value, quoted: quoted);
      case ParamDefaultKind.assign:
        if (!missing) return _emit(value, quoted: quoted);
        final units = await _operand(op.word, quoted: quoted);
        await _assign(part, _plain(units));
        return units;
    }
  }

  /// `${x:=значение}`: присваивание через состояние, поэтому `readonly` проверяется там же. Позиционные
  /// и спецпараметры присвоить нельзя, как в bash.
  Future<void> _assign(ParamPart part, String newValue) async {
    final name = part.name;
    final sub = part.subscript;
    if (part.kind != ParamKind.value ||
        (sub == null && _isPositionalOrSpecial(name))) {
      throw ShellParamError('\$$name: cannot assign in this way', exitCode: 1);
    }
    switch (sub) {
      case null:
        state.set(name, newValue);
      case AllElements():
        throw ShellParamError('$name[@]: bad array subscript', exitCode: 1);
      case IndexElement(:final index):
        // Сырой ключ уходит в состояние: там он вычисляется как индекс или используется как ключ.
        state.setElement(name, await text(index), newValue);
    }
  }

  /// Единицы значения: скаляр — одна строка; список — элементы через границы. В кавычках пустой элемент
  /// сохраняется маркером, а `"$*"` склеивает элементы первым символом IFS.
  List<_Unit> _emit(_Param value, {required bool quoted}) {
    final out = <_Unit>[];
    if (!value.isList) {
      _addQuotedText(value.items.isEmpty ? '' : value.items.first, quoted, out);
      return out;
    }
    if (value.star && quoted) {
      final ifs = state.get('IFS') ?? _defaultIfs;
      final joined = value.items.join(ifs.isEmpty ? '' : ifs[0]);
      _addQuotedText(joined, true, out);
      return out;
    }
    for (var k = 0; k < value.items.length; k++) {
      if (k > 0) out.add(_boundaryUnit);
      final item = value.items[k];
      if (item.isNotEmpty) {
        _addText(item, _kindOf(quoted), out);
      } else if (quoted) {
        out.add(_marker);
      }
    }
    return out;
  }

  /// Применяет [transform] к каждому элементу. Для скаляра это одна строка, для списка — все элементы.
  static _Param _mapItems(_Param value, String Function(String) transform) =>
      value.withItems([for (final item in value.items) transform(item)]);

  /// `${x:offset:length}` для скаляра (по байтам) и для списка (по элементам). Позиционные параметры
  /// включают `$0` в индекс 0, как у bash: `${@:0}` начинается с имени оболочки.
  _Param _slice(_Param value, ParamPart part, int start, int? count) {
    if (!value.isList) {
      final bytes = ShellText.toByteChars(
        value.items.isEmpty ? '' : value.items.first,
      );
      final from = _sliceStart(bytes.length, start);
      // Неустановленная переменная даёт пустой срез без проверки длины, как в bash. Заданная пустая
      // проверяется: `x=; ${x:0:-1}` — ошибка, поэтому здесь важна именно установка, а не пустота.
      final to = value.isSet ? _sliceEnd(bytes.length, from, count) : from;
      return value.withItems([
        ShellText.fromByteChars(ShellText.cut(bytes, from, to)),
      ]);
    }
    var items = value.items;
    var indices = value.indices;
    if (part.subscript == null && (part.name == '@' || part.name == '*')) {
      items = ['bash', ...items];
      indices = null;
    }
    final from = _listStart(items.length, start, indices);
    final to = _sliceEnd(items.length, from, count);
    return value.withItems(items.sublist(from, to));
  }

  /// Начало среза в строке длиной [length]: отрицательное смещение считается от конца, за пределы
  /// строки — пустой срез (возвращается длина, то есть «после конца»).
  static int _sliceStart(int length, int start) {
    if (start >= 0) return start > length ? length : start;
    final from = length + start;
    return from < 0 ? length : from;
  }

  /// Начало среза списка. Для индексированного массива положительное смещение — это индекс элемента, а не
  /// его порядковый номер, поэтому идём по индексам.
  static int _listStart(int length, int start, List<int>? indices) {
    if (indices != null && start >= 0) {
      for (var k = 0; k < indices.length; k++) {
        if (indices[k] >= start) return k;
      }
      return length;
    }
    return _sliceStart(length, start);
  }

  /// Конец среза. Положительная длина — это [from] плюс длина, но не дальше конца. Отрицательная длина —
  /// отступ конца от конца значения (`${x:1:-1}`); если конец оказался раньше начала, bash прерывает
  /// скрипт ошибкой `N: substring expression < 0`, и здесь это тоже ошибка.
  static int _sliceEnd(int length, int from, int? count) {
    if (count == null) return length;
    if (count < 0) {
      final end = length + count;
      if (end < from) {
        throw ShellParamError('$count: substring expression < 0', exitCode: 1);
      }
      return end;
    }
    final end = from + count;
    return end > length ? length : end;
  }

  /// `#`, `##`, `%`, `%%`: снимает самое короткое или самое длинное совпадение с начала или конца.
  /// Буквальный образец снимается без перебора длин.
  static String _trim(
    String value,
    _Pattern pattern, {
    required bool prefix,
    required bool longest,
  }) {
    final bytes = ShellText.toByteChars(value);
    final n = bytes.length;
    final literal = pattern.literal;
    if (literal != null) {
      if (prefix && bytes.startsWith(literal)) {
        return ShellText.fromByteChars(ShellText.cut(bytes, literal.length));
      }
      if (!prefix && bytes.endsWith(literal)) {
        return ShellText.fromByteChars(
          ShellText.cut(bytes, 0, n - literal.length),
        );
      }
      return value;
    }
    for (var step = 0; step <= n; step++) {
      if (prefix) {
        final k = longest ? n - step : step;
        if (pattern.matches(ShellText.cut(bytes, 0, k))) {
          return ShellText.fromByteChars(ShellText.cut(bytes, k));
        }
      } else {
        final s = longest ? step : n - step;
        if (pattern.matches(ShellText.cut(bytes, s))) {
          return ShellText.fromByteChars(ShellText.cut(bytes, 0, s));
        }
      }
    }
    return value;
  }

  /// `/`, `//`, `/#`, `/%`. Совпадение берётся самым левым и самым длинным, как в bash. Пустой образец
  /// ничего не заменяет, кроме `/#` и `/%`, которые вставляют замену в начало или конец.
  static String _replace(
    String value,
    _Pattern pattern,
    String replacement,
    ReplaceMode mode,
  ) {
    final bytes = ShellText.toByteChars(value);
    final rep = ShellText.toByteChars(replacement);
    final n = bytes.length;
    final literal = pattern.literal;
    if (literal == '') {
      return switch (mode) {
        ReplaceMode.prefix => ShellText.fromByteChars(rep + bytes),
        ReplaceMode.suffix => ShellText.fromByteChars(bytes + rep),
        _ => value,
      };
    }
    switch (mode) {
      case ReplaceMode.prefix:
        for (var k = n; k >= 0; k--) {
          if (pattern.matches(ShellText.cut(bytes, 0, k))) {
            return ShellText.fromByteChars(rep + ShellText.cut(bytes, k));
          }
        }
        return value;
      case ReplaceMode.suffix:
        for (var s = 0; s <= n; s++) {
          if (pattern.matches(ShellText.cut(bytes, s))) {
            return ShellText.fromByteChars(ShellText.cut(bytes, 0, s) + rep);
          }
        }
        return value;
      case ReplaceMode.first:
        final match = _findMatch(bytes, pattern, 0);
        if (match == null) return value;
        return ShellText.fromByteChars(
          ShellText.cut(bytes, 0, match.$1) +
              rep +
              ShellText.cut(bytes, match.$2),
        );
      case ReplaceMode.all:
        final out = StringBuffer();
        var pos = 0;
        while (true) {
          final match = _findMatch(bytes, pattern, pos);
          if (match == null) break;
          out
            ..write(ShellText.cut(bytes, pos, match.$1))
            ..write(rep);
          pos = match.$2;
        }
        out.write(ShellText.cut(bytes, pos));
        return ShellText.fromByteChars(out.toString());
    }
  }

  /// Самое левое непустое совпадение образца, начинающееся не раньше [from]: (начало, конец) или null.
  static (int, int)? _findMatch(String bytes, _Pattern pattern, int from) {
    final literal = pattern.literal;
    if (literal != null) {
      final index = bytes.indexOf(literal, from);
      return index < 0 ? null : (index, index + literal.length);
    }
    final n = bytes.length;
    for (var s = from; s < n; s++) {
      for (var e = n; e > s; e--) {
        if (pattern.matches(ShellText.cut(bytes, s, e))) return (s, e);
      }
    }
    return null;
  }

  /// `^`, `^^`, `,`, `,,`, `~`, `~~`: смена регистра ASCII-букв. Без образца затрагивает все символы (или
  /// первый для одинарной формы); с образцом — только символы, которые ему соответствуют.
  static String _changeCase(
    String value,
    ParamCaseMode mode,
    _Pattern? pattern,
  ) {
    final bytes = ShellText.toByteChars(value);
    final firstOnly = switch (mode) {
      ParamCaseMode.upperFirst ||
      ParamCaseMode.lowerFirst ||
      ParamCaseMode.toggleFirst => true,
      _ => false,
    };
    final out = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      final ch = bytes[i];
      final applies =
          (!firstOnly || i == 0) && (pattern == null || pattern.matches(ch));
      if (!applies) {
        out.write(ch);
        continue;
      }
      final converted = switch (mode) {
        ParamCaseMode.upperFirst ||
        ParamCaseMode.upperAll => ShellText.upperAscii(ch),
        ParamCaseMode.lowerFirst ||
        ParamCaseMode.lowerAll => ShellText.lowerAscii(ch),
        _ => ShellText.toggleAscii(ch),
      };
      out.write(converted);
    }
    return ShellText.fromByteChars(out.toString());
  }

  /// Преобразование `@Q`, `@E`, `@U`, `@u`, `@L`, `@l` одного элемента.
  static String _transform(String value, String letter) => switch (letter) {
    'Q' => ShellText.quote(value),
    'E' => ShellText.expandEscapes(value),
    'U' => ShellText.upperAscii(value),
    'L' => ShellText.lowerAscii(value),
    'u' => ShellText.upperFirstAscii(value),
    _ => ShellText.lowerFirstAscii(value),
  };

  /// Разбивает поля по IFS. Пробельные разделители схлопываются, непробельный ставит границу всегда
  /// (`a::b` даёт три поля, как в bash). Кавычки и литералы не режутся.
  /// Границы [_Kind.boundary] (между элементами списка) делят вход на группы; каждая группа режется по IFS.
  List<List<_Unit>> _split(List<_Unit> units, String ifs) {
    final fields = <List<_Unit>>[];
    var group = <_Unit>[];
    for (final unit in units) {
      if (unit.kind == _Kind.boundary) {
        fields.addAll(_splitByIfs(group, ifs));
        group = <_Unit>[];
      } else {
        group.add(unit);
      }
    }
    fields.addAll(_splitByIfs(group, ifs));
    return fields;
  }

  List<List<_Unit>> _splitByIfs(List<_Unit> units, String ifs) {
    if (ifs.isEmpty) {
      return [if (units.isNotEmpty || units.any((u) => u.ch.isEmpty)) units];
    }
    final fields = <List<_Unit>>[];
    var current = <_Unit>[];
    var marked = false;
    for (final unit in units) {
      if (unit.ch.isEmpty) {
        marked = true;
        continue;
      }
      final isSeparator = unit.kind == _Kind.expanded && ifs.contains(unit.ch);
      if (!isSeparator) {
        current.add(unit);
        if (unit.kind == _Kind.quoted) marked = true;
        continue;
      }
      if (_isWhitespace(unit.ch)) {
        if (current.isNotEmpty || marked) {
          fields.add(current);
          current = <_Unit>[];
          marked = false;
        }
      } else {
        fields.add(current);
        current = <_Unit>[];
        marked = false;
      }
    }
    if (current.isNotEmpty || marked) fields.add(current);
    return fields;
  }

  static bool _isWhitespace(String ch) => ch == ' ' || ch == '\t' || ch == '\n';

  /// Глоб для одного поля. Без активных метасимволов или без совпадений поле возвращается как есть
  /// (`nullglob` выключен, как в bash по умолчанию).
  Future<List<String>> _glob(List<_Unit> field) async {
    final plain = field.map((u) => u.ch).join();
    if (!field.any(_isActiveMeta)) return [plain];
    final matches = await _matches(field);
    if (matches.isEmpty) return [plain];
    matches.sort();
    return matches;
  }

  static bool _isActiveMeta(_Unit u) =>
      u.kind != _Kind.quoted && (u.ch == '*' || u.ch == '?' || u.ch == '[');

  Future<List<String>> _matches(List<_Unit> field) async {
    final absolute = field.isNotEmpty && field.first.ch == '/';
    final dirOnly = field.isNotEmpty && field.last.ch == '/';
    final segments = <List<_Unit>>[[]];
    for (final unit in field) {
      if (unit.ch == '/') {
        segments.add([]);
      } else {
        segments.last.add(unit);
      }
    }
    var candidates = [absolute ? VfsPath.root : ''];
    for (final segment in segments) {
      if (segment.isEmpty) continue;
      final hasMeta = segment.any(_isActiveMeta);
      final literal = segment.map((u) => u.ch).join();
      final pattern = hasMeta ? _Pattern(segment) : null;
      // Скрытые имена (с точкой) глоб не раскрывает, если шаблон не начинается с точки.
      final allowHidden = segment.first.ch == '.';
      final next = <String>[];
      for (final base in candidates) {
        if (pattern == null) {
          final path = _join(base, literal);
          if (await fs.stat(path, cwd: state.cwd) != null) next.add(path);
          continue;
        }
        for (final child in await _children(base)) {
          if (child.name.startsWith('.') && !allowHidden) continue;
          if (pattern.matches(ShellText.toByteChars(child.name))) {
            next.add(_join(base, child.name));
          }
        }
      }
      candidates = next;
    }
    final result = <String>[];
    for (final path in candidates) {
      if (!dirOnly) {
        result.add(path);
        continue;
      }
      final node = await fs.stat(path, cwd: state.cwd);
      if (node?.kind == VfsNodeKind.dir) result.add('$path/');
    }
    return result;
  }

  /// Дети каталога для обхода. Не каталог или отсутствующий путь — пустой список, как у глоба в shell.
  /// Счётчик записей ограничивает обход больших каталогов.
  Future<List<VfsNode>> _children(String base) async {
    final List<VfsNode> children;
    try {
      children = await fs.list(base.isEmpty ? '.' : base, cwd: state.cwd);
    } on VfsException {
      return const [];
    }
    _walked += children.length;
    if (_walked > fs.limits.maxWalkEntries) {
      throw ShellLimitExceeded(
        'glob matches too many files (limit ${fs.limits.maxWalkEntries})',
      );
    }
    return children;
  }

  static String _join(String base, String name) {
    if (base.isEmpty) return name;
    if (base.endsWith('/')) return '$base$name';
    return '$base/$name';
  }
}
