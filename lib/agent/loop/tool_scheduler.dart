import 'dart:async';

import 'package:probably_works/agent/policy/policy_engine.dart';
import 'package:probably_works/agent/tools/tool_catalog.dart';
import 'package:probably_works/agent/tools/tool_effect.dart';
import 'package:probably_works/agent/tools/tool_executor.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/util/cancel_token.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// Чем закончился батч вызовов одного шага модели.
enum ToolScheduleEnd {
  /// У каждого вызова есть результат. Ход может спросить модель снова.
  done,

  /// Вызов `finish` завершил задачу. Вызовы после него записаны как невыполненные.
  finish,

  /// Ход отменён. Уже начатые вызовы дописаны, остальные — как отменённые.
  cancelled,
}

/// Запуск инструментов одного ответа модели.
///
/// Независимые вызовы стартуют сразу, в том числе подтверждения: карточка
/// запрашивается внутри [ToolExecutor.execute], и чужой ответ её не держит.
/// Конфликт по [ToolEffect] сохраняет порядок модели, поэтому запись и чтение
/// того же пути не накладываются, а diff зависимой записи считается уже после
/// предыдущей. Пути перед графом приводятся к канонической форме хоста и
/// обновляются снова, когда завершается команда: она могла создать симлинк.
/// `finish` ждёт предшественников и не даёт стартовать хвосту.
///
/// Результат пишется в ленту в исходном порядке, даже если вызовы завершились
/// иначе. Фоновый процесс отпускает зависимые операции хоста только когда
/// завершается сам: [ToolResult.whenSettled], а не текст «запущено».
/// Число одновременных процессов на хосте ограничивает исполнитель команд;
/// ожидание карточки до него не доходит.
class ToolScheduler {
  ToolScheduler._({
    required this.calls,
    required this.workspace,
    required this.policy,
    required this.hostKind,
    required this.canonicalize,
    required this.cancel,
    required this.alreadyAnswered,
    required this.resumed,
    required this.execute,
    required this.commit,
  });

  final List<LlmToolCall> calls;
  final String? workspace;
  final PolicyEngine policy;
  final HostKind hostKind;

  /// Раскрывает `~` и симлинки. null оставляет лексические ключи: так устроены
  /// тесты без Host. Сессия передаёт операцию хоста.
  final PathCanonicalizer? canonicalize;
  final CancelToken cancel;
  final Set<String> alreadyAnswered;
  final Map<String, Future<ToolResult> Function()> resumed;
  final Future<ToolResult> Function(LlmToolCall call) execute;
  final Future<void> Function(LlmToolCall call, ToolResult result) commit;

  /// Планирует [calls]. [alreadyAnswered] уже есть в ленте и только удовлетворяют
  /// зависимости. [resumed] — карточки, показанные снова: их будущее заменяет [execute].
  static Future<ToolScheduleEnd> run({
    required List<LlmToolCall> calls,
    required String? workspace,
    required PolicyEngine policy,
    required HostKind hostKind,
    required CancelToken cancel,
    PathCanonicalizer? canonicalize,
    required Future<ToolResult> Function(LlmToolCall call) execute,
    required Future<void> Function(LlmToolCall call, ToolResult result) commit,
    Set<String> alreadyAnswered = const {},
    Map<String, Future<ToolResult> Function()> resumed = const {},
  }) {
    final scheduler = ToolScheduler._(
      calls: calls,
      workspace: workspace,
      policy: policy,
      hostKind: hostKind,
      canonicalize: canonicalize,
      cancel: cancel,
      alreadyAnswered: alreadyAnswered,
      resumed: resumed,
      execute: execute,
      commit: commit,
    );
    return scheduler._run();
  }

  final List<_Slot> _slots = [];
  final Map<int, Future<void>> _running = {};
  Future<void> _flushChain = Future<void>.value();
  Future<void> _launchMutex = Future<void>.value();
  Object? _failure;
  int? _finishAt;
  bool _pathsDirty = false;
  bool _boundOnce = false;

