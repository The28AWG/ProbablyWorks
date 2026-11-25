import 'dart:async';
import 'dart:convert';

import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/domain/chat_usage.dart';
import 'package:pw_agent/providers/ai/reasoning.dart';

/// Настройки приложения (kv-таблица) и доверие workspace.
@lazySingleton
class SettingsRepository {
  SettingsRepository(this._db);

  final AppDatabase _db;

  $KvSettingsTable get _kvSettingsTable => _db.kvSettings;

  /// Вся kv-таблица в памяти после [preload]: чтения синхронны, записи обновляют и память, и БД.
  final _cache = <String, String>{};
  var _preloaded = false;
  static const _settingsChangeTick = Object();

  static const keyDefaultModel = 'defaultModel';
  static const keyTitleModel = 'titleModel';

  /// Модель memory-цикла проекта. Пусто — модель текущего чата, затем модель по умолчанию.
  static const keyMemoryModel = 'memoryModel';

  /// Модель субагентов. Пусто — использовать модель родительского чата.
  static const keySubagentModel = 'subagentModel';

  /// Запасная модель на случай 429/5xx/404 основной. Пусто — без fallback.
  static const keyFallbackModel = 'fallbackModel';

  /// Уровни рассуждений для моделей из настроек. Пусто — auto.
  static const keyDefaultReasoning = 'defaultReasoning';
  static const keyMemoryReasoning = 'memoryReasoning';
  static const keySubagentReasoning = 'subagentReasoning';
  static const keyFallbackReasoning = 'fallbackReasoning';
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

  /// Старые ключи llama.cpp. Читаются `LlmProviderSettingsStore` для
  /// существующих профилей; новые значения пишутся в `provider.llamacpp.*`.
  static const keyLlamaCppEnabled = 'llamaCpp.enabled';
  static const keyLlamaCppBaseUrl = 'llamaCpp.baseUrl';

  /// Одноразовая миграция прав файлов, созданных до их ужесточения.
  static const keyPermissionsMigrated = 'permissionsMigrated';

  /// Через сколько минут простоя среда выполнения выгружает локальную
  /// модель из памяти. `0` — никогда.
  static const keyLocalModelsAutoUnload = 'localModelsAutoUnload';
  static const keyLastUsageContextPrefix = 'contextLength:';
  static const keyDailyBudgetPrefix = 'dailyBudget:';
  static const keyDailyUsagePrefix = 'dailyUsage:';
  static const keyCompactionInfoPrefix = 'compactionInfo:';

  /// Предпочтения агента, которые возвращает к значениям по умолчанию сброс.
  ///
  /// Доверие проектов, расходы чатов, одноразовые флаги миграций и секреты
  /// сюда не входят: сброс настроек не должен стирать данные или доступы.
  static const preferenceKeys = <String>[
    keyDefaultModel,
    keyTitleModel,
    keyMemoryModel,
    keySubagentModel,
    keyFallbackModel,
    keyDefaultReasoning,
    keyMemoryReasoning,
    keySubagentReasoning,
    keyFallbackReasoning,
    keyLanguage,
    keyThemeMode,
    keyDefaultPolicy,
    keyDenylist,
    keySecurityProfile,
    keyLimits,
    keyPinnedModels,
    keyStepsGroup,
    keyStepsExpandWhileActive,
    keyStepsThoughts,
    keyStepsTools,
    keySidebarWidth,
    keyLlamaCppEnabled,
    keyLlamaCppBaseUrl,
    keyLocalModelsAutoUnload,
  ];

  /// Загружает kv-таблицу в память. Вызывается при старте, до первого чтения настроек.
  Future<void> preload() async {
    final rows = await _db.select(_kvSettingsTable).get();
    _cache
      ..clear()
      ..addAll({for (final row in rows) row.key: row.value});
    _preloaded = true;
  }

