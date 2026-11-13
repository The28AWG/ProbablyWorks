import 'dart:async';

import 'package:app_ui/app_ui.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/shortcuts/keybinding.dart';
import 'package:probably_works/app/shortcuts/keybinding_service.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/settings/presentation/widgets/settings_form_row.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Настройка горячих клавиш приложения. Хранится на устройстве.
class KeybindingsSection extends StatefulWidget {
  const KeybindingsSection({super.key});

  @override
  State<KeybindingsSection> createState() => _KeybindingsSectionState();
}

class _KeybindingsSectionState extends State<KeybindingsSection> {
  late final KeybindingService _service;

  @override
  void initState() {
    super.initState();
    _service = getIt<KeybindingService>();
    unawaited(_service.load());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: _service,
      builder: (context, _) => AppSection(
        title: l10n.keybindingsTitle,
        description: l10n.keybindingsHint,
        children: [
          for (final id in KeybindingActions.all)
            SettingsFormRow(
              title: _title(l10n, id),
              description: _service.isOverridden(id)
                  ? l10n.keybindingOverridden
                  : null,
              trailing: _service.isOverridden(id)
                  ? IconButton(
                      tooltip: l10n.keybindingReset,
                      icon: const Icon(Icons.restore),
                      onPressed: () => _reset(id),
                    )
                  : null,
              child: OutlinedButton.icon(
                onPressed: () => _record(id),
                icon: const Icon(Icons.keyboard_outlined),
                label: Text(_service.bindingFor(id).label),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _reset(String actionId) async {
    final binding = _service.defaultBindingFor(actionId);
    final conflict = _service.conflictFor(actionId, binding);
    if (conflict != null) {
      final l10n = AppLocalizations.of(context);
      AppSnackBar.show(
        context,
        l10n.keybindingConflict(_title(l10n, conflict)),
      );
      return;
    }
    await _service.reset(actionId);
  }

  Future<void> _record(String actionId) async {
    final binding = await showDialog<Keybinding>(
      context: context,
      builder: (_) => const _ShortcutRecorderDialog(),
    );
    if (binding == null || !mounted) return;
    final conflict = _service.conflictFor(actionId, binding);
    if (conflict != null) {
      final l10n = AppLocalizations.of(context);
      AppSnackBar.show(
        context,
        l10n.keybindingConflict(_title(l10n, conflict)),
      );
      return;
    }
    await _service.save(actionId, binding);
  }

  String _title(AppLocalizations l10n, String id) => switch (id) {
    KeybindingActions.paletteOpen => l10n.keybindingPaletteOpen,
    KeybindingActions.chatNew => l10n.keybindingChatNew,
    KeybindingActions.settingsOpen => l10n.keybindingSettingsOpen,
    _ => id,
  };
}

class _ShortcutRecorderDialog extends StatefulWidget {
  const _ShortcutRecorderDialog();

  @override
  State<_ShortcutRecorderDialog> createState() =>
      _ShortcutRecorderDialogState();
}

class _ShortcutRecorderDialogState extends State<_ShortcutRecorderDialog> {
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _focus = FocusNode(onKeyEvent: _onKey);
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (_isModifier(event.logicalKey)) return KeyEventResult.handled;
    final keyboard = HardwareKeyboard.instance;
    Navigator.of(context).pop(
      Keybinding(
        key: event.logicalKey,
        control: keyboard.isControlPressed,
        meta: keyboard.isMetaPressed,
        shift: keyboard.isShiftPressed,
        alt: keyboard.isAltPressed,
      ),
    );
    return KeyEventResult.handled;
  }

  static bool _isModifier(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.controlLeft ||
      key == LogicalKeyboardKey.controlRight ||
      key == LogicalKeyboardKey.shiftLeft ||
      key == LogicalKeyboardKey.shiftRight ||
      key == LogicalKeyboardKey.altLeft ||
      key == LogicalKeyboardKey.altRight ||
      key == LogicalKeyboardKey.metaLeft ||
      key == LogicalKeyboardKey.metaRight ||
      key == LogicalKeyboardKey.capsLock ||
      key == LogicalKeyboardKey.numLock ||
      key == LogicalKeyboardKey.scrollLock;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppLayout.dialogWidth),
        child: AppCard(
          child: Focus(
            autofocus: true,
            focusNode: _focus,
            onKeyEvent: _onKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.keybindingRecordTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  l10n.keybindingRecordHint,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.commonCancel),
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
