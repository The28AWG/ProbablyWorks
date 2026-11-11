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

  factory AgentProfile.local() => const AgentProfile(
    id: 'local',
    name: 'This computer',
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

String agentProfileTokenKey(String profileId) => 'agent.$profileId.token';
