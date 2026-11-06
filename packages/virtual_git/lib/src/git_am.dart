/// Вспомогательные функции для `git am`: разбор mbox и урезание преамбулы письма.
// ignore_for_file: avoid-substring
library;

import 'package:virtual_git/src/git_apply_whitespace.dart';

/// Сообщения в формате mbox: разделитель `From ` в начале строки.
List<String> splitMboxMessages(String text) {
  final lines = text.split('\n');
  final messages = <String>[];
  final buffer = StringBuffer();
  void flush() {
    if (buffer.isEmpty) return;
    messages.add(buffer.toString());
    buffer.clear();
  }

  for (final line in lines) {
    if (line.startsWith('From ') && buffer.isNotEmpty) {
      flush();
    }
    if (buffer.isNotEmpty) buffer.writeln();
    buffer.write(line);
  }
  flush();
  return messages;
}

/// Удаляет префикс `>` у строк после заголовков письма (упрощённый mailinfo).
String stripMboxGreaterThanBody(String message) {
  final lines = message.split('\n');
  var inHeaders = true;
  final out = <String>[];
  for (final line in lines) {
    if (inHeaders) {
      out.add(line);
      if (line.isEmpty) {
        inHeaders = false;
      }
      continue;
    }
    if (line.startsWith('>')) {
      out.add(line.length > 1 ? line.substring(1) : '');
    } else {
      out.add(line);
    }
  }
  return out.join('\n');
}

/// Отрезает тело до маркера scissors (`git am -c` / `--scissors`), если есть.
String applyScissorsToBody(String body, {required bool scissors}) {
  if (!scissors) return body;
  const marker = '------------------------ >8 ------------------------';
  final index = body.indexOf(marker);
  if (index < 0) return body;
  return body.substring(index + marker.length).trimLeft();
}

/// Парсит заголовки письма в map (многострочные значения склеиваются с пробелом).
Map<String, String> parseMailHeaders(String message) {
  final lines = message.split('\n');
  final map = <String, String>{};
  var index = 0;
  while (index < lines.length) {
    final line = lines[index];
    if (line.isEmpty) break;
    final colon = line.indexOf(':');
    if (colon <= 0) break;
    final name = line.substring(0, colon).trim().toLowerCase();
    var value = line.substring(colon + 1).trim();
    index++;
    while (index < lines.length &&
        lines[index].isNotEmpty &&
        (lines[index].startsWith(' ') || lines[index].startsWith('\t'))) {
      value = '$value ${lines[index].trim()}';
      index++;
    }
    map[name] = value;
  }
  return map;
}

/// Имя и email из `From:` в стиле git (упрощённо: `Name <email>` или только email).
({String name, String email}) parseFromHeader(String from) {
  final angle = RegExp(r'<([^>]+)>').firstMatch(from);
  if (angle != null) {
    final email = angle.group(1)!;
    var name = from.substring(0, angle.start).trim();
    if (name.startsWith('"') && name.endsWith('"') && name.length >= 2) {
      name = name.substring(1, name.length - 1);
    }
    if (name.isEmpty) {
      name = email.split('@').first;
    }
    return (name: name, email: email);
  }
  final email = from.trim();
  return (name: email.split('@').first, email: email);
}

/// Дата из `Date:` (RFC 2822) в секунды и смещение; при ошибке — null.
({int seconds, String tz})? parseDateHeader(String? dateHeader) {
  if (dateHeader == null || dateHeader.trim().isEmpty) return null;
  try {
    final parsed = DateTime.parse(dateHeader);
    final utc = parsed.toUtc();
    final seconds = utc.millisecondsSinceEpoch ~/ 1000;
    final offset = parsed.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final totalMinutes = offset.abs().inMinutes;
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    final tz =
        '$sign${hours.toString().padLeft(2, '0')}${minutes.toString().padLeft(2, '0')}';
    return (seconds: seconds, tz: tz);
  } on FormatException {
    return null;
  }
}

