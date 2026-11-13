import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Внутриприложенческое сочетание клавиш.
@immutable
class Keybinding {
  const Keybinding({
    required this.key,
    this.control = false,
    this.meta = false,
    this.shift = false,
    this.alt = false,
  });

  final LogicalKeyboardKey key;
  final bool control;
  final bool meta;
  final bool shift;
  final bool alt;

  bool matches(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    return event.logicalKey == key &&
        keyboard.isControlPressed == control &&
        keyboard.isMetaPressed == meta &&
        keyboard.isShiftPressed == shift &&
        keyboard.isAltPressed == alt;
  }

  /// Подпись для настроек. На macOS основная клавиша называется Cmd.
  String get label {
    final parts = <String>[
      if (control) 'Ctrl',
      if (meta) defaultTargetPlatform == TargetPlatform.macOS ? 'Cmd' : 'Meta',
      if (alt) 'Alt',
      if (shift) 'Shift',
      key.keyLabel.isEmpty ? '?' : key.keyLabel.toUpperCase(),
    ];
    return parts.join('+');
  }

  String encode() => [
    if (control) 'ctrl',
    if (meta) 'meta',
    if (alt) 'alt',
    if (shift) 'shift',
    _nameOf(key),
  ].join('+');

  static Keybinding? decode(String raw) {
    final parts = raw
        .toLowerCase()
        .split('+')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return null;
    var control = false;
    var meta = false;
    var shift = false;
    var alt = false;
    LogicalKeyboardKey? key;
    for (final part in parts) {
      switch (part) {
        case 'ctrl':
        case 'control':
          control = true;
        case 'meta':
        case 'cmd':
        case 'command':
          meta = true;
        case 'shift':
          shift = true;
        case 'alt':
        case 'option':
          alt = true;
        default:
          key = _keyFromName(part);
      }
    }
    if (key == null || (control && meta)) return null;
    return Keybinding(
      key: key,
      control: control,
      meta: meta,
      shift: shift,
      alt: alt,
    );
  }

  static String _nameOf(LogicalKeyboardKey key) {
    for (final entry in _keys.entries) {
      if (entry.value == key) return entry.key;
    }
    return key.keyLabel.toLowerCase();
  }

  static LogicalKeyboardKey? _keyFromName(String name) => _keys[name];

  static const _keys = <String, LogicalKeyboardKey>{
    'a': LogicalKeyboardKey.keyA,
    'b': LogicalKeyboardKey.keyB,
    'c': LogicalKeyboardKey.keyC,
    'd': LogicalKeyboardKey.keyD,
    'e': LogicalKeyboardKey.keyE,
    'f': LogicalKeyboardKey.keyF,
    'g': LogicalKeyboardKey.keyG,
    'h': LogicalKeyboardKey.keyH,
    'i': LogicalKeyboardKey.keyI,
    'j': LogicalKeyboardKey.keyJ,
    'k': LogicalKeyboardKey.keyK,
    'l': LogicalKeyboardKey.keyL,
    'm': LogicalKeyboardKey.keyM,
    'n': LogicalKeyboardKey.keyN,
    'o': LogicalKeyboardKey.keyO,
    'p': LogicalKeyboardKey.keyP,
    'q': LogicalKeyboardKey.keyQ,
    'r': LogicalKeyboardKey.keyR,
    's': LogicalKeyboardKey.keyS,
    't': LogicalKeyboardKey.keyT,
    'u': LogicalKeyboardKey.keyU,
    'v': LogicalKeyboardKey.keyV,
    'w': LogicalKeyboardKey.keyW,
    'x': LogicalKeyboardKey.keyX,
    'y': LogicalKeyboardKey.keyY,
    'z': LogicalKeyboardKey.keyZ,
    '0': LogicalKeyboardKey.digit0,
    '1': LogicalKeyboardKey.digit1,
    '2': LogicalKeyboardKey.digit2,
    '3': LogicalKeyboardKey.digit3,
    '4': LogicalKeyboardKey.digit4,
    '5': LogicalKeyboardKey.digit5,
    '6': LogicalKeyboardKey.digit6,
    '7': LogicalKeyboardKey.digit7,
    '8': LogicalKeyboardKey.digit8,
    '9': LogicalKeyboardKey.digit9,
    'comma': LogicalKeyboardKey.comma,
    'period': LogicalKeyboardKey.period,
    'slash': LogicalKeyboardKey.slash,
    'backslash': LogicalKeyboardKey.backslash,
    'minus': LogicalKeyboardKey.minus,
    'equal': LogicalKeyboardKey.equal,
    'bracketleft': LogicalKeyboardKey.bracketLeft,
    'bracketright': LogicalKeyboardKey.bracketRight,
    'semicolon': LogicalKeyboardKey.semicolon,
    'quote': LogicalKeyboardKey.quote,
    'backquote': LogicalKeyboardKey.backquote,
    'space': LogicalKeyboardKey.space,
    'enter': LogicalKeyboardKey.enter,
    'escape': LogicalKeyboardKey.escape,
    'tab': LogicalKeyboardKey.tab,
  };

  @override
  bool operator ==(Object other) =>
      other is Keybinding &&
      other.key == key &&
      other.control == control &&
      other.meta == meta &&
      other.shift == shift &&
      other.alt == alt;

  @override
  int get hashCode => Object.hash(key, control, meta, shift, alt);
}
