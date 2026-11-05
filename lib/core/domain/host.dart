/// Тип Host. `virtual` — песочница: файлы в базе приложения, команды интерпретирует сам агент (см. `lib/host/virtual`).
enum HostKind { local, ssh, virtual }

/// Семейство shell-диалекта Host: по нему ShellAdapter выбирает команды. Это не конкретная ОС:
/// `posix` объединяет все POSIX-совместимые системы. Виртуальный Host использует `posix`.
enum HostOs { posix, macos, windows, unknown }

enum SshAuthType { password, key }

/// Удалённый Host по умолчанию, когда локального нет (iOS): сначала SSH, иначе виртуальный. Виртуальный
/// доступен всегда, поэтому без SSH он остаётся рабочим вариантом, а не пустым списком. Null — хостов нет.
Host? preferredRemoteHost(Iterable<Host> hosts) {
  Host? virtual;
  for (final host in hosts) {
    if (host.kind == HostKind.ssh) return host;
    if (host.kind == HostKind.virtual) virtual ??= host;
  }
  return virtual;
}

/// Машина, на которой работает агент: локальная или удалённая через SSH.
class Host {
  const Host({
    required this.id,
    required this.name,
    required this.kind,
    required this.createdAt,
    required this.updatedAt,
    this.address,
    this.port = 22,
    this.username,
    this.authType = SshAuthType.key,
    this.keyPath,
    this.hostKeyFingerprint,
    this.os = HostOs.posix,
    this.defaultWorkspace,
    this.shellOverride,
    this.notes,
    this.connectTimeoutSeconds,
    this.lastCheckAt,
    this.lastLatencyMs,
    this.lastCheckError,
  });

  final String id;
  final String name;
  final HostKind kind;
  final String? address;
  final int port;
  final String? username;
  final SshAuthType authType;
  final String? keyPath;
  final String? hostKeyFingerprint;
  final HostOs os;
  final String? defaultWorkspace;
  final String? shellOverride;
  final String? notes;

  /// Таймаут подключения SSH для этого Host; null — лимит из Settings.
  final int? connectTimeoutSeconds;

  /// Результат последней проверки подключения (хранится, чтобы список показывал его после перезапуска).
  final DateTime? lastCheckAt;
  final int? lastLatencyMs;
  final String? lastCheckError;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isLocal => kind == HostKind.local;

  Host copyWith({
    String? id,
    String? name,
    HostKind? kind,
    String? address,
    int? port,
    String? username,
    SshAuthType? authType,
    String? keyPath,
    String? hostKeyFingerprint,
    bool clearHostKeyFingerprint = false,
    HostOs? os,
    String? defaultWorkspace,
    String? shellOverride,
    String? notes,
    int? connectTimeoutSeconds,
    DateTime? lastCheckAt,
    int? lastLatencyMs,
    String? lastCheckError,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => Host(
    id: id ?? this.id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? DateTime.now(),
    address: address ?? this.address,
    port: port ?? this.port,
    username: username ?? this.username,
    authType: authType ?? this.authType,
    keyPath: keyPath ?? this.keyPath,
    hostKeyFingerprint: clearHostKeyFingerprint
        ? null
        : (hostKeyFingerprint ?? this.hostKeyFingerprint),
    os: os ?? this.os,
    defaultWorkspace: defaultWorkspace ?? this.defaultWorkspace,
    shellOverride: shellOverride ?? this.shellOverride,
    notes: notes ?? this.notes,
    connectTimeoutSeconds: connectTimeoutSeconds ?? this.connectTimeoutSeconds,
    lastCheckAt: lastCheckAt ?? this.lastCheckAt,
    lastLatencyMs: lastLatencyMs ?? this.lastLatencyMs,
    lastCheckError: lastCheckError ?? this.lastCheckError,
  );
}
