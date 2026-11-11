import 'dart:convert';

/// Единая таблица лимитов и таймаутов. Дефолты можно переопределить в Settings;
/// жёсткие защиты (Policy, host key) настройками не отключаются.
class AppLimits {
  const AppLimits({
    this.foregroundExecTimeout = const Duration(minutes: 10),
    this.backgroundMaxRuntime = const Duration(hours: 2),
    this.maxParallelExecPerHost = 4,
    this.sshConnectTimeout = const Duration(seconds: 15),
    this.sshKeepAlive = const Duration(seconds: 30),
    this.toolOutputForModelChars = 60000,
    this.readFileChunkBytes = 20000,
    this.readFileLineBytes = 2000,
    this.logOutputDbBytes = 1024 * 1024,
    this.attachmentMaxBytes = 256 * 1024,
    this.attachmentsPerMessage = 8,
    this.maxAgentSteps = 25,
    this.streamWatchdog = const Duration(seconds: 60),
    this.killGrace = const Duration(seconds: 5),
    this.sshIdleClose = const Duration(minutes: 5),
    this.softContextRatio = 0.7,
    this.hardContextRatio = 0.9,
    this.contextReserveTokens = 8000,
    this.recentWindowMessages = 40,
  });

  /// Строгий разбор для Settings: неизвестные ключи игнорируются, неверные значения — FormatException.
  factory AppLimits.parse(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('expected a JSON object');
    }
    int? intOf(String key) {
      final value = decoded[key];
      if (value == null) return null;
      if (value is! num || value <= 0 || value != value.toInt()) {
        throw FormatException('$key must be a positive integer');
      }
      return value.toInt();
    }

    /// Необязательное неотрицательное целое: ноль допустим, например чтобы
    /// отключить резерв под ответ.
    int? nonNegativeIntOf(String key) {
      final value = decoded[key];
      if (value == null) return null;
      if (value is! num || value < 0 || value != value.toInt()) {
        throw FormatException('$key must be a non-negative integer');
      }
      return value.toInt();
    }

    Duration? secondsOf(String key) {
      final value = intOf(key);
      return value == null ? null : Duration(seconds: value);
    }

    /// Доля окна: строго между 0 и 1. Значения вне диапазона — ошибка настроек.
    double? ratioOf(String key) {
      final value = decoded[key];
      if (value == null) return null;
      if (value is! num || value <= 0 || value >= 1) {
        throw FormatException('$key must be between 0 and 1');
      }
      return value.toDouble();
    }

