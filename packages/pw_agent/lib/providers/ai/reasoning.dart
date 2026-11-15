import 'package:equatable/equatable.dart';

/// Уровень рассуждений, который реально уходит провайдеру.
///
/// Порядок значений важен: по нему выбирается ближайший поддерживаемый уровень
/// при понижении (см. [resolveReasoning]).
enum ReasoningEffort { none, minimal, low, medium, high, xhigh, max }

/// Выбор пользователя в чате или настройках.
///
/// [inherit] — следовать уровню по умолчанию из настроек. [auto] — не отправлять
/// поле и позволить провайдеру решить самому. Остальные значения — явный уровень.
enum ReasoningPreference {
  inherit,
  auto,
  none,
  minimal,
  low,
  medium,
  high,
  xhigh,
  max;

  /// Уровень для запроса. Null — поле не отправляется.
  ReasoningEffort? get effort => switch (this) {
    inherit || auto => null,
    none => ReasoningEffort.none,
    minimal => ReasoningEffort.minimal,
    low => ReasoningEffort.low,
    medium => ReasoningEffort.medium,
    high => ReasoningEffort.high,
    xhigh => ReasoningEffort.xhigh,
    max => ReasoningEffort.max,
  };

  /// Выбор из значения уровня. Нужен для настроек и для fallback.
  static ReasoningPreference fromEffort(ReasoningEffort? effort) =>
      switch (effort) {
        null => auto,
        ReasoningEffort.none => none,
        ReasoningEffort.minimal => minimal,
        ReasoningEffort.low => low,
        ReasoningEffort.medium => medium,
        ReasoningEffort.high => high,
        ReasoningEffort.xhigh => xhigh,
        ReasoningEffort.max => max,
      };

  /// Разбор значения из БД или настроек. Неизвестное значение — [auto].
  static ReasoningPreference parse(
    String? raw, {
    ReasoningPreference fallback = auto,
  }) => values.asNameMap()[raw] ?? fallback;
}

/// Возможности модели в отношении рассуждений.
///
/// [supported] == null означает «провайдер не сообщил». В этом случае UI
/// показывает общий набор уровней, а по умолчанию ничего не отправляет.
class LlmReasoningCapability extends Equatable {
  const LlmReasoningCapability({
    this.supported,
    this.efforts,
    this.defaultEffort,
    this.mandatory = false,
    this.supportsMaxTokens = false,
  });

  /// false — модель точно не умеет; true — умеет; null — неизвестно.
  final bool? supported;

  /// Поддерживаемые уровни. Null — список неизвестен, разрешён общий набор.
  final List<ReasoningEffort>? efforts;

  /// Уровень по умолчанию, если провайдер его сообщил.
  final ReasoningEffort? defaultEffort;

  /// true — отключить рассуждения нельзя, `none` будет отклонён.
  final bool mandatory;

  /// Модель принимает `reasoning.max_tokens` вместо/вместе с effort.
  final bool supportsMaxTokens;

  /// Можно ли выбрать «выключено». Для неизвестной возможности считаем, что можно:
  /// провайдер сам вернёт понятную ошибку, если уровень не подходит.
  bool get canDisable => supported != false && !mandatory;

  /// Уровни для UI: известный список или общий набор.
  List<ReasoningEffort> get selectableEfforts {
    if (supported == false) return const [];
    final known = efforts;
    if (known == null || known.isEmpty) return ReasoningEffort.values;
    return known;
  }

  /// Копия с заменёнными полями. Нужна каталогу при обновлении деталей.
  LlmReasoningCapability copyWith({
    bool? supported,
    List<ReasoningEffort>? efforts,
    ReasoningEffort? defaultEffort,
    bool? mandatory,
    bool? supportsMaxTokens,
  }) => LlmReasoningCapability(
    supported: supported ?? this.supported,
    efforts: efforts ?? this.efforts,
    defaultEffort: defaultEffort ?? this.defaultEffort,
    mandatory: mandatory ?? this.mandatory,
    supportsMaxTokens: supportsMaxTokens ?? this.supportsMaxTokens,
  );

  Map<String, Object?> toJson() => {
    'supported': supported,
    'efforts': efforts == null
        ? null
        : [for (final effort in efforts!) effort.name],
    'default': defaultEffort?.name,
    'mandatory': mandatory,
    'maxTokens': supportsMaxTokens,
  };

  /// Читает JSON. Повреждённые поля игнорируются, а не роняют каталог.
  static LlmReasoningCapability? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final supported = raw['supported'];
    final rawEfforts = raw['efforts'];
    final rawDefault = raw['default'];
    return LlmReasoningCapability(
      supported: supported is bool ? supported : null,
      efforts: rawEfforts is List
          ? [
              for (final item in rawEfforts)
                if (item is String) ReasoningEffort.values.asNameMap()[item],
            ].whereType<ReasoningEffort>().toList()
          : null,
      defaultEffort: rawDefault is String
          ? ReasoningEffort.values.asNameMap()[rawDefault]
          : null,
      mandatory: raw['mandatory'] == true,
      supportsMaxTokens: raw['maxTokens'] == true,
    );
  }

  @override
  List<Object?> get props => [
    supported,
    efforts,
    defaultEffort,
    mandatory,
    supportsMaxTokens,
  ];
}

/// Превращает выбор пользователя в уровень для запроса.
///
/// `inherit` и `auto` дают null: поле в тело запроса не попадает.
/// Для неизвестной возможности возвращается выбранный уровень: провайдер сам
/// сообщит, если он несовместим с моделью. Для известной — уровень понижается
/// до ближайшего поддерживаемого, а `none` у mandatory-модели заменяется
/// уровнем по умолчанию (или auto).
ReasoningEffort? resolveReasoning({
  required LlmReasoningCapability? capability,
  required ReasoningPreference preference,
}) {
  final requested = preference.effort;
  if (requested == null) return null;
  if (capability?.supported == false) return null;
  if (capability == null || capability.supported == null) return requested;
  if (requested == ReasoningEffort.none && capability.mandatory) {
    return capability.defaultEffort;
  }
  final allowed = capability.efforts;
  if (allowed == null || allowed.isEmpty) return requested;
  if (allowed.contains(requested)) return requested;
  // Понижаем до ближайшего поддерживаемого, не выше выбранного.
  for (var index = requested.index; index >= 0; index--) {
    final candidate = ReasoningEffort.values[index];
    if (allowed.contains(candidate)) return candidate;
  }
  // Ниже выбранного ничего нет: берём самый низкий из поддерживаемых.
  return allowed.reduce((a, b) => a.index <= b.index ? a : b);
}

/// Уровень по умолчанию для служебного вызова: `none`, если модель позволяет,
/// иначе `auto`. Нужен заголовкам и сжатию, чтобы не тратить токены зря и не
/// получать 400 от mandatory-моделей.
ReasoningEffort? resolveUtilityReasoning(LlmReasoningCapability? capability) {
  if (capability?.supported == false) return null;
  if (capability?.mandatory ?? false) return capability?.defaultEffort;
  return ReasoningEffort.none;
}
