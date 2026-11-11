import 'package:app_ui/app_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_density.dart';

/// Центральная колонка чата. Лента, шапка, док внимания и композер делят одну ширину [AppLayout.chatMaxWidth],
/// поэтому текст и поле ввода образуют одну линию чтения.
///
/// Боковой отступ берётся из [ChatDensity]: на узкой области он меньше, чтобы текст не сжимался в узкую полосу.
abstract final class ChatColumn {
  const ChatColumn._();

  /// Элемент прокручиваемой ленты. Ширина задаётся точно: иначе колонка Markdown
  /// центрируется по самой длинной строке, а полоса прокрутки уезжает от края окна.
  /// Без LayoutBuilder: он вызывает builder во время разметки и строит детей внутри фазы
  /// layout. Здесь ширина берётся из ограничений: SizedBox тянется до maxWidth колонки.
  static Widget item(BuildContext context, Widget child) => Align(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: AppLayout.chatMaxWidth),
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: ChatDensityScope.of(context).gutter,
          ),
          child: child,
        ),
      ),
    ),
  );

  /// Блок вне прокрутки (шапка, док, композер): центрируется и ограничивается по ширине.
  static Widget fixed(BuildContext context, Widget child) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: AppLayout.chatMaxWidth),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: ChatDensityScope.of(context).gutter,
        ),
        child: child,
      ),
    ),
  );
}
