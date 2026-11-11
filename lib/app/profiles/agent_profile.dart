/// Тип профиля агента.
enum AgentProfileKind { local, remote }

/// Подключение к агенту: встроенный локальный или удалённый сервер.
final class AgentProfile {
  const AgentProfile({
    required this.id,
    required this.name,
    required this.kind,
    this.baseUri,
  });

  factory AgentProfile.local([String id = 'local']) => AgentProfile(
    id: id,
    // Имя локального профиля локализуется в интерфейсе через localHostTitle.
    name: '',
    kind: AgentProfileKind.local,
  );

  factory AgentProfile.fromJson(Map<String, dynamic> json) => AgentProfile(
    id: '${json['id'] ?? ''}',
    name: '${json['name'] ?? ''}',
    kind: AgentProfileKind.values.byName('${json['kind'] ?? 'remote'}'),
    baseUri: json['baseUri'] is String
        ? Uri.tryParse(json['baseUri'] as String)
        : null,
  );

  AgentProfile copyWith({
    String? id,
    String? name,
    AgentProfileKind? kind,
    Uri? baseUri,
  }) => AgentProfile(
    id: id ?? this.id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    baseUri: baseUri ?? this.baseUri,
  );

  final String id;
  final String name;
  final AgentProfileKind kind;

  /// Корень удалённого сервера; у локального профиля null.
  final Uri? baseUri;

  bool get isLocal => kind == AgentProfileKind.local;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'baseUri': baseUri?.toString(),
  };
}

/// Профили лежат в клиентской настройке; токены — в SecretStore.
const String agentProfilesKey = 'agentProfiles';
const String activeAgentProfileKey = 'activeAgentProfile';
const String localAgentProfileKey = 'localAgentProfileId';

String agentProfileTokenKey(String profileId) => 'agent.$profileId.token';
