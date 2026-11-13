import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/anchored_sliver_list.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_column.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_message_tile.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_step_ledger.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_viewport.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/tools/tool_catalog.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/host/host_terminal.dart';

/// Лента чата: сообщения, журнал шагов и текст, который сейчас печатается.
///
/// Лента сверху вниз: новое внизу. Внизу всегда остаётся пустой отступ в треть высоты окна. Последний ход
/// (сообщение пользователя и ответ агента) имеет минимальную высоту, которая заполняет окно до этого отступа.
/// Поэтому сообщение пользователя прилипает к верху окна, а ответ растёт вниз. Пока пользователь следит за
/// концом, прокрутка едет вместе с новым текстом. Прокрутка вверх отключает слежение, и текст под взглядом
/// не уезжает: коррекция считается в layout (см. [AnchoredSliverList]), без кадров с рывком.
/// Кнопка «к новым сообщениям» возвращает к концу. Отправка своего сообщения всегда возвращает к концу.
class ChatTimeline extends StatefulWidget {
  const ChatTimeline({
    required this.state,
    this.jumpToMessageId,
    this.terminalFor,
    this.editingMessageId,
    this.messageEditor,
    this.onEditMessage,
    this.onRegenerate,
    this.onForkMessage,
    this.editDraftTexts = const {},
    super.key,
  });

  final ChatState state;

  /// Сообщение, к которому нужно прокрутить ленту после открытия.
  final String? jumpToMessageId;

  /// Терминал активного запуска по его id; `null`, если запуск не выполняется в PTY.
  final HostTerminal? Function(String runId)? terminalFor;

  /// Сообщение пользователя, пузырь которого заменён композером правки.
  final String? editingMessageId;

  /// Композер правки. Показывается вместо пузыря [editingMessageId].
  final Widget? messageEditor;

  /// «Изменить» или нажатие по пузырю пользователя. Null — правку из ленты не начать.
  final ValueChanged<ChatMessage>? onEditMessage;

  /// Перезапуск последнего ответа. Null — действие недоступно.
  final VoidCallback? onRegenerate;

  /// Форк истории до завершённого ответа. Null — действие недоступно.
  final ValueChanged<ChatMessage>? onForkMessage;

  /// Неотправленный текст правки по id сообщения. Пузырь показывает его вместо исходного и окрашен.
  final Map<String, String> editDraftTexts;

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

  /// Ключи сообщений для точной прокрутки. Создаются только для видимых строк.
  final _messageKeys = <String, GlobalKey>{};
  String? _pendingJumpId;
  String? _highlightId;
  Timer? _highlightTimer;

  /// Сообщение пользователя, после которого ход только что начался: его ход выезжает снизу к верху окна.
  String? _sentId;

  /// Id элементов, построенных в текущем проходе. По ним убираем ключи тех, кого больше нет.
  final _liveIds = <String>{};

