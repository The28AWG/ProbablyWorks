import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/app/shortcuts/keybinding.dart';
import 'package:probably_works/app/shortcuts/keybinding_service.dart';
import 'package:probably_works/core/settings/client_settings.dart';

void main() {
  test('round-trips a shortcut', () {
    const binding = Keybinding(
      key: LogicalKeyboardKey.keyN,
      control: true,
      shift: true,
    );
    expect(Keybinding.decode(binding.encode()), binding);
    expect(binding.label, 'Ctrl+Shift+N');
    expect(
      Keybinding.decode('meta+k'),
      const Keybinding(key: LogicalKeyboardKey.keyK, meta: true),
    );
    expect(Keybinding.decode('ctrl+meta+k'), isNull);
  });

  test('persists overrides and reports conflicts', () async {
    final settings = MemoryClientSettings();
    final service = KeybindingService(settings);
    await service.load();

    const binding = Keybinding(
      key: LogicalKeyboardKey.keyK,
      control: true,
      shift: true,
    );
    await service.save(KeybindingActions.paletteOpen, binding);

    expect(service.bindingFor(KeybindingActions.paletteOpen), binding);
    expect(service.isOverridden(KeybindingActions.paletteOpen), isTrue);
    expect(
      service.conflictFor(KeybindingActions.chatNew, binding),
      KeybindingActions.paletteOpen,
    );

    final reloaded = KeybindingService(settings);
    await reloaded.load();
    expect(reloaded.bindingFor(KeybindingActions.paletteOpen), binding);

    await reloaded.reset(KeybindingActions.paletteOpen);
    expect(reloaded.isOverridden(KeybindingActions.paletteOpen), isFalse);
  });
}
