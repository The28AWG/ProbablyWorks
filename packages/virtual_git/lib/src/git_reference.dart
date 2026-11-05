// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_object_id.dart';

sealed class GitReferenceTarget {
  const GitReferenceTarget();
}

final class GitDirectReferenceTarget extends GitReferenceTarget {
  const GitDirectReferenceTarget(this.objectId);

  final GitObjectId objectId;

  @override
  bool operator ==(Object other) =>
      other is GitDirectReferenceTarget && other.objectId == objectId;

  @override
  int get hashCode => objectId.hashCode;
}

final class GitSymbolicReferenceTarget extends GitReferenceTarget {
  const GitSymbolicReferenceTarget(this.referenceName);

  final String referenceName;

  @override
  bool operator ==(Object other) =>
      other is GitSymbolicReferenceTarget &&
      other.referenceName == referenceName;

  @override
  int get hashCode => referenceName.hashCode;
}

final class GitReference {
  GitReference(String name, this.target) : name = _validateName(name);

  factory GitReference.fromStorageValue(String name, String value) {
    final normalizedValue = value.trim();
    if (normalizedValue.startsWith('ref:')) {
      final referenceName = normalizedValue.substring('ref:'.length).trim();
      return GitReference.symbolic(name, referenceName);
    }

    return GitReference.direct(name, GitObjectId.fromHex(normalizedValue));
  }

  factory GitReference.direct(String name, GitObjectId objectId) =>
      GitReference(name, GitDirectReferenceTarget(objectId));

  factory GitReference.symbolic(String name, String referenceName) =>
      GitReference(
        name,
        GitSymbolicReferenceTarget(_validateName(referenceName)),
      );

  final String name;
  final GitReferenceTarget target;

  bool get isDirect => target is GitDirectReferenceTarget;

  bool get isSymbolic => target is GitSymbolicReferenceTarget;

  GitObjectId? get objectId => switch (target) {
    GitDirectReferenceTarget(:final objectId) => objectId,
    _ => null,
  };

  String? get targetReferenceName => switch (target) {
    GitSymbolicReferenceTarget(:final referenceName) => referenceName,
    _ => null,
  };

  String get storageValue => switch (target) {
    GitDirectReferenceTarget(:final objectId) => objectId.hex,
    GitSymbolicReferenceTarget(:final referenceName) => 'ref: $referenceName',
  };

  static String _validateName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        value,
        'name',
        'Reference name must not be empty.',
      );
    }
    if (trimmed.contains(' ')) {
      throw ArgumentError.value(
        value,
        'name',
        'Reference name must not contain spaces.',
      );
    }
    return trimmed;
  }

  @override
  bool operator ==(Object other) =>
      other is GitReference && other.name == name && other.target == target;

  @override
  int get hashCode => Object.hash(name, target);

  @override
  String toString() => name;
}