  Future<ToolScheduleEnd> _run() async {
    _createSlots();
    _wireFixed();
    _pathsDirty = canonicalize != null;
    if (canonicalize == null) _rewireEffects();
    try {
      while (true) {
        await _flush();
        if (_failure != null) break;
        if (cancel.isCancelled && _running.isEmpty) {
          // Уже показанная карточка закрывается своим ответом (отказ или пустой
          // вопрос): синтетическая строка оставила бы запуск в waiting*.
          _skipPending('cancelled by the user', resumeWaiting: true);
          if (_running.isNotEmpty) continue;
          await _flush();
          break;
        }
        await _launch();
        if (_running.isEmpty) {
          if (_slots.any((slot) => slot.phase == _Phase.pending)) {
            _skipPending('not executed: internal scheduling error');
            await _flush();
          }
          break;
        }
        final finished = await _nextFinished();
        _running.remove(finished);
      }
    } finally {
      final pending = List<Future<void>>.of(_running.values);
      if (pending.isNotEmpty) {
        try {
          await Future.wait(pending);
        } on Object {
          // Результат сбоя уже лежит в вызове или в [_failure].
        }
      }
    }
    final failure = _failure;
    if (failure != null) throw failure;
    if (cancel.isCancelled) return ToolScheduleEnd.cancelled;
    if (_slots.any((slot) => slot.result?.finish ?? false)) {
      return ToolScheduleEnd.finish;
    }
    return ToolScheduleEnd.done;
  }

  void _createSlots() {
    for (var i = 0; i < calls.length; i++) {
      final call = calls[i];
      final answered = alreadyAnswered.contains(call.id);
      final effect = toolEffectFor(
        call,
        workspace: workspace,
        policy: policy,
        hostKind: hostKind,
      );
      _slots.add(
        _Slot(
          index: i,
          call: call,
          rawEffect: effect,
          effect: effect,
          phase: answered ? _Phase.settled : _Phase.pending,
          textReady: answered,
          committed: answered,
          effectSettled: answered,
        ),
      );
    }
  }

  /// Зависимости, которые не меняются при смене пути: поиск по ленте и `finish`.
  void _wireFixed() {
    for (var i = 0; i < _slots.length; i++) {
      final slot = _slots[i];
      if (_finishAt == null && slot.call.name == ToolNames.finish) {
        _finishAt = i;
      }
      if (!slot.effect.transcriptRead) continue;
      for (var j = 0; j < i; j++) {
        slot.transcriptDeps.add(j);
      }
    }
  }

  /// Граф путей заново: канонические ключи могли смениться после команды.
  void _rewireEffects() {
    for (final slot in _slots) {
      if (slot.phase == _Phase.pending) slot.effectDeps.clear();
    }
    for (var i = 0; i < _slots.length; i++) {
      final slot = _slots[i];
      if (slot.phase != _Phase.pending) continue;
      for (var j = 0; j < i; j++) {
        if (slot.effect.conflictsWith(_slots[j].effect)) {
          slot.effectDeps.add(j);
        }
      }
    }
    final finishAt = _finishAt;
    if (finishAt == null) return;
    final finish = _slots[finishAt];
    if (finish.phase == _Phase.pending) {
      for (var j = 0; j < finishAt; j++) {
        finish.effectDeps.add(j);
      }
    }
    for (var i = finishAt + 1; i < _slots.length; i++) {
      final slot = _slots[i];
      if (slot.phase == _Phase.pending) slot.effectDeps.add(finishAt);
    }
  }

  /// Один заход за раз. Канонизация ждёт Host, и два захода иначе стартовали
  /// бы один и тот же вызов. Ошибка захода остаётся у его вызывающего, а
  /// следующий заход всё равно получает очередь.
  Future<void> _launch() async {
    final previous = _launchMutex;
    final gate = Completer<void>();
    _launchMutex = gate.future;
    try {
      await previous;
      await _startWave();
    } finally {
      gate.complete();
    }
  }

  Future<void> _startWave() async {
    if (cancel.isCancelled || _failure != null) return;
    if (_pathsDirty) {
      while (_pathsDirty) {
        _pathsDirty = false;
        final first = !_boundOnce;
        await _rebind(includeSettled: first);
        _boundOnce = true;
        if (cancel.isCancelled || _failure != null) return;
      }
      _rewireEffects();
    }
    for (final slot in _slots) {
      if (slot.phase != _Phase.pending || !_ready(slot)) continue;
      slot.phase = _Phase.running;
      _running[slot.index] = _runSlot(slot);
    }
  }

  bool _ready(_Slot slot) {
    for (final index in slot.effectDeps) {
      if (!_slots[index].effectSettled) return false;
    }
    for (final index in slot.transcriptDeps) {
      if (!_slots[index].committed) return false;
    }
    return true;
  }

