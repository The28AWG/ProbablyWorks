import 'package:flutter/widgets.dart';

/// Дизайн-токены: единственный источник отступов, радиусов, длительностей и ширин.
/// Экраны не используют «магические» числа для этих величин.
abstract final class AppSpacing {
  const AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

abstract final class AppRadius {
  const AppRadius._();

  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 28;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
}

abstract final class AppDurations {
  const AppDurations._();

  static const fast = Duration(milliseconds: 150);
  static const normal = Duration(milliseconds: 250);
  static const pulse = Duration(milliseconds: 1200);
}

abstract final class AppBreakpoints {
  const AppBreakpoints._();

  /// Широкий режим: список чатов постоянной панелью.
  static const double wide = 1100;

  /// Средний режим: список чатов в drawer.
  static const double medium = 800;

  /// Очень узкая область (телефон и узкое окно): значки вместо чипов, плотные отступы композера.
  /// Ширина меряется по области чата, а не по окну, поэтому порог совпадает с отступами внутри колонки.
  static const double tiny = 360;
}

abstract final class AppLayout {
  const AppLayout._();

  /// Максимальная ширина ленты чата: текст читается без растягивания на весь экран.
  static const double chatMaxWidth = 760;

  /// Формы и мастер онбординга.
  static const double formMaxWidth = 560;

  /// Колонка названия в строке формы настроек. Ниже [formMaxWidth] строка складывается в колонку,
  /// поэтому колонка названия и поля делят ширину только там, где есть место для двух колонок.
  static const double formLabelWidth = 240;

  /// Страницы настроек и хостов.
  static const double pageMaxWidth = 720;

  /// Ширина боковой панели по умолчанию: навигация и список чатов.
  static const double sidebarWidth = 280;

  /// Границы, в которых пользователь может растянуть или сузить боковую панель.
  static const double sidebarMinWidth = 220;
  static const double sidebarMaxWidth = 420;

  /// Ширина свёрнутой боковой панели: только иконки.
  static const double railWidth = 56;

  /// Ширина диалогов с формами.
  static const double dialogWidth = 480;

  /// Ширина текстового блока пустого состояния.
  static const double emptyStateWidth = 320;

  /// Максимальная ширина чипа вложения в композере: длинное имя файла обрезается многоточием.
  static const double attachmentChipMaxWidth = 180;

  /// Максимальная ширина значения в чипе строки настроек на узкой области. На широкой берутся
  /// значения из `ChatMetaBar` (модель 180, папка 140).
  static const double chipNarrowMaxWidth = 120;
}
