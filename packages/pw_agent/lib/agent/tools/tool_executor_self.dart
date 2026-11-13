part of 'tool_executor.dart';

extension _ToolExecutorSelf on ToolExecutor {
  // ---- self tools --------------------------------------------------------

  Future<ToolResult> _selfTool(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    if (ToolExecutor._selfReadTools.contains(call.name)) {
      return ToolResult(await _self.read(call.name, args));
    }
    return _selfWrite(ctx, call, args);
  }

  Future<ToolResult> _selfWrite(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final change = await _self.prepare(call.name, args);
    final decision = ctx.policy.decide(call.name, args);
    if (decision == PolicyDecision.deny) {
      return _denied(ctx, call, args, 'denied by policy');
    }
    final bool needsApproval;
    final String reason;
    final keyPath = change.keyPath;
    // Лимиты меняют поведение самого агента: таймауты, параллелизм, размер контекста
    // и число шагов. Даже в авто-подтверждении это решение пользователя, а не побочный
    // эффект задачи.
    final limitsChange =
        call.name == ToolNames.settingsUpdate &&
        args['key'] == SettingsRepository.keyLimits;
    if (limitsChange) {
      needsApproval = true;
      reason = 'operational limits change how the agent runs';
    } else if (keyPath != null) {
      // Путь к ключу, который назвал пользователь, — его команда: подтверждение не нужно ни в Ask, ни в YOLO.
      // Путь, найденный агентом, может оказаться не тем ключом: спрашиваем всегда.
      final named = await _keyPathNamedByUser(ctx.chat.id, keyPath);
      needsApproval = !named;
      reason = 'key path was found by the agent, not named by you';
    } else {
      needsApproval = decision == PolicyDecision.ask;
      reason = ctx.policy.reasonFor(call.name, args);
    }
    // Один id на всю жизнь записи: карточка подтверждения и итоговая строка журнала.
    final runId = ToolExecutor._uuid.v4();
    if (needsApproval) {
      final approved = await _approve(
        ctx,
        call,
        args,
        runId: runId,
        summary: change.summary,
        command: change.summary,
        reason: reason,
        allowStoredGrant: !limitsChange,
      );
      if (!approved.allowed) {
        return _rejected(change.summary, reason: approved.reason);
      }
    }
    final String text;
    try {
      text = await change.apply();
    } on Object catch (error) {
      return ToolResult('${call.name} failed: $error', isError: true);
    }
    await _saveRun(
      _newRun(
        ctx,
        runId,
        call,
        args,
        ToolRunStatus.done,
        command: change.summary,
        finishedAt: DateTime.now(),
      ).copyWith(resultPreview: previewToolText(text)),
    );
    return ToolResult(text);
  }

  /// Дословное вхождение пути в сообщения пользователя этого чата. Текст модели и файлов сюда не входит.
  Future<bool> _keyPathNamedByUser(String chatId, String keyPath) async {
    final messages = await _chats.messages(chatId);
    return messages.any(
      (message) =>
          message.role == MessageRole.user && message.text.contains(keyPath),
    );
  }
}
