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

  test('draft and message edits keep independent revisions', () async {
    final draftRevision = await chats.saveDraft(
      'c1',
      const ChatDraft(text: 'one'),
      expectedRevision: 0,
    );
    final editRevision = await chats.saveMessageEdits('c1', {
      'm1': const ChatDraft(text: 'edit'),
    }, expectedRevision: 0);

    expect(draftRevision, 1);
    expect(editRevision, 1);
    final saved = (await chats.chat('c1'))!;
    expect(saved.draftRevision, 1);
    expect(saved.messageEditsRevision, 1);

    await chats.saveDraft(
      'c1',
      const ChatDraft(text: 'two'),
      expectedRevision: 1,
    );
    await chats.saveMessageEdits('c1', {
      'm1': const ChatDraft(text: 'edit 2'),
    }, expectedRevision: 1);
    final after = (await chats.chat('c1'))!;
    expect(after.draftRevision, 2);
    expect(after.messageEditsRevision, 2);
  });

  test(
    'updateChat changes only requested fields and checks revision',
    () async {
      final updated = await chats.updateChat(
        'c1',
        title: 'Новый',
        expectedRevision: 0,
      );
      expect(updated.title, 'Новый');
      expect(updated.revision, 1);

      await expectLater(
        chats.updateChat('c1', model: 'model/x', expectedRevision: 0),
        throwsA(
          isA<AgentApiException>().having(
            (error) => error.code,
            'code',
            'chat_conflict',
          ),
        ),
      );

      final saved = await chats.updateChat(
        'c1',
        model: 'model/x',
        expectedRevision: 1,
      );
      expect(saved.title, 'Новый');
      expect(saved.model, 'model/x');
      expect(saved.revision, 2);
      expect(saved.draftRevision, 0);
      expect(saved.messageEditsRevision, 0);
    },
  );

  test('a draft conflict keeps local and remote versions', () async {
    final base = (await chats.chat('c1'))!;
    drafts.prime('c1', base);
    final other = ChatDraftStore(chats)..prime('c1', base);

    drafts.update('c1', const ChatDraft(text: 'local'));
    other.update('c1', const ChatDraft(text: 'remote'));
    await other.flush();
    await drafts.flush();

    final conflict = drafts.conflictFor('c1');
    expect(conflict, isNotNull);
    expect(conflict!.local?.text, 'local');
    expect(conflict.remote?.text, 'remote');
    expect(drafts.of('c1').text, 'local');

    drafts.acceptRemote('c1');
    expect(drafts.of('c1').text, 'remote');
    expect(drafts.conflictFor('c1'), isNull);
  });

  test('keeping the local draft resolves the conflict', () async {
    final base = (await chats.chat('c1'))!;
    drafts.prime('c1', base);
    final other = ChatDraftStore(chats)..prime('c1', base);

    drafts.update('c1', const ChatDraft(text: 'local'));
    other.update('c1', const ChatDraft(text: 'remote'));
    await other.flush();
    await drafts.flush();
    expect(drafts.conflictFor('c1'), isNotNull);

    await drafts.keepLocal('c1');
    expect((await chats.chat('c1'))!.draft.text, 'local');
    expect(drafts.conflictFor('c1'), isNull);
  });

  test(
    'remote message edits apply while the composer draft is dirty',
    () async {
      final base = (await chats.chat('c1'))!;
      drafts
        ..prime('c1', base)
        ..update('c1', const ChatDraft(text: 'local draft'));

      final remote = base.copyWith(
        messageEditsRevision: 1,
        messageEdits: {'m1': const ChatDraft(text: 'remote edit')},
      );

      expect(drafts.applyRemote('c1', remote), isTrue);
      expect(drafts.of('c1').text, 'local draft');
      expect(drafts.editOf('c1', 'm1')?.text, 'remote edit');
    },
  );

  test('remote draft applies while message edits are dirty', () async {
    final base = (await chats.chat('c1'))!;
    drafts
      ..prime('c1', base)
      ..updateEdit('c1', 'm1', const ChatDraft(text: 'local edit'));

    final remote = base.copyWith(
      draftRevision: 1,
      draft: const ChatDraft(text: 'remote draft'),
    );

    expect(drafts.applyRemote('c1', remote), isTrue);
    expect(drafts.of('c1').text, 'remote draft');
    expect(drafts.editOf('c1', 'm1')?.text, 'local edit');
  });

  test('a draft and a message-edit conflict are both kept', () async {
    final base = (await chats.chat('c1'))!;
    drafts.prime('c1', base);
    final other = ChatDraftStore(chats)..prime('c1', base);

    drafts
      ..update('c1', const ChatDraft(text: 'local draft'))
      ..updateEdit('c1', 'm1', const ChatDraft(text: 'local edit'));
    other
      ..update('c1', const ChatDraft(text: 'remote draft'))
      ..updateEdit('c1', 'm1', const ChatDraft(text: 'remote edit'));
    await other.flush();
    await drafts.flush();

    expect(drafts.conflictFor('c1')?.kind, DraftConflictKind.draft);
    drafts.acceptRemote('c1', kind: DraftConflictKind.draft);
    expect(drafts.conflictFor('c1')?.kind, DraftConflictKind.messageEdits);
    drafts.acceptRemote('c1', kind: DraftConflictKind.messageEdits);
    expect(drafts.conflictFor('c1'), isNull);
    expect(drafts.of('c1').text, 'remote draft');
    expect(drafts.editOf('c1', 'm1')?.text, 'remote edit');
  });

  test('a message edit conflict keeps both maps separately', () async {
    final base = (await chats.chat('c1'))!;
    drafts.prime('c1', base);
    final other = ChatDraftStore(chats)..prime('c1', base);

    drafts.updateEdit('c1', 'm1', const ChatDraft(text: 'local'));
    other.updateEdit('c1', 'm1', const ChatDraft(text: 'remote'));
    await other.flush();
    await drafts.flush();

    final conflict = drafts.conflictFor('c1');
    expect(conflict?.kind, DraftConflictKind.messageEdits);
    expect(conflict?.localEdits?['m1']?.text, 'local');
    expect(conflict?.remoteEdits?['m1']?.text, 'remote');

    drafts.acceptRemote('c1');
    expect(drafts.editOf('c1', 'm1')?.text, 'remote');
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

  test('mentions of a draft survive a database round-trip', () async {
    await drafts.flush();
    drafts.update(
      'c1',
      const ChatDraft(
        text: 'смотри @app.dart',
        mentions: [
          MentionRef(
            kind: MentionKind.file,
            path: 'src/app.dart',
            start: 7,
            end: 16,
          ),
        ],
      ),
    );
    await drafts.flush();

    final saved = (await chats.chat('c1'))!.draft.mentions.single;
    expect(saved.path, 'src/app.dart');
    expect(saved.kind, MentionKind.file);
    expect(saved.start, 7);
    expect(saved.end, 16);
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
