import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/exec/exec_log_store.dart';
import 'package:pw_agent/agent/recovery/startup_recovery.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/security/secret_store.dart';

void main() {
  test(
    'startup keeps an unanswered card and interrupts a live command',
    () async {
      final db = openInMemoryDatabase();
      final tmp = Directory.systemTemp.createTempSync('pw_recovery');
      addTearDown(() async {
        await db.close();
        tmp.deleteSync(recursive: true);
      });
      final chats = ChatRepository(db);
      final settings = SettingsRepository(db);
      await settings.preload();
      final hosts = HostRepository(db, MemorySecretStore());
      await hosts.ensureLocalHost(DateTime.now());
      final now = DateTime.now();
      await chats.saveChat(
        Chat(
          id: 'c',
          hostId: 'local',
          title: 't',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await chats.saveToolRun(
        ToolRun(
          id: 'run',
          chatId: 'c',
          messageId: 'm',
          toolName: 'run_command',
          argsJson: '{"command":"sleep 10"}',
          status: ToolRunStatus.running,
          startedAt: now,
        ),
      );
      await chats.saveToolRun(
        ToolRun(
          id: 'ask',
          chatId: 'c',
          messageId: 'm',
          toolName: 'ask_user',
          argsJson: '{"question":"color?"}',
          status: ToolRunStatus.waitingUser,
          startedAt: now,
          toolCallId: 'call',
        ),
      );

      final recovered = await StartupRecovery(
        chats,
        ExecLogStore(tmp),
        settings,
      ).run(closedText: 'closed');

      expect(recovered, 1);
      final runs = await chats.toolRunsForChat('c');
      expect(
        runs.singleWhere((run) => run.id == 'run').status,
        ToolRunStatus.interrupted,
      );
      expect(
        runs.singleWhere((run) => run.id == 'ask').status,
        ToolRunStatus.waitingUser,
      );
      final messages = await chats.messages('c');
      expect(messages.single.role, MessageRole.event);
      expect(messages.single.text, 'closed');
    },
  );
}
