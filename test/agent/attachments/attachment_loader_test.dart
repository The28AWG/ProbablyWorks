import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/attachments/attachment_loader.dart';
import 'package:probably_works/agent/domain/chat_models.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('attach_test_'));
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String name, List<int> bytes) =>
      File('${dir.path}/$name')..writeAsBytesSync(bytes);

  test('text file goes into content, not into a path', () async {
    final file = write('notes.md', utf8.encode('заметка\nвторая строка'));
    final result = await loadAttachment(file.path, maxBytes: 1024);

    final ref = result.ref!;
    expect(ref.mode, AttachmentMode.attach);
    expect(ref.content, 'заметка\nвторая строка');
    expect(ref.bytes, isNull);
    expect(ref.toJson().containsKey('path'), isFalse);
    expect(ref.toJson()['content'], isNotNull);
  });

  test('png and pdf are binary file parts with a mime type', () async {
    final png = write('shot.PNG', [0x89, 0x50, 0x4e, 0x47, 0, 1, 2]);
    final pdf = write('doc.pdf', '%PDF-1.4 text'.codeUnits);

    final image = (await loadAttachment(png.path, maxBytes: 1024)).ref!;
    expect(image.mode, AttachmentMode.file);
    expect(image.mimeType, 'image/png');
    expect(image.bytes, Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0, 1, 2]));
    expect(image.sizeBytes, 7);

    final document = (await loadAttachment(pdf.path, maxBytes: 1024)).ref!;
    expect(document.mimeType, 'application/pdf');
    expect(document.content, isNull);
  });

  test('a file larger than the limit is refused', () async {
    final file = write('big.txt', List.filled(100, 0x61));
    final result = await loadAttachment(file.path, maxBytes: 99);
    expect(result.problem, AttachmentProblem.tooLarge);
    expect(result.ref, isNull);
  });

  test('unknown binary and invalid utf-8 are refused', () async {
    final binary = write('data.bin', [1, 0, 2, 0]);
    final invalid = write('latin.txt', [0xff, 0xfe, 0x41]);

    expect(
      (await loadAttachment(binary.path, maxBytes: 1024)).problem,
      AttachmentProblem.unsupportedType,
    );
    expect(
      (await loadAttachment(invalid.path, maxBytes: 1024)).problem,
      AttachmentProblem.unsupportedType,
    );
  });

  test('a missing file is reported as unreadable', () async {
    final result = await loadAttachment('${dir.path}/none.txt', maxBytes: 1);
    expect(result.problem, AttachmentProblem.unreadable);
  });

  test(
    'picker cache inside the cleanup dir is removed after reading',
    () async {
      final cached = write('cached.txt', 'x'.codeUnits);
      final kept = write('mine.txt', 'y'.codeUnits);

      await loadAttachment(
        cached.path,
        maxBytes: 1024,
        removeAfterReadUnder: dir.path,
      );
      expect(cached.existsSync(), isFalse);

      final sub = Directory('${dir.path}/other')..createSync();
      final outside = File('${sub.path}/z.txt')..writeAsStringSync('z');
      await loadAttachment(
        outside.path,
        maxBytes: 1024,
        removeAfterReadUnder: '${dir.path}/cache',
      );
      expect(outside.existsSync(), isTrue);
      expect(kept.existsSync(), isTrue);
    },
  );

  test('persisted json drops bytes and reads legacy mention as a file', () {
    final ref = AttachmentRef(
      name: 'a.png',
      mode: AttachmentMode.file,
      mimeType: 'image/png',
      bytes: Uint8List.fromList([1, 2, 3]),
      sizeBytes: 3,
    );
    final json = ref.toJson();
    expect(json.containsKey('bytes'), isFalse);
    final restored = AttachmentRef.fromJson(json);
    expect(restored.mode, AttachmentMode.file);
    expect(restored.bytes, isNull);
    expect(restored.hasContent, isFalse);

    final legacy = AttachmentRef.fromJson({
      'name': 'old.txt',
      'mode': 'mention',
      'path': '/home/u/old.txt',
      'sizeBytes': 10,
    });
    expect(legacy.mode, AttachmentMode.file);
    expect(legacy.hasContent, isFalse);
  });
}
