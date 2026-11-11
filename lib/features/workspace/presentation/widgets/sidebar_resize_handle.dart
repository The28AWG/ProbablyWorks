import 'dart:async';

import 'package:app_ui/app_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/features/workspace/presentation/bloc/sidebar_cubit.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Ручка на правом краю боковой панели: тянуть мышью или менять стрелками с клавиатуры.
/// Ширину задаёт [SidebarCubit]; ручка только сообщает, когда начался и закончился жест.
class SidebarResizeHandle extends StatefulWidget {
  const SidebarResizeHandle({
    required this.enabled,
    required this.onDragStart,
    required this.onDragEnd,
    super.key,
  });

  /// Выключена в свёрнутом режиме: остаётся только линия-разделитель.
  final bool enabled;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;

  @override
  State<SidebarResizeHandle> createState() => _SidebarResizeHandleState();
}

class _SidebarResizeHandleState extends State<SidebarResizeHandle> {
  var _focused = false;

  /// Шаг изменения ширины стрелками: берётся из токенов, как и остальные отступы.
  static const _keyStep = AppSpacing.lg;

  void _onFocusChanged(bool focused) => setState(() => _focused = focused);

  /// Ширина считается от положения курсора в начале жеста, а не от дельт. Поэтому при уходе курсора
  /// за границу панель стоит на ней, а обратное движение меняет ширину только когда курсор вернулся к границе.
  var _dragStartX = 0.0;
  var _dragStartWidth = 0.0;

  void _dragStart(DragStartDetails details) {
    _dragStartX = details.globalPosition.dx;
    _dragStartWidth = context.read<SidebarCubit>().state.width;
    widget.onDragStart();
  }

  void _dragUpdate(DragUpdateDetails details) => context
      .read<SidebarCubit>()
      .resizeTo(_dragStartWidth + details.globalPosition.dx - _dragStartX);

  void _dragEnd(DragEndDetails details) {
    widget.onDragEnd();
    unawaited(context.read<SidebarCubit>().commit());
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final cubit = context.read<SidebarCubit>();
    final delta = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => -_keyStep,
      LogicalKeyboardKey.arrowRight => _keyStep,
      _ => null,
    };
    if (delta == null) return KeyEventResult.ignored;
    cubit
      ..resizeBy(delta)
      ..commit();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final lineColor = _focused ? scheme.primary : scheme.outlineVariant;
    return Semantics(
      label: widget.enabled ? l10n.sidebarResize : null,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.resizeColumn
            : MouseCursor.defer,
        child: Focus(
          canRequestFocus: widget.enabled,
          onFocusChange: _onFocusChanged,
          onKeyEvent: _onKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: widget.enabled ? _dragStart : null,
            onHorizontalDragUpdate: widget.enabled ? _dragUpdate : null,
            onHorizontalDragEnd: widget.enabled ? _dragEnd : null,
            child: SizedBox(
              width: AppSpacing.sm,
              child: Center(
                child: SizedBox(
                  width: _focused ? 2 : 1,
                  child: ColoredBox(color: lineColor),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