    final d = defaults;
    final softContextRatio = ratioOf('softContextRatio') ?? d.softContextRatio;
    final hardContextRatio = ratioOf('hardContextRatio') ?? d.hardContextRatio;
    if (softContextRatio > hardContextRatio) {
      throw const FormatException(
        'softContextRatio must not exceed hardContextRatio',
      );
    }
    return AppLimits(
      foregroundExecTimeout:
          secondsOf('foregroundExecTimeoutSeconds') ?? d.foregroundExecTimeout,
      backgroundMaxRuntime:
          secondsOf('backgroundMaxRuntimeSeconds') ?? d.backgroundMaxRuntime,
      maxParallelExecPerHost:
          intOf('maxParallelExecPerHost') ?? d.maxParallelExecPerHost,
      sshConnectTimeout:
          secondsOf('sshConnectTimeoutSeconds') ?? d.sshConnectTimeout,
      sshKeepAlive: secondsOf('sshKeepAliveSeconds') ?? d.sshKeepAlive,
      sshIdleClose: secondsOf('sshIdleCloseSeconds') ?? d.sshIdleClose,
      toolOutputForModelChars:
          intOf('toolOutputForModelChars') ?? d.toolOutputForModelChars,
      readFileChunkBytes: intOf('readFileChunkBytes') ?? d.readFileChunkBytes,
      readFileLineBytes: intOf('readFileLineBytes') ?? d.readFileLineBytes,
      logOutputDbBytes: intOf('logOutputDbBytes') ?? d.logOutputDbBytes,
      attachmentMaxBytes: intOf('attachmentMaxBytes') ?? d.attachmentMaxBytes,
      attachmentsPerMessage:
          intOf('attachmentsPerMessage') ?? d.attachmentsPerMessage,
      maxAgentSteps: intOf('maxAgentSteps') ?? d.maxAgentSteps,
      streamWatchdog: secondsOf('streamWatchdogSeconds') ?? d.streamWatchdog,
      killGrace: secondsOf('killGraceSeconds') ?? d.killGrace,
      softContextRatio: softContextRatio,
      hardContextRatio: hardContextRatio,
      contextReserveTokens:
          nonNegativeIntOf('contextReserveTokens') ?? d.contextReserveTokens,
      recentWindowMessages:
          intOf('recentWindowMessages') ?? d.recentWindowMessages,
    );
  }

  /// Для старта: повреждённый JSON в БД не ломает приложение, берутся значения по умолчанию.
  factory AppLimits.fromJson(String? raw) {
    if (raw == null || raw.isEmpty) return defaults;
    try {
      return AppLimits.parse(raw);
    } on FormatException {
      return defaults;
    }
  }

  static const defaults = AppLimits();

  final Duration foregroundExecTimeout;
  final Duration backgroundMaxRuntime;
  final int maxParallelExecPerHost;
  final Duration sshConnectTimeout;
  final Duration sshKeepAlive;
  final int toolOutputForModelChars;

  /// Максимум байтов текста за один вызов read_file.
  final int readFileChunkBytes;

  /// Максимум байтов одной строки за один вызов read_file; остаток читается через byte_offset.
  final int readFileLineBytes;
  final int logOutputDbBytes;
  final int attachmentMaxBytes;
  final int attachmentsPerMessage;
  final int maxAgentSteps;
  final Duration streamWatchdog;
  final Duration killGrace;
  final Duration sshIdleClose;
  final double softContextRatio;
  final double hardContextRatio;
  final int contextReserveTokens;
  final int recentWindowMessages;

  AppLimits copyWith({
    Duration? foregroundExecTimeout,
    Duration? backgroundMaxRuntime,
    int? maxParallelExecPerHost,
    Duration? sshConnectTimeout,
    Duration? sshKeepAlive,
    int? toolOutputForModelChars,
    int? readFileChunkBytes,
    int? readFileLineBytes,
    int? logOutputDbBytes,
    int? attachmentMaxBytes,
    int? attachmentsPerMessage,
    int? maxAgentSteps,
    Duration? streamWatchdog,
    Duration? killGrace,
    Duration? sshIdleClose,
    double? softContextRatio,
    double? hardContextRatio,
    int? contextReserveTokens,
    int? recentWindowMessages,
  }) => AppLimits(
    foregroundExecTimeout: foregroundExecTimeout ?? this.foregroundExecTimeout,
    backgroundMaxRuntime: backgroundMaxRuntime ?? this.backgroundMaxRuntime,
    maxParallelExecPerHost:
        maxParallelExecPerHost ?? this.maxParallelExecPerHost,
    sshConnectTimeout: sshConnectTimeout ?? this.sshConnectTimeout,
    sshKeepAlive: sshKeepAlive ?? this.sshKeepAlive,
    toolOutputForModelChars:
        toolOutputForModelChars ?? this.toolOutputForModelChars,
    readFileChunkBytes: readFileChunkBytes ?? this.readFileChunkBytes,
    readFileLineBytes: readFileLineBytes ?? this.readFileLineBytes,
    logOutputDbBytes: logOutputDbBytes ?? this.logOutputDbBytes,
    attachmentMaxBytes: attachmentMaxBytes ?? this.attachmentMaxBytes,
    attachmentsPerMessage: attachmentsPerMessage ?? this.attachmentsPerMessage,
    maxAgentSteps: maxAgentSteps ?? this.maxAgentSteps,
    streamWatchdog: streamWatchdog ?? this.streamWatchdog,
    killGrace: killGrace ?? this.killGrace,
    sshIdleClose: sshIdleClose ?? this.sshIdleClose,
    softContextRatio: softContextRatio ?? this.softContextRatio,
    hardContextRatio: hardContextRatio ?? this.hardContextRatio,
    contextReserveTokens: contextReserveTokens ?? this.contextReserveTokens,
    recentWindowMessages: recentWindowMessages ?? this.recentWindowMessages,
  );

  /// Переопределяемые значения для JSON в Settings. Длительности — в секундах.
  Map<String, Object> toMap() => {
    'foregroundExecTimeoutSeconds': foregroundExecTimeout.inSeconds,
    'backgroundMaxRuntimeSeconds': backgroundMaxRuntime.inSeconds,
    'maxParallelExecPerHost': maxParallelExecPerHost,
    'sshConnectTimeoutSeconds': sshConnectTimeout.inSeconds,
    'sshKeepAliveSeconds': sshKeepAlive.inSeconds,
    'sshIdleCloseSeconds': sshIdleClose.inSeconds,
    'toolOutputForModelChars': toolOutputForModelChars,
    'readFileChunkBytes': readFileChunkBytes,
    'readFileLineBytes': readFileLineBytes,
    'logOutputDbBytes': logOutputDbBytes,
    'attachmentMaxBytes': attachmentMaxBytes,
    'attachmentsPerMessage': attachmentsPerMessage,
    'maxAgentSteps': maxAgentSteps,
    'streamWatchdogSeconds': streamWatchdog.inSeconds,
    'killGraceSeconds': killGrace.inSeconds,
    'softContextRatio': softContextRatio,
    'hardContextRatio': hardContextRatio,
    'contextReserveTokens': contextReserveTokens,
    'recentWindowMessages': recentWindowMessages,
  };

  String toJson() => jsonEncode(toMap());
}
