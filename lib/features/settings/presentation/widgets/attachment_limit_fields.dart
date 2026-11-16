import 'package:app_ui/app_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Числовые поля лимитов вложений: файлов на сообщение, байтов и символов
/// превью в контексте.
///
/// Единица измерения стоит суффиксом внутри поля, поэтому каждому полю нужна
/// ширина сразу на значение и на суффикс. Когда места мало, поля складываются
/// в колонку: иначе суффикс переносится на вторую строку и поле выглядит
/// сломанным. Ошибка показывается одной строкой под полями, а не трижды
/// внутри них.
class AttachmentLimitFields extends StatelessWidget {
  const AttachmentLimitFields({
    required this.perMessage,
    required this.maxBytes,
    required this.inlineChars,
    required this.error,
    super.key,
  });

  /// Минимальная ширина строки из трех полей. Ниже неё значение и суффикс
  /// «символов» уже не помещаются рядом внутри одного поля.
  static const rowMinWidth = 420.0;

  final TextEditingController perMessage;
  final TextEditingController maxBytes;
  final TextEditingController inlineChars;

  /// Ошибка ввода. Null — ошибки нет.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final fields = <Widget>[
      _UnitField(controller: perMessage, unit: l10n.settingsAttachUnitFiles),
      _UnitField(controller: maxBytes, unit: l10n.settingsAttachUnitBytes),
      _UnitField(controller: inlineChars, unit: l10n.settingsAttachUnitChars),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < rowMinWidth) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < fields.length; i++) ...[
                    if (i > 0) const SizedBox(height: AppSpacing.md),
                    fields[i],
                  ],
                ],
              );
            }
            return Row(
              children: [
                for (var i = 0; i < fields.length; i++) ...[
                  if (i > 0) const SizedBox(width: AppSpacing.md),
                  Expanded(child: fields[i]),
                ],
              ],
            );
          },
        ),
        if (error case final text?)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}

/// Одно числовое поле лимита: значение и единица измерения внутри поля.
class _UnitField extends StatelessWidget {
  const _UnitField({required this.controller, required this.unit});

  final TextEditingController controller;
  final String unit;

  @override
  Widget build(BuildContext context) => AppTextField(
    controller: controller,
    suffixText: unit,
    keyboardType: TextInputType.number,
  );
}
