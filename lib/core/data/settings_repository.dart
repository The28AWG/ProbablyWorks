import 'dart:convert';

import 'package:injectable/injectable.dart';
import 'package:probably_works/agent/domain/steps_display.dart';
import 'package:probably_works/agent/policy/security_profile.dart';
import 'package:probably_works/core/config/app_limits.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/domain/chat_usage.dart';

/// Настройки приложения (kv-таблица) и доверие workspace.
@lazySingleton
class SettingsRepository {
  SettingsRepository(this._db);

  final AppDatabase _db;

  $KvSettingsTable get _kvSettingsTable => _db.kvSettings;

  /// Вся kv-таблица в памяти после [preload]: чтения синхронны, записи обновляют и память, и БД.
  final _cache = <String, String>{};
  var _preloaded = false;

  static const keyDefaultModel = 'defaultModel';
  static const keyTitleModel = 'titleModel';
  static const keyLanguage = 'language';
  static const keyThemeMode = 'themeMode';
  static const keyDefaultPolicy = 'defaultPolicy';
  static const keyDenylist = 'denylist';
  static const keySecurityProfile = 'securityProfile';
  static const keyLimits = 'limits';
  static const keyPinnedModels = 'pinnedModels';
  static const keyStepsGroup = 'stepsGroup';
  static const keyStepsExpandWhileActive = 'stepsExpandWhileActive';
  static const keyStepsThoughts = 'stepsThoughts';
  static const keyStepsTools = 'stepsTools';
  static const keySidebarWidth = 'sidebarWidth';
  static const keyLastUsageContextPrefix = 'contextLength:';
  static const keyDailyBudgetPrefix = 'dailyBudget:';
  static const keyDailyUsagePrefix = 'dailyUsage:';
  static const keyCompactionInfoPrefix = 'compactionInfo:';

  /// Загружает kv-таблицу в память. Вызывается при старте, до первого чтения настроек.
  Future<void> preload() async {
    final rows = await _db.select(_kvSettingsTable).get();
    _cache
      ..clear()
      ..addAll({for (final row in rows) row.key: row.value});
    _preloaded = true;
  }

