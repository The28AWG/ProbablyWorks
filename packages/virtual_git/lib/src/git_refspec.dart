// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
final class GitRefSpec {
  const GitRefSpec({this.force = false, this.source, this.destination});

  factory GitRefSpec.parse(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(value, 'value', 'Refspec must not be empty.');
    }

    final force = trimmed.startsWith('+');
    final rawSpec = force ? trimmed.substring(1) : trimmed;
    final separatorIndex = rawSpec.indexOf(':');
    final source = separatorIndex == -1
        ? rawSpec
        : rawSpec.substring(0, separatorIndex);
    final destination = separatorIndex == -1
        ? null
        : rawSpec.substring(separatorIndex + 1);
    final normalizedSource = source.isEmpty ? null : source;
    final normalizedDestination = destination == null || destination.isEmpty
        ? null
        : destination;
    if (normalizedSource == null && normalizedDestination == null) {
      throw ArgumentError.value(
        value,
        'value',
        'Refspec must include a source, a destination, or both.',
      );
    }

    return GitRefSpec(
      force: force,
      source: normalizedSource,
      destination: normalizedDestination,
    );
  }

  final bool force;
  final String? source;
  final String? destination;

  String get storageValue {
    final buffer = StringBuffer();
    if (force) {
      buffer.write('+');
    }
    buffer.write(source ?? '');
    if (destination != null) {
      buffer.write(':');
      buffer.write(destination);
    }
    return buffer.toString();
  }

  @override
  String toString() => storageValue;
}
