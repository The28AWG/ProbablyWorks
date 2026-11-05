// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'package:virtual_git/src/git_hash_algorithm.dart';

final class GitObjectId {
  factory GitObjectId.fromHex(String value) {
    final normalized = value.trim().toLowerCase();
    if (!isValidHex(normalized)) {
      throw FormatException(
        'Git object id must be a 40- or 64-character lowercase hex string.',
        value,
      );
    }
    return GitObjectId._(normalized);
  }

  factory GitObjectId.fromBytes(List<int> bytes) {
    if (bytes.length != 20 && bytes.length != 32) {
      throw FormatException(
        'Git object id bytes must be 20 or 32 bytes long.',
        bytes.length,
      );
    }
    return GitObjectId._(_encodeHex(bytes));
  }

  factory GitObjectId.compute(
    List<int> bytes, {
    GitHashAlgorithm algorithm = GitHashAlgorithm.sha1,
  }) {
    final digest = switch (algorithm) {
      GitHashAlgorithm.sha1 => crypto.sha1.convert(bytes).bytes,
      GitHashAlgorithm.sha256 => crypto.sha256.convert(bytes).bytes,
    };
    return GitObjectId.fromBytes(digest);
  }

  GitObjectId._(this.hex);

  final String hex;

  static final RegExp _hexPattern = RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$');

  static bool isValidHex(String value) => _hexPattern.hasMatch(value);

  int get length => hex.length;

  GitHashAlgorithm get algorithm => switch (length) {
    40 => GitHashAlgorithm.sha1,
    64 => GitHashAlgorithm.sha256,
    _ => throw StateError('Unsupported object id length: $length'),
  };

  bool get isSha1 => length == 40;

  bool get isSha256 => length == 64;

  Uint8List toBytes() {
    final bytes = <int>[];
    for (var index = 0; index < hex.length; index += 2) {
      bytes.add(int.parse(hex.substring(index, index + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  static String _encodeHex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  @override
  bool operator ==(Object other) => other is GitObjectId && other.hex == hex;

  @override
  int get hashCode => hex.hashCode;

  @override
  String toString() => hex;
}
