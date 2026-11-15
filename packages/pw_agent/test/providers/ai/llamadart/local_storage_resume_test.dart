import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

void main() {
  test('download resumes from a part file after a restart', () async {
    final bytes = List<int>.generate(1024 * 1024, (i) => i % 251);
    var requests = 0;
    var sawRange = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        requests++;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (requests == 1) {
          request.response.headers.set(HttpHeaders.etagHeader, '"v1"');
          request.response.contentLength = bytes.length;
          request.response.add(bytes.sublist(0, 200000));
          // Закрываем раньше заявленного Content-Length: клиент увидит обрыв
          // и оставит .part для докачки.
          await request.response.close();
          return;
        }
        final start = int.parse(
          RegExp(r'bytes=(\d+)-').firstMatch(range ?? 'bytes=0-')!.group(1)!,
        );
        sawRange = sawRange || start > 0;
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(HttpHeaders.etagHeader, '"v1"')
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${bytes.length - 1}/${bytes.length}',
          )
          ..contentLength = bytes.length - start
          ..add(bytes.sublist(start));
        await request.response.close();
      } on Object {
        // Намеренный обрыв первой попытки.
      }
    });
    addTearDown(server.close);

    final cache = Directory.systemTemp.createTempSync('llamadart_resume_');
    addTearDown(() => cache.deleteSync(recursive: true));
    final source = ModelSource.url(
      Uri.parse('http://127.0.0.1:${server.port}/model.gguf'),
    );

    final first = DefaultModelDownloadManager(
      defaultCacheDirectory: cache.path,
    );
    await expectLater(
      first.ensureModel(source, options: ModelLoadOptions(maxRetries: 0)),
      throwsA(isA<Exception>()),
    );

    // Новый менеджер = новый процесс: кэш на диске остался.
    final second = DefaultModelDownloadManager(
      defaultCacheDirectory: cache.path,
    );
    final entry = await second.ensureModel(source);

    expect(sawRange, isTrue);
    expect(File(entry.filePath).readAsBytesSync(), bytes);
  });
}
