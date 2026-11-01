import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_tokens.dart';

/// Центральная колонка чата. Лента, шапка, док внимания и композер делят одну ширину [AppLayout.chatMaxWidth],
/// поэтому текст и поле ввода образуют одну линию чтения.
abstract final class ChatColumn {
  const ChatColumn._();

  /// Элемент прокручиваемой ленты. Ширина задаётся точно: иначе колонка Markdown
  /// центрируется по самой длинной строке, а полоса прокрутки уезжает от края окна.
  static Widget item(Widget child) => LayoutBuilder(
    builder: (context, constraints) {
      final available = constraints.maxWidth;
      final width = available < AppLayout.chatMaxWidth
          ? available
          : AppLayout.chatMaxWidth;
      return Align(
        child: SizedBox(
          width: width,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: child,
          ),
        ),
      );
    },
  );

  /// Блок вне прокрутки (шапка, док, композер): центрируется и ограничивается по ширине.
  static Widget fixed(Widget child) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: AppLayout.chatMaxWidth),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: child,
      ),
    ),
  );
}
