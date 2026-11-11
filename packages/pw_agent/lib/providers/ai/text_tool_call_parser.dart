/// Разбор текстовых форматов tool call, которые OpenRouter отдаёт в `content`,
/// когда провайдер модели не превратил их в поле `tool_calls`.
library;

import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

/// Достаёт из текста ответа вызовы инструментов, которые модель написала
/// разметкой, а не структурным `tool_calls`.
///
/// Пока такая разметка остаётся в тексте, цикл агента её не исполняет.
/// Парсер забирает законченный блок, превращает его в [LlmToolCall] и из
/// видимого текста убирает. Незакрытый хвост в конце ответа возвращается
/// текстом: обрезанный аргумент исполнять нельзя.
///
/// Форматы, которые чаще всего протекают в `content`:
/// * Dots — `<dots_function_call>` (invoke/parameter или JSON);
/// * Hermes и Qwen — JSON внутри `<tool_call>`, а также XML Qwen3-Coder
///   (`<function=имя><parameter=имя>`);
/// * GLM — `<arg_key>` / `<arg_value>` внутри `<tool_call>`;
/// * MiniMax — `<minimax:tool_call>`, и общий invoke-формат `<function_calls>`;
/// * DeepSeek V3 — маркеры `<｜tool▁call…｜>` (U+FF5C и U+2581);
/// * Kimi — `<|tool_call_begin|>`;
/// * Mistral — `[TOOL_CALLS]` и JSON;
/// * Llama — `<function=имя>…</function>`.
///
/// Вызов принимается, только если имя есть среди инструментов запроса.
/// Чужой пример разметки остаётся обычным текстом. Значения из XML
/// приводятся к типу по JSON Schema инструмента: иначе `offset` строкой
/// не пройдёт проверку аргументов.
class TextToolCallParser {
  /// [tools] — инструменты этого запроса. Пустой список ничего не извлекает.
  TextToolCallParser(List<LlmToolSpec> tools)
    : _names = {for (final tool in tools) tool.name},
      _properties = {for (final tool in tools) tool.name: _propertiesOf(tool)},
      _defs = {for (final tool in tools) tool.name: _defsOf(tool)};

  final Set<String> _names;
  final Map<String, Map<String, dynamic>> _properties;
  final Map<String, Map<String, dynamic>> _defs;

  final List<LlmToolCall> _calls = [];

  /// Хвост, который может быть началом маркера или незакрытым блоком.
  var _pending = '';

  /// Вызовы из уже закрытых блоков, в порядке появления. У текстового формата
  /// нет id, поэтому id синтетический (`text_0`, …) и уникален в пределах ответа.
  List<LlmToolCall> get calls => List.unmodifiable(_calls);

  /// Кусок `content`. Разметка законченного вызова в результат не попадает.
  List<LlmTextDelta> add(String chunk) {
    final out = <LlmTextDelta>[];
    var rest = _pending + chunk;
    _pending = '';
    while (rest.isNotEmpty) {
      final hit = _find(rest);
      if (hit == null) {
        final keep = _holdSuffix(rest);
        _emit(out, _head(rest, rest.length - keep));
        _pending = _tail(rest, rest.length - keep);
        return out;
      }
      _emit(out, _head(rest, hit.start));
      if (hit.kind == _Kind.llamaHold) {
        _pending = _tail(rest, hit.start);
        return out;
      }
      if (hit.kind == _Kind.mistral) {
        final end = _jsonValueEnd(rest, hit.openEnd);
        if (end == null) {
          _pending = _tail(rest, hit.start);
          return out;
        }
        if (end < 0) {
          _emit(out, _slice(rest, hit.start, hit.openEnd));
          rest = _tail(rest, hit.openEnd);
          continue;
        }
        final calls = _parseJsonCalls(_slice(rest, hit.openEnd, end));
        if (!_accept(calls)) _emit(out, _slice(rest, hit.start, end));
        rest = _tail(rest, end);
        continue;
      }
      final closeAt = rest.indexOf(hit.close, hit.openEnd);
      if (closeAt < 0) {
        _pending = _tail(rest, hit.start);
        return out;
      }
      final blockEnd = closeAt + hit.close.length;
      final calls = _parse(hit, _slice(rest, hit.openEnd, closeAt));
      if (!_accept(calls)) _emit(out, _slice(rest, hit.start, blockEnd));
      rest = _tail(rest, blockEnd);
    }
    return out;
  }

