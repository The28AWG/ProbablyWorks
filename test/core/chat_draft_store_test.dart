import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/core/data/chat_draft_store.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/security/secret_store.dart';

void main() {
  late AppDatabase db;
  late ChatRepository chats;
  late ChatDraftStore drafts;
  final now = DateTime(2026, 11, 2, 12);

  setUp(() async {
    db = openInMemoryDatabase();
    chats = ChatRepository(db);
    drafts = ChatDraftStore(chats);
    await HostRepository(db, MemorySecretStore()).ensureLocalHost(now);
    await chats.saveChat(
      Chat(
        id: 'c1',
        hostId: 'local',
        title: 'Первый',
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  tearDown(() async {
    await drafts.flush();
    await db.close();
  });

  test('a typed draft is saved to the database after a short pause', () async {
    drafts.update('c1', const ChatDraft(text: 'набираю'));

    // Пока пользователь печатает, запись откладывается.
    expect((await chats.chat('c1'))!.draft.text, isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect((await chats.chat('c1'))!.draft.text, 'набираю');
  });

  test(
    'saving a draft keeps the chat position: updatedAt does not change',
    () async {
      await drafts.flush();
      drafts.update('c1', const ChatDraft(text: 'черновик'));
      await drafts.flush();

      final saved = (await chats.chat('c1'))!;
      expect(saved.draft.text, 'черновик');
      expect(saved.updatedAt, now);
    },
  );

  test('a draft change does not re-emit the chat list', () async {
    final emissions = <List<Chat>>[];
    final sub = chats.watchChats().listen(emissions.add);
    addTearDown(sub.cancel);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    drafts.update('c1', const ChatDraft(text: 'набираю'));
    await drafts.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // Только первая загрузка: набор черновика список не перерисовывает.
    expect(emissions, hasLength(1));

    // Настоящее изменение чата список обновляет, и черновик в нём уже актуален.
    await chats.saveChat((await chats.chat('c1'))!.copyWith(title: 'Новый'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(emissions, hasLength(2));
    expect(emissions.last.single.title, 'Новый');
    expect(emissions.last.single.draft.text, 'набираю');
  });

  test('rejects a stale draft revision', () async {
    final first = await chats.saveDraft(
      'c1',
      const ChatDraft(text: 'one'),
      expectedRevision: 0,
    );
    expect(first, 1);

    await expectLater(
      chats.saveDraft(
        'c1',
        const ChatDraft(text: 'stale'),
        expectedRevision: 0,
      ),
      throwsA(
        isA<AgentApiException>().having(
          (error) => error.code,
          'code',
          'draft_conflict',
        ),
      ),
    );
  });

  test('attachments of a draft are stored redacted', () async {
    await drafts.flush();
    drafts.update(
      'c1',
      const ChatDraft(
        attachments: [
          AttachmentRef(
            name: 'env.txt',
            mode: AttachmentMode.attach,
            content: 'token=sk-secret-value-123456789',
          ),
        ],
      ),
    );
    await drafts.flush();

    final saved = (await chats.chat('c1'))!.draft.attachments.single;
    expect(saved.name, 'env.txt');
    expect(saved.content, isNot(contains('sk-secret-value-123456789')));
  });

  test('moving a draft copies it and clears the source', () async {
    await chats.saveChat(
      Chat(
        id: 'c2',
        hostId: 'local',
        title: 'Второй',
        createdAt: now,
        updatedAt: now,
      ),
    );
    drafts.update('c1', const ChatDraft(text: 'перенести'));

    await drafts.move('c1', 'c2');

    expect((await chats.chat('c2'))!.draft.text, 'перенести');
    expect((await chats.chat('c1'))!.draft.isEmpty, isTrue);
  });

  test('a discarded chat draft is not written afterwards', () async {
    drafts
      ..update('c1', const ChatDraft(text: 'удалённый'))
      ..discard('c1');
    await drafts.flush();

    expect((await chats.chat('c1'))!.draft.isEmpty, isTrue);
  });

  test('of() reads from memory first and falls back to the stored chat', () {
    final stored = Chat(
      id: 'c1',
      hostId: 'local',
      title: 'Первый',
      createdAt: now,
      updatedAt: now,
      draft: const ChatDraft(text: 'из записи'),
    );
    expect(drafts.of('c1', fallback: stored).text, 'из записи');

    drafts.update('c1', const ChatDraft(text: 'из памяти'));
    expect(drafts.of('c1', fallback: stored).text, 'из памяти');
  });

  test(
    'a message edit is saved without moving the chat and keeps empty text',
    () async {
      await drafts.flush();
      drafts.updateEdit('c1', 'm1', const ChatDraft());
      expect((await chats.chat('c1'))!.messageEdits, isEmpty);

      await drafts.flush();
      final saved = (await chats.chat('c1'))!;
      expect(saved.messageEdits['m1']?.text, isEmpty);
      expect(saved.updatedAt, now);

      drafts.updateEdit('c1', 'm1', const ChatDraft(text: 'правка'));
      await drafts.flush();
      expect((await chats.chat('c1'))!.messageEdits['m1']?.text, 'правка');
      expect((await chats.chat('c1'))!.updatedAt, now);
    },
  );

  test('a message edit does not re-emit the chat list', () async {
    final emissions = <List<Chat>>[];
    final sub = chats.watchChats().listen(emissions.add);
    addTearDown(sub.cancel);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    drafts.updateEdit('c1', 'm1', const ChatDraft(text: 'правка'));
    await drafts.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(emissions, hasLength(1));
  });

  test('message edit attachments are stored redacted', () async {
    await drafts.flush();
    drafts.updateEdit(
      'c1',
      'm1',
      const ChatDraft(
        attachments: [
          AttachmentRef(
            name: 'env.txt',
            mode: AttachmentMode.attach,
            content: 'token=sk-secret-value-123456789',
          ),
        ],
      ),
    );
    await drafts.flush();

    final saved = (await chats.chat('c1'))!
        .messageEdits['m1']!
        .attachments
        .single;
    expect(saved.name, 'env.txt');
    expect(saved.content, isNot(contains('sk-secret-value-123456789')));
  });

  test('removing a message edit drops it', () async {
    drafts
      ..updateEdit('c1', 'm1', const ChatDraft(text: 'правка'))
      ..removeEdit('c1', 'm1');
    await drafts.flush();
    expect((await chats.chat('c1'))!.messageEdits, isEmpty);
  });

  test('discarding a chat drops its message edits', () async {
    drafts
      ..updateEdit('c1', 'm1', const ChatDraft(text: 'ещё'))
      ..discard('c1');
    await drafts.flush();
    expect((await chats.chat('c1'))!.messageEdits, isEmpty);
  });
}