  /// Id элементов, которые уже показывались. Новые элементы появляются плавно, остальные нет.
  final _seenIds = <String>{};
  var _built = false;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController()..addListener(_onScroll);
    _pendingJumpId = widget.jumpToMessageId;
    if (_pendingJumpId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToPending());
    }
  }

  @override
  void didUpdateWidget(covariant ChatTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.jumpToMessageId;
    if (target != null && target != oldWidget.jumpToMessageId) {
      _pendingJumpId = target;
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToPending());
    }
    final messages = widget.state.messages;
    final sentNow =
        messages.length > oldWidget.state.messages.length &&
        messages.last.role == MessageRole.user;
    if (!sentNow) return;
    // Перестроение уже идёт: достаточно поменять поля, setState здесь не нужен.
    _sentId = messages.last.id;
    _follow = true;
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _jumpToPending() {
    final id = _pendingJumpId;
    if (id == null || !mounted) return;
    if (_follow) setState(() => _follow = false);
    _attemptJump(id, 0);
  }

  /// Точная прокрутка работает, только когда строка построена. Для далёкого
  /// сообщения сначала прыгаем на примерную долю ленты, затем уточняем.
  void _attemptJump(String id, int attempt) {
    if (!mounted || _pendingJumpId != id) return;
    final context = _messageKeys[id]?.currentContext;
    if (context != null) {
      _pendingJumpId = null;
      setState(() => _highlightId = id);
      _highlightTimer?.cancel();
      _highlightTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _highlightId = null);
      });
      unawaited(
        Scrollable.ensureVisible(
          context,
          alignment: 0.12,
          duration: AppDurations.normal,
          curve: Curves.easeOutCubic,
        ),
      );
      return;
    }
    if (attempt >= 5 || !_scroll.hasClients) {
      if (attempt >= 5) _pendingJumpId = null;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _attemptJump(id, attempt + 1),
      );
      return;
    }
    final visible = [
      for (final message in widget.state.messages)
        if (message.role != MessageRole.tool) message,
    ];
    final index = visible.indexWhere((message) => message.id == id);
    if (index < 0) {
      _pendingJumpId = null;
      return;
    }
    final max = _scroll.position.maxScrollExtent;
    final ratio = visible.length <= 1 ? 0.0 : index / (visible.length - 1);
    _scroll.jumpTo((max * ratio).clamp(0.0, max));
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _attemptJump(id, attempt + 1),
    );
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // Внизу — когда конец ответа виден. Нижний отступ входит в прокрутку, поэтому конец — это maxScrollExtent.
    final atEnd = _scroll.position.extentAfter <= _followThreshold;
    if (atEnd == _follow) return;
    setState(() {
      _follow = atEnd;
    });
  }

  /// Элемент новый, если его ещё не было в ленте. Первую отрисовку не анимируем: чат открывается сразу.
  bool _isFresh(String id) => _built && !_seenIds.contains(id);

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final visible = [
      for (final m in state.messages)
        if (m.role != MessageRole.tool) m,
    ];
    // Пустой чат показывает ChatBody (приветствие и композер), здесь лента пуста.
    final empty = visible.isEmpty && !state.isRunning;
    return AnimatedSwitcher(
      duration: AppDurations.normal,
      child: empty
          ? const SizedBox.shrink(key: ValueKey('empty'))
          : LayoutBuilder(
              key: const ValueKey('timeline'),
              builder: (context, constraints) =>
                  _buildTimeline(visible, constraints.maxHeight),
            ),
    );
  }

  Widget _buildTimeline(List<ChatMessage> visible, double viewportHeight) {
    final state = widget.state;
    final chat = state.chat;
    final runsByMessage = <String, List<ToolRun>>{};
    for (final run in state.runs) {
      runsByMessage.putIfAbsent(run.messageId, () => []).add(run);
    }
    final boundary = _compactionBoundary(chat, visible);
    final lastUser = visible.lastIndexWhere((m) => m.role == MessageRole.user);
    final lastAnswer = visible.lastIndexWhere(
      (m) => m.role == MessageRole.assistant && m.text.trim().isNotEmpty,
    );
    final answerIds = _answerIds(state.messages, running: state.isRunning);
    final taskTimes = _taskDurations(state.messages, running: state.isRunning);

    // Строки собираем от старого к новому: лента сверху вниз.
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
          fresh: _isFresh(id),
          child: ChatColumn.item(
            context,
            ChatStepLedger(
              steps: value,
              live: state.live,
              terminalFor: widget.terminalFor,
              expandThoughts: display.thoughts == ThoughtsVisibility.expanded,
              expandTools: display.tools == ToolsVisibility.expanded,
              expandWhileActive: display.expandWhileActive,
              workspace: _projectWorkspace(state),
              windows: _hostWindows(state),
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

    void item(String id, Widget child, {String? messageId}) {
      flush();
      _liveIds.add(id);
      rows.add(
        _KeyedTimelineItem(
          id: id,
          fresh: _isFresh(id),
          anchorKey: messageId == null
              ? null
              : _messageKeys.putIfAbsent(messageId, GlobalKey.new),
          highlighted: messageId != null && messageId == _highlightId,
          child: ChatColumn.item(context, child),
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
        if (display.thoughts != ThoughtsVisibility.current) {
          step(
            ThoughtStep(id: 'thought:${message.id}', text: message.reasoning),
            slot,
          );
        }
      }
      // Пустой текст ассистента не рисуем, но его шаги остаются в журнале.
      if (!isAssistant || message.text.trim().isNotEmpty) {
        final edit = widget.onEditMessage;
        final tile = ChatMessageTile(
          key: const ValueKey('bubble'),
          message: message,
          editable: !state.isRunning,
          isLastAnswer: answerIds.contains(message.id),
          turnElapsed: taskTimes[message.id],
          onEdit: message.role == MessageRole.user && edit != null
              ? () => edit(message)
              : null,
          onRegenerate: i == lastAnswer && !state.isRunning
              ? widget.onRegenerate
              : null,
          onFork:
              answerIds.contains(message.id) &&
                  !state.isRunning &&
                  widget.onForkMessage != null
              ? () => widget.onForkMessage!(message)
              : null,
          editText: widget.editDraftTexts[message.id],
        );
        // Смена пузыря и композера правки меняет высоту: слот сглаживает только этот переход.
        // Сворачивание текста анимировать нельзя: пузырь уже короткий, а слот ещё держит
        // прежнюю высоту, и под сообщением остаётся пустота. У остальных строк слота нет,
        // чтобы первое появление ленты не анимировало каждую высоту.
        final editor = widget.messageEditor;
        final editing =
            message.role == MessageRole.user &&
            message.id == widget.editingMessageId &&
            editor != null;
        item(
          message.id,
          messageId: message.id,
          message.role == MessageRole.user
              ? _UserBubbleSlot(
                  editing: editing,
                  child: AnimatedSwitcher(
                    duration: AppDurations.fast,
                    child: editing
                        ? KeyedSubtree(
                            key: const ValueKey('editing'),
                            child: editor,
                          )
                        : tile,
                  ),
                )
              : tile,
        );
      }
      for (final run in runsByMessage[message.id] ?? const <ToolRun>[]) {
        if (display.tools != ToolsVisibility.active || run.isActive) {
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
            fresh: _isFresh('stream'),
            child: ChatColumn.item(
              context,
              AppMarkdown(data: state.streamText),
            ),
          )
        : null;

    _seenIds.addAll(_liveIds);
    _built = true;

    final gap = viewportHeight * _bottomGapFraction;
    // Последний ход заполняет окно от верхнего отступа до низа. Отступ внизу входит в ход.
    final turnMinHeight = math.max(0.0, viewportHeight - AppSpacing.md);
    // Лента сверху вниз: старое выше, новое ниже. Отступ внизу входит в последний элемент: он и есть
    // хвост ленты, к которому прокрутка держит конец. Ход заполняет окно до отступа.
    final gapBox = SizedBox(key: const ValueKey('timeline-gap'), height: gap);
    final List<Widget> children;
    if (lastUser < 0) {
      children = [
        ...rows,
        Column(
          key: const ValueKey('tail'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [?stream, gapBox],
        ),
      ];
    } else {
      final userId = visible[lastUser].id;
      final turn = [...rows.sublist(turnStart), ?stream, gapBox];
      children = [
        ...rows.sublist(0, turnStart),
        // Высота выезжает от нуля, когда пользователь только отправил сообщение.
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
      ];
    }

    return ChatViewport(
      height: viewportHeight,
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          AnchoredSliverList(
            following: _follow,
            delegate: SliverChildListDelegate([
              const SizedBox(height: AppSpacing.md),
              ...children,
            ]),
          ),
        ],
      ),
    );
  }

  /// Id ответов, под которыми стоит «Копировать»: закрывающее сообщение каждого законченного хода.
  ///
  /// Ход — сообщение пользователя и всё до следующего такого сообщения. У каждого законченного хода
  /// свой ответ. Пока агент отвечает, у текущего хода ответа нет: это процесс, он ещё может дописать
  /// текст и инструменты, и уже показанное сообщение не последнее. Ответы прошлых ходов при этом остаются.
  /// Внутри хода ответ — последнее сообщение ассистента, и только если после него действие не продолжается
  /// ([_isFinalAnswer]): есть текст и нет вызовов, кроме `finish`. Более ранний текст того же хода,
  /// за которым идут инструменты, — шаг, а не ответ.
  static Set<String> _answerIds(
    List<ChatMessage> messages, {
    required bool running,
  }) {
    final starts = <int>[
      for (var i = 0; i < messages.length; i++)
        if (messages[i].role == MessageRole.user) i,
    ];
    final ids = <String>{};
    for (var k = 0; k < starts.length; k++) {
      if (running && k == starts.length - 1) break;
      final end = k + 1 < starts.length ? starts[k + 1] : messages.length;
      ChatMessage? answer;
      for (var i = starts[k] + 1; i < end; i++) {
        final message = messages[i];
        if (message.role == MessageRole.assistant) answer = message;
      }
      if (answer != null && _isFinalAnswer(answer)) ids.add(answer.id);
    }
    return ids;
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

/// Слот сообщения пользователя. Высоту анимирует только смена пузыря и композера правки.
///
/// Раскрытие и сворачивание текста живут внутри пузыря и родителя не перестраивают. [AnimatedSize]
/// здесь не подходит: он всегда догоняет ребёнка отдельной анимацией, поэтому при сворачивании пузырь
/// уже короткий, а слот ещё держит прежнюю высоту — под сообщением остаётся пустая полоса.
class _UserBubbleSlot extends StatefulWidget {
  const _UserBubbleSlot({required this.editing, required this.child});

  /// Сейчас вместо пузыря показан композер правки.
  final bool editing;
  final Widget child;

  @override
  State<_UserBubbleSlot> createState() => _UserBubbleSlotState();
}

class _UserBubbleSlotState extends State<_UserBubbleSlot>
    with SingleTickerProviderStateMixin {
  /// Плавная смена высоты включена на время перехода в правку и обратно.
  var _animate = false;

  @override
  void didUpdateWidget(covariant _UserBubbleSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editing != widget.editing) _animate = true;
  }

  void _animationEnded() {
    if (!_animate || !mounted) return;
    setState(() => _animate = false);
  }

  @override
  Widget build(BuildContext context) => _SnapSize(
    animate: _animate,
    duration: AppDurations.normal,
    curve: Curves.easeOutCubic,
    vsync: this,
    onEnd: _animationEnded,
    child: widget.child,
  );
}

/// Размер ребёнка. Пока [animate] ложно, слот равен ребёнку в том же кадре.
/// Когда [animate] истинно, слот догоняет новую высоту от размера прошлого кадра.
class _SnapSize extends SingleChildRenderObjectWidget {
  const _SnapSize({
    required this.animate,
    required this.duration,
    required this.curve,
    required this.vsync,
    required this.onEnd,
    required super.child,
  });

  final bool animate;
  final Duration duration;
  final Curve curve;
  final TickerProvider vsync;
  final VoidCallback onEnd;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSnapSize(
    animate: animate,
    duration: duration,
    curve: curve,
    vsync: vsync,
    onEnd: onEnd,
    textDirection: Directionality.maybeOf(context),
  );

  @override
  void updateRenderObject(BuildContext context, _RenderSnapSize renderObject) {
    renderObject
      ..animate = animate
      ..duration = duration
      ..curve = curve
      ..vsync = vsync
      ..onEnd = onEnd
      ..textDirection = Directionality.maybeOf(context);
  }
}

class _RenderSnapSize extends RenderAligningShiftedBox {
  _RenderSnapSize({
    required TickerProvider vsync,
    required this._animate,
    required Duration duration,
    required Curve curve,
    required this._onEnd,
    required super.textDirection,
  }) : _vsync = vsync,
       super(alignment: Alignment.topCenter) {
    _controller = AnimationController(vsync: vsync, duration: duration)
      ..addListener(_handleTick)
      ..addStatusListener(_handleStatus);
    _animation = CurvedAnimation(parent: _controller, curve: curve);
  }

  late final AnimationController _controller;
  late final CurvedAnimation _animation;
  final SizeTween _tween = SizeTween();

  /// Размер, к которому сейчас идём. Null, пока ребёнок ни разу не разложен.
  Size? _end;
  double _lastTick = 0;
  bool _animate;
  TickerProvider _vsync;
  VoidCallback _onEnd;
  final LayerHandle<ClipRectLayer> _clip = LayerHandle<ClipRectLayer>();

  bool get animate => _animate;

  set animate(bool value) {
    if (value == _animate) return;
    _animate = value;
    markNeedsLayout();
  }

  Duration get duration => _controller.duration!;

  set duration(Duration value) {
    if (value == _controller.duration) return;
    _controller.duration = value;
  }

  Curve get curve => _animation.curve;

  set curve(Curve value) {
    if (value == _animation.curve) return;
    _animation.curve = value;
  }

  TickerProvider get vsync => _vsync;

  set vsync(TickerProvider value) {
    if (value == _vsync) return;
    _vsync = value;
    _controller.resync(value);
  }

  VoidCallback get onEnd => _onEnd;

  set onEnd(VoidCallback value) {
    if (identical(value, _onEnd)) return;
    _onEnd = value;
  }

  void _handleTick() {
    if (_controller.value != _lastTick) markNeedsLayout();
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _onEnd();
  }

  /// Копия размера, которую можно хранить: чужой [Size] из layout менять нельзя.
  Size _adopt(Size value) {
    var adopted = value;
    assert(() {
      adopted = debugAdoptSize(value);
      return true;
    }());
    return adopted;
  }

  void _go(Size target) {
    _tween.begin = hasSize ? _adopt(size) : _adopt(target);
    _tween.end = _end = _adopt(target);
    _lastTick = 0;
    _controller.forward(from: 0);
  }

  @override
  void detach() {
    _controller.stop();
    super.detach();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    final target = child.size;
    if (!_animate) {
      // Не трогаем value контроллера: присваивание из layout снова пометит объект грязным.
      if (_controller.isAnimating) _controller.stop();
      _end = _adopt(target);
      size = constraints.constrain(target);
    } else if (_end != target) {
      _go(target);
      size = constraints.constrain(_tween.evaluate(_animation)!);
    } else {
      // Слот уходил из дерева на середине перехода: тикер остановлен в detach, здесь его продолжаем.
      if (!_controller.isAnimating && _controller.value < 1) {
        _lastTick = _controller.value;
        _controller.forward();
      }
      final animated = _tween.evaluate(_animation) ?? target;
      size = constraints.constrain(animated);
    }
    alignChild();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final overflows =
        size.width < child.size.width || size.height < child.size.height;
    if (!overflows) {
      _clip.layer = null;
      super.paint(context, offset);
      return;
    }
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      super.paint,
      oldLayer: _clip.layer,
    );
  }

  @override
  void dispose() {
    _clip.layer = null;
    _controller
      ..removeListener(_handleTick)
      ..removeStatusListener(_handleStatus)
      ..dispose();
    super.dispose();
  }
}

/// Элемент ленты с ключом по id: состояние виджетов сохраняется при перестроении.
class _KeyedTimelineItem extends StatelessWidget {
  const _KeyedTimelineItem({
    required this.id,
    required this.fresh,
    required this.child,
    this.anchorKey,
    this.highlighted = false,
  });

  final String id;

  /// Элемент появился только что: его плавно показываем.
  final bool fresh;
  final Widget child;

  /// Ключ для перехода к сообщению из поиска.
  final GlobalKey? anchorKey;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    Widget content = _Appear(animate: fresh, child: child);
    if (highlighted) {
      content = DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer
              .withValues(alpha: 0.28),
          borderRadius: AppRadius.mdAll,
        ),
        child: content,
      );
    }
    final keyed = KeyedSubtree(key: ValueKey(id), child: content);
    return anchorKey == null
        ? keyed
        : KeyedSubtree(key: anchorKey, child: keyed);
  }
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

/// Рабочая папка проекта для подписи файла. Дом сюда не попадает: без выбранной папки путь полный.
String? _projectWorkspace(ChatState state) {
  final project = state.project?.workspace.trim();
  if (project != null && project.isNotEmpty) return project;
  final folder = state.chat?.workspace?.trim();
  if (folder != null && folder.isNotEmpty) return folder;
  return null;
}

/// Windows-хост сравнивает пути без регистра. Чужой хост не найден — сравнение как у POSIX.
bool _hostWindows(ChatState state) {
  final hostId = state.chat?.hostId;
  if (hostId == null) return false;
  for (final host in state.hosts) {
    if (host.id == hostId) return host.os == HostOs.windows;
  }
  return false;
}
