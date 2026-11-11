import 'package:app_ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/features/workspace/presentation/bloc/sidebar_cubit.dart';
import 'package:probably_works/features/workspace/presentation/widgets/sidebar_resize_handle.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/core/data/settings_repository.dart';

class _FakeSettings implements SettingsRepository {
  final values = <String, String>{};

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
  testWidgets(
    'width follows the pointer only again after it returns to the handle',
    (tester) async {
      var dragEvents = 0;
      final cubit = SidebarCubit(_FakeSettings(), AppLayout.sidebarWidth);
      addTearDown(cubit.close);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: BlocProvider.value(
              value: cubit,
              child: BlocBuilder<SidebarCubit, SidebarState>(
                builder: (context, state) => Row(
                  children: [
                    SizedBox(width: state.width),
                    SidebarResizeHandle(
                      enabled: true,
                      onDragStart: () => dragEvents++,
                      onDragEnd: () => dragEvents++,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(SidebarResizeHandle)),
      );
      // Курсор далеко за максимум: панель стоит на границе.
      await gesture.moveBy(const Offset(400, 0));
      await tester.pump();
      expect(cubit.state.width, AppLayout.sidebarMaxWidth);

      // Курсор возвращается, но ещё не у ручки: ширина не меняется.
      await gesture.moveBy(const Offset(-200, 0));
      await tester.pump();
      expect(cubit.state.width, AppLayout.sidebarMaxWidth);

      // Курсор вернулся к ручке и пошёл дальше: ширина следует за ним.
      await gesture.moveBy(const Offset(-200, 0));
      await tester.pump();
      expect(cubit.state.width, lessThan(AppLayout.sidebarMaxWidth));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(dragEvents, 2);
    },
  );
}