  /// Конец потока. Незакрытый блок уходит в текст и не исполняется.
  List<LlmTextDelta> flush() {
    final out = <LlmTextDelta>[];
    _emit(out, _pending);
    _pending = '';
    return out;
  }

  void _emit(List<LlmTextDelta> out, String text) {
    if (text.isEmpty) return;
    out.add(LlmTextDelta(text));
  }

  bool _accept(List<_Parsed> parsed) {
    final before = _calls.length;
    for (final call in parsed) {
      if (!_names.contains(call.name)) continue;
      _calls.add(
        LlmToolCall(
          id: 'text_${_calls.length}',
          name: call.name,
          arguments: jsonEncode(call.args),
        ),
      );
    }
    return _calls.length != before;
  }

  _Hit? _find(String text) {
    _Hit? best;
    for (final tag in _tags) {
      final index = text.indexOf(tag.open);
      if (index < 0) continue;
      best = _earlier(
        best,
        _Hit(
          start: index,
          openEnd: index + tag.open.length,
          kind: tag.kind,
          close: tag.close,
        ),
      );
    }
    return _earlier(best, _findLlama(text));
  }

  /// `<function=имя>` без закрывающей скобки ещё может оказаться именем
  /// известного инструмента, поэтому держим хвост, пока не увидим `>`.
  _Hit? _findLlama(String text) {
    const open = '<function=';
    var from = 0;
    while (from < text.length) {
      final index = text.indexOf(open, from);
      if (index < 0) return null;
      final nameStart = index + open.length;
      final gt = text.indexOf('>', nameStart);
      if (gt < 0) {
        return _Hit(start: index, openEnd: nameStart, kind: _Kind.llamaHold);
      }
      final name = _slice(text, nameStart, gt);
      if (_names.contains(name)) {
        return _Hit(
          start: index,
          openEnd: gt + 1,
          kind: _Kind.llama,
          close: '</function>',
          llamaName: name,
        );
      }
      from = gt + 1;
    }
    return null;
  }

  List<_Parsed> _parse(_Hit hit, String body) => switch (hit.kind) {
    _Kind.dots => _parseDots(body),
    _Kind.invoke => _parseInvokes(body),
    _Kind.toolCall => _parseToolCall(body),
    _Kind.deepseekCall => _parseDeepseekCall(body),
    _Kind.deepseekSection => _parseInner(
      body,
      _dsCallBegin,
      _dsCallEnd,
      _parseDeepseekCall,
    ),
    _Kind.kimiCall => _parseKimiCall(body),
    _Kind.kimiSection => _parseInner(
      body,
      _kimiCallBegin,
      _kimiCallEnd,
      _parseKimiCall,
    ),
    _Kind.llama => _parseLlama(hit.llamaName ?? '', body),
    _Kind.mistral || _Kind.llamaHold => const [],
  };