  /// Возвращает предпочтения агента к значениям по умолчанию.
  ///
  /// Удаляет ключи из [preferenceKeys] и все настройки провайдеров
  /// (`provider.<id>.*`). Секреты провайдеров лежат в `SecretStore` и
  /// остаются на месте. После очистки кэш перечитывается из базы: чтения
  /// настроек синхронны и должны сразу видеть значения по умолчанию.
  Future<void> resetPreferences() async {
    final keys = <String>{...preferenceKeys};
    for (final key in await _keys()) {
      if (key.startsWith('provider.')) keys.add(key);
    }
    await _db.transaction(() async {
      for (final key in keys) {
        await (_db.delete(
          _kvSettingsTable,
        )..where((t) => t.key.equals(key))).go();
      }
    });
    await preload();
  }

  /// Все ключи kv-таблицы: из кэша после [preload] или из базы.
  Future<List<String>> _keys() async {
    if (_preloaded) return _cache.keys.toList();
    final rows = await _db.select(_kvSettingsTable).get();
    return [for (final row in rows) row.key];
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

  /// Изменение настроек, в том числе записанное другим клиентом.
  ///
  /// Отслеживаются только настройки: расход дня, лимит и метаданные сжатия
  /// пишутся на каждом шаге агента и к странице настроек не относятся. Иначе
  /// открытая страница перечитывала бы всё на каждое действие агента.
  ///
  /// Первое событие — текущее состояние таблицы: подписчик уже прочитал его
  /// при загрузке, поэтому начальный снимок пропускаем.
  Stream<void> get changes => _db
      .select(_kvSettingsTable)
      .watch()
      .map(_settingsFingerprint)
      .distinct()
      .skip(1)
      .map((_) => _settingsChangeTick);

  /// Отпечаток настроек: значения ключей без учёта расхода чатов. Сравнение
  /// идёт по строке, поэтому таблица-результат не считается изменившейся,
  /// пока настройки те же.
  String _settingsFingerprint(List<KvRow> rows) {
    final parts = <String>[
      for (final row in rows)
        if (!_isChatScoped(row.key)) '${row.key}\u001f${row.value}',
    ]..sort();
    return parts.join('\u001e');
  }

  /// Ключи, привязанные к чату и обновляемые во время хода агента.
  static bool _isChatScoped(String key) =>
      key.startsWith(keyDailyUsagePrefix) ||
      key.startsWith(keyDailyBudgetPrefix) ||
      key.startsWith(keyCompactionInfoPrefix) ||
      key.startsWith(keyLastUsageContextPrefix);

  /// Выполняет несколько чтений и записей как одну транзакцию.
  ///
  /// Нужна проверкам ревизий: пока транзакция не завершилась, drift не пускает
  /// другие запросы к базе, поэтому параллельное сохранение не пройдёт между
  /// проверкой и записью. Ошибка внутри откатывает изменения и пробрасывается.
  Future<T> transaction<T>(Future<T> Function() action) =>
      _db.transaction(action);

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

  /// Уровень рассуждений по ключу. Неизвестное или пустое значение — auto.
  Future<ReasoningPreference> readReasoning(String key) async =>
      ReasoningPreference.parse(await read(key));

  /// Уровень из памяти (см. [cached]).
  ReasoningPreference cachedReasoning(String key) =>
      ReasoningPreference.parse(cached(key));

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

  /// Удаляет все kv-записи чата: дневной лимит, расход по дням и метаданные
  /// сжатия. Вызывается при удалении чата, иначе ключи остаются навсегда.
  Future<void> deleteChatData(String chatId) async {
    final usagePrefix = '$keyDailyUsagePrefix$chatId:';
    final usageKeys = _preloaded
        ? _cache.keys.where((key) => key.startsWith(usagePrefix)).toList()
        : [
            for (final row in await _db.select(_kvSettingsTable).get())
              if (row.key.startsWith(usagePrefix)) row.key,
          ];
    for (final key in [
      dailyBudgetKey(chatId),
      compactionInfoKey(chatId),
      ...usageKeys,
    ]) {
      await write(key, null);
    }
  }

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
