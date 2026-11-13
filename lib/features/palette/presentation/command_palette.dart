import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/palette/domain/palette_command.dart';
import 'package:probably_works/features/palette/presentation/palette_controller.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/domain/search.dart';

/// Модальное окно единой палитры: поиск, фильтры, команды и чаты.
class CommandPaletteDialog extends StatefulWidget {
  const CommandPaletteDialog({
    required this.controller,
    required this.onCommand,
    required this.onHit,
    required this.onClose,
    super.key,
  });

  final PaletteController controller;
  final ValueChanged<PaletteCommand> onCommand;
  final ValueChanged<SearchHit> onHit;
  final VoidCallback onClose;

  @override
  State<CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<CommandPaletteDialog> {
  static const _rowExtent = 62.0;

  late final TextEditingController _input;
  late final FocusNode _focus;
  final _scroll = ScrollController();
  var _lastSelected = 0;

  PaletteController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: _controller.raw);
    _focus = FocusNode(onKeyEvent: _onKey);
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (_input.text != _controller.raw) {
      _input.value = TextEditingValue(
        text: _controller.raw,
        selection: TextSelection.collapsed(offset: _controller.raw.length),
      );
    }
    final changed = _lastSelected != _controller.selected;
    if (changed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelected());
    }
    setState(() => _lastSelected = _controller.selected);
  }

  void _scrollToSelected() {
    if (!_scroll.hasClients) return;
    final target = (_controller.selected * _rowExtent).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    final current = _scroll.offset;
    final viewport = _scroll.position.viewportDimension;
    if (target < current) {
      unawaited(
        _scroll.animateTo(
          target,
          duration: AppDurations.fast,
          curve: Curves.easeOut,
        ),
      );
    } else if (target + _rowExtent > current + viewport) {
      unawaited(
        _scroll.animateTo(
          target + _rowExtent - viewport,
          duration: AppDurations.fast,
          curve: Curves.easeOut,
        ),
      );
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _controller.moveSelection(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _controller.moveSelection(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _activate();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_controller.canGoBack) {
        _controller.goBack();
      } else {
        widget.onClose();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _activate() {
    final result = _controller.selectedResult;
    if (result == null) return;
    if (result.kind == PaletteResultKind.back) {
      _controller.goBack();
      return;
    }
    if (result.isGroup && result.command != null) {
      _controller.enterGroup(result.command!);
      return;
    }
    if (result.command != null) {
      widget.onCommand(result.command!);
      return;
    }
    if (result.hit != null) widget.onHit(result.hit!);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xxl,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: AppLayout.formMaxWidth,
          maxHeight: size.height * 0.72,
        ),
        child: AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: AppTextField(
                  controller: _input,
                  focusNode: _focus,
                  autofocus: true,
                  hint: l10n.paletteSearchHint,
                  prefixIcon: Icons.search,
                  onChanged: _controller.setRaw,
                ),
              ),
              if (_controller.query.filters.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.xs,
                      children: [
                        for (final filter in _controller.query.filters)
                          InputChip(
                            label: Text(_filterLabel(l10n, filter)),
                            onDeleted: () => _controller.removeFilter(filter),
                          ),
                      ],
                    ),
                  ),
                ),
              if (_controller.query.errors.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(
                    left: AppSpacing.lg,
                    top: AppSpacing.sm,
                    right: AppSpacing.lg,
                  ),
                  child: AppBanner(
                    message: _errorLabel(l10n, _controller.query.errors.first),
                    icon: Icons.error_outline,
                    tone: AppTone.danger,
                    margin: EdgeInsets.zero,
                  ),
                ),
              if (_controller.loading)
                const Padding(
                  padding: EdgeInsets.only(top: AppSpacing.sm),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              const SizedBox(height: AppSpacing.sm),
              Expanded(
                child: _controller.results.isEmpty
                    ? Center(
                        child: Text(
                          _controller.loading
                              ? l10n.paletteLoading
                              : l10n.paletteNoResults,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        itemExtent: _rowExtent,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                        ),
                        itemCount: _controller.results.length,
                        itemBuilder: (context, index) => _ResultTile(
                          result: _controller.results[index],
                          selected:
                              index == _controller.selected &&
                              _controller.selectionVisible,
                          onTap: () => _onTapResult(index),
                          onHover: (_) => _controller.selectIndex(index),
                          typeLabel: _typeLabel(
                            l10n,
                            _controller.results[index],
                          ),
                        ),
                      ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.paletteKeyboardHint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Text(
                      '@command · @project · @current',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _onTapResult(int index) {
    _controller.selectIndex(index);
    _activate();
  }

  String _filterLabel(AppLocalizations l10n, PaletteFilter filter) =>
      switch (filter.kind) {
        PaletteFilterKind.command => l10n.paletteFilterCommand,
        PaletteFilterKind.project => l10n.paletteFilterProject(
          filter.value ?? '',
        ),
        PaletteFilterKind.currentProject => l10n.paletteFilterCurrentProject,
        PaletteFilterKind.current => l10n.paletteFilterCurrentChat,
        PaletteFilterKind.chat => l10n.paletteFilterChat(filter.value ?? ''),
        PaletteFilterKind.scope => l10n.paletteFilterScope(filter.value ?? ''),
      };

  String _errorLabel(
    AppLocalizations l10n,
    PaletteQueryError error,
  ) => switch (error) {
    PaletteQueryError.missingValue => l10n.paletteFilterMissingValue,
    PaletteQueryError.noCurrentChat ||
    PaletteQueryError.scopeWithoutChat => l10n.paletteFilterNoCurrentChat,
    PaletteQueryError.noCurrentProject ||
    PaletteQueryError.scopeWithoutProject => l10n.paletteFilterNoCurrentProject,
    PaletteQueryError.invalidScope => l10n.paletteFilterInvalidScope,
    PaletteQueryError.projectNotFound => l10n.paletteFilterProjectNotFound,
    PaletteQueryError.projectAmbiguous => l10n.paletteFilterProjectAmbiguous,
    PaletteQueryError.chatNotFound => l10n.paletteFilterChatNotFound,
    PaletteQueryError.chatAmbiguous => l10n.paletteFilterChatAmbiguous,
    PaletteQueryError.conflictingScope => l10n.paletteFilterConflictingScope,
  };

  String _typeLabel(AppLocalizations l10n, PaletteResult result) =>
      switch (result.kind) {
        PaletteResultKind.command => l10n.paletteTypeCommand,
        PaletteResultKind.chat => l10n.paletteTypeChat,
        PaletteResultKind.message => l10n.paletteTypeMessage,
        PaletteResultKind.back => '',
      };
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.result,
    required this.selected,
    required this.onTap,
    required this.onHover,
    required this.typeLabel,
  });

  final PaletteResult result;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<bool> onHover;
  final String typeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = result.kind == PaletteResultKind.back
        ? AppLocalizations.of(context).paletteBack
        : result.title;
    final icon =
        result.icon ??
        switch (result.kind) {
          PaletteResultKind.command => Icons.bolt_outlined,
          PaletteResultKind.chat => Icons.chat_bubble_outline,
          PaletteResultKind.message => Icons.subject,
          PaletteResultKind.back => Icons.arrow_back,
        };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? scheme.surfaceContainerHighest : Colors.transparent,
        borderRadius: AppRadius.mdAll,
        child: InkWell(
          onTap: onTap,
          onHover: onHover,
          borderRadius: AppRadius.mdAll,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Icon(icon, size: 20, color: scheme.onSurfaceVariant),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                      if (result.subtitle != null &&
                          result.subtitle!.trim().isNotEmpty)
                        Text(
                          result.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                if (result.isGroup)
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  )
                else if (typeLabel.isNotEmpty)
                  Text(
                    typeLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