  Future<String?> read(String key) async {
    if (_preloaded) return _cache[key];
    final row = await (_db.select(
      _kvSettingsTable,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  /// Значение из памяти без ожидания: нужно первому кадру нового чата. Доступно после [preload].
  String? cached(String key) {
    assert(_preloaded, 'SettingsRepository.preload() не вызван');
    return _cache[key];
  }

  Stream<String?> watch(String key) =>
      (_db.select(_kvSettingsTable)..where((t) => t.key.equals(key)))
          .watchSingleOrNull()
          .map((row) => row?.value);

  Future<void> write(String key, String? value) async {
    if (_preloaded) {
      if (value == null) {
        _cache.remove(key);
      } else {
        _cache[key] = value;
      }
    }
    if (value == null) {
      await (_db.delete(
        _kvSettingsTable,
      )..where((t) => t.key.equals(key))).go();
      return;
    }
    await _db
        .into(_kvSettingsTable)
        .insertOnConflictUpdate(
          KvSettingsCompanion.insert(key: key, value: value),
        );
  }

  Future<AppLimits> limits() async => AppLimits.fromJson(await read(keyLimits));

  /// Лимиты из памяти (см. [cached]).
  AppLimits cachedLimits() => AppLimits.fromJson(cached(keyLimits));

  Future<void> saveLimits(AppLimits limits) =>
      write(keyLimits, limits.toJson());

  static String trustKey(String hostId, String workspace) =>
      'trust:$hostId:$workspace';

  /// Доверие к workspace: без него AGENTS.md и skills не загружаются.
  Future<bool> isTrusted(String hostId, String workspace) async =>
      (await read(trustKey(hostId, workspace))) == 'yes';

  Future<void> setTrusted(
    String hostId,
    String workspace, {
    required bool trusted,
  }) => write(trustKey(hostId, workspace), trusted ? 'yes' : null);

  /// Закреплённые модели (id через OpenRouter) для быстрого выбора.
  Future<List<String>> readPinnedModels() async =>
      _pinnedFrom(await read(keyPinnedModels));

  List<String> cachedPinnedModels() => _pinnedFrom(cached(keyPinnedModels));

  static List<String> _pinnedFrom(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    return (jsonDecode(raw) as List<dynamic>).cast<String>();
  }

  Future<void> savePinnedModels(List<String> ids) =>
      write(keyPinnedModels, jsonEncode(ids));

  /// Журнал шагов по умолчанию. Неизвестное значение в kv-таблице даёт поведение по умолчанию.
  Future<StepsDisplay> readStepsDisplay() async => _stepsFrom(
    group: await read(keyStepsGroup),
    expandWhileActive: await read(keyStepsExpandWhileActive),
    thoughts: await read(keyStepsThoughts),
    tools: await read(keyStepsTools),
  );

  StepsDisplay cachedStepsDisplay() => _stepsFrom(
    group: cached(keyStepsGroup),
    expandWhileActive: cached(keyStepsExpandWhileActive),
    thoughts: cached(keyStepsThoughts),
    tools: cached(keyStepsTools),
  );

  static StepsDisplay _stepsFrom({
    required String? group,
    required String? expandWhileActive,
    required String? thoughts,
    required String? tools,
  }) {
    const defaults = StepsDisplay.defaults;
    return StepsDisplay(
      group: group != 'no',
      expandWhileActive: expandWhileActive != 'no',
      thoughts:
          ThoughtsVisibility.values.asNameMap()[thoughts] ?? defaults.thoughts,
      tools: ToolsVisibility.values.asNameMap()[tools] ?? defaults.tools,
    );
  }

  Future<void> saveStepsDisplay(StepsDisplay value) async {
    await write(keyStepsGroup, value.group ? 'yes' : 'no');
    await write(
      keyStepsExpandWhileActive,
      value.expandWhileActive ? 'yes' : 'no',
    );
    await write(keyStepsThoughts, value.thoughts.name);
    await write(keyStepsTools, value.tools.name);
  }

  /// Метаданные последнего сжатия истории чата. Null — сжатия ещё не было.
  static String compactionInfoKey(String chatId) =>
      '$keyCompactionInfoPrefix$chatId';

  Future<ChatCompactionInfo?> readCompactionInfo(String chatId) async {
    final raw = await read(compactionInfoKey(chatId));
    if (raw == null || raw.isEmpty) return null;
    try {
      return ChatCompactionInfo.decode(raw);
    } on FormatException {
      return null;
    }
  }

  Future<void> saveCompactionInfo(String chatId, ChatCompactionInfo info) =>
      write(compactionInfoKey(chatId), info.encode());

  /// Дневной лимит трат конкретного чата. Null — без лимита.
  static String dailyBudgetKey(String chatId) => '$keyDailyBudgetPrefix$chatId';

  Future<double?> readDailyBudget(String chatId) async {
    final raw = await read(dailyBudgetKey(chatId));
    if (raw == null || raw.isEmpty) return null;
    final value = double.tryParse(raw);
    return value == null || value <= 0 ? null : value;
  }

  Future<void> saveDailyBudget(String chatId, double? value) =>
      write(dailyBudgetKey(chatId), value?.toStringAsFixed(6));

  /// Расход чата за [day]. Битая или отсутствующая запись — нулевой расход.
  Future<ChatDailyUsage> readDailyUsage(String chatId, {DateTime? day}) async {
    final raw = await read(dailyUsageKey(chatId, day ?? DateTime.now()));
    return raw == null || raw.isEmpty
        ? const ChatDailyUsage()
        : ChatDailyUsage.decode(raw);
  }

  /// Добавляет один запрос к расходу дня. Возвращает новое состояние счётчика.
  Future<ChatDailyUsage> addDailyUsage(
    String chatId, {
    required int promptTokens,
    required int completionTokens,
    required double costUsd,
    DateTime? day,
  }) async {
    final at = day ?? DateTime.now();
    final key = dailyUsageKey(chatId, at);
    final current = await readDailyUsage(chatId, day: at);
    final next = current.plus(
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      costUsd: costUsd,
    );
    await write(key, next.encode());
    return next;
  }

  static String dailyUsageKey(String chatId, DateTime day) =>
      '$keyDailyUsagePrefix$chatId:${usageDayKey(day)}';

  Future<List<String>> readDenylist() async {
    final raw = await read(keyDenylist);
    if (raw == null) return defaultDenylist;
    return raw.isEmpty ? const [] : raw.split('\n');
  }

  Future<void> saveDenylist(List<String> patterns) =>
      write(keyDenylist, patterns.join('\n'));

  /// Уровни команд. Пустая или битая запись читается как встроенный профиль.
  Future<SecurityProfile> readSecurityProfile() async {
    final raw = await read(keySecurityProfile);
    if (raw == null || raw.isEmpty) return const SecurityProfile();
    return SecurityProfile.decode(raw);
  }

  /// Сохраняет профиль целиком: отсутствие ключа в JSON значит, что уровень убран.
  Future<void> saveSecurityProfile(SecurityProfile profile) =>
      write(keySecurityProfile, profile.encode());

  /// Дефолтный denylist: дополнительный запрет поверх разбора command_shield.
  /// Критическая команда отклоняется и без совпадения с шаблоном.
  static const defaultDenylist = [
    r'rm\s+-rf\s+/(\s|$)',
    r'\bmkfs(\.|\s)',
    r'\bdd\s+.*\bof=/dev/',
    r'\bshutdown\b',
    r'\breboot\b',
    r'chmod\s+-R\s+777\s+/(\s|$)',
    r':\(\)\s*\{',
  ];
}
