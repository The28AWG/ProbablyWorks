import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:probably_works/app/shortcuts/keybinding.dart';
import 'package:probably_works/core/settings/client_settings.dart';

/// Действия, которым можно назначить горячую клавишу.
abstract final class KeybindingActions {
  static const paletteOpen = 'palette.open';
  static const chatNew = 'chat.new';
  static const settingsOpen = 'settings.open';

  static const all = [paletteOpen, chatNew, settingsOpen];
}

/// Хранит переназначенные сочетания и применяет их к событиям клавиатуры.
///
/// Overrides лежат в [ClientSettings], а не в настройках агента: это настройка
/// устройства, и на разных ОС основные клавиши разные.
class KeybindingService extends ChangeNotifier {
  KeybindingService(this._settings);

  static const key = 'keybindings';

  final ClientSettings _settings;
  final _overrides = <String, Keybinding>{};
  var _loaded = false;

  bool get loaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final raw = await _settings.read(ClientSettingsKeys.keybindings);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          final id = '${entry.key}';
          if (!KeybindingActions.all.contains(id)) continue;
          if (entry.value is! String) continue;
          final binding = Keybinding.decode(entry.value as String);
          if (binding != null) _overrides[id] = binding;
        }
      }
    } on FormatException {
      // Битое значение не должно ломать запуск.
    }
    notifyListeners();
  }

  Keybinding bindingFor(String actionId) =>
      _overrides[actionId] ?? _defaultFor(actionId);

  Keybinding defaultBindingFor(String actionId) => _defaultFor(actionId);

  bool isOverridden(String actionId) => _overrides.containsKey(actionId);

  /// Первое действие с таким же сочетанием, кроме [exceptId].
  String? conflictFor(String actionId, Keybinding binding) {
    for (final id in KeybindingActions.all) {
      if (id == actionId) continue;
      if (bindingFor(id) == binding) return id;
    }
    return null;
  }

  /// Назначает сочетание или сбрасывает его при null.
  Future<void> save(String actionId, Keybinding? binding) async {
    if (binding == null) {
      _overrides.remove(actionId);
    } else {
      _overrides[actionId] = binding;
    }
    await _persist();
    notifyListeners();
  }

  Future<void> reset(String actionId) => save(actionId, null);

  Future<void> resetAll() async {
    _overrides.clear();
    await _persist();
    notifyListeners();
  }

  /// Действие, чьё сочетание совпало с событием. Null — событие не наше.
  String? actionFor(KeyEvent event) {
    if (event is! KeyDownEvent) return null;
    for (final id in KeybindingActions.all) {
      if (bindingFor(id).matches(event)) return id;
    }
    return null;
  }

  Keybinding _defaultFor(String actionId) {
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final primary = mac;
    return switch (actionId) {
      KeybindingActions.paletteOpen => Keybinding(
        key: LogicalKeyboardKey.keyK,
        control: !primary,
        meta: primary,
      ),
      KeybindingActions.chatNew => Keybinding(
        key: LogicalKeyboardKey.keyN,
        control: !primary,
        meta: primary,
        shift: true,
      ),
      KeybindingActions.settingsOpen => Keybinding(
        key: LogicalKeyboardKey.comma,
        control: !primary,
        meta: primary,
      ),
      _ => Keybinding(
        key: LogicalKeyboardKey.f12,
        control: !primary,
        meta: primary,
      ),
    };
  }

  Future<void> _persist() async {
    final json = jsonEncode({
      for (final entry in _overrides.entries) entry.key: entry.value.encode(),
    });
    await _settings.write(ClientSettingsKeys.keybindings, json);
  }
}
