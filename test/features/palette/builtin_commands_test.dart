import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/palette/domain/builtin_commands.dart';
import 'package:probably_works/features/palette/domain/command_registry.dart';
import 'package:probably_works/features/palette/domain/palette_command.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

void main() {
  late AppLocalizations en;
  late AppLocalizations ru;

  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    ru = await AppLocalizations.delegate.load(const Locale('ru'));
  });

  CommandRegistry registry({
    required bool pauseSupported,
    required bool notificationsPaused,
  }) => CommandRegistry(
    builtinPaletteCommands(
      en,
      ru,
      hasProject: false,
      pauseSupported: pauseSupported,
      notificationsPaused: notificationsPaused,
    ),
  );

  test('hidden when the server does not support the pause', () {
    final commands = registry(
      pauseSupported: false,
      notificationsPaused: false,
    );

    expect(
      commands.childrenOf(null, 'en').map((command) => command.id),
      isNot(contains('notifications')),
    );
  });

  test('offers the three presets without a resume action', () {
    final commands = registry(pauseSupported: true, notificationsPaused: false);

    expect(
      commands.childrenOf('notifications', 'en').map((command) => command.id),
      [
        'notifications.focus',
        'notifications.meeting',
        'notifications.overnight',
      ],
    );
  });

  test('adds the resume action while the pause is active', () {
    final commands = registry(pauseSupported: true, notificationsPaused: true);

    expect(
      commands.childrenOf('notifications', 'en').map((command) => command.id),
      [
        'notifications.focus',
        'notifications.meeting',
        'notifications.overnight',
        'notifications.resume',
      ],
    );
  });

  test('the whole group is hidden while offline', () {
    final commands = registry(pauseSupported: true, notificationsPaused: false);

    expect(
      commands
          .childrenOf(null, 'en', online: false)
          .map((command) => command.id),
      isNot(contains('notifications')),
    );
  });

  test('commands keep their builtin action ids', () {
    final commands = registry(pauseSupported: true, notificationsPaused: true);

    expect(
      commands.byId('notifications.focus')?.action,
      const BuiltinPaletteAction(BuiltinPaletteActions.pauseFocus),
    );
    expect(
      commands.byId('notifications.resume')?.action,
      const BuiltinPaletteAction(BuiltinPaletteActions.resumeNotifications),
    );
  });
}
