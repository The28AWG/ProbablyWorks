enum TaskStatus { idle, planning, active, done }

enum PlanItemStatus { pending, doing, done }

class PlanItem {
  const PlanItem({
    required this.id,
    required this.text,
    this.status = PlanItemStatus.pending,
  });

  factory PlanItem.fromJson(Map<String, dynamic> json) => PlanItem(
    id: json['id'] as String,
    text: json['text'] as String,
    status: PlanItemStatus.values.byName(json['status'] as String),
  );

  final String id;
  final String text;
  final PlanItemStatus status;

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'status': status.name,
  };
}

/// Факт — строка с id: id нужен для unpin и для UI.
class PinnedFact {
  const PinnedFact({
    required this.id,
    required this.text,
    required this.createdAt,
    this.source,
  });

  factory PinnedFact.fromJson(Map<String, dynamic> json) => PinnedFact(
    id: json['id'] as String,
    text: json['text'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    source: json['source'] as String?,
  );

  final String id;
  final String text;
  final DateTime createdAt;
  final String? source;

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'createdAt': createdAt.toIso8601String(),
    'source': source,
  };
}

/// Ревизия состояния задачи. Мутируется только незапечатанная (current) ревизия;
/// запечатанная — неизменяемый снимок «ДО» или «ПОСЛЕ» пользовательского сообщения.
class SessionStateRevision {
  SessionStateRevision({
    required this.id,
    required this.chatId,
    required this.createdAt,
    this.parentId,
    this.triggeredByMessageId,
    this.sealed = false,
    this.goal,
    this.taskStatus = TaskStatus.idle,
    List<PlanItem>? plan,
    List<PinnedFact>? pinnedFacts,
  }) : plan = plan ?? [],
       pinnedFacts = pinnedFacts ?? [];

  final String id;
  final String chatId;
  final String? parentId;
  final String? triggeredByMessageId;
  final DateTime createdAt;
  bool sealed;
  String? goal;
  TaskStatus taskStatus;
  List<PlanItem> plan;
  List<PinnedFact> pinnedFacts;

  /// Новая незапечатанная ревизия-наследник этой (fork).
  SessionStateRevision forkInto({
    required String newId,
    required String? triggeredBy,
    required DateTime at,
  }) => SessionStateRevision(
    id: newId,
    chatId: chatId,
    parentId: id,
    triggeredByMessageId: triggeredBy,
    createdAt: at,
    goal: goal,
    taskStatus: taskStatus,
    plan: [...plan],
    pinnedFacts: [...pinnedFacts],
  );

  /// Копия для восстановления после edit/truncate: текущая, но от снимка.
  SessionStateRevision restoreCopy({
    required String newId,
    required DateTime at,
  }) => forkInto(newId: newId, triggeredBy: null, at: at);

  Map<String, dynamic> stateToJson() => {
    'goal': goal,
    'taskStatus': taskStatus.name,
    'plan': [for (final p in plan) p.toJson()],
    'pinnedFacts': [for (final f in pinnedFacts) f.toJson()],
  };

  void applyStateJson(Map<String, dynamic> json) {
    goal = json['goal'] as String?;
    taskStatus = TaskStatus.values.byName(
      json['taskStatus'] as String? ?? 'idle',
    );
    plan = [
      for (final p in (json['plan'] as List? ?? const []))
        PlanItem.fromJson(p as Map<String, dynamic>),
    ];
    pinnedFacts = [
      for (final f in (json['pinnedFacts'] as List? ?? const []))
        PinnedFact.fromJson(f as Map<String, dynamic>),
    ];
  }

  /// Короткое описание для индекса прошлых ревизий в контексте модели.
  String summaryLine() =>
      '$id | ${taskStatus.name} | ${goal ?? '-'} | ${sealed ? 'sealed' : 'current'}';
}
