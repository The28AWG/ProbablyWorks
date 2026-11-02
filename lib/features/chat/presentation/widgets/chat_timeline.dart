import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
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
/// Лента перевёрнута: новое внизу, и прокрутка от низа не зависит от высоты элементов выше.
/// Пока пользователь внизу, конец последнего сообщения стоит у низа окна, нижний отступ остаётся
/// под ним. Отступ есть только у ленты выше окна: короткий чат стоит у низа без пустого места.
/// Прокрутка вверх отключает слежение, и текст под взглядом не уезжает, даже когда
/// элементы над ним дорисовываются или растут. Прокрутка вниз (до конца ответа или дальше, в
/// отступ) включает слежение снова. Кнопка «к новым сообщениям» возвращает к концу. Отправка своего
/// сообщения всегда прокручивает вниз.
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

  /// Доля высоты окна ленты, которая остаётся пустой под последним сообщением.
  static const _bottomInsetFraction = 1 / 3;

  late final ScrollController _scroll;
  var _follow = true;
  var _showJump = false;

  /// Нижний отступ ленты, который сейчас применён. Ноль, пока лента умещается в окно: см. [_onMetrics].
  var _bottomInset = 0.0;

  /// Пользователь сам прокрутил в пустой отступ под ответом: слежение не тянет его обратно.
  var _inInset = false;

  /// Ключи элементов ленты. По ним находим место элемента на экране, чтобы держать его на месте.
  final _itemKeys = <String, GlobalKey>{};

  /// Id элементов, построенных в текущем проходе. По ним убираем ключи тех, кого больше нет.
  final _liveIds = <String>{};

  /// Элемент, который держим на месте, пока пользователь читает историю.
  _Anchor? _anchor;
  var _anchorScheduled = false;

  /// Смещение, при котором конец последнего сообщения касается низа окна: нижний отступ под ним.
  double get _followOffset => _bottomInset;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController()..addListener(_onScroll);
  }

  /// Пересчитывает отступ по размерам ленты. Содержимое переполняет окно, когда maxScrollExtent
  /// больше уже применённого отступа: тогда отступ нужен. Иначе прокрутка до него не доходит,
  /// и пустое место остаётся под последним сообщением.
  bool _onMetrics(ScrollMetricsNotification notification) {
    final metrics = notification.metrics;
    if (metrics.axisDirection != .up) return false;
    final overflow = metrics.maxScrollExtent > _bottomInset;
    final inset = overflow
        ? metrics.viewportDimension * _bottomInsetFraction
        : 0.0;
    if (inset != _bottomInset) {
      setState(() => _bottomInset = inset);
      if (_follow) _scheduleFollow();
    }
    return false;
  }

  /// Элемент сменил высоту. Чаще всего это живой терминал, который растёт сам, без перестройки ленты:
  /// якорь пересчитываем, иначе читаемый текст уедет.
  bool _onItemResized(SizeChangedLayoutNotification notification) {
    if (!_follow) _scheduleAnchor();
    return false;
  }

  @override
  void didUpdateWidget(covariant ChatTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    final messages = widget.state.messages;
    final sentNow =
        messages.length > oldWidget.state.messages.length &&
        messages.last.role == MessageRole.user;
    // Перестроение уже идёт: достаточно поменять флаг, setState здесь не нужен.
    if (sentNow) {
      _follow = true;
      _showJump = false;
      _inInset = false;
      _anchor = null;
    }
    if (_follow) _scheduleFollow();
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
    // Смещение меньше нижнего отступа означает, что пользователь прокрутил в пустой отступ вниз.
    _inInset = pixels < _followOffset;
    // Внизу — когда конец ответа виден. Прокрутка в пустой отступ тоже означает «внизу».
    final atEnd = pixels <= _followOffset + _followThreshold;
    // Пока пользователь читает историю, запоминаем, где стоит верхний элемент: см. _settleAnchor.
    if (!atEnd) _scheduleAnchor();
    if (atEnd == _follow) return;
    setState(() {
      _follow = atEnd;
      _showJump = !atEnd;
    });
  }

  void _scheduleFollow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_follow || !_scroll.hasClients) return;
      if (!_inInset) _scroll.jumpTo(_followOffset);
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
      _inInset = false;
      _anchor = null;
    });
    if (!_scroll.hasClients) return;
    await _scroll.animateTo(
      _followOffset,
      duration: AppDurations.normal,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = widget.state;
    final chat = state.chat;
    final visible = [
      for (final m in state.messages)
        if (m.role != MessageRole.tool) m,
    ];
    if (visible.isEmpty && !state.isRunning) {
      return ChatWelcome(
        hostLabel: hostLabelOf(state.hosts, chat?.hostId ?? '', l10n),
        onSuggest: (text) =>
            context.read<ChatBloc>().add(ChatSuggestionPicked(text)),
      );
    }

    final runsByMessage = <String, List<ToolRun>>{};
    for (final run in state.runs) {
      runsByMessage.putIfAbsent(run.messageId, () => []).add(run);
    }
    final boundary = _compactionBoundary(chat, visible);

    // Строки собираем от старого к новому и только потом переворачиваем: лента перевёрнута.
    // Шаги (рассуждения и команды) подряд, без видимого текста между ними, образуют одну группу.
    final rows = <Widget>[];
    var anchor = 'start';
    var steps = <LedgerStep>[];
    var stepsAnchor = anchor;

    void flush() {
      if (steps.isEmpty) return;
      rows.add(
        _KeyedTimelineItem(
          id: 'steps:$stepsAnchor',
          liveIds: _liveIds,
          itemKeys: _itemKeys,
          child: ChatColumn.item(
            ChatStepLedger(
              steps: steps,
              live: state.live,
              terminalFor: widget.terminalFor,
            ),
          ),
        ),
      );
      steps = [];
    }

    void step(LedgerStep value) {
      if (steps.isEmpty) stepsAnchor = anchor;
      steps.add(value);
    }

    void item(String id, Widget child) {
      flush();
      rows.add(
        _KeyedTimelineItem(
          id: id,
          liveIds: _liveIds,
          itemKeys: _itemKeys,
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
      final isAssistant = message.role == MessageRole.assistant;
      if (isAssistant && message.reasoning.isNotEmpty) {
        step(ThoughtStep(id: 'thought:${message.id}', text: message.reasoning));
      }
      // Пустой текст ассистента не рисуем, но его шаги остаются в журнале.
      if (!isAssistant || message.text.trim().isNotEmpty) {
        item(
          message.id,
          ChatMessageTile(message: message, editable: !state.isRunning),
        );
      }
      for (final run in runsByMessage[message.id] ?? const <ToolRun>[]) {
        step(RunStep(run));
      }
    }
    // Рассуждения, которые ещё стримятся: они новее всех записанных шагов.
    if (state.streamReasoning.isNotEmpty) {
      step(
        ThoughtStep(
          id: 'thought:live',
          text: state.streamReasoning,
          live: state.streamText.isEmpty,
        ),
      );
    }
    flush();

    // Ключи строятся вместе с элементами, поэтому убираем только те, кого в ленте больше нет.
    _liveIds.clear();
    final children = <Widget>[
      if (state.streamText.isNotEmpty)
        _KeyedTimelineItem(
          id: 'stream',
          liveIds: _liveIds,
          itemKeys: _itemKeys,
          child: ChatColumn.item(AppMarkdown(data: state.streamText)),
        ),
      ...rows.reversed,
    ];
    _itemKeys.removeWhere((id, _) => !_liveIds.contains(id));
    if (!_follow) _scheduleAnchor();

    return Stack(
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: _onMetrics,
          child: NotificationListener<SizeChangedLayoutNotification>(
            onNotification: _onItemResized,
            // Снизу — треть высоты окна, если лента выше окна: конец ответа стоит у низа окна.
            child: ListView(
              controller: _scroll,
              reverse: true,
              padding: EdgeInsets.only(
                top: AppSpacing.md,
                bottom: _bottomInset,
              ),
              children: children,
            ),
          ),
        ),
        if (_showJump)
          Positioned(
            left: 0,
            right: 0,
            bottom: AppSpacing.md,
            child: Center(
              child: FilledButton.tonalIcon(
                onPressed: _jumpToLatest,
                icon: const Icon(Icons.arrow_downward, size: 16),
                label: Text(l10n.chatScrollToLatest),
              ),
            ),
          ),
      ],
    );
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
    required this.liveIds,
    required this.itemKeys,
    required this.child,
  });

  final String id;
  final Set<String> liveIds;
  final Map<String, GlobalKey> itemKeys;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    liveIds.add(id);
    return KeyedSubtree(
      key: ValueKey(id),
      child: SizeChangedLayoutNotifier(
        child: KeyedSubtree(
          key: itemKeys.putIfAbsent(id, GlobalKey.new),
          child: child,
        ),
      ),
    );
  }
}

/// Элемент ленты, который держим на месте: его ключ, верхний край на экране и смещение, при котором
/// это было измерено.
class _Anchor {
  const _Anchor(this.key, this.top, this.pixels);

  final GlobalKey key;
  final double top;
  final double pixels;
}
