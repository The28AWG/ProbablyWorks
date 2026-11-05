// ignore_for_file: cascade_invocations
// Причина: каскады оставлены как в git_core.
// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'dart:typed_data';

import 'package:virtual_git/src/git_delta.dart';

final class GitDeltaCodec {
  const GitDeltaCodec();

  GitDelta decode(List<int> bytes) {
    var offset = 0;
    final baseSize = _decodeVarInt(bytes, offset);
    offset += baseSize.length;
    final resultSize = _decodeVarInt(bytes, offset);
    offset += resultSize.length;

    final instructions = <GitDeltaInstruction>[];
    while (offset < bytes.length) {
      final opcode = bytes[offset++];
      if ((opcode & 0x80) != 0) {
        var copyOffset = 0;
        var copySize = 0;

        if ((opcode & 0x01) != 0) {
          copyOffset |= bytes[offset++];
        }
        if ((opcode & 0x02) != 0) {
          copyOffset |= bytes[offset++] << 8;
        }
        if ((opcode & 0x04) != 0) {
          copyOffset |= bytes[offset++] << 16;
        }
        if ((opcode & 0x08) != 0) {
          copyOffset |= bytes[offset++] << 24;
        }
        if ((opcode & 0x10) != 0) {
          copySize |= bytes[offset++];
        }
        if ((opcode & 0x20) != 0) {
          copySize |= bytes[offset++] << 8;
        }
        if ((opcode & 0x40) != 0) {
          copySize |= bytes[offset++] << 16;
        }
        if (copySize == 0) {
          copySize = 0x10000;
        }

        instructions.add(
          GitDeltaCopyInstruction(offset: copyOffset, size: copySize),
        );
        continue;
      }

      if (opcode == 0) {
        throw const FormatException('Delta opcode 0 is reserved.');
      }

      final insertLength = opcode & 0x7f;
      final insertEnd = offset + insertLength;
      if (insertEnd > bytes.length) {
        throw const FormatException('Delta insert instruction overruns input.');
      }

      instructions.add(
        GitDeltaInsertInstruction(bytes.sublist(offset, insertEnd)),
      );
      offset = insertEnd;
    }

    return GitDelta(
      baseSize: baseSize.value,
      resultSize: resultSize.value,
      instructions: instructions,
    );
  }

  Uint8List encode(GitDelta delta) {
    final output = BytesBuilder();
    output.add(_encodeVarInt(delta.baseSize));
    output.add(_encodeVarInt(delta.resultSize));

    for (final instruction in delta.instructions) {
      switch (instruction) {
        case GitDeltaInsertInstruction(:final bytes):
          if (bytes.length > 0x7f) {
            throw ArgumentError.value(
              bytes.length,
              'instruction.bytes',
              'Delta insert instruction cannot exceed 127 bytes.',
            );
          }
          output.addByte(bytes.length);
          output.add(bytes);
        case GitDeltaCopyInstruction(:final offset, :final size):
          if (offset < 0) {
            throw ArgumentError.value(
              offset,
              'instruction.offset',
              'Delta copy instruction offset must not be negative.',
            );
          }
          if (size <= 0 || size > 0x10000) {
            throw ArgumentError.value(
              size,
              'instruction.size',
              'Delta copy instruction size must be between 1 and 65536.',
            );
          }

          var opcode = 0x80;
          final payload = <int>[];

          if ((offset & 0xff) != 0) {
            opcode |= 0x01;
            payload.add(offset & 0xff);
          }
          if (((offset >> 8) & 0xff) != 0) {
            opcode |= 0x02;
            payload.add((offset >> 8) & 0xff);
          }
          if (((offset >> 16) & 0xff) != 0) {
            opcode |= 0x04;
            payload.add((offset >> 16) & 0xff);
          }
          if (((offset >> 24) & 0xff) != 0) {
            opcode |= 0x08;
            payload.add((offset >> 24) & 0xff);
          }

          if (size != 0x10000) {
            if ((size & 0xff) != 0) {
              opcode |= 0x10;
              payload.add(size & 0xff);
            }
            if (((size >> 8) & 0xff) != 0) {
              opcode |= 0x20;
              payload.add((size >> 8) & 0xff);
            }
            if (((size >> 16) & 0xff) != 0) {
              opcode |= 0x40;
              payload.add((size >> 16) & 0xff);
            }
          }

          output.addByte(opcode);
          output.add(payload);
      }
    }

    return output.takeBytes();
  }

  Uint8List apply(List<int> baseBytes, List<int> deltaBytes) {
    final delta = decode(deltaBytes);
    if (baseBytes.length != delta.baseSize) {
      throw FormatException(
        'Delta base size does not match the provided base object.',
        baseBytes.length,
      );
    }

    final output = BytesBuilder();
    for (final instruction in delta.instructions) {
      switch (instruction) {
        case GitDeltaInsertInstruction(:final bytes):
          output.add(bytes);
        case GitDeltaCopyInstruction(:final offset, :final size):
          final end = offset + size;
          if (offset < 0 || end > baseBytes.length) {
            throw FormatException(
              'Delta copy instruction reads beyond the base object.',
              end,
            );
          }
          output.add(baseBytes.sublist(offset, end));
      }
    }

    final result = output.takeBytes();
    if (result.length != delta.resultSize) {
      throw FormatException(
        'Delta result size does not match the reconstructed object.',
        result.length,
      );
    }
    return result;
  }

  ({int value, int length}) _decodeVarInt(List<int> bytes, int offset) {
    var value = 0;
    var shift = 0;
    var length = 0;

    while (true) {
      if (offset + length >= bytes.length) {
        throw const FormatException('Delta varint overruns input.');
      }

      final byte = bytes[offset + length];
      value |= (byte & 0x7f) << shift;
      length++;
      if ((byte & 0x80) == 0) {
        return (value: value, length: length);
      }
      shift += 7;
    }
  }

  Uint8List _encodeVarInt(int value) {
    if (value < 0) {
      throw ArgumentError.value(
        value,
        'value',
        'Delta varint must be non-negative.',
      );
    }

    final bytes = <int>[];
    var remaining = value;
    while (true) {
      var byte = remaining & 0x7f;
      remaining >>= 7;
      if (remaining != 0) {
        byte |= 0x80;
      }
      bytes.add(byte);
      if (remaining == 0) {
        break;
      }
    }
    return Uint8List.fromList(bytes);
  }
}