  List<_Parsed> _parseDots(String body) {
    final trimmed = body.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      final calls = _parseJsonCalls(trimmed);
      if (calls.isNotEmpty) return calls;
    }
    return _parseInvokes(trimmed);
  }

  /// `<tool_call>` общий для нескольких семейств: сначала JSON, потом XML.
  /// JSON проверяется первым, чтобы строка `<arg_key>` внутри аргумента
  /// не уехала в разбор GLM.
  List<_Parsed> _parseToolCall(String body) {
    final trimmed = body.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      final calls = _parseJsonCalls(trimmed);
      if (calls.isNotEmpty) return calls;
    }
    if (trimmed.contains('<invoke')) return _parseInvokes(trimmed);
    if (trimmed.contains('<function=')) return _parseQwen(trimmed);
    if (trimmed.contains('<arg_key>')) return _parseGlm(trimmed);
    return _parseNameThenJson(trimmed);
  }

  List<_Parsed> _parseInvokes(String body) {
    final out = <_Parsed>[];
    for (final invoke in _invoke.allMatches(body)) {
      final name = invoke.group(1) ?? invoke.group(2) ?? invoke.group(3);
      if (name == null || !_names.contains(name)) continue;
      out.add(_xmlArgs(name, _parameters(invoke.group(4) ?? '')));
    }
    return out;
  }

  Map<String, String> _parameters(String body) {
    final args = <String, String>{};
    for (final parameter in _parameter.allMatches(body)) {
      final name =
          parameter.group(1) ?? parameter.group(2) ?? parameter.group(3);
      if (name == null || name.isEmpty) continue;
      args[name] = parameter.group(4) ?? '';
    }
    return args;
  }

  List<_Parsed> _parseQwen(String body) {
    final out = <_Parsed>[];
    for (final function in _qwenFunction.allMatches(body)) {
      final name = function.group(1);
      if (name == null || !_names.contains(name)) continue;
      final args = <String, String>{};
      for (final parameter in _qwenParameter.allMatches(
        function.group(2) ?? '',
      )) {
        final key = parameter.group(1);
        if (key == null || key.isEmpty) continue;
        args[key] = parameter.group(2) ?? '';
      }
      out.add(_xmlArgs(name, args));
    }
    return out;
  }

  List<_Parsed> _parseGlm(String body) {
    final tag = body.indexOf('<');
    if (tag < 0) return const [];
    final name = _head(body, tag).trim();
    if (!_names.contains(name)) return const [];
    final args = <String, String>{};
    for (final pair in _glmArg.allMatches(body)) {
      final key = pair.group(1)?.trim();
      if (key == null || key.isEmpty) continue;
      args[key] = pair.group(2) ?? '';
    }
    if (args.isEmpty) return const [];
    return [_xmlArgs(name, args)];
  }

  /// Имя на первой строке, дальше JSON аргументов. Так пишут некоторые шаблоны Qwen.
  List<_Parsed> _parseNameThenJson(String text) {
    final split = text.indexOf('\n');
    if (split < 0) return const [];
    final name = _head(text, split).trim();
    if (!_names.contains(name)) return const [];
    return _argsOf(name, _tail(text, split + 1));
  }

  List<_Parsed> _parseDeepseekCall(String body) {
    final sep = body.indexOf(_dsSep);
    final head = sep < 0 ? body : _tail(body, sep + _dsSep.length);
    return _namedJsonHead(head);
  }

  List<_Parsed> _parseKimiCall(String body) {
    const sep = '<|tool_call_argument_begin|>';
    final split = body.indexOf(sep);
    if (split < 0) return const [];
    final name = _kimiName(_head(body, split));
    if (!_names.contains(name)) return const [];
    return _argsOf(name, _tail(body, split + sep.length));
  }

  /// `functions.get_weather:0` → `get_weather`. Индекс после двоеточия — номер вызова Kimi.
  String _kimiName(String raw) {
    var name = raw.trim();
    const prefix = 'functions.';
    if (name.startsWith(prefix)) name = _tail(name, prefix.length);
    final colon = name.lastIndexOf(':');
    if (colon <= 0) return name;
    final suffix = _tail(name, colon + 1);
    if (int.tryParse(suffix) == null) return name;
    return _head(name, colon);
  }

  List<_Parsed> _parseLlama(String name, String body) {
    if (!_names.contains(name)) return const [];
    if (body.contains('<parameter=')) {
      final args = <String, String>{};
      for (final parameter in _qwenParameter.allMatches(body)) {
        final key = parameter.group(1);
        if (key == null || key.isEmpty) continue;
        args[key] = parameter.group(2) ?? '';
      }
      return [_xmlArgs(name, args)];
    }
    return _argsOf(name, body);
  }

  List<_Parsed> _parseInner(
    String body,
    String open,
    String close,
    List<_Parsed> Function(String body) parse,
  ) {
    final out = <_Parsed>[];
    var rest = body;
    var found = false;
    while (true) {
      final start = rest.indexOf(open);
      if (start < 0) break;
      final from = start + open.length;
      final end = rest.indexOf(close, from);
      if (end < 0) break;
      found = true;
      out.addAll(parse(_slice(rest, from, end)));
      rest = _tail(rest, end + close.length);
    }
    if (!found) return parse(body);
    return out;
  }

  /// Объект `{name, arguments}` или массив таких объектов. `arguments` бывает
  /// и объектом, и строкой с JSON — так пишет Hermes.
  List<_Parsed> _parseJsonCalls(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      return const [];
    }
    if (decoded is Map) {
      final one = _parsedFromMap(decoded);
      return one == null ? const [] : [one];
    }
    if (decoded is! List) return const [];
    final out = <_Parsed>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final one = _parsedFromMap(item);
      if (one != null) out.add(one);
    }
    return out;
  }

  _Parsed? _parsedFromMap(Map<dynamic, dynamic> map) {
    final name = map['name'];
    if (name is! String || !_names.contains(name)) return null;
    if (!map.containsKey('arguments') && !map.containsKey('parameters')) {
      return _Parsed(name, {});
    }
    final raw = map.containsKey('arguments')
        ? map['arguments']
        : map['parameters'];
    if (raw == null) return _Parsed(name, {});
    if (raw is Map) return _Parsed(name, _stringKeyMap(raw));
    if (raw is! String) return null;
    if (raw.trim().isEmpty) return _Parsed(name, {});
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return _Parsed(name, _stringKeyMap(decoded));
    } on FormatException {
      return null;
    }
  }

  /// Первая строка — имя, остаток — JSON аргументов (у DeepSeek ещё и в ```json).
  List<_Parsed> _namedJsonHead(String text) {
    final trimmed = text.trim();
    final split = trimmed.indexOf('\n');
    final name = (split < 0 ? trimmed : _head(trimmed, split)).trim();
    if (!_names.contains(name)) return const [];
    if (split < 0) return [_Parsed(name, {})];
    return _argsOf(name, _tail(trimmed, split + 1));
  }

  List<_Parsed> _argsOf(String name, String jsonText) {
    final trimmed = _stripFence(jsonText);
    if (trimmed.isEmpty) return [_Parsed(name, {})];
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return const [];
      return [_Parsed(name, _stringKeyMap(decoded))];
    } on FormatException {
      return const [];
    }
  }

  _Parsed _xmlArgs(String name, Map<String, String> raw) => _Parsed(name, {
    for (final entry in raw.entries)
      entry.key: _coerce(name, entry.key, entry.value),
  });

  /// XML отдаёт всё строками. Тип берём из схемы, чтобы число и bool
  /// не остались текстом. У строки снимается только один перевод строки
  /// по краям: модели кладут значение на отдельную строку, а отступ
  /// внутри `content` / `old_string` значим.
  Object? _coerce(String tool, String key, String raw) {
    final text = _stripEdgeNewline(raw);
    final type = _typeOf(tool, key);
    if (type == null || type == 'string') return text;
    final trimmed = text.trim();
    if (trimmed == 'null') return null;
    switch (type) {
      case 'integer':
        return int.tryParse(trimmed) ?? text;
      case 'number':
        final number = num.tryParse(trimmed);
        if (number == null) return text;
        if (number is int) return number;
        return number == number.roundToDouble() ? number.toInt() : number;
      case 'boolean':
        final lower = trimmed.toLowerCase();
        if (lower == 'true' || lower == '1') return true;
        if (lower == 'false' || lower == '0') return false;
        return text;
      case 'array':
      case 'object':
        try {
          return jsonDecode(trimmed);
        } on FormatException {
          return text;
        }
      default:
        return text;
    }
  }

  String? _typeOf(String tool, String key) {
    final property = _properties[tool]?[key];
    if (property is! Map) return null;
    return _schemaType(_stringKeyMap(property), _defs[tool] ?? const {});
  }

  static String? _schemaType(
    Map<String, dynamic> schema,
    Map<String, dynamic> defs, [
    int depth = 0,
  ]) {
    if (depth > 8) return null;
    final type = schema['type'];
    if (type is String && type != 'null') return type;
    if (type is List) {
      for (final item in type) {
        if (item is String && item != 'null') return item;
      }
    }
    final ref = schema[r'$ref'];
    if (ref is String && ref.startsWith(r'#/$defs/')) {
      final target = defs[ref.split('/').last];
      if (target is Map) {
        return _schemaType(_stringKeyMap(target), defs, depth + 1);
      }
    }
    for (final key in const ['anyOf', 'oneOf', 'allOf']) {
      final options = schema[key];
      if (options is! List) continue;
      for (final option in options) {
        if (option is! Map) continue;
        if (option['type'] == 'null') continue;
        final resolved = _schemaType(_stringKeyMap(option), defs, depth + 1);
        if (resolved != null) return resolved;
      }
    }
    return null;
  }

  static Map<String, dynamic> _propertiesOf(LlmToolSpec tool) {
    final properties = tool.parameters['properties'];
    if (properties is! Map) return const {};
    return _stringKeyMap(properties);
  }

  static Map<String, dynamic> _defsOf(LlmToolSpec tool) {
    final defs = tool.parameters[r'$defs'];
    if (defs is! Map) return const {};
    return _stringKeyMap(defs);
  }

  static Map<String, dynamic> _stringKeyMap(Map<dynamic, dynamic> raw) => {
    for (final entry in raw.entries)
      if (entry.key case final String key) key: entry.value,
  };

  /// Самый длинный суффикс, который ещё может стать началом маркера.
  /// Иначе тег, разрезанный между чанками, мелькает в тексте ответа.
  int _holdSuffix(String text) {
    var keep = 0;
    for (final tag in _tags) {
      final length = _prefixSuffixLength(text, tag.open);
      if (length > keep) keep = length;
    }
    final llama = _prefixSuffixLength(text, '<function=');
    if (llama > keep) keep = llama;
    return keep;
  }

  static int _prefixSuffixLength(String text, String tag) {
    for (var len = tag.characters.length - 1; len > 0; len--) {
      final prefix = tag.characters.take(len).string;
      if (text.endsWith(prefix)) return prefix.length;
    }
    return 0;
  }
}

