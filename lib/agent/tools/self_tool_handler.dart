import 'dart:convert';

import 'package:injectable/injectable.dart';
import 'package:probably_works/agent/domain/steps_display.dart';
import 'package:probably_works/agent/tools/tool_catalog.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/core/config/app_limits.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/util/char_substring.dart';
import 'package:probably_works/core/util/home_path.dart';
import 'package:probably_works/host/host_diagnostics.dart';
import 'package:probably_works/providers/ai/model_catalog.dart';
import 'package:uuid/uuid.dart';

/// Готовое изменение: текст для карточки подтверждения и действие, которое выполняется после решения.
class SelfChange {
  const SelfChange({required this.summary, required this.apply, this.keyPath});

  /// Что именно будет сделано: показывается в карточке подтверждения.
  final String summary;

  /// Путь к ключу из host_add. По нему решается, нужно ли подтверждение.
  final String? keyPath;

  /// Применяет изменение и возвращает текст для модели.
  final Future<String> Function() apply;
}

/// Self-инструменты: чтение состояния приложения, проверка подключения и запись хостов и настроек.
/// Решения Policy и подтверждения принимает ToolExecutor; здесь только чтение, валидация и применение.
@lazySingleton
class SelfToolHandler {
  SelfToolHandler(
    this._hosts,
    this._settings,
    this._locale,
    this._catalog,
    this._diagnostics,
  );

  final HostRepository _hosts;
  final SettingsRepository _settings;
  final LocaleController _locale;
  final ModelCatalogService _catalog;
  final HostDiagnostics _diagnostics;

  static const _uuid = Uuid();

  static const _hostUpdateFields = {'id', 'name', 'notes', 'defaultWorkspace'};

  static const _settingKeys = [
    SettingsRepository.keyLanguage,
    SettingsRepository.keyDefaultModel,
    SettingsRepository.keyTitleModel,
    SettingsRepository.keyPinnedModels,
    SettingsRepository.keyLimits,
    SettingsRepository.keyStepsGroup,
    SettingsRepository.keyStepsThoughts,
    SettingsRepository.keyStepsTools,
  ];

  /// Инструменты только для чтения: выполняются сразу, без подтверждения.
  Future<String> read(String name, Map<String, dynamic> args) => switch (name) {
    ToolNames.hostList => _hostList(),
    ToolNames.settingsRead => _settingsRead(),
    ToolNames.hostTest => _hostTest(args),
    ToolNames.hostDiagnose => _hostDiagnose(args),
    _ => throw ArgumentError.value(name, 'name', 'not a read-only self tool'),
  };

  /// Запись: проверяет аргументы до подтверждения, чтобы карточка показывала уже допустимое изменение.
  Future<SelfChange> prepare(String name, Map<String, dynamic> args) =>
      switch (name) {
        ToolNames.hostAdd => _prepareHostAdd(args),
        ToolNames.hostUpdate => _prepareHostUpdate(args),
        ToolNames.settingsUpdate => _prepareSettingsUpdate(args),
        _ => throw ArgumentError.value(name, 'name', 'not a write self tool'),
      };

  // ---- read ----------------------------------------------------------------

  Future<String> _hostList() async => jsonEncode([
    for (final host in await _hosts.all())
      {
        'id': host.id,
        'name': host.name,
        'kind': host.kind.name,
        'address': host.address,
        'port': host.port,
        'username': host.username,
        'authType': host.authType.name,
        'os': host.os.name,
        'defaultWorkspace': host.defaultWorkspace,
        'notes': host.notes,
        'lastCheckAt': host.lastCheckAt?.toIso8601String(),
        'lastLatencyMs': host.lastLatencyMs,
        'lastCheckError': host.lastCheckError,
      },
  ]);

  Future<String> _settingsRead() async => jsonEncode(await _allSettings());

  Future<String> _hostTest(Map<String, dynamic> args) async {
    final result = await _diagnostics.test(await _requiredHost(args));
    return result.ok
        ? 'ok: host_info succeeded in ${result.latencyMs} ms'
        : 'failed: ${result.error}';
  }

  Future<String> _hostDiagnose(Map<String, dynamic> args) async {
    final steps = await _diagnostics.diagnose(await _requiredHost(args));
    return [
      for (final step in steps)
        '${step.name}: ${step.status.name}: ${step.message}',
    ].join('\n');
  }

  /// Только настройки из whitelist. Секреты и denylist/defaultPolicy сюда не входят.
  Future<Map<String, Object?>> _allSettings() async {
    final steps = await _settings.readStepsDisplay();
    return {
      SettingsRepository.keyLanguage:
          await _settings.read(SettingsRepository.keyLanguage) ?? 'system',
      SettingsRepository.keyDefaultModel:
          await _settings.read(SettingsRepository.keyDefaultModel) ?? '',
      SettingsRepository.keyTitleModel:
          await _settings.read(SettingsRepository.keyTitleModel) ?? '',
      SettingsRepository.keyPinnedModels: await _settings.readPinnedModels(),
      SettingsRepository.keyLimits: (await _settings.limits()).toMap(),
      SettingsRepository.keyStepsGroup: steps.group ? 'yes' : 'no',
      SettingsRepository.keyStepsThoughts: steps.thoughts.name,
      SettingsRepository.keyStepsTools: steps.tools.name,
    };
  }

