import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/domain/steps_display.dart';
import 'package:probably_works/agent/tools/tool_catalog.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_column.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_message_tile.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_meta_bar.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_step_ledger.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_welcome.dart';
import 'package:probably_works/host/host_terminal.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Лента чата: сообщения, журнал шагов и текст, который сейчас печатается.
///
/// Лента перевёрнута: новое внизу, прокрутка идёт от низа. Внизу всегда остаётся пустой отступ
/// в треть высоты окна. Последний ход (сообщение пользователя и ответ агента) имеет минимальную
/// высоту, которая заполняет окно до этого отступа. Поэтому сообщение пользователя прилипает к верху
/// окна, а ответ растёт вниз. Когда ответ доходит до отступа, текст ползёт вверх, отступ остаётся.
/// Прокрутка вверх отключает слежение, и текст под взглядом не уезжает. Кнопка «к новым сообщениям»
/// возвращает к концу. Отправка своего сообщения всегда возвращает к концу.
class ChatTimeline extends StatefulWidget {
  const ChatTimeline({required this.state, this.terminalFor, super.key});

  final ChatState state;

  /// Терминал активного запуска по его id; `null`, если запуск не выполняется в PTY.
  final HostTerminal? Function(String runId)? terminalFor;

  @override
  State<ChatTimeline> createState() => _ChatTimelineState();
}

class _ChatTimelineState extends State<ChatTimeline> {
  /// Расстояние до конца, в пределах которого считаем, что пользователь «внизу».
  static const _followThreshold = 80.0;

  /// Доля высоты окна, которая остаётся пустой под последним сообщением.
  static const _bottomGapFraction = 1 / 3;

  late final ScrollController _scroll;
  var _follow = true;
  var _showJump = false;

  /// Сообщение пользователя, после которого ход только что начался: его ход выезжает снизу к верху окна.
  String? _sentId;

  /// Элемент, который держим на месте, пока пользователь читает историю.
  _Anchor? _anchor;
  var _anchorScheduled = false;

  /// Ключи элементов ленты. По ним находим место элемента на экране, чтобы держать его на месте.
  final _itemKeys = <String, GlobalKey>{};

  /// Id элементов, построенных в текущем проходе. По ним убираем ключи тех, кого больше нет.
  final _liveIds = <String>{};

