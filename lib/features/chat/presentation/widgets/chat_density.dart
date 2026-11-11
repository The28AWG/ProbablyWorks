import 'package:app_ui/app_ui.dart';
import 'package:flutter/widgets.dart';

/// Плотность чата по ширине его области: от неё зависят отступы колонки, композера, число строк поля
/// и вид строки настроек.
///
/// Ширина меряется в `ChatBody` через `LayoutBuilder`, а не через `MediaQuery`: при открытой боковой панели
/// окно шире области чата, и плотность должна следовать за самой областью. Без [ChatDensityScope] действует
/// [regular], поэтому виджеты, которые тестируют отдельно, выглядят как в широком окне.
enum ChatDensity {
  /// Широкая область: отступы и подписи как в обычном окне.
  regular,

  /// Узкая область (одна колонка на весь экран): поле ввода короче, текст меньше.
  narrow,

  /// Очень узкая область: чипы настроек только значки, отступы минимальные.
  tiny;

  /// Плотность по ширине области чата. Пороги из [AppBreakpoints].
  static ChatDensity fromWidth(double width) => switch (width) {
    < AppBreakpoints.tiny => .tiny,
    < AppBreakpoints.medium => .narrow,
    _ => .regular,
  };

  /// Горизонтальный отступ колонки чата (лента, шапка, док, композер).
  double get gutter => switch (this) {
    .regular => AppSpacing.lg,
    .narrow => AppSpacing.md,
    .tiny => AppSpacing.sm,
  };

  /// Отступы карточки композера: слева больше, потому что там «+», справа кнопка действия.
  EdgeInsets get composerPadding => switch (this) {
    .regular => const EdgeInsets.fromLTRB(
      AppSpacing.md,
      AppSpacing.sm,
      AppSpacing.xs,
      AppSpacing.xs,
    ),
    .narrow => const EdgeInsets.fromLTRB(
      AppSpacing.sm,
      AppSpacing.xs,
      AppSpacing.xs,
      AppSpacing.xs,
    ),
    .tiny => const EdgeInsets.all(AppSpacing.xs),
  };

  /// Вертикальный отступ текста внутри поля ввода.
  double get inputVerticalPadding => switch (this) {
    .regular => 10,
    .narrow || .tiny => AppSpacing.sm,
  };

  /// Высота строки текста в поле ввода. Null — широкая область берёт высоту из темы без изменений.
  /// На узком экране строки плотнее, чтобы поле занимало меньше места.
  double? get inputLineHeight => switch (this) {
    .regular => null,
    .narrow || .tiny => 1.3,
  };

  /// Скругление карточки композера. На очень узком экране углы мельче (`md` вместо `lg`), чтобы карточка
  /// выглядела плотнее остального интерфейса. Совпадает с радиусом скелета композера (см. `ComposerSkeleton`).
  BorderRadius get composerRadius => switch (this) {
    .regular || .narrow => AppRadius.lgAll,
    .tiny => AppRadius.mdAll,
  };

  /// Число строк, после которого поле ввода начинает прокручиваться.
  ///
  /// На широкой области остаётся 8. На узкой — 5 строк внизу и 10 в пустом чате, где композер стоит по центру
  /// и места больше. Значения согласованы с `docs/ui/RULEBOOK.md`.
  int composerMaxLines({required bool centered}) => switch (this) {
    .regular => 8,
    .narrow || .tiny => centered ? 10 : 5,
  };

  /// Чипы строки настроек показывают только значки: значение уходит в подсказку.
  bool get iconOnlyChips => this == ChatDensity.tiny;
}

/// Передаёт плотность чата вниз по дереву. Ставится один раз в `ChatBody`.
class ChatDensityScope extends InheritedWidget {
  const ChatDensityScope({
    required this.density,
    required super.child,
    super.key,
  });

  final ChatDensity density;

  /// Плотность ближайшего [ChatDensityScope] или [ChatDensity.regular], если его нет.
  static ChatDensity of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatDensityScope>()?.density ??
      ChatDensity.regular;

  @override
  bool updateShouldNotify(ChatDensityScope oldWidget) =>
      density != oldWidget.density;
}
