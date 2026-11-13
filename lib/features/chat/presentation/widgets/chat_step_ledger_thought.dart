part of 'chat_step_ledger.dart';

/// Строка рассуждений: первая строка текста, раскрывается до полного текста по нажатию.
/// Пока шаг идёт, первая строка обновляется, а раскрытый текст следует за новым куском, если читатель внизу.
class _ThoughtRow extends StatefulWidget {
  const _ThoughtRow({
    required this.text,
    required this.live,
    required this.inGroup,
    this.expandedByDefault = false,
  });

  final String text;
  final bool live;
  final bool inGroup;

  /// Раскрыто, пока пользователь сам не переключил строку.
  final bool expandedByDefault;

  @override
  State<_ThoughtRow> createState() => _ThoughtRowState();
}

class _ThoughtRowState extends State<_ThoughtRow>
    with AutomaticKeepAliveClientMixin<_ThoughtRow> {
  /// Выбор пользователя; `null` — раскрытие задаёт настройка. По умолчанию рассуждение свёрнуто, в том числе пока стримится.
  bool? _userExpanded;

  bool get _expanded => _userExpanded ?? widget.expandedByDefault;

  final _scroll = ScrollController();

  /// Насколько близко к концу текста считаем, что читатель «внизу».
  static const _followSlack = 24.0;

  @override
  bool get wantKeepAlive => _userExpanded != null;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ThoughtRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Следуем за текстом, только если читатель и так внизу: иначе он не сможет прочитать предыдущее.
    final following =
        !_scroll.hasClients || _scroll.position.extentAfter < _followSlack;
    if (widget.live && widget.text != oldWidget.text && following) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final text = widget.text.trim();
    final canExpand = text.isNotEmpty;
    final summary = _firstLine(text);
    final tone = widget.live
        ? toneColors(context, AppTone.progress).foreground
        : theme.colorScheme.onSurfaceVariant;

    return StepBlock(
      kind: StepKind.thought,
      inGroup: widget.inGroup,
      accent: tone,
      expanded: _expanded && canExpand,
      onToggle: canExpand
          ? () {
              setState(() => _userExpanded = !_expanded);
              updateKeepAlive();
            }
          : null,
      canFullHeight: canExpand,
      header: (palette) => Row(
        children: [
          Icon(Icons.psychology_outlined, size: 16, color: palette.accent),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              summary.isEmpty ? l10n.statusThinking : summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(color: palette.text),
            ),
          ),
          if (canExpand)
            AnimatedRotation(
              turns: _expanded ? 0.5 : 0,
              duration: AppDurations.fast,
              curve: Curves.easeOutCubic,
              child: Icon(Icons.expand_more, size: 18, color: palette.muted),
            ),
        ],
      ),
      body: (palette, fullHeight) => _ThoughtText(
        text: text,
        color: palette.muted,
        fullHeight: fullHeight,
        scroll: _scroll,
      ),
    );
  }

  static String _firstLine(String text) {
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '';
  }
}

/// Текст рассуждения в теле блока. Полная высота: без внутреннего скролла. Иначе лимит 220 со скроллом.
class _ThoughtText extends StatelessWidget {
  const _ThoughtText({
    required this.text,
    required this.color,
    required this.fullHeight,
    required this.scroll,
  });

  final String text;
  final Color color;
  final bool fullHeight;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final content = SelectableText(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color),
    );
    if (fullHeight) return content;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: SingleChildScrollView(controller: scroll, child: content),
    );
  }
}
