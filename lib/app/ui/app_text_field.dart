import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_theme.dart';

/// Поле ввода приложения. Оформление берётся из темы (заливка, без обводки, акцент при фокусе),
/// поэтому везде выглядит одинаково. [mono] — моноширинный шрифт для путей, ключей, JSON.
class AppTextField extends StatelessWidget {
  const AppTextField({
    this.controller,
    this.label,
    this.hint,
    this.helper,
    this.error,
    this.prefixIcon,
    this.suffix,
    this.obscure = false,
    this.mono = false,
    this.enabled = true,
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
  final IconData? prefixIcon;
  final Widget? suffix;
  final bool obscure;
  final bool mono;
  final bool enabled;
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
        prefixIcon: prefixIcon == null ? null : Icon(prefixIcon, size: 20),
        suffixIcon: suffix,
      ),
    );
  }
}
