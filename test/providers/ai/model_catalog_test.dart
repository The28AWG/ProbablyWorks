import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/core/data/saved_model_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

/// Провайдер со сценарием ответов на listModels: по одному ответу на вызов.
class _ScriptedLlm implements LlmProvider {
  final List<Future<List<LlmModelInfo>> Function()> script = [];
  int calls = 0;

  @override
  Future<LlmKeyInfo> checkKey() =>
      Future.value(const LlmKeyInfo(label: 'test', usage: 0));

  @override
  Future<List<LlmModelInfo>> listModels() {
    calls++;
    return script.removeAt(0)();
  }

  @override
  Stream<LlmEvent> stream(LlmRequest request) =>
      throw UnimplementedError('not used by the catalog');
}

LlmModelInfo _model(String id, {String? name, bool tools = true}) =>
    LlmModelInfo(
      id: id,
      name: name ?? id,
      contextLength: 1000,
      supportsTools: tools,
    );

void main() {
  late AppDatabase db;
  late SavedModelRepository repository;
  late _ScriptedLlm llm;
  late ModelCatalogService catalog;

  setUp(() {
    db = openInMemoryDatabase();
    repository = SavedModelRepository(db);
    llm = _ScriptedLlm();
    catalog = ModelCatalogService(repository, llm);
  });

  tearDown(() => db.close());

  group('refresh', () {
    test('keeps the list in memory and marks the sync time', () async {
      llm.script.add(() async => [_model('a/x'), _model('b/y')]);

      await catalog.refresh();

      expect(catalog.state.models.map((m) => m.id), ['a/x', 'b/y']);
      expect(catalog.state.loaded, isTrue);
      expect(catalog.state.error, isNull);
      expect(catalog.state.loading, isFalse);
    });

    test('does not write the whole list to the database', () async {
      llm.script.add(() async => [_model('a/x'), _model('b/y')]);

      await catalog.refresh();

      expect(await repository.all(), isEmpty);
    });

    test('concurrent calls share a single request', () async {
      final gate = Completer<List<LlmModelInfo>>();
      llm.script.add(() => gate.future);

      final first = catalog.refresh();
      final second = catalog.refresh();
      expect(catalog.state.loading, isTrue);
      gate.complete([_model('a/x')]);
      await Future.wait([first, second]);

      expect(llm.calls, 1);
    });

    test('a failed refresh rethrows and keeps the previous list', () async {
      llm.script.add(() async => [_model('a/x')]);
      llm.script.add(() async => throw const LlmFailure('network down'));
      await catalog.refresh();

      await expectLater(catalog.refresh(), throwsA(isA<LlmFailure>()));

      expect(catalog.state.models.single.id, 'a/x');
      expect(catalog.state.error, contains('network down'));
      expect(catalog.state.loading, isFalse);
    });

    test('an empty list is an error and does not drop models', () async {
      llm.script.add(() async => [_model('a/x')]);
      llm.script.add(() async => const <LlmModelInfo>[]);
      await catalog.refresh();

      await expectLater(catalog.refresh(), throwsA(isA<LlmFailure>()));

      expect(catalog.state.models.single.id, 'a/x');
      expect(catalog.state.error, isNotNull);
    });

    test('a successful refresh clears the error', () async {
      llm.script.add(() async => throw const LlmFailure('boom'));
      llm.script.add(() async => [_model('a/x')]);
      await expectLater(catalog.refresh(), throwsA(isA<LlmFailure>()));

      await catalog.refresh();

      expect(catalog.state.error, isNull);
      expect(catalog.state.loaded, isTrue);
    });
  });

  group('selected models', () {
    test(
      'remember stores name, context and tool support from the list',
      () async {
        llm.script.add(() async => [_model('a/x', name: 'Named X')]);
        await catalog.refresh();

        await catalog.remember(['a/x']);

        final saved = (await repository.all()).single;
        expect(saved.name, 'Named X');
        expect(saved.contextLength, 1000);
        expect(saved.supportsTools, isTrue);
        expect(catalog.state.saved['a/x']!.name, 'Named X');
      },
    );

    test('remember of an unknown id keeps the id as the name', () async {
      await catalog.remember(['a/unknown']);

      expect(catalog.state.nameOf('a/unknown'), 'a/unknown');
      expect((await repository.all()).single.id, 'a/unknown');
    });

    test('remember ignores empty ids', () async {
      await catalog.remember(['', 'a/x']);

      expect((await repository.all()).map((m) => m.id), ['a/x']);
    });

    test('a refresh updates saved details of models still listed', () async {
      llm.script.add(() async => [_model('a/x', name: 'Old')]);
      await catalog.refresh();
      await catalog.remember(['a/x']);

      llm.script.add(() async => [_model('a/x', name: 'New')]);
      await catalog.refresh();

      expect(catalog.state.saved['a/x']!.name, 'New');
      expect((await repository.all()).single.name, 'New');
    });

    test('a model that left the list keeps its saved details', () async {
      llm.script.add(() async => [_model('a/x', name: 'Kept')]);
      await catalog.refresh();
      await catalog.remember(['a/x']);

      llm.script.add(() async => [_model('b/y')]);
      await catalog.refresh();

      expect(catalog.state.statusOf('a/x'), ModelStatus.unavailable);
      expect(catalog.state.nameOf('a/x'), 'Kept');
      expect((await repository.all()).single.name, 'Kept');
    });

    test('loadSaved restores details without any network call', () async {
      await repository.save(const [SavedModel(id: 'a/x', name: 'Saved')]);

      await catalog.loadSaved();

      expect(catalog.state.nameOf('a/x'), 'Saved');
      expect(catalog.state.loaded, isFalse);
      expect(llm.calls, 0);
    });
  });

  group('statusOf', () {
    test('unknown until the list is loaded', () async {
      expect(catalog.state.statusOf('a/x'), ModelStatus.unknown);
      expect(catalog.state.statusOf(null), ModelStatus.unknown);
      expect(catalog.state.statusOf(''), ModelStatus.unknown);
    });

    test('available when listed, unavailable when not', () async {
      llm.script.add(() async => [_model('a/x')]);
      await catalog.refresh();

      expect(catalog.state.statusOf('a/x'), ModelStatus.available);
      expect(catalog.state.statusOf('b/y'), ModelStatus.unavailable);
    });
  });

  test('watch emits the current state first, then every change', () async {
    final sizes = <int>[];
    final sub = catalog.watch().listen((s) => sizes.add(s.models.length));

    llm.script.add(() async => [_model('a/x'), _model('b/y')]);
    await catalog.refresh();
    // Broadcast-стрим доставляет события асинхронно.
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(sizes, [0, 0, 2]);
  });

  test('retry delay grows and stops at the last step', () {
    expect(ModelCatalogService.retryDelayFor(0), const Duration(seconds: 15));
    expect(ModelCatalogService.retryDelayFor(1), const Duration(seconds: 30));
    expect(ModelCatalogService.retryDelayFor(2), const Duration(minutes: 1));
    expect(ModelCatalogService.retryDelayFor(4), const Duration(minutes: 5));
    expect(ModelCatalogService.retryDelayFor(50), const Duration(minutes: 5));
  });
}
