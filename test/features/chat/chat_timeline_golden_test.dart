import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_timeline.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

import 'package:probably_works/test_support/golden_fonts.dart';

/// Полоса прокрутки всегда видна, чтобы на эталоне было видно её положение у края окна.
class _AlwaysVisibleScrollbars extends MaterialScrollBehavior {
  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => Scrollbar(
    controller: details.controller,
    thumbVisibility: true,
    child: child,
  );
}

const _assistantText = '''
Вот план. Сначала проверю `pubspec.yaml`, затем запущу `flutter analyze`.

- читаю конфигурацию проекта
- ищу неиспользуемые импорты
- собираю отчёт

Если всё чисто, покажу итог и предложу следующий шаг.
''';

ChatState _longChat() {
  final start = DateTime(2026);
  final messages = <ChatMessage>[];
  for (var i = 0; i < 6; i++) {
    // Каждое задание занимает 3m 4x s: на эталоне видна метка времени в реальном формате.
    final asked = start.add(Duration(hours: i));
    messages
      ..add(
        ChatMessage(
          id: 'u$i',
          chatId: 'c',
          seq: i * 2,
          role: MessageRole.user,
          createdAt: asked,
          text:
              'Запрос номер ${i + 1}: проверь проект и скажи, что нужно поправить',
        ),
      )
      ..add(
        ChatMessage(
          id: 'a$i',
          chatId: 'c',
          seq: i * 2 + 1,
          role: MessageRole.assistant,
          createdAt: asked.add(Duration(minutes: 3, seconds: i + 40)),
          text: _assistantText,
        ),
      );
  }
  return ChatState(chatId: 'c', messages: messages);
}

void main() {
  setUpAll(GoldenFonts.load);

  for (final brightness in Brightness.values) {
    testWidgets(
      'chat timeline keeps the scrollbar at the window edge (${brightness.name})',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: brightness == Brightness.light
                ? AppTheme.light
                : AppTheme.dark,
            locale: const Locale('ru'),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ScrollConfiguration(
                behavior: _AlwaysVisibleScrollbars(),
                child: ChatTimeline(state: _longChat()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile('goldens/chat_timeline_${brightness.name}.png'),
        );
      },
    );
  }
}
