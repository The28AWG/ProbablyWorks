import 'package:app_ui/app_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/features/workspace/presentation/bloc/sidebar_cubit.dart';

/// Настройки в памяти: кубит работает с ними так же, как с kv-таблицей.
class _FakeSettings implements SettingsRepository {
  _FakeSettings([Map<String, String>? values]) : values = values ?? {};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('SettingsRepository is not used in this test');
}

void main() {
  group('loadWidth', () {
    test('returns the default width when nothing is stored', () async {
      expect(
        await SidebarCubit.loadWidth(_FakeSettings()),
        AppLayout.sidebarWidth,
      );
    });

    test('returns the stored width', () async {
      final settings = _FakeSettings({
        SettingsRepository.keySidebarWidth: '350',
      });

      expect(await SidebarCubit.loadWidth(settings), 350);
    });

    test('clamps a stored width that is out of bounds', () async {
      final settings = _FakeSettings({
        SettingsRepository.keySidebarWidth: '9999',
      });

      expect(await SidebarCubit.loadWidth(settings), AppLayout.sidebarMaxWidth);
    });

    test('ignores a stored value that is not a number', () async {
      final settings = _FakeSettings({
        SettingsRepository.keySidebarWidth: 'wide',
      });

      expect(await SidebarCubit.loadWidth(settings), AppLayout.sidebarWidth);
    });
  });

  test('starts with the width it was given, without a later jump', () {
    final cubit = SidebarCubit(_FakeSettings(), 350);
    addTearDown(cubit.close);

    expect(cubit.state.width, 350);
  });

  test(
    'resizing stays within the bounds and is saved only on commit',
    () async {
      final settings = _FakeSettings();
      final cubit = SidebarCubit(settings, AppLayout.sidebarWidth);
      addTearDown(cubit.close);

      cubit.resizeBy(-1000);
      expect(cubit.state.width, AppLayout.sidebarMinWidth);
      expect(settings.values, isEmpty);

      cubit.resizeBy(1000);
      expect(cubit.state.width, AppLayout.sidebarMaxWidth);

      cubit.resizeBy(-100);
      await cubit.commit();
      expect(
        settings.values[SettingsRepository.keySidebarWidth],
        (AppLayout.sidebarMaxWidth - 100).round().toString(),
      );
    },
  );

  test('resizeTo follows the given width and stays within the bounds', () {
    final cubit = SidebarCubit(_FakeSettings(), AppLayout.sidebarWidth);
    addTearDown(cubit.close);

    cubit.resizeTo(AppLayout.sidebarMaxWidth + 300);
    expect(cubit.state.width, AppLayout.sidebarMaxWidth);

    cubit.resizeTo(AppLayout.sidebarMinWidth - 300);
    expect(cubit.state.width, AppLayout.sidebarMinWidth);

    cubit.resizeTo(300);
    expect(cubit.state.width, 300);
  });
}
