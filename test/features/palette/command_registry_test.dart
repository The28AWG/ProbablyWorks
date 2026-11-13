import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/palette/domain/command_registry.dart';
import 'package:probably_works/features/palette/domain/palette_command.dart';

PaletteCommand _command(
  String id,
  String ru, {
  String? en,
  String? parentId,
  PaletteAction? action = const BuiltinPaletteAction('run'),
  bool enabled = true,
}) => PaletteCommand(
  id: id,
  parentId: parentId,
  titles: LocalizedText(ru: ru, en: en ?? ru),
  keywords: LocalizedText(ru: ru, en: en ?? ru),
  action: action,
  enabled: enabled,
);

void main() {
  test('builds a tree and rejects broken hierarchies', () {
    final registry = CommandRegistry([
      PaletteCommand(
        id: 'nav',
        titles: const LocalizedText(ru: 'Навигация', en: 'Navigation'),
        order: 10,
      ),
      _command('nav.chats', 'Чаты', en: 'Chats', parentId: 'nav'),
      _command('nav.hosts', 'Хосты', en: 'Hosts', parentId: 'nav'),
      _command('new', 'Новый чат', en: 'New chat'),
    ]);

    expect(registry.childrenOf(null, 'ru').map((c) => c.id), ['new', 'nav']);
    expect(registry.childrenOf('nav', 'ru').map((c) => c.id), [
      'nav.hosts',
      'nav.chats',
    ]);
    expect(
      registry.pathOf(registry.byId('nav.chats')!, 'ru'),
      'Навигация → Чаты',
    );

    expect(
      () => CommandRegistry([_command('a', 'A', parentId: 'missing')]),
      throwsArgumentError,
    );
    expect(
      () => CommandRegistry([_command('a', 'A'), _command('a', 'B')]),
      throwsArgumentError,
    );
  });

  test('finds exact, prefix, multilingual and fuzzy matches', () {
    final registry = CommandRegistry([
      _command('settings', 'Настройки', en: 'Settings'),
      _command('new', 'Новый чат', en: 'New chat'),
      _command('memory', 'Память проекта', en: 'Project memory'),
    ]);

    expect(registry.search('настройки', 'ru').first.command.id, 'settings');
    expect(registry.search('настр', 'ru').first.command.id, 'settings');
    expect(registry.search('settings', 'ru').first.command.id, 'settings');
    expect(registry.search('нстроки', 'ru').first.command.id, 'settings');
    expect(registry.search('memory', 'ru').first.command.id, 'memory');
  });

  test('finds children by the parent path', () {
    final registry = CommandRegistry([
      PaletteCommand(
        id: 'nav',
        titles: const LocalizedText(ru: 'Навигация', en: 'Navigation'),
        order: 10,
      ),
      _command('nav.chats', 'Чаты', en: 'Chats', parentId: 'nav'),
      _command('nav.hosts', 'Хосты', en: 'Hosts', parentId: 'nav'),
    ]);

    final ids = registry.search('навигация', 'ru').map((m) => m.command.id);
    expect(ids, containsAll(['nav.chats', 'nav.hosts']));
  });

  test('hides a group without enabled commands', () {
    final registry = CommandRegistry([
      PaletteCommand(
        id: 'project',
        titles: const LocalizedText(ru: 'Проект', en: 'Project'),
        order: 20,
      ),
      _command(
        'project.memory',
        'Память проекта',
        en: 'Project memory',
        parentId: 'project',
        enabled: false,
      ),
    ]);

    expect(registry.childrenOf(null, 'ru'), isEmpty);
  });
}
