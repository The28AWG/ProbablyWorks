import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:probably_works/app/bootstrap/client_info.dart';
import 'package:probably_works/core/platform/client_info.dart';
import 'package:probably_works/core/settings/client_settings.dart';

void main() {
  test('client info provides headers for the remote API', () {
    const info = ClientInfo(
      packageName: 'probably_works',
      version: '1.2.3',
      buildNumber: '42',
    );

    expect(info.headers, containsPair('x-client-app', ClientInfo.appName));
    expect(info.headers, containsPair('x-client-package', 'probably_works'));
    expect(info.headers, containsPair('x-client-version', '1.2.3'));
    expect(info.headers, containsPair('x-client-build', '42'));
    expect(
      info.headers['x-client-platform'],
      defaultTargetPlatform.name.toLowerCase(),
    );
  });

  test('client id is stable across loads and goes into headers', () async {
    final settings = MemoryClientSettings();

    final first = await ensureClientId(settings);
    final second = await ensureClientId(settings);

    expect(first, isNotNull);
    expect(first, matches(RegExp(r'^[a-f0-9-]{36}$')));
    expect(second, first);

    const info = ClientInfo(
      packageName: 'probably_works',
      version: '1.2.3',
      buildNumber: '42',
      clientId: 'client-install-1',
    );
    expect(info.headers, containsPair('x-client-id', 'client-install-1'));
  });

  test('concurrent client id creation returns one id', () async {
    final settings = _GatedSettings();

    final first = ensureClientId(settings);
    await settings.firstReadStarted;
    final second = ensureClientId(settings);
    settings.releaseFirstRead();

    final ids = await Future.wait([first, second]);
    expect(ids, everyElement(isNotNull));
    expect(ids.first, ids[1]);
  });

  test('package app name is not used in headers', () {
    final info = ClientInfo.fromPackageInfo(
      PackageInfo(
        appName: 'probably_works',
        packageName: 'probably_works',
        version: '1.0.0',
        buildNumber: '5',
      ),
    );

    expect(info.headers['x-client-app'], ClientInfo.appName);
  });

  test('empty package info falls back to defaults', () {
    final info = ClientInfo.fromPackageInfo(
      PackageInfo(appName: '', packageName: '', version: '', buildNumber: ''),
    );

    expect(info.packageName, ClientInfo.fallbackPackageName);
    expect(info.version, ClientInfo.fallbackVersion);
    expect(info.buildNumber, ClientInfo.fallbackBuildNumber);
  });

  test('resetting interface preferences keeps the device id', () {
    expect(
      ClientSettingsKeys.interfacePreferences,
      isNot(contains(ClientSettingsKeys.clientId)),
    );
  });
}

/// Хранилище, удерживающее первое чтение, чтобы два вызова гарантированно
/// пересеклись во времени.
final class _GatedSettings implements ClientSettings {
  final values = <String, String>{};
  final _firstReadStarted = Completer<void>();
  final _releaseFirstRead = Completer<void>();
  var _reads = 0;

  Future<void> get firstReadStarted => _firstReadStarted.future;

  void releaseFirstRead() => _releaseFirstRead.complete();

  @override
  Future<String?> read(String key) async {
    // Значение читается до ожидания: без блокировки оба вызова увидят null.
    final value = values[key];
    if (_reads++ == 0) {
      _firstReadStarted.complete();
      await _releaseFirstRead.future;
    }
    return value;
  }

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}