/// Склеивает структурные tool_calls роутера и вызовы, вынутые из текста.
///
/// Одинаковые имя и аргументы не повторяются: иначе одна команда выполнилась
/// бы дважды, если роутер отдал и JSON, и исходную разметку.
List<LlmToolCall> mergeToolCalls(
  List<LlmToolCall> structured,
  List<LlmToolCall> textual,
) => [
  ...structured,
  for (final call in textual)
    if (!structured.any(
      (other) => other.name == call.name && other.arguments == call.arguments,
    ))
      call,
];

class _Parsed {
  const _Parsed(this.name, this.args);

  final String name;
  final Map<String, dynamic> args;
}

enum _Kind {
  dots,
  invoke,
  toolCall,
  deepseekCall,
  deepseekSection,
  kimiCall,
  kimiSection,
  mistral,
  llama,
  llamaHold,
}

class _Hit {
  const _Hit({
    required this.start,
    required this.openEnd,
    required this.kind,
    this.close = '',
    this.llamaName,
  });

  final int start;
  final int openEnd;
  final _Kind kind;
  final String close;
  final String? llamaName;
}

class _Tag {
  const _Tag(this.open, this.close, this.kind);

  final String open;
  final String close;
  final _Kind kind;
}

/// DeepSeek печатает маркеры символами U+FF5C (`｜`) и U+2581 (`▁`), не ASCII `|` и `_`.
const _dsCallBegin = '<\uFF5Ctool\u2581call\u2581begin\uFF5C>';
const _dsCallEnd = '<\uFF5Ctool\u2581call\u2581end\uFF5C>';
const _dsCallsBegin = '<\uFF5Ctool\u2581calls\u2581begin\uFF5C>';
const _dsCallsEnd = '<\uFF5Ctool\u2581calls\u2581end\uFF5C>';
const _dsSep = '<\uFF5Ctool\u2581sep\uFF5C>';

