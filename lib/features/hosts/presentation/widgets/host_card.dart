import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/util/text_clip.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Карточка хоста в списке. У SSH-хоста — адрес, статус проверки и кнопка проверки; у виртуального — пояснение
/// вместо адреса, но статус и проверка есть (проверка запускает `host_info` в песочнице); у локального —
/// только название и система, потому что проверять подключение к этому компьютеру незачем.
/// Действия (проверка, правка, удаление) отдаются колбэками: карточка не знает о кубите.
///
/// Адаптация к ширине: если места справа хватает, кнопки стоят в одну строку с текстом. На узком экране
/// они уходят под текст, а заголовок с чипом статуса переносится на вторую строку, иначе текст ужимается
/// до нечитаемой ширины и ряд переполняется.

/// Название системы для карточки: технический код (`posix`) пользователю не показываем.
String _osLabel(HostOs os, AppLocalizations l10n) => switch (os) {
  HostOs.posix => l10n.hostOsPosix,
  HostOs.macos => l10n.hostOsMacos,
  HostOs.windows => l10n.hostOsWindows,
  HostOs.unknown => l10n.hostOsUnknown,
};

class HostCard extends StatelessWidget {
  const HostCard({
    required this.host,
    required this.testing,
    required this.onTest,
    required this.onEdit,
    required this.onDelete,
    super.key,
  });

  final Host host;
  final bool testing;
  final VoidCallback onTest;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  /// Ширина содержимого карточки (без её отступов), начиная с которой кнопки стоят в строке с текстом.
  /// Меньше — кнопки уходят под текст. Порог подобран так, чтобы текст остался не уже ~180 px:
  /// аватар (~60 px) и три кнопки (~152 px) занимают в сумме около 210 px.
  static const _inlineActionsMinWidth = 400.0;

  /// Размер иконки аватара в обычном и компактном режиме (см. [_avatar]).
  static const _iconSize = 24.0;
  static const _compactIconSize = 20.0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = host.lastCheckError != null;
    final checked = host.lastCheckAt != null;
    final (tone, statusLabel) = failed
        ? (AppTone.danger, l10n.hostStatusFailed)
        : checked
        ? (AppTone.success, l10n.hostStatusOnline)
        : (AppTone.neutral, l10n.hostStatusUnknown);
    // У локального хоста нет адреса: он всегда на этом компьютере, поэтому показываем систему.
    // У виртуального адреса тоже нет: он живёт в приложении, поэтому показываем пояснение.
    final address = switch (host.kind) {
      HostKind.local => _osLabel(host.os, l10n),
      HostKind.virtual => l10n.hostVirtualSubtitle,
      HostKind.ssh =>
        '${host.username ?? ''}@${host.address ?? ''}:${host.port}',
    };
    final name = hostDisplayName(host, l10n);
    final notes = host.notes;

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Wrap, а не Row: длинное название и чип статуса на узком экране переносятся, а не переполняют ряд.
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              name,
              style: theme.textTheme.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            // Статус есть только у SSH-хостов: для локального он всегда «доступен» и ничего не сообщает.
            if (!host.isLocal) StatusChip(label: statusLabel, tone: tone),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          address,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // Моноширинный шрифт только у SSH-адреса: у локального и виртуального это не адрес, а пояснение.
          style: host.kind == HostKind.ssh
              ? TextStyle(
                  fontFamily: AppTheme.monoFamily,
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                )
              : theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
        ),
        if (!host.isLocal) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            _statusLine(host, l10n),
            style: theme.textTheme.labelSmall?.copyWith(
              color: failed ? scheme.error : scheme.onSurfaceVariant,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (notes != null && notes.isNotEmpty)
          Text(
            notes,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );

    // Кнопки действий в одном ряду с одинаковым видом (без рамок) и небольшим зазором.
    // Проверки нет у локального хоста: команды и так выполняются на этом компьютере.
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.xs,
      children: [
        if (!host.isLocal)
          IconButton(
            tooltip: l10n.hostTest,
            icon: testing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.network_check),
            onPressed: testing ? null : onTest,
          ),
        IconButton(
          tooltip: l10n.commonEdit,
          icon: const Icon(Icons.edit_outlined),
          onPressed: onEdit,
        ),
        // Локальный хост неудаляем: он создаётся при старте (на iOS его нет, см. ensureLocalHost).
        if (!host.isLocal)
          IconButton(
            tooltip: l10n.commonDelete,
            icon: const Icon(Icons.delete_outline),
            color: scheme.error,
            onPressed: onDelete,
          ),
      ],
    );

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Компактный режим — тот же порог, что и для кнопок: на узком экране уменьшаем и аватар.
          final compact = constraints.maxWidth < _inlineActionsMinWidth;
          final avatar = _avatar(scheme, compact: compact);
          final leading = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              avatar,
              const SizedBox(width: AppSpacing.md),
              Expanded(child: info),
            ],
          );
          if (compact) {
            // Узкий экран: кнопки справа под текстом, полная ширина достаётся тексту.
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                leading,
                const SizedBox(height: AppSpacing.xs),
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            );
          }
          return Row(
            children: [
              avatar,
              const SizedBox(width: AppSpacing.md),
              Expanded(child: info),
              actions,
            ],
          );
        },
      ),
    );
  }

  /// Аватар хоста: квадрат с иконкой системы. В компактном режиме (узкий экран) квадрат 36 px
  /// с иконкой 20 px, в обычном — 48 px с иконкой 24 px: на узком экране он не должен забирать ширину тексту.
  Widget _avatar(ColorScheme scheme, {required bool compact}) => DecoratedBox(
    decoration: BoxDecoration(
      color: scheme.primaryContainer,
      borderRadius: AppRadius.mdAll,
    ),
    child: Padding(
      padding: EdgeInsets.all(compact ? AppSpacing.sm : AppSpacing.md),
      child: Icon(
        hostDisplayIcon(host),
        size: compact ? _compactIconSize : _iconSize,
        color: scheme.onPrimaryContainer,
      ),
    ),
  );

  String _statusLine(Host host, AppLocalizations l10n) {
    final at = host.lastCheckAt;
    if (at == null) return l10n.hostNeverChecked;
    final time = _formatTime(at);
    final error = host.lastCheckError;
    if (error != null) {
      return l10n.hostLastCheckFailed(
        time,
        TextClip.headTail(error, maxChars: 200),
      );
    }
    return l10n.hostLastCheckOk(time, host.lastLatencyMs ?? 0);
  }

  static String _formatTime(DateTime value) {
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
