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
/// под ним. Прокрутка вверх отключает слежение, и текст под взглядом не уезжает, даже когда
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

  /// Доля высоты экрана, которая остаётся пустой под последним сообщением.
  static const _bottomInsetFraction = 2 / 3;

  late final ScrollController _scroll;
  var _attached = false;
  var _follow = true;
  var _showJump = false;

  /// Высота нижнего отступа ленты. Пересчитывается при смене размера окна.
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    final inset = MediaQuery.sizeOf(context).height * _bottomInsetFraction;
    if (!_attached) {
      _attached = true;
      // Сразу стартуем с конца ответа, чтобы первый кадр не показывал пустой отступ.
      _scroll = ScrollController(initialScrollOffset: inset)
        ..addListener(_onScroll);
    }
    _bottomInset = inset;
    // Смена размера окна меняет отступ: если следим, снова ставим конец ответа в низ окна.
    if (_follow) _scheduleFollow();
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

    // Ключ у каждого элемента: без него Flutter переиспользует состояние по индексу, и при вставке
    // в начало раскрытие шагов или наведение уехали бы на соседний элемент.
    _liveIds.clear();

    // Порядок от нового к старому: лента перевёрнута, нулевой индекс стоит у низа.
    final children = <Widget>[
      if (state.streamText.isNotEmpty)
        _KeyedTimelineItem(
          id: 'stream',
          liveIds: _liveIds,
          itemKeys: _itemKeys,
          child: ChatColumn.item(AppMarkdown(data: state.streamText)),
        ),
      for (var i = visible.length - 1; i >= 0; i--) ...[
        if (runsByMessage[visible[i].id] case final runs?)
          _KeyedTimelineItem(
            id: 'ledger:${visible[i].id}',
            liveIds: _liveIds,
            itemKeys: _itemKeys,
            child: ChatColumn.item(
              ChatStepLedger(
                runs: runs,
                live: state.live,
                terminalFor: widget.terminalFor,
              ),
            ),
          ),
        _KeyedTimelineItem(
          id: visible[i].id,
          liveIds: _liveIds,
          itemKeys: _itemKeys,
          child: ChatColumn.item(
            ChatMessageTile(message: visible[i], editable: !state.isRunning),
          ),
        ),
        if (i == boundary)
          _KeyedTimelineItem(
            id: 'compaction',
            liveIds: _liveIds,
            itemKeys: _itemKeys,
            child: ChatColumn.item(
              ChatCompactionMarker(summary: chat?.compactionSummary),
            ),
          ),
      ],
    ];
    _itemKeys.removeWhere((id, _) => !_liveIds.contains(id));
    if (!_follow) _scheduleAnchor();

    return Stack(
      children: [
        ListView(
          controller: _scroll,
          reverse: true,
          // Снизу — две трети высоты окна: конец ответа стоит у низа окна, отступ остаётся под ним.
          padding: EdgeInsets.only(top: AppSpacing.md, bottom: _bottomInset),
          children: children,
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

/// Элемент ленты с ключом по id. Ключ выдаём при построении списка, а не при отрисовке элемента:
/// очистка ключей в [ChatTimeline.build] должна видеть все живые id.
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
      key: itemKeys.putIfAbsent(id, GlobalKey.new),
      child: child,
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