const _kimiCallBegin = '<|tool_call_begin|>';
const _kimiCallEnd = '<|tool_call_end|>';
const _kimiSectionBegin = '<|tool_calls_section_begin|>';
const _kimiSectionEnd = '<|tool_calls_section_end|>';

const _tags = [
  _Tag('<dots_function_call>', '</dots_function_call>', _Kind.dots),
  _Tag('<minimax:tool_call>', '</minimax:tool_call>', _Kind.invoke),
  _Tag('<function_calls>', '</function_calls>', _Kind.invoke),
  _Tag(_dsCallsBegin, _dsCallsEnd, _Kind.deepseekSection),
  _Tag(_dsCallBegin, _dsCallEnd, _Kind.deepseekCall),
  _Tag(_kimiSectionBegin, _kimiSectionEnd, _Kind.kimiSection),
  _Tag(_kimiCallBegin, _kimiCallEnd, _Kind.kimiCall),
  _Tag('<tool_call>', '</tool_call>', _Kind.toolCall),
  _Tag('[TOOL_CALLS]', '', _Kind.mistral),
];

/// Имя в кавычках или без. После имени допускаются другие атрибуты (`string="true"`).
final _invoke = RegExp(
  r'<invoke\s+name\s*=\s*(?:"([^"]*)"|'
  r"'([^']*)'"
  r'|([^\s>/]+))[^>]*>(.*?)</invoke>',
  dotAll: true,
);

