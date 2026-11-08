import 'package:injectable/injectable.dart';
import 'package:logging/logging.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/exec/exec_log_store.dart';
import 'package:probably_works/core/config/app_limits.dart';
import 'package:probably_works/core/data/chat_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:uuid/uuid.dart';

/// Восстановление после аварийного завершения: запуски команд, которые не дошли до финала,
/// помечаются interrupted, их логи переносятся в БД, осиротевшие файлы удаляются.
///
/// Вопрос и подтверждение не прерываются. Нет ответа в базе — карточка ещё нужна,
/// но этот класс её не показывает: открытие чата регистрирует карточку в брокере.
/// Продолжение самих вызовов (результат прерванного процесса и независимая работа)
/// запускает AgentHub.resumeAfterRestart следом, не дожидаясь открытия.
/// Остановка хода и явный отказ записывают другой статус ещё в живом процессе,
/// поэтому сюда они не попадают.
@lazySingleton
class StartupRecovery {
  StartupRecovery(this._chats, this._logs, this._settings);

  final ChatRepository _chats;
  final ExecLogStore _logs;
  final SettingsRepository _settings;

  final _log = Logger('StartupRecovery');

  static const _uuid = Uuid();

  /// [closedText] — событие в чате (на языке интерфейса): запуск прервали при закрытии приложения.
  Future<int> run({required String closedText}) async {
    final limits = await _settings.limits();
    final active = await _chats.allActiveRuns();
    // Ожидание пользователя — не оборванный процесс. Статус остаётся, пока не будет ответа.
    final runs = [
      for (final run in active)
        if (run.status != ToolRunStatus.waitingApproval &&
            run.status != ToolRunStatus.waitingUser)
          run,
    ];
    for (final run in runs) {
      await _finalize(run, limits);
    }
    // Одно событие на чат, даже если в нём несколько прерванных запусков.
    // Неотвеченная карточка события не порождает: её ход ещё не закончен.
    final chats = {for (final run in runs) run.chatId};
    for (final chatId in chats) {
      final seq = await _chats.nextSeq(chatId);
      await _chats.insertMessage(
        ChatMessage(
          id: _uuid.v4(),
          chatId: chatId,
          seq: seq,
          role: MessageRole.event,
          createdAt: DateTime.now(),
          text: closedText,
        ),
      );
    }
    final removed = await _logs.gcUnreferenced({});
    if (runs.isNotEmpty || removed > 0) {
      _log.info(
        'recovered ${runs.length} interrupted runs, removed $removed orphan logs',
      );
    }
    return runs.length;
  }

  Future<void> _finalize(ToolRun run, AppLimits limits) async {
    var outputText = run.outputText ?? '';
    var truncated = run.outputTruncated;
    final logPath = run.logPath;
    if (logPath != null) {
      final compacted = await _logs.compactToDb(
        logPath,
        maxBytes: limits.logOutputDbBytes,
      );
      outputText = compacted.text;
      truncated = truncated || compacted.truncated;
    }
    await _chats.saveToolRun(
      run.copyWith(
        status: ToolRunStatus.interrupted,
        outputText: outputText,
        outputTruncated: truncated,
        resultPreview:
            'interrupted: the application was closed while the run was active',
        finishedAt: DateTime.now(),
        clearLogPath: true,
      ),
    );
  }
}