  /// Id элементов, которые уже показывались. Новые элементы появляются плавно, остальные нет.
  final _seenIds = <String>{};
  var _built = false;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController()..addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant ChatTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    final messages = widget.state.messages;
    final sentNow =
        messages.length > oldWidget.state.messages.length &&
        messages.last.role == MessageRole.user;
    if (!sentNow) return;
    // Перестроение уже идёт: достаточно поменять поля, setState здесь не нужен.
    _sentId = messages.last.id;
    _follow = true;
    _showJump = false;
    _anchor = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || _scroll.position.pixels == 0) {
        return;
      }
      unawaited(
        _scroll.animateTo(
          0,
          duration: AppDurations.normal,
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pixels = _scroll.position.pixels;
    // Внизу — когда конец ответа виден. Нижний отступ находится внутри прокрутки до нуля.
    final atEnd = pixels <= _followThreshold;
    // Пока пользователь читает историю, запоминаем, где стоит верхний элемент: см. _settleAnchor.
    if (!atEnd) _scheduleAnchor();
    if (atEnd == _follow) return;
    setState(() {
      _follow = atEnd;
      _showJump = !atEnd;
    });
  }

  /// Держит верхний видимый элемент на месте, пока пользователь не внизу. Прокрутка самого
  /// пользователя этим не отменяется: компенсируется только то, что изменилось в ленте.
  void _scheduleAnchor() {
    if (_anchorScheduled) return;
    _anchorScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anchorScheduled = false;
      if (mounted) _settleAnchor();
    });
  }

  void _settleAnchor() {
    final viewport = context.findRenderObject();
    if (_follow || !_scroll.hasClients || viewport is! RenderBox) {
      _anchor = null;
      return;
    }
    final previous = _anchor;
    final previousTop = previous == null
        ? null
        : _topInViewport(previous.key, viewport);
    if (previous == null || previousTop == null) {
      _anchor = _pickAnchor(viewport);
      return;
    }
    final pixels = _scroll.position.pixels;
    // Сдвиг элемента на экране = прокрутка пользователя + изменение ленты над ним или под ним.
    // Лишь прокрутку пользователя мы не трогаем, а изменение ленты гасим.
    final shift = (previousTop - previous.top) - (pixels - previous.pixels);
    if (shift.abs() < 0.5) {
      _anchor = _Anchor(previous.key, previousTop, pixels);
      return;
    }
    _scroll.jumpTo(pixels - shift);
    final restored = _scroll.position.pixels;
    _anchor = _Anchor(
      previous.key,
      previousTop + (restored - pixels),
      restored,
    );
  }

  /// Новый якорь: видимый элемент, который ближе всего к верхнему краю окна.
  _Anchor? _pickAnchor(RenderBox viewport) {
    _Anchor? best;
    var bestDistance = double.infinity;
    for (final entry in _itemKeys.entries) {
      final top = _topInViewport(entry.value, viewport);
      if (top == null || top.abs() >= bestDistance) continue;
      if (!_isVisible(entry.value, top, viewport)) continue;
      bestDistance = top.abs();
      best = _Anchor(entry.value, top, _scroll.position.pixels);
    }
    return best;
  }

  /// Верхний край элемента относительно окна, даже если он уже ушёл за край. Null, если элемента нет.
  double? _topInViewport(GlobalKey key, RenderBox viewport) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero, ancestor: viewport).dy;
  }

  bool _isVisible(GlobalKey key, double top, RenderBox viewport) {
    final height =
        (key.currentContext?.findRenderObject() as RenderBox?)?.size.height;
    return height != null && top + height > 0 && top < viewport.size.height;
  }

  Future<void> _jumpToLatest() async {
    setState(() {
      _follow = true;
      _showJump = false;
      _anchor = null;
    });
    if (!_scroll.hasClients) return;
    await _scroll.animateTo(
      0,
      duration: AppDurations.normal,
      curve: Curves.easeOutCubic,
    );
  }

  /// Элемент новый, если его ещё не было в ленте. Первую отрисовку не анимируем: чат открывается сразу.
  bool _isFresh(String id) => _built && !_seenIds.contains(id);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = widget.state;
    final visible = [
      for (final m in state.messages)
        if (m.role != MessageRole.tool) m,
    ];
    final empty = visible.isEmpty && !state.isRunning;
    return AnimatedSwitcher(
      duration: AppDurations.normal,
      child: empty
          ? ChatWelcome(
              key: const ValueKey('welcome'),
              hostLabel: hostLabelOf(
                state.hosts,
                state.chat?.hostId ?? '',
                l10n,
              ),
              onSuggest: (text) =>
                  context.read<ChatBloc>().add(ChatSuggestionPicked(text)),
            )
          : LayoutBuilder(
              key: const ValueKey('timeline'),
              builder: (context, constraints) =>
                  _buildTimeline(visible, l10n, constraints.maxHeight),
            ),
    );
  }

  Widget _buildTimeline(
    List<ChatMessage> visible,
    AppLocalizations l10n,
    double viewportHeight,
  ) {
    final state = widget.state;
    final chat = state.chat;
    final runsByMessage = <String, List<ToolRun>>{};
    for (final run in state.runs) {
      runsByMessage.putIfAbsent(run.messageId, () => []).add(run);
    }
    final boundary = _compactionBoundary(chat, visible);
    final lastUser = visible.lastIndexWhere((m) => m.role == MessageRole.user);
    final lastAnswerId = _lastAnswerId(visible);
    final taskTimes = _taskDurations(state.messages, running: state.isRunning);

    // Строки собираем от старого к новому и только потом переворачиваем: лента перевёрнута.
    // Шаги (рассуждения и команды) подряд, без видимого текста между ними, образуют одну группу.
    _liveIds.clear();
    final display = state.stepsDisplay;
    final rows = <Widget>[];
    var anchor = 'start';
    var steps = <LedgerStep>[];
    // Слоты шагов сегмента дают стабильные ключи строкам, когда группировка выключена.
    var slots = <String>[];
    var stepsAnchor = anchor;
    var thoughts = 0;
    // Индекс строки, с которой начинается последний ход: сообщение пользователя и всё после него.
    var turnStart = 0;

    void ledger(String id, List<LedgerStep> value) {
      _liveIds.add(id);
      rows.add(
        _KeyedTimelineItem(
          id: id,
          itemKeys: _itemKeys,
          fresh: _isFresh(id),
          child: ChatColumn.item(
            ChatStepLedger(
              steps: value,
              live: state.live,
              terminalFor: widget.terminalFor,
            ),
          ),
        ),
      );
    }

    void flush() {
      final segment = steps;
      final segmentSlots = slots;
      steps = [];
      slots = [];
      thoughts = 0;
      if (segment.isEmpty) return;
      if (display.group) {
        ledger('steps:$stepsAnchor', segment);
        return;
      }
      for (var i = 0; i < segment.length; i++) {
        ledger('steps:$stepsAnchor/${segmentSlots[i]}', [segment[i]]);
      }
    }

    void step(LedgerStep value, String slot) {
      if (steps.isEmpty) stepsAnchor = anchor;
      steps.add(value);
      slots.add(slot);
    }

    void item(String id, Widget child) {
      flush();
      _liveIds.add(id);
      rows.add(
        _KeyedTimelineItem(
          id: id,
          itemKeys: _itemKeys,
          fresh: _isFresh(id),
          child: ChatColumn.item(child),
        ),
      );
      anchor = id;
    }

    for (var i = 0; i < visible.length; i++) {
      final message = visible[i];
      if (i == boundary) {
        item(
          'compaction',
          ChatCompactionMarker(summary: chat?.compactionSummary),
        );
      }
      if (i == lastUser) {
        flush();
        turnStart = rows.length;
      }
      final isAssistant = message.role == MessageRole.assistant;
      if (isAssistant && message.reasoning.isNotEmpty) {
        // Номер считаем и для скрытых мыслей: ключ строки не должен зависеть от настройки.
        final slot = 'thought#${thoughts++}';
        if (display.thoughts == ThoughtsVisibility.all) {
          step(
            ThoughtStep(id: 'thought:${message.id}', text: message.reasoning),
            slot,
          );
        }
      }
      // Пустой текст ассистента не рисуем, но его шаги остаются в журнале.
      if (!isAssistant || message.text.trim().isNotEmpty) {
        item(
          message.id,
          ChatMessageTile(
            message: message,
            editable: !state.isRunning,
            isLastAnswer: message.id == lastAnswerId,
            turnElapsed: taskTimes[message.id],
          ),
        );
      }
      for (final run in runsByMessage[message.id] ?? const <ToolRun>[]) {
        if (display.tools == ToolsVisibility.all || run.isActive) {
          step(RunStep(run), run.id);
        }
      }
    }
    // Рассуждение, которое ещё стримится, новее всех записанных шагов и всегда видно.
    if (state.streamReasoning.isNotEmpty) {
      step(
        ThoughtStep(
          id: 'thought:live',
          text: state.streamReasoning,
          live: state.streamText.isEmpty,
        ),
        'thought#${thoughts++}',
      );
    }
    flush();

    final streaming = state.streamText.isNotEmpty;
    if (streaming) _liveIds.add('stream');
    final stream = streaming
        ? _KeyedTimelineItem(
            id: 'stream',
            itemKeys: _itemKeys,
            fresh: _isFresh('stream'),
            child: ChatColumn.item(AppMarkdown(data: state.streamText)),
          )
        : null;

    // Id уже зарегистрированы при сборке строк: убираем только ключи тех, кого в ленте больше нет.
    _itemKeys.removeWhere((id, _) => !_liveIds.contains(id));
    _seenIds.addAll(_liveIds);
    _built = true;
    if (!_follow) _scheduleAnchor();

    final gap = viewportHeight * _bottomGapFraction;
    // Высота, которую занимает последний ход: от верха окна до отступа внизу.
    final turnMinHeight = math.max(0.0, viewportHeight - gap - AppSpacing.md);
    final List<Widget> children;
    if (lastUser < 0) {
      children = [?stream, ...rows.reversed];
    } else {
      final userId = visible[lastUser].id;
      final turn = [...rows.sublist(turnStart), ?stream];
      children = [
        // Ход заполняет окно до отступа. Высота выезжает от нуля, когда пользователь только отправил сообщение.
        TweenAnimationBuilder<double>(
          key: ValueKey('turn:$userId'),
          tween: Tween<double>(begin: _sentId == userId ? 0.0 : 1.0, end: 1.0),
          duration: AppDurations.normal,
          curve: Curves.easeOutCubic,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: turn,
          ),
          builder: (context, fill, child) => ConstrainedBox(
            constraints: BoxConstraints(minHeight: fill * turnMinHeight),
            child: child,
          ),
        ),
        ...rows.sublist(0, turnStart).reversed,
      ];
    }

    return Stack(
      children: [
        // Любое изменение высоты элемента (анимация, копирование ушло с предыдущего ответа, раскрытие шага)
        // во время чтения истории гасится якорем на этом же кадре, поэтому текст под взглядом не уезжает.
        NotificationListener<SizeChangedLayoutNotification>(
          onNotification: _onLayoutChanged,
          child: ListView(
            controller: _scroll,
            reverse: true,
            padding: EdgeInsets.only(top: AppSpacing.md, bottom: gap),
            children: children,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: AppSpacing.md,
          child: Center(
            child: AnimatedSwitcher(
              duration: AppDurations.fast,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: animation.drive(
                    Tween<Offset>(
                      begin: const Offset(0, 0.5),
                      end: Offset.zero,
                    ),
                  ),
                  child: child,
                ),
              ),
              child: _showJump
                  ? FilledButton.tonalIcon(
                      key: const ValueKey('jump'),
                      onPressed: _jumpToLatest,
                      icon: const Icon(Icons.arrow_downward, size: 16),
                      label: Text(l10n.chatScrollToLatest),
                    )
                  : const SizedBox.shrink(key: ValueKey('none')),
            ),
          ),
        ),
      ],
    );
  }

  /// Размер элемента изменился: при чтении истории гасим сдвиг якорем на этом же кадре.
  bool _onLayoutChanged(SizeChangedLayoutNotification _) {
    if (!_follow) _scheduleAnchor();
    return false;
  }

  /// Id последнего ответа агента, который виден в ленте. Кнопка «Копировать» показывается только у него.
  static String? _lastAnswerId(List<ChatMessage> visible) {
    for (var i = visible.length - 1; i >= 0; i--) {
      final message = visible[i];
      if (message.role == MessageRole.assistant &&
          message.text.trim().isNotEmpty) {
        return message.id;
      }
    }
    return null;
  }

  /// Время каждого задания: от сообщения пользователя до последнего шага его хода (ответа ассистента или
  /// результата инструмента). Задание — сообщение пользователя и всё до следующего такого сообщения.
  /// Ключ — id финального ответа задания. Время показываем только у законченного задания: последнее задание
  /// без времени, пока идёт ход.
  static Map<String, Duration> _taskDurations(
    List<ChatMessage> messages, {
    required bool running,
  }) {
    final result = <String, Duration>{};
    final starts = [
      for (var i = 0; i < messages.length; i++)
        if (messages[i].role == MessageRole.user) i,
    ];
    for (var k = 0; k < starts.length; k++) {
      final closed = k + 1 < starts.length;
      if (!closed && running) break;
      final end = closed ? starts[k + 1] : messages.length;
      ChatMessage? last;
      ChatMessage? answer;
      for (var i = starts[k] + 1; i < end; i++) {
        final message = messages[i];
        if (message.role == MessageRole.assistant) answer = message;
        if (message.role == MessageRole.assistant ||
            message.role == MessageRole.tool) {
          last = message;
        }
      }
      if (last == null || answer == null || !_isFinalAnswer(answer)) continue;
      final elapsed = last.createdAt.difference(messages[starts[k]].createdAt);
      if (!elapsed.isNegative) result[answer.id] = elapsed;
    }
    return result;
  }

  /// Финальный ответ задания: текст и без вызовов инструментов, кроме `finish`.
  /// Ответ с другими инструментами — промежуточный шаг (в том числе до сообщения, отправленного во время хода).
  static bool _isFinalAnswer(ChatMessage message) {
    if (message.text.trim().isEmpty) return false;
    for (final call in message.toolCalls) {
      if (call.name != ToolNames.finish) return false;
    }
    return true;
  }

  /// Индекс видимого сообщения, с которого начинаются несводные сообщения, или -1, если метки нет.
  static int _compactionBoundary(Chat? chat, List<ChatMessage> visible) {
    final until = chat?.compactedUntilSeq ?? 0;
    if (until <= 0) return -1;
    final index = visible.indexWhere((m) => m.seq > until);
    return index > 0 ? index : -1;
  }
}