final _parameter = RegExp(
  r'<parameter\s+name\s*=\s*(?:"([^"]*)"|'
  r"'([^']*)'"
  r'|([^\s>/]+))[^>]*>(.*?)</parameter>',
  dotAll: true,
);

final _qwenFunction = RegExp(
  r'<function=([^\s>]+)>(.*?)</function>',
  dotAll: true,
);

final _qwenParameter = RegExp(
  r'<parameter=([^\s>]+)>(.*?)</parameter>',
  dotAll: true,
);

final _glmArg = RegExp(
  r'<arg_key>(.*?)</arg_key>\s*<arg_value>(.*?)</arg_value>',
  dotAll: true,
);

/// Конец JSON-значения после `[TOOL_CALLS]`. null — значение ещё не дописано,
/// отрицательное — дальше не JSON, маркер нужно оставить в тексте.
int? _jsonValueEnd(String text, int start) {
  var index = start;
  while (index < text.length && _isSpace(text.codeUnitAt(index))) {
    index++;
  }
  if (index >= text.length) return null;
  final open = text.codeUnitAt(index);
  if (open != 0x7b && open != 0x5b) return -1;
  var depth = 0;
  var inString = false;
  var escape = false;
  for (var cursor = index; cursor < text.length; cursor++) {
    final unit = text.codeUnitAt(cursor);
    if (inString) {
      if (escape) {
        escape = false;
      } else if (unit == 0x5c) {
        escape = true;
      } else if (unit == 0x22) {
        inString = false;
      }
      continue;
    }
    if (unit == 0x22) {
      inString = true;
      continue;
    }
    if (unit == 0x7b || unit == 0x5b) depth++;
    if (unit != 0x7d && unit != 0x5d) continue;
    depth--;
    if (depth == 0) return cursor + 1;
    if (depth < 0) return -1;
  }
  return null;
}

bool _isSpace(int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0a || unit == 0x0d;

/// Снимает одну обрамляющую строку ```json … ```, если модель завернула аргументы.
String _stripFence(String text) {
  var trimmed = text.trim();
  if (!trimmed.startsWith('```')) return trimmed;
  final split = trimmed.indexOf('\n');
  if (split < 0) return trimmed;
  trimmed = _tail(trimmed, split + 1);
  if (trimmed.endsWith('```')) {
    trimmed = _head(trimmed, trimmed.length - 3);
  }
  return trimmed.trim();
}

String _stripEdgeNewline(String value) {
  var text = value;
  if (text.startsWith('\r\n')) {
    text = _tail(text, 2);
  } else if (text.startsWith('\n')) {
    text = _tail(text, 1);
  }
  if (text.endsWith('\r\n')) {
    text = _head(text, text.length - 2);
  } else if (text.endsWith('\n')) {
    text = _head(text, text.length - 1);
  }
  return text;
}

_Hit? _earlier(_Hit? current, _Hit? next) {
  if (next == null) return current;
  if (current == null || next.start < current.start) return next;
  if (next.start == current.start && next.openEnd > current.openEnd) {
    return next;
  }
  return current;
}

/// Куски по индексам кодпоинтов (`indexOf`), без [String.substring]:
/// его запрещает DCM, а индекс может попасть между суррогатами.
String _head(String text, int endUnits) {
  if (endUnits <= 0) return '';
  if (endUnits >= text.length) return text;
  var units = 0;
  final out = StringBuffer();
  for (final char in text.characters) {
    final next = units + char.length;
    if (next > endUnits) break;
    out.write(char);
    units = next;
  }
  return out.toString();
}

String _tail(String text, int startUnits) {
  if (startUnits <= 0) return text;
  if (startUnits >= text.length) return '';
  var units = 0;
  final out = StringBuffer();
  for (final char in text.characters) {
    if (units >= startUnits) out.write(char);
    units += char.length;
  }
  return out.toString();
}

String _slice(String text, int startUnits, int endUnits) {
  if (endUnits <= startUnits) return '';
  return _head(_tail(text, startUnits), endUnits - startUnits);
}
