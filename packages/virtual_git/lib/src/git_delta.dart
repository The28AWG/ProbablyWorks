// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'dart:typed_data';

sealed class GitDeltaInstruction {
  const GitDeltaInstruction();
}

final class GitDeltaCopyInstruction extends GitDeltaInstruction {
  const GitDeltaCopyInstruction({required this.offset, required this.size});

  final int offset;
  final int size;
}

final class GitDeltaInsertInstruction extends GitDeltaInstruction {
  GitDeltaInsertInstruction(List<int> bytes)
    : bytes = Uint8List.fromList(bytes) {
    if (this.bytes.isEmpty) {
      throw ArgumentError.value(
        bytes,
        'bytes',
        'Delta insert instruction bytes must not be empty.',
      );
    }
  }

  final Uint8List bytes;
}

final class GitDelta {
  const GitDelta({
    required this.baseSize,
    required this.resultSize,
    required this.instructions,
  });

  final int baseSize;
  final int resultSize;
  final List<GitDeltaInstruction> instructions;
}
