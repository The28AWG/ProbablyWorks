import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/state/session_state_service.dart';
import 'package:probably_works/core/data/chat_repository.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/security/secret_store.dart';

void main() {
  late AppDatabase db;
  late ChatRepository chats;
  late SessionStateService service;

  setUp(() async {
    db = openInMemoryDatabase();
    chats = ChatRepository(db);
    service = SessionStateService(chats);
    await HostRepository(
      db,
      MemorySecretStore(),
    ).ensureLocalHost(DateTime.now());
    final now = DateTime.now();
    await chats.saveChat(
      Chat(
        id: 'c1',
        hostId: HostRepository.localHostId,
        title: 't',
        titleSource: ChatTitleSource.user,
        createdAt: now,
        updatedAt: now,
        policyMode: PolicyMode.ask,
      ),
    );
  });

  tearDown(() => db.close());

  Future<Chat> fresh() async => (await chats.chat('c1'))!;

  test('user message seals the current revision and opens a child that inherits it', () async {
    final root = await service.current(await fresh());
    await service.mutate(await fresh(), (rev) => rev.goal = 'A');

    final moved = await service.onUserMessage(await fresh(), 'm1');
    final sealed = (await chats.revision(moved.sealedBefore))!;
    final opened = (await chats.revision(moved.opened))!;

    expect(sealed.sealed, isTrue);
    expect(sealed.goal, 'A');
    expect(opened.sealed, isFalse);
    expect(opened.parentId, root.id);
    expect(opened.triggeredByMessageId, 'm1');
    expect(opened.goal, 'A');
  });

  test('changes after a seal go only to the open revision', () async {
    await service.current(await fresh());
    await service.mutate(await fresh(), (rev) => rev.goal = 'A');
    final moved = await service.onUserMessage(await fresh(), 'm1');

    await service.mutate(await fresh(), (rev) => rev.goal = 'B');

    expect((await chats.revision(moved.sealedBefore))!.goal, 'A');
    expect((await chats.revision(moved.opened))!.goal, 'B');
  });

  test(
    'restoreBefore makes the snapshot taken before the message current again',
    () async {
      await service.current(await fresh());
      await service.mutate(await fresh(), (rev) => rev.goal = 'A');
      final moved = await service.onUserMessage(await fresh(), 'm1');
      await service.mutate(await fresh(), (rev) => rev.goal = 'C');
      final message = ChatMessage(
        id: 'm1',
        chatId: 'c1',
        seq: 1,
        role: MessageRole.user,
        createdAt: DateTime.now(),
        sealedBeforeRevisionId: moved.sealedBefore,
        openedRevisionId: moved.opened,
      );

      await service.restoreBefore(await fresh(), message);

      final current = (await chats.revision(
        (await fresh()).currentRevisionId!,
      ))!;
      expect(current.goal, 'A');
      expect(current.sealed, isFalse);
      expect(current.id, isNot(moved.sealedBefore));
    },
  );

  test('restoreAfter restores the revision opened by the message', () async {
    await service.current(await fresh());
    await service.mutate(await fresh(), (rev) => rev.goal = 'A');
    final moved = await service.onUserMessage(await fresh(), 'm1');
    await service.mutate(await fresh(), (rev) => rev.goal = 'C');
    await service.mutate(await fresh(), (rev) => rev.goal = 'D');
    final message = ChatMessage(
      id: 'm1',
      chatId: 'c1',
      seq: 1,
      role: MessageRole.user,
      createdAt: DateTime.now(),
      sealedBeforeRevisionId: moved.sealedBefore,
      openedRevisionId: moved.opened,
    );

    await service.restoreAfter(await fresh(), message);

    final current = (await chats.revision((await fresh()).currentRevisionId!))!;
    expect(current.goal, 'D');
    expect(current.parentId, moved.opened);
  });

  test('sealed index lists only sealed revisions', () async {
    await service.current(await fresh());
    expect(await service.sealedIndex('c1'), isEmpty);

    await service.onUserMessage(await fresh(), 'm1');

    expect(await service.sealedIndex('c1'), hasLength(1));
  });
}