  Future<void> _runSlot(_Slot slot) async {
    try {
      final resumedCall = resumed[slot.call.id];
      final result = resumedCall == null
          ? await execute(slot.call)
          : await resumedCall();
      slot
        ..result = result
        ..textReady = true;
      if (result.finish) _skipAfter(slot.index);
      await _flush();
      final settled = result.whenSettled;
      if (settled != null) {
        try {
          await settled;
        } on Object {
          // Зависимому чтению важен факт завершения процесса, не его ошибка.
        }
      }
    } on Object catch (error) {
      // Сбой одного вызова остаётся его результатом. Зависимые читают то, что
      // реально лежит на хосте, и ход из-за этого не обрывается.
      slot.result ??= ToolResult('tool failed: $error', isError: true);
      slot.textReady = true;
      await _flush();
    } finally {
      slot.effectSettled = true;
      if (slot.phase == _Phase.running) slot.phase = _Phase.settled;
      // Команда могла создать симлинк. Следующий запуск пересоберёт ключи
      // ещё не начатых вызовов. Запись файла ссылку не создаёт.
      if (canonicalize != null && slot.effect.hostWrite) _pathsDirty = true;
    }
  }

  /// [includeSettled] — первый проход: уже отвеченные вызовы тоже держат пути.
  /// Позже их ключ не трогают: команда этого батча не меняет то, что уже записано.
  Future<void> _rebind({required bool includeSettled}) async {
    final resolve = canonicalize;
    if (resolve == null) return;
    final cache = <String, Future<String?>>{};
    Future<String?> cached(String path) =>
        cache.putIfAbsent(path, () => resolve(path));
    for (final slot in _slots) {
      if (slot.phase == _Phase.running) continue;
      if (slot.phase == _Phase.settled && !includeSettled) continue;
      slot.effect = await slot.rawEffect.bindPaths(cached);
    }
  }

  /// Хвост после `finish` в ленту попадает, но на Host не идёт.
  void _skipAfter(int index) {
    for (var i = index + 1; i < _slots.length; i++) {
      final slot = _slots[i];
      if (slot.phase == _Phase.running || slot.textReady) continue;
      slot
        ..result = const ToolResult('not executed: the task was finished')
        ..textReady = true
        ..effectSettled = true
        ..phase = _Phase.settled;
    }
  }

  void _skipPending(String reason, {bool resumeWaiting = false}) {
    for (final slot in _slots) {
      if (slot.phase != _Phase.pending) continue;
      if (resumeWaiting && resumed.containsKey(slot.call.id)) {
        slot.phase = _Phase.running;
        _running[slot.index] = _runSlot(slot);
        continue;
      }
      slot
        ..result = ToolResult(reason)
        ..textReady = true
        ..effectSettled = true
        ..phase = _Phase.settled;
    }
  }

  Future<int> _nextFinished() {
    final pending = <Future<int>>[];
    for (final entry in _running.entries) {
      pending.add(_finishedIndex(entry.key, entry.value));
    }
    return Future.any(pending);
  }

  Future<int> _finishedIndex(int index, Future<void> done) async {
    await done;
    return index;
  }

  Future<void> _flush() {
    final previous = _flushChain;
    final scheduled = _commitAfter(previous);
    _flushChain = scheduled;
    return scheduled;
  }

  Future<void> _commitAfter(Future<void> previous) async {
    await previous;
    await _commitPrefix();
  }

  Future<void> _commitPrefix() async {
    if (_failure != null) return;
    for (final slot in _slots) {
      if (slot.committed) continue;
      // Дальше в ленте дырка: более поздний результат ждёт свой черёд.
      if (!slot.textReady) break;
      final result = slot.result;
      if (result == null) break;
      try {
        await commit(slot.call, result);
      } on Object catch (error) {
        _failure ??= error;
        return;
      }
      slot.committed = true;
    }
    // Поиск по ленте становится готов, как только предыдущие результаты
    // записаны, не дожидаясь фонового процесса, который их породил.
    await _launch();
  }
}

enum _Phase { pending, running, settled }

class _Slot {
  _Slot({
    required this.index,
    required this.call,
    required this.rawEffect,
    required this.effect,
    required this.phase,
    required this.textReady,
    required this.committed,
    required this.effectSettled,
  });

  final int index;
  final LlmToolCall call;

  /// Эффект по аргументам вызова, до канонизации. Повторный проход идёт от него,
  /// иначе уже отброшенный неразрешённый путь некуда вернуть.
  final ToolEffect rawEffect;
  ToolEffect effect;
  final Set<int> effectDeps = {};
  final Set<int> transcriptDeps = {};
  _Phase phase;
  ToolResult? result;
  bool textReady;
  bool committed;
  bool effectSettled;
}
