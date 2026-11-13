part of 'tool_executor.dart';

extension _ToolExecutorRead on ToolExecutor {
  // ---- read_file -----------------------------------------------------------

  /// Чтение с Host: путь проверяется до запуска. Чувствительные пути и чтение
  /// вне workspace требуют подтверждения, даже если политика разрешила инструмент.
  Future<ToolResult> _hostRead(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) {
    final path = _resolve(ctx, toolStringArg(args, 'path'));
    return _hostOp(
      ctx,
      call,
      args,
      _hostOpForRead(ctx, call, args, path),
      guardedPath: path,
      recursive: call.name == ToolNames.grep,
    );
  }

  /// Служебная read-операция для вызова. Путь уже разрешён относительно workspace.
  HostOp _hostOpForRead(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
    String path,
  ) => switch (call.name) {
    ToolNames.readFile => ReadFileOp(
      path,
      offset: _intArg(args, 'offset', min: 1, fallback: 1),
      byteOffset: _intArg(args, 'byte_offset', min: 0, fallback: 0),
      limit: _intArg(
        args,
        'limit',
        min: 1,
        max: ToolExecutor._maxReadLines,
        fallback: ToolExecutor._defaultReadLines,
      ),
      chunkBytes: math.min(
        math.max(
          ctx.limits.readFileChunkBytes,
          ToolExecutor._minReadChunkBytes,
        ),
        ctx.limits.toolOutputForModelChars ~/ 2,
      ),
      lineBytes: ctx.limits.readFileLineBytes,
    ),
    ToolNames.listDir => ListDirOp(path),
    ToolNames.grep => GrepOp(toolStringArg(args, 'pattern'), path),
    ToolNames.glob => GlobOp(toolStringArg(args, 'pattern'), path),
    ToolNames.statPath => StatOp(path),
    _ => throw ArgumentError.value(call.name, 'call.name', 'not a read tool'),
  };
}