/// Элемент ленты с ключами по id для стабильного состояния и якоря прокрутки.
class _KeyedTimelineItem extends StatelessWidget {
  const _KeyedTimelineItem({
    required this.id,
    required this.itemKeys,
    required this.fresh,
    required this.child,
  });

  final String id;
  final Map<String, GlobalKey> itemKeys;

  /// Элемент появился только что: его плавно показываем.
  final bool fresh;
  final Widget child;

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: ValueKey(id),
    child: SizeChangedLayoutNotifier(
      child: _Appear(
        animate: fresh,
        child: KeyedSubtree(
          key: itemKeys.putIfAbsent(id, GlobalKey.new),
          child: child,
        ),
      ),
    ),
  );
}

/// Плавное появление элемента ленты: прозрачность и сдвиг на один отступ снизу вверх.
/// Сдвиг не меняет раскладку, поэтому соседние элементы не дёргаются.
class _Appear extends StatefulWidget {
  const _Appear({required this.animate, required this.child});

  final bool animate;
  final Widget child;

  @override
  State<_Appear> createState() => _AppearState();
}

class _AppearState extends State<_Appear> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppDurations.normal,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _controller.forward();
    } else {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _curve,
    child: widget.child,
    builder: (context, child) => Opacity(
      opacity: _curve.value,
      child: Transform.translate(
        offset: Offset(0, (1 - _curve.value) * AppSpacing.sm),
        child: child,
      ),
    ),
  );
}

/// Элемент, который держим на месте: его ключ, верхний край на экране и смещение, при котором
/// это было измерено.
class _Anchor {
  const _Anchor(this.key, this.top, this.pixels);

  final GlobalKey key;
  final double top;
  final double pixels;
}
