import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/core/util/async_semaphore.dart';
import 'package:pw_agent/core/util/line_diff.dart';
import 'package:pw_agent/core/util/pid_marker_parser.dart';
import 'package:pw_agent/core/util/redactor.dart';
import 'package:pw_agent/core/util/shell_quote.dart';
import 'package:pw_agent/core/util/text_clip.dart';
import 'package:pw_agent/core/util/utf8_chunk_decoder.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('PidMarkerParser', () {
    test('extracts pid from first line and passes the rest through', () {
      final parser = PidMarkerParser();
      final out = parser.add(_bytes('PW_PID:4242\nhello\n'));
      expect(parser.pid, 4242);
      expect(utf8.decode(out), 'hello\n');
    });

    test('handles marker split across chunks', () {
      final parser = PidMarkerParser();
      expect(parser.add(_bytes('PW_P')), isEmpty);
      expect(parser.add(_bytes('ID:7\nab')), _bytes('ab'));
      expect(parser.pid, 7);
      expect(utf8.decode(parser.add(_bytes('cd'))), 'cd');
    });

    test('returns output untouched when there is no marker', () {
      final parser = PidMarkerParser();
      expect(
        utf8.decode(parser.add(_bytes('plain output\n'))),
        'plain output\n',
      );
      expect(parser.pid, isNull);
    });

    test('flush returns buffered bytes if command ended before the marker', () {
      final parser = PidMarkerParser();
      expect(parser.add(_bytes('PW')), isEmpty);
      expect(utf8.decode(parser.flush()), 'PW');
    });
  });

  group('Utf8ChunkDecoder', () {
    test('joins a multi-byte character split across chunks', () {
      final encoded = utf8.encode('привет');
      final decoder = Utf8ChunkDecoder();
      final first = decoder.add(encoded.sublist(0, 3));
      final second = decoder.add(encoded.sublist(3));
      expect(first + second, 'привет');
      expect(decoder.close(), isEmpty);
    });
  });

  group('Redactor', () {
    test('masks api keys, bearer tokens and private keys', () {
      final text =
          'key=sk-or-v1-abcdef123456 Authorization: Bearer abcdefghijkl\n'
          '-----BEGIN OPENSSH PRIVATE KEY-----\nAAA\n-----END OPENSSH PRIVATE KEY-----';
      final out = Redactor.redact(text);
      expect(out, isNot(contains('abcdef123456')));
      expect(out, isNot(contains('abcdefghijkl')));
      expect(out, contains('[PRIVATE KEY REDACTED]'));
    });

    test('keeps ordinary text', () {
      expect(Redactor.redact('ls -la /tmp'), 'ls -la /tmp');
    });
  });

  group('TextClip', () {
    test('keeps head and tail and marks omitted part', () {
      final text = 'a' * 100 + 'z' * 100;
      final clipped = TextClip.headTail(text, maxChars: 50);
      expect(clipped.startsWith('a'), isTrue);
      expect(clipped.endsWith('z'), isTrue);
      expect(clipped, contains('truncated 150 chars'));
    });

    test('returns short text as is', () {
      expect(TextClip.headTail('short', maxChars: 50), 'short');
    });
  });

  group('LineDiff', () {
    test('marks removed and added lines', () {
      final diff = LineDiff.compute('a\nb\nc', 'a\nB\nc');
      expect(diff.where((l) => l.kind == DiffKind.remove).map((l) => l.text), [
        'b',
      ]);
      expect(diff.where((l) => l.kind == DiffKind.add).map((l) => l.text), [
        'B',
      ]);
    });
  });

  group('shQuote', () {
    test('escapes single quotes', () {
      expect(shQuote("it's"), "'it'\\''s'");
    });
  });

  group('AsyncSemaphore', () {
    test('limits concurrency', () async {
      final sem = AsyncSemaphore(2);
      var running = 0;
      var maxRunning = 0;
      Future<void> task() => sem.run(() async {
        running++;
        maxRunning = running > maxRunning ? running : maxRunning;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        running--;
      });
      await Future.wait([for (var i = 0; i < 6; i++) task()]);
      expect(maxRunning, 2);
    });
  });
}