  // ---- host_add ------------------------------------------------------------

  Future<SelfChange> _prepareHostAdd(Map<String, dynamic> args) async {
    final name = _required(args, 'name');
    final address = _required(args, 'address');
    if (address.contains(RegExp(r'\s'))) {
      throw ArgumentError.value(address, 'address', 'must not contain spaces');
    }
    final port = _intOr(args, 'port', 22);
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'must be 1..65535');
    }
    final username = _optional(args, 'username');
    final authType = _enumOr(
      args,
      'authType',
      SshAuthType.values,
      SshAuthType.key,
    );
    final os = _enumOr(args, 'os', HostOs.values, HostOs.posix);
    final keyPath = _optional(args, 'keyPath');
    if (keyPath != null) {
      if (authType != SshAuthType.key) {
        throw ArgumentError.value(
          keyPath,
          'keyPath',
          'is used only with authType key',
        );
      }
      if (!isSupportedKeyPath(keyPath)) {
        throw ArgumentError.value(
          keyPath,
          'keyPath',
          'use an absolute path or ~/...; other forms are not expanded',
        );
      }
    }
    final workspace = _optional(args, 'defaultWorkspace');
    final notes = _optional(args, 'notes');
    final id = _uuid.v4();
    final now = DateTime.now();
    final target = '${username == null ? '' : '$username@'}$address:$port';
    return SelfChange(
      summary:
          'Добавить SSH-хост «$name» ($target)'
          '${keyPath == null ? '' : ', ключ: $keyPath'}',
      keyPath: keyPath,
      apply: () async {
        await _hosts.save(
          Host(
            id: id,
            name: name,
            kind: HostKind.ssh,
            address: address,
            port: port,
            username: username,
            authType: authType,
            keyPath: keyPath,
            os: os,
            defaultWorkspace: workspace,
            notes: notes,
            createdAt: now,
            updatedAt: now,
          ),
        );
        return 'host added, id $id. Passwords and passphrases are entered on '
            'the Hosts page. Run host_diagnose to check the connection.';
      },
    );
  }

  // ---- host_update ---------------------------------------------------------

  Future<SelfChange> _prepareHostUpdate(Map<String, dynamic> args) async {
    for (final key in args.keys) {
      if (!_hostUpdateFields.contains(key)) {
        throw ArgumentError.value(
          key,
          key,
          'cannot be changed by the agent: change it on the Hosts page',
        );
      }
    }
    final host = await _requiredHost(args);
    final hasName = args.containsKey('name');
    final hasNotes = args.containsKey('notes');
    final hasWorkspace = args.containsKey('defaultWorkspace');
    if (!hasName && !hasNotes && !hasWorkspace) {
      throw ArgumentError(
        'nothing to change: pass name, notes or defaultWorkspace',
      );
    }
    final name = hasName ? _required(args, 'name') : host.name;
    final notes = hasNotes ? _optional(args, 'notes') : host.notes;
    final workspace = hasWorkspace
        ? _optional(args, 'defaultWorkspace')
        : host.defaultWorkspace;
    final changes = [
      if (hasName) 'имя → «$name»',
      if (hasNotes) 'заметки: ${charPrefix(notes ?? 'очистить', 120)}',
      if (hasWorkspace) 'рабочая папка: ${workspace ?? 'очистить'}',
    ];
    return SelfChange(
      summary: 'Изменить хост «${host.name}»: ${changes.join(', ')}',
      apply: () async {
        // Хост перечитывается при применении: за время подтверждения он мог измениться.
        final current = await _hosts.byId(host.id) ?? host;
        await _hosts.save(
          _rebuild(
            current,
            name: name,
            notes: notes,
            defaultWorkspace: workspace,
          ),
        );
        return 'host updated: ${host.id}';
      },
    );
  }

  static Host _rebuild(
    Host host, {
    required String name,
    required String? notes,
    required String? defaultWorkspace,
  }) => Host(
    id: host.id,
    name: name,
    kind: host.kind,
    address: host.address,
    port: host.port,
    username: host.username,
    authType: host.authType,
    keyPath: host.keyPath,
    hostKeyFingerprint: host.hostKeyFingerprint,
    os: host.os,
    defaultWorkspace: defaultWorkspace,
    shellOverride: host.shellOverride,
    notes: notes,
    connectTimeoutSeconds: host.connectTimeoutSeconds,
    lastCheckAt: host.lastCheckAt,
    lastLatencyMs: host.lastLatencyMs,
    lastCheckError: host.lastCheckError,
    createdAt: host.createdAt,
    updatedAt: DateTime.now(),
  );

  // ---- settings_update -----------------------------------------------------

  Future<SelfChange> _prepareSettingsUpdate(Map<String, dynamic> args) async {
    final key = _required(args, 'key');
    final value = _required(args, 'value');
    final apply = _settingWriter(key, value);
    final before = (await _allSettings())[key];
    return SelfChange(
      summary:
          'Изменить настройку $key: ${charPrefix('$before', 80)} → '
          '${charPrefix(value, 80)}',
      apply: apply,
    );
  }

  /// Проверяет значение и возвращает действие записи. Для неизвестного ключа — ошибка аргумента.
  Future<String> Function() _settingWriter(String key, String value) {
    if (!_settingKeys.contains(key)) {
      throw ArgumentError.value(
        key,
        'key',
        'unknown setting; allowed: ${_settingKeys.join(', ')}',
      );
    }
    switch (key) {
      case SettingsRepository.keyLanguage:
        if (!const {'system', 'en', 'ru'}.contains(value)) {
          throw ArgumentError.value(value, 'value', 'expected system, en or ru');
        }
        return () async {
          await _settings.write(key, value);
          _locale.apply(value);
          return 'language set to $value';
        };
      case SettingsRepository.keyDefaultModel:
      case SettingsRepository.keyTitleModel:
        if (value.contains(RegExp(r'\s'))) {
          throw ArgumentError.value(value, 'value', 'model id has no spaces');
        }
        return () async {
          await _settings.write(key, value);
          return '$key set to $value';
        };
      case SettingsRepository.keyPinnedModels:
        final ids = _jsonStrings(value);
        return () async {
          await _settings.savePinnedModels(ids);
          if (ids.isNotEmpty) await _catalog.remember(ids);
          return 'pinned models: ${ids.length}';
        };
      case SettingsRepository.keyLimits:
        final limits = _parseLimits(value);
        return () async {
          await _settings.saveLimits(limits);
          return 'limits saved';
        };
      case SettingsRepository.keyStepsGroup:
        if (value != 'yes' && value != 'no') {
          throw ArgumentError.value(value, 'value', 'expected yes or no');
        }
        return () async {
          final current = await _settings.readStepsDisplay();
          await _settings.saveStepsDisplay(
            current.copyWith(group: value == 'yes'),
          );
          return 'stepsGroup set to $value';
        };
      case SettingsRepository.keyStepsThoughts:
        final thoughts = _enumOf(ThoughtsVisibility.values, value, 'value');
        return () async {
          final current = await _settings.readStepsDisplay();
          await _settings.saveStepsDisplay(
            current.copyWith(thoughts: thoughts),
          );
          return 'stepsThoughts set to ${thoughts.name}';
        };
      case SettingsRepository.keyStepsTools:
        final tools = _enumOf(ToolsVisibility.values, value, 'value');
        return () async {
          final current = await _settings.readStepsDisplay();
          await _settings.saveStepsDisplay(current.copyWith(tools: tools));
          return 'stepsTools set to ${tools.name}';
        };
    }
    throw ArgumentError.value(key, 'key', 'unknown setting');
  }

  // ---- helpers -------------------------------------------------------------

  Future<Host> _requiredHost(Map<String, dynamic> args) async {
    final id = _required(args, 'id');
    final host = await _hosts.byId(id);
    if (host == null) throw ArgumentError.value(id, 'id', 'unknown host id');
    return host;
  }

  static List<String> _jsonStrings(String value) {
    final Object? decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      throw ArgumentError.value(value, 'value', 'expected a JSON array');
    }
    if (decoded is! List || decoded.any((item) => item is! String)) {
      throw ArgumentError.value(value, 'value', 'expected a JSON array of ids');
    }
    return decoded.cast<String>();
  }

  static AppLimits _parseLimits(String value) {
    try {
      return AppLimits.parse(value);
    } on FormatException catch (error) {
      throw ArgumentError.value(value, 'value', 'invalid limits: ${error.message}');
    }
  }

  static String _required(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is! String || value.trim().isEmpty) {
      throw ArgumentError.value(value, key, 'required string');
    }
    return value.trim();
  }

  /// Пустая строка означает «не задано»: для заметок это очистка.
  static String? _optional(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value == null) return null;
    if (value is! String) throw ArgumentError.value(value, key, 'string expected');
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int _intOr(Map<String, dynamic> args, String key, int fallback) {
    final value = args[key];
    if (value == null) return fallback;
    if (value is! num || value != value.toInt()) {
      throw ArgumentError.value(value, key, 'integer expected');
    }
    return value.toInt();
  }

  static T _enumOr<T extends Enum>(
    Map<String, dynamic> args,
    String key,
    List<T> values,
    T fallback,
  ) {
    final raw = args[key];
    return raw == null ? fallback : _enumOf(values, raw, key);
  }

  static T _enumOf<T extends Enum>(List<T> values, Object? raw, String key) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    throw ArgumentError.value(
      raw,
      key,
      'expected one of ${values.map((v) => v.name).join(', ')}',
    );
  }
}
