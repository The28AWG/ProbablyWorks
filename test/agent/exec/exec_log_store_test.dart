import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/exec/exec_log_store.dart';

void main() {
  late Directory root;
  late ExecLogStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pw_logs_');
    store = ExecLogStore(root);
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'small log is moved to the DB text unchanged and the file is deleted',
    () async {
      final path = await store.open('c1', 't1');
      store.append('t1', 'hello\n');
      await store.closeSink('t1');

      final result = await store.compactToDb(path, maxBytes: 1024);

      expect(result.text, 'hello\n');
      expect(result.truncated, isFalse);
      expect(File(path).existsSync(), isFalse);
    },
  );

  test('huge log keeps only the tail without reading it whole', () async {
    final path = await store.open('c1', 't2');
    final line = 'x' * 999;
    store.append('t2', 'HEAD-MARK\n');
    for (var i = 0; i < 3000; i++) {
      store.append('t2', '$line\n');
    }
    store.append('t2', 'TAIL-MARK\n');
    await store.closeSink('t2');
    final size = File(path).lengthSync();
    expect(size, greaterThan(3000000));

    final result = await store.compactToDb(path, maxBytes: 4000);

    expect(result.truncated, isTrue);
    expect(result.text.length, lessThanOrEqualTo(4000));
    expect(result.text, isNot(contains('HEAD-MARK')));
    expect(result.text, endsWith('TAIL-MARK\n'));
    // Срез по байтам попал в середину строки: неполная первая строка
    // отбрасывается, как вытеснение в терминале.
    expect(result.text, startsWith('$line\n'));
    expect(File(path).existsSync(), isFalse);
  });

  test('live tail keeps recent output and is released explicitly', () async {
    await store.open('c1', 't3');
    store
      ..append('t3', 'first\n')
      ..append('t3', 'second\n');

    expect(store.liveTail('t3'), 'first\nsecond\n');

    store.dropLiveTail('t3');
    expect(store.liveTail('t3'), isNull);
  });

  test('live tail keeps only the last characters', () async {
    await store.open('c1', 't4');
    store
      ..append('t4', 'START')
      ..append('t4', 'x' * 300000);

    final tail = store.liveTail('t4');
    expect(tail, isNotNull);
    expect(tail, endsWith('x'));
    expect(tail, isNot(contains('START')));
  });

  test('missing file compacts to empty text', () async {
    final result = await store.compactToDb(
      '${root.path}/nope.log',
      maxBytes: 100,
    );
    expect(result.text, '');
    expect(result.truncated, isFalse);
  });
}
