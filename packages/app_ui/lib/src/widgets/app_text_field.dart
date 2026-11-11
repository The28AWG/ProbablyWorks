import 'package:app_ui/src/theme/app_theme.dart';
import 'package:material_ui/material_ui.dart';

/// Поле ввода приложения. Оформление берётся из темы (заливка, без обводки, акцент при фокусе),
/// поэтому везде выглядит одинаково. [mono] — моноширинный шрифт для путей, ключей, JSON.
class AppTextField extends StatelessWidget {
  const AppTextField({
    this.controller,
    this.label,
    this.hint,
    this.helper,
    this.error,
    this.errorMaxLines,
    this.prefixIcon,
    this.suffix,
    this.suffixText,
    this.obscure = false,
    this.mono = false,
    this.enabled = true,
    this.readOnly = false,
    this.autofocus = false,
    this.minLines,
    this.maxLines = 1,
    this.keyboardType,
    this.onChanged,
    this.onSubmitted,
    this.focusNode,
    super.key,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final String? helper;
  final String? error;

  /// Сколько строк занимает [error]. Без значения — одна строка, длинный текст обрезается.
  final int? errorMaxLines;

  final IconData? prefixIcon;
  final Widget? suffix;

  /// Единица измерения внутри поля справа, например «байт»: вместо подписи, которой поле не нужно.
  final String? suffixText;
  final bool obscure;
  final bool mono;
  final bool enabled;

  /// Только чтение: поле сохраняет высоту и оформление, но текст не редактируется. Так сохранённый
  /// ключ и поле ввода занимают одну строку одинаковой высоты.
  final bool readOnly;
  final bool autofocus;
  final int? minLines;
  final int? maxLines;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscure,
      enabled: enabled,
      readOnly: readOnly,
      autofocus: autofocus,
      minLines: minLines,
      maxLines: obscure ? 1 : maxLines,
      keyboardType: keyboardType,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: mono
          ? theme.textTheme.bodyMedium?.copyWith(
              fontFamily: AppTheme.monoFamily,
              fontSize: 13,
            )
          : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        errorText: error,
        errorMaxLines: errorMaxLines,
        prefixIcon: prefixIcon == null ? null : Icon(prefixIcon, size: 20),
        suffixIcon: suffix,
        suffixText: suffixText,
      ),
    );
  }
}
