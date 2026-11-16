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
    this.attachmentInlineChars = 4000,
    this.maxAgentSteps = 500,
    this.economicalMaxAgentSteps = 40,
    this.maxTurnTokens = 0,
    this.maxTurnCostUsd = 0,
    this.turnMaxWallClock = Duration.zero,
    this.progressRepeatLimit = 3,
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

    /// Необязательное неотрицательное число: ноль отключает бюджет.
    double? nonNegativeDoubleOf(String key) {
      final value = decoded[key];
      if (value == null) return null;
      if (value is! num || value < 0) {
        throw FormatException('$key must be a non-negative number');
      }
      return value.toDouble();
    }

    Duration? secondsOf(String key) {
      final value = intOf(key);
      return value == null ? null : Duration(seconds: value);
    }

    /// Как [secondsOf], но ноль допустим: он отключает ограничение.
    Duration? nonNegativeSecondsOf(String key) {
      final value = nonNegativeIntOf(key);
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
      attachmentInlineChars:
          intOf('attachmentInlineChars') ?? d.attachmentInlineChars,
      maxAgentSteps: nonNegativeIntOf('maxAgentSteps') ?? d.maxAgentSteps,
      economicalMaxAgentSteps:
          intOf('economicalMaxAgentSteps') ?? d.economicalMaxAgentSteps,
      maxTurnTokens: nonNegativeIntOf('maxTurnTokens') ?? d.maxTurnTokens,
      maxTurnCostUsd: nonNegativeDoubleOf('maxTurnCostUsd') ?? d.maxTurnCostUsd,
      turnMaxWallClock:
          nonNegativeSecondsOf('turnMaxWallClockSeconds') ?? d.turnMaxWallClock,
      progressRepeatLimit:
          intOf('progressRepeatLimit') ?? d.progressRepeatLimit,
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

  /// Сколько символов текстового вложения входит в контекст как превью.
  /// Остальное модель дочитывает через `read_run_output attachment=…`, иначе одно
  /// вложение могло бы занять всё окно: сжатие истории его не сокращает.
  final int attachmentInlineChars;

  /// Аварийный потолок шагов за ход. Ноль — без ограничения: работа
  /// ограничивается бюджетами хода и политикой провайдера.
  final int maxAgentSteps;

  /// Потолок шагов для провайдеров, у которых накладные расходы вызова
  /// не измеряются. Всегда конечный: для таких провайдеров шаг — единственный
  /// доступный прокси стоимости.
  final int economicalMaxAgentSteps;

  /// Суммарные prompt+completion токены за ход. Ноль — без ограничения.
  final int maxTurnTokens;

  /// Оценка стоимости хода в USD. Ноль — без ограничения.
  final double maxTurnCostUsd;

  /// Максимальная длительность хода. Ноль — без ограничения.
  final Duration turnMaxWallClock;

  /// Сколько раз подряд можно повторить одно и то же действие с тем же
  /// результатом, прежде чем ProgressGuard предупредит модель. Следующее
  /// повторение останавливает ход.
  final int progressRepeatLimit;

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
    int? attachmentInlineChars,
    int? maxAgentSteps,
    int? economicalMaxAgentSteps,
    int? maxTurnTokens,
    double? maxTurnCostUsd,
    Duration? turnMaxWallClock,
    int? progressRepeatLimit,
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
    attachmentInlineChars: attachmentInlineChars ?? this.attachmentInlineChars,
    maxAgentSteps: maxAgentSteps ?? this.maxAgentSteps,
    economicalMaxAgentSteps:
        economicalMaxAgentSteps ?? this.economicalMaxAgentSteps,
    maxTurnTokens: maxTurnTokens ?? this.maxTurnTokens,
    maxTurnCostUsd: maxTurnCostUsd ?? this.maxTurnCostUsd,
    turnMaxWallClock: turnMaxWallClock ?? this.turnMaxWallClock,
    progressRepeatLimit: progressRepeatLimit ?? this.progressRepeatLimit,
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
    'attachmentInlineChars': attachmentInlineChars,
    'maxAgentSteps': maxAgentSteps,
    'economicalMaxAgentSteps': economicalMaxAgentSteps,
    'maxTurnTokens': maxTurnTokens,
    'maxTurnCostUsd': maxTurnCostUsd,
    'turnMaxWallClockSeconds': turnMaxWallClock.inSeconds,
    'progressRepeatLimit': progressRepeatLimit,
    'streamWatchdogSeconds': streamWatchdog.inSeconds,
    'killGraceSeconds': killGrace.inSeconds,
    'softContextRatio': softContextRatio,
    'hardContextRatio': hardContextRatio,
    'contextReserveTokens': contextReserveTokens,
    'recentWindowMessages': recentWindowMessages,
  };

  String toJson() => jsonEncode(toMap());
}
