import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:pw_agent/core/security/keyring_backend.dart';

/// Windows backend через Credential Manager (`CredWriteW`/`CredReadW`).
///
/// FFI-функции загружаются лениво: на Linux и macOS файл можно импортировать,
/// но `advapi32.dll` не открывается. Записи имеют тип generic credential.
final class WindowsCredentialBackend implements KeyringBackend {
  static const _service = 'com.the28awg.probably_works';
  static const _userName = 'probably-works';

  @override
  String get name => 'Windows Credential Manager';

  @override
  Future<String?> read(String key) async {
    final target = _target(key).toNativeUtf16();
    final credential = calloc<Pointer<_Credential>>();
    try {
      final ok = _api.credRead(target, _credentialTypeGeneric, 0, credential);
      if (ok == 0 || credential.value == nullptr) return null;
      try {
        final value = credential.value.ref;
        final bytes = value.credentialBlob.asTypedList(
          value.credentialBlobSize,
        );
        return utf8.decode(bytes);
      } finally {
        _api.credFree(credential.value.cast<Void>());
      }
    } finally {
      calloc
        ..free(target)
        ..free(credential);
    }
  }

  @override
  Future<void> write(String key, String value) async {
    final target = _target(key).toNativeUtf16();
    final userName = _userName.toNativeUtf16();
    final secret = utf8.encode(value);
    final blob = calloc<Uint8>(secret.length);
    final credential = calloc<_Credential>();
    try {
      blob.asTypedList(secret.length).setAll(0, secret);
      credential.ref
        ..type = _credentialTypeGeneric
        ..targetName = target
        ..userName = userName
        ..credentialBlob = blob
        ..credentialBlobSize = secret.length
        ..persist = _credentialPersistLocalMachine;
      final ok = _api.credWrite(credential, 0);
      if (ok == 0) {
        throw StateError('CredWriteW failed for ${_target(key)}');
      }
    } finally {
      calloc
        ..free(target)
        ..free(userName)
        ..free(blob)
        ..free(credential);
    }
  }

  @override
  Future<void> delete(String key) async {
    final target = _target(key).toNativeUtf16();
    try {
      // Отсутствующая запись не считается ошибкой.
      _api.credDelete(target, _credentialTypeGeneric, 0);
    } finally {
      calloc.free(target);
    }
  }

  static String _target(String key) => '$_service:$key';
}

const _credentialTypeGeneric = 1;
const _credentialPersistLocalMachine = 2;

_Advapi32 get _api => _Advapi32.instance;

final class _Advapi32 {
  _Advapi32() : _library = DynamicLibrary.open('advapi32.dll') {
    credWrite = _library
        .lookupFunction<
          Int32 Function(Pointer<_Credential>, Uint32),
          int Function(Pointer<_Credential>, int)
        >('CredWriteW');
    credRead = _library
        .lookupFunction<
          Int32 Function(
            Pointer<Utf16>,
            Uint32,
            Uint32,
            Pointer<Pointer<_Credential>>,
          ),
          int Function(Pointer<Utf16>, int, int, Pointer<Pointer<_Credential>>)
        >('CredReadW');
    credDelete = _library
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Uint32, Uint32),
          int Function(Pointer<Utf16>, int, int)
        >('CredDeleteW');
    credFree = _library
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('CredFree');
  }

  static final instance = _Advapi32();

  final DynamicLibrary _library;
  late final int Function(Pointer<_Credential>, int) credWrite;
  late final int Function(
    Pointer<Utf16>,
    int,
    int,
    Pointer<Pointer<_Credential>>,
  )
  credRead;
  late final int Function(Pointer<Utf16>, int, int) credDelete;
  late final void Function(Pointer<Void>) credFree;
}

final class _Credential extends Struct {
  @Uint32()
  external int flags;

  @Uint32()
  external int type;

  external Pointer<Utf16> targetName;

  external Pointer<Utf16> comment;

  external _FileTime lastWritten;

  @Uint32()
  external int credentialBlobSize;

  external Pointer<Uint8> credentialBlob;

  @Uint32()
  external int persist;

  @Uint32()
  external int attributeCount;

  external Pointer<Void> attributes;

  external Pointer<Utf16> targetAlias;

  external Pointer<Utf16> userName;
}

final class _FileTime extends Struct {
  @Uint32()
  external int low;

  @Uint32()
  external int high;
}