/// Нормализация CRLF в LF для тела письма (`git am --keep-cr` оставляет `\r`).
String normalizeMboxNewlines(String body, {required bool keepCr}) {
  if (keepCr) return body;
  return body.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}

/// Извлекает текст патча после заголовков (первый `diff --git` или конец заголовка).
String mailBodyAfterHeaders(String message) {
  final lines = message.split('\n');
  var headerEnd = 0;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].isEmpty) {
      headerEnd = i + 1;
      break;
    }
  }
  final body = lines.sublist(headerEnd).join('\n');
  final diff = body.indexOf('diff --git ');
  if (diff >= 0) {
    return body.substring(diff);
  }
  return body;
}

/// Действие `--whitespace` для `git apply` / `git am`.
GitApplyWhitespacePolicy? parseWhitespacePolicy(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  switch (raw) {
    case 'nowarn':
      return GitApplyWhitespacePolicy.nowarn;
    case 'warn':
      return GitApplyWhitespacePolicy.warn;
    case 'error':
      return GitApplyWhitespacePolicy.error;
    case 'error-all':
      return GitApplyWhitespacePolicy.errorAll;
    case 'fix':
      return GitApplyWhitespacePolicy.fix;
    default:
      return null;
  }
}

/// Строка темы как у `git mailinfo` (без `-k`).
String mailinfoSubjectLine(
  String rawSubject, {
  required bool keepSubject,
  required bool keepNonPatchBrackets,
}) {
  var s = rawSubject.trim();
  if (keepSubject) {
    return s;
  }
  if (keepNonPatchBrackets) {
    while (true) {
      final match = RegExp(r'^\s*\[([^\]]*)\]\s*').firstMatch(s);
      if (match == null) break;
      final inner = match.group(1)!;
      if (!inner.toLowerCase().contains('patch')) break;
      s = s.substring(match.end).trimLeft();
    }
  } else {
    while (true) {
      final match = RegExp(r'^\s*\[([^\]]*)\]\s*').firstMatch(s);
      if (match == null) break;
      s = s.substring(match.end).trimLeft();
    }
  }
  s = _stripLeadingRePrefix(s);
  if (s.startsWith(':')) {
    s = s.substring(1).trimLeft();
  }
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _stripLeadingRePrefix(String value) {
  var s = value.trimLeft();
  while (true) {
    final match = RegExp(
      r'^(re|aw|sv|fw)\s*:\s*',
      caseSensitive: false,
    ).firstMatch(s);
    if (match == null) break;
    s = s.substring(match.end).trimLeft();
  }
  return s;
}

/// `--quoted-cr`: предупреждение или замена `\r` в конце строк тела до патча.
({String body, int warnCount}) applyQuotedCrToBody(
  String body, {
  required String? action,
}) {
  final mode = action ?? 'warn';
  if (mode == 'nowarn') {
    return (body: body, warnCount: 0);
  }
  final lines = body.split('\n');
  var warns = 0;
  final out = <String>[];
  for (final line in lines) {
    if (line.endsWith('\r')) {
      warns++;
      out.add(mode == 'strip' ? line.substring(0, line.length - 1) : line);
    } else {
      out.add(line);
    }
  }
  return (body: out.join('\n'), warnCount: warns);
}

/// Строка `Message-ID:` для хвоста коммита (как у `git am -m`).
String? messageIdTrailer(Map<String, String> headers) {
  final id = headers['message-id'];
  if (id == null || id.trim().isEmpty) return null;
  return 'Message-ID: ${id.trim()}\n';
}

/// Псевдо `-u` / `--utf8`: mbox в virtual_git уже читается как UTF-8 (`utf8.decode`);
/// отдельное перекодирование метаданных не требуется, поведение совместимо с git при валидном UTF-8.
String recodeMailinfoMetadata(String message) => message;
