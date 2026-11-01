import 'package:material_ui/material_ui.dart';

/// Семантические цвета, которых нет в [ColorScheme]: успех, предупреждение, статусы агента, код и diff.
/// Значения заданы для светлой и тёмной темы отдельно, контраст текста проверен на фоне поверхностей.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.success,
    required this.successContainer,
    required this.warning,
    required this.warningContainer,
    required this.info,
    required this.infoContainer,
    required this.running,
    required this.waiting,
    required this.muted,
    required this.codeSurface,
    required this.codeText,
    required this.diffAdd,
    required this.diffAddText,
    required this.diffRemove,
    required this.diffRemoveText,
  });

  static const light = AppColors(
    success: Color(0xFF1F8A4C),
    successContainer: Color(0xFFD7F3E1),
    warning: Color(0xFFB45309),
    warningContainer: Color(0xFFFDEFC7),
    info: Color(0xFF1D4ED8),
    infoContainer: Color(0xFFDCE6FF),
    running: Color(0xFF3B5BDB),
    waiting: Color(0xFFB45309),
    muted: Color(0xFF6B7280),
    codeSurface: Color(0xFF111827),
    codeText: Color(0xFFE5E7EB),
    diffAdd: Color(0x2E1F8A4C),
    diffAddText: Color(0xFF14653A),
    diffRemove: Color(0x2EC62828),
    diffRemoveText: Color(0xFFA11D1D),
  );

  static const dark = AppColors(
    success: Color(0xFF4ADE80),
    successContainer: Color(0xFF14372A),
    warning: Color(0xFFFBBF24),
    warningContainer: Color(0xFF3F2E0B),
    info: Color(0xFF93C5FD),
    infoContainer: Color(0xFF13294B),
    running: Color(0xFF8FA6FF),
    waiting: Color(0xFFFBBF24),
    muted: Color(0xFF9CA3AF),
    codeSurface: Color(0xFF0B0F1A),
    codeText: Color(0xFFE5E7EB),
    diffAdd: Color(0x334ADE80),
    diffAddText: Color(0xFF86EFAC),
    diffRemove: Color(0x33F87171),
    diffRemoveText: Color(0xFFFCA5A5),
  );

  final Color success;
  final Color successContainer;
  final Color warning;
  final Color warningContainer;
  final Color info;
  final Color infoContainer;
  final Color running;
  final Color waiting;
  final Color muted;
  final Color codeSurface;
  final Color codeText;
  final Color diffAdd;
  final Color diffAddText;
  final Color diffRemove;
  final Color diffRemoveText;

  @override
  AppColors copyWith({
    Color? success,
    Color? successContainer,
    Color? warning,
    Color? warningContainer,
    Color? info,
    Color? infoContainer,
    Color? running,
    Color? waiting,
    Color? muted,
    Color? codeSurface,
    Color? codeText,
    Color? diffAdd,
    Color? diffAddText,
    Color? diffRemove,
    Color? diffRemoveText,
  }) => AppColors(
    success: success ?? this.success,
    successContainer: successContainer ?? this.successContainer,
    warning: warning ?? this.warning,
    warningContainer: warningContainer ?? this.warningContainer,
    info: info ?? this.info,
    infoContainer: infoContainer ?? this.infoContainer,
    running: running ?? this.running,
    waiting: waiting ?? this.waiting,
    muted: muted ?? this.muted,
    codeSurface: codeSurface ?? this.codeSurface,
    codeText: codeText ?? this.codeText,
    diffAdd: diffAdd ?? this.diffAdd,
    diffAddText: diffAddText ?? this.diffAddText,
    diffRemove: diffRemove ?? this.diffRemove,
    diffRemoveText: diffRemoveText ?? this.diffRemoveText,
  );

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      success: Color.lerp(success, other.success, t)!,
      successContainer: Color.lerp(
        successContainer,
        other.successContainer,
        t,
      )!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningContainer: Color.lerp(
        warningContainer,
        other.warningContainer,
        t,
      )!,
      info: Color.lerp(info, other.info, t)!,
      infoContainer: Color.lerp(infoContainer, other.infoContainer, t)!,
      running: Color.lerp(running, other.running, t)!,
      waiting: Color.lerp(waiting, other.waiting, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      codeSurface: Color.lerp(codeSurface, other.codeSurface, t)!,
      codeText: Color.lerp(codeText, other.codeText, t)!,
      diffAdd: Color.lerp(diffAdd, other.diffAdd, t)!,
      diffAddText: Color.lerp(diffAddText, other.diffAddText, t)!,
      diffRemove: Color.lerp(diffRemove, other.diffRemove, t)!,
      diffRemoveText: Color.lerp(diffRemoveText, other.diffRemoveText, t)!,
    );
  }
}

extension AppColorsContext on BuildContext {
  /// Семантические цвета текущей темы.
  AppColors get appColors => Theme.of(this).extension<AppColors>()!;
}
