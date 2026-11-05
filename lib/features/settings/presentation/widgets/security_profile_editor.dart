/// Редактор уровней команд в настройках.
///
/// Сверху проверка живой команды: тот же классификатор, что у агента.
/// Ниже категории базы знаний. Уровень категории задаётся сегментами,
/// команда внутри категории может его заменить, аргумент — заменить команду.
/// Поиск и фильтр не прячут жёсткий пол: он объяснён баннером.
library;

import 'package:command_shield/command_shield.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/policy/command_catalog.dart';
import 'package:probably_works/agent/policy/command_classifier.dart';
import 'package:probably_works/agent/policy/security_profile.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Редактор [profile]. Каждое изменение сразу уходит в [onChanged].
class SecurityProfileEditor extends StatefulWidget {
  /// Создаёт редактор. [denylist] — уже сохранённый список, по строке на шаблон.
  const SecurityProfileEditor({
    required this.profile,
    required this.denylist,
    required this.onChanged,
    super.key,
  });

  /// Текущие уровни.
  final SecurityProfile profile;

  /// Сохранённый denylist, тем же текстом, что и в поле настроек после записи.
  final String denylist;

  /// Сохраняет новый профиль.
  final ValueChanged<SecurityProfile> onChanged;

  @override
  State<SecurityProfileEditor> createState() => _SecurityProfileEditorState();
}

class _SecurityProfileEditorState extends State<SecurityProfileEditor> {
  final _search = TextEditingController();
  var _query = '';
  KnowledgeCategory? _filter;
  KnowledgeCategory? _openCategory;
  String? _openCommand;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final catalog = CommandCatalog.instance;
    final query = _query;
    final categories = [
      for (final category in KnowledgeCategory.values)
        if (catalog.namesIn(category).isNotEmpty) category,
    ];
    final visible = [
      for (final category in categories)
        if (_filter == null || _filter == category) category,
    ];
    final anyMatch = query.isEmpty || _hasMatch(catalog, visible, query);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppBanner(
          margin: EdgeInsets.zero,
          tone: AppTone.info,
          icon: Icons.lock_outline,
          title: l10n.securityFloorTitle,
          message: l10n.securityFloorMessage,
        ),
        const SizedBox(height: AppSpacing.lg),
        _Preview(profile: widget.profile, denylist: widget.denylist),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: AppTextField(
                controller: _search,
                hint: l10n.securitySearchHint,
                prefixIcon: Icons.search,
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            TextButton(
              onPressed: () => _addCommand(context),
              child: Text(
                l10n.securityAddCommand,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            FilterChip(
              label: Text(
                l10n.securityFilterAll,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              selected: _filter == null,
              onSelected: (_) => setState(() => _filter = null),
            ),
            for (final category in categories)
              FilterChip(
                label: Text(
                  _categoryLabel(l10n, category),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                selected: _filter == category,
                onSelected: (selected) =>
                    setState(() => _filter = selected ? category : null),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        if (!anyMatch && !_hasCustom(catalog))
          const _NoMatches()
        else
          for (final category in visible) ...[
            if (_matches(catalog.namesIn(category), query)) ...[
              _CategoryCard(
                category: category,
                names: [
                  for (final name in catalog.namesIn(category))
                    if (query.isEmpty || name.contains(query)) name,
                ],
                profile: widget.profile,
                expanded: query.isNotEmpty || _openCategory == category,
                openCommand: _openCommand,
                onToggle: () => setState(() {
                  _openCategory = _openCategory == category ? null : category;
                  _openCommand = null;
                }),
                onOpenCommand: (name) => setState(
                  () => _openCommand = _openCommand == name ? null : name,
                ),
                onChanged: widget.onChanged,
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ],
        _CustomCommands(
          profile: widget.profile,
          catalog: catalog,
          query: query,
          openCommand: _openCommand,
          onOpenCommand: (name) =>
              setState(() => _openCommand = _openCommand == name ? null : name),
          onChanged: widget.onChanged,
        ),
      ],
    );
  }

  bool _hasMatch(
    CommandCatalog catalog,
    List<KnowledgeCategory> categories,
    String query,
  ) {
    for (final category in categories) {
      if (_matches(catalog.namesIn(category), query)) return true;
    }
    for (final name in widget.profile.commands.keys) {
      if (catalog.categoryOf(name) == null && name.contains(query)) return true;
    }
    return false;
  }

  bool _hasCustom(CommandCatalog catalog) {
    for (final name in widget.profile.commands.keys) {
      if (catalog.categoryOf(name) == null) return true;
    }
    for (final rule in widget.profile.arguments) {
      if (catalog.categoryOf(rule.executable) == null) return true;
    }
    return false;
  }

  bool _matches(List<String> names, String query) {
    if (query.isEmpty) return true;
    for (final name in names) {
      if (name.contains(query)) return true;
    }
    return false;
  }

  Future<void> _addCommand(BuildContext context) async {
    final name = await _askCommandName(context);
    if (name == null || !mounted) return;
    final known = CommandCatalog.instance.categoryOf(name);
    if (known == null) {
      widget.onChanged(widget.profile.withCommand(name, CommandRisk.ask));
    }
    setState(() {
      _search.text = name;
      _filter = known;
      _openCategory = known;
      _openCommand = name;
    });
  }
}

class _Preview extends StatefulWidget {
  const _Preview({required this.profile, required this.denylist});

  final SecurityProfile profile;
  final String denylist;

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  final _sample = TextEditingController();
  var _text = '';

  @override
  void dispose() {
    _sample.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final outcome = _outcome(_text);
    final tone = switch (outcome?.risk) {
      CommandRisk.auto => AppTone.success,
      CommandRisk.ask => AppTone.warning,
      CommandRisk.deny => AppTone.danger,
      null => AppTone.neutral,
    };
    final colors = toneColors(context, tone);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppTextField(
          controller: _sample,
          hint: l10n.securityPreviewHint,
          mono: true,
          prefixIcon: Icons.terminal,
          onChanged: (value) => setState(() => _text = value),
        ),
        const SizedBox(height: AppSpacing.sm),
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.background,
            borderRadius: AppRadius.mdAll,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  outcome == null
                      ? l10n.securityPreviewEmpty
                      : _riskLabel(l10n, outcome.risk),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colors.foreground,
                  ),
                ),
                if (outcome != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    outcome.reason,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFamily: AppTheme.monoFamily,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  CommandClassification? _outcome(String sample) {
    final trimmed = sample.trim();
    if (trimmed.isEmpty) return null;
    try {
      return CommandClassifier(
        denylist: [
          for (final line in widget.denylist.split('\n'))
            if (line.trim().isNotEmpty) line.trim(),
        ],
        profile: widget.profile,
      ).classify(trimmed);
    } on FormatException {
      return const CommandClassification(
        CommandRisk.deny,
        'denylist expression is invalid',
      );
    }
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.category,
    required this.names,
    required this.profile,
    required this.expanded,
    required this.openCommand,
    required this.onToggle,
    required this.onOpenCommand,
    required this.onChanged,
  });

  final KnowledgeCategory category;
  final List<String> names;
  final SecurityProfile profile;
  final bool expanded;
  final String? openCommand;
  final VoidCallback onToggle;
  final ValueChanged<String> onOpenCommand;
  final ValueChanged<SecurityProfile> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final level = profile.categories[category] ?? CommandRisk.ask;
    final own = _ownCount(level);
    final nameSet = names.toSet();
    final changed = profile.restoreCategory(category, nameSet) != profile;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _categoryLabel(l10n, category),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    Text(
                      own == 0
                          ? l10n.securityCommandCount(names.length)
                          : '${l10n.securityCommandCount(names.length)} · ${l10n.securityOwnLevels(own)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: _categoryLabel(l10n, category),
                onPressed: onToggle,
                icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: _RiskSelector(
              value: level,
              onChanged: (risk) =>
                  onChanged(profile.withCategory(category, risk)),
            ),
          ),
          if (expanded) ...[
            if (changed) ...[
              const SizedBox(height: AppSpacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () =>
                      onChanged(profile.restoreCategory(category, nameSet)),
                  child: Text(
                    l10n.securityRestoreCategory,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
            const Divider(height: AppSpacing.xl),
            for (final name in names) ...[
              _CommandTile(
                name: name,
                fallback: level,
                profile: profile,
                expanded: openCommand == name,
                onToggle: () => onOpenCommand(name),
                onChanged: onChanged,
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        ],
      ),
    );
  }

  int _ownCount(CommandRisk level) {
    var count = 0;
    for (final name in names) {
      final own = profile.commands[name];
      if (own != null && own != level) count++;
    }
    return count;
  }
}

class _CustomCommands extends StatelessWidget {
  const _CustomCommands({
    required this.profile,
    required this.catalog,
    required this.query,
    required this.openCommand,
    required this.onOpenCommand,
    required this.onChanged,
  });

  final SecurityProfile profile;
  final CommandCatalog catalog;
  final String query;
  final String? openCommand;
  final ValueChanged<String> onOpenCommand;
  final ValueChanged<SecurityProfile> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final names = <String>{
      for (final name in profile.commands.keys)
        if (catalog.categoryOf(name) == null) name,
      for (final rule in profile.arguments)
        if (catalog.categoryOf(rule.executable) == null) rule.executable,
    }.toList()..sort();
    final visible = [
      for (final name in names)
        if (query.isEmpty || name.contains(query)) name,
    ];
    if (names.isEmpty) return const SizedBox.shrink();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.securityCustom,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium,
          ),
          if (query.isNotEmpty && visible.isEmpty && names.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text(
                l10n.securityNoMatches,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final name in visible) ...[
            const SizedBox(height: AppSpacing.sm),
            _CommandTile(
              name: name,
              fallback: CommandRisk.ask,
              profile: profile,
              expanded: openCommand == name,
              onToggle: () => onOpenCommand(name),
              onChanged: onChanged,
              onRemove: () => onChanged(profile.withoutCommand(name)),
            ),
          ],
        ],
      ),
    );
  }
}

class _CommandTile extends StatelessWidget {
  const _CommandTile({
    required this.name,
    required this.fallback,
    required this.profile,
    required this.expanded,
    required this.onToggle,
    required this.onChanged,
    this.onRemove,
  });

  final String name;
  final CommandRisk fallback;
  final SecurityProfile profile;
  final bool expanded;
  final VoidCallback onToggle;
  final ValueChanged<SecurityProfile> onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final level = profile.commands[name] ?? fallback;
    final rules = [
      for (final rule in profile.arguments)
        if (rule.executable == name) rule,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: AppTheme.monoFamily,
                ),
              ),
            ),
            if (onRemove != null)
              IconButton(
                tooltip: l10n.commonDelete,
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline),
              ),
            IconButton(
              tooltip: l10n.securityArguments,
              onPressed: onToggle,
              icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: _RiskSelector(
            value: level,
            onChanged: (risk) => onChanged(
              onRemove != null || risk != fallback
                  ? profile.withCommand(name, risk)
                  : profile.withoutCommand(name),
            ),
          ),
        ),
        if (expanded) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.securityArguments,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          for (final rule in rules) ...[
            const SizedBox(height: AppSpacing.sm),
            _ArgumentRow(rule: rule, onChanged: onChanged, profile: profile),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => _addArgument(context),
              child: Text(
                l10n.securityAddArgument,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _addArgument(BuildContext context) async {
    final rule = await _askArgument(context, name);
    if (rule == null) return;
    onChanged(profile.withArgument(rule));
  }
}

class _ArgumentRow extends StatelessWidget {
  const _ArgumentRow({
    required this.rule,
    required this.profile,
    required this.onChanged,
  });

  final ArgumentRuleConfig rule;
  final SecurityProfile profile;
  final ValueChanged<SecurityProfile> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final label = rule.kind == ArgumentMatchKind.anyArgument
        ? l10n.securityArgumentAny
        : rule.token;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: rule.kind == ArgumentMatchKind.anyArgument
                      ? null
                      : AppTheme.monoFamily,
                ),
              ),
            ),
            IconButton(
              tooltip: l10n.commonDelete,
              onPressed: () => onChanged(profile.withoutArgument(rule)),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: _RiskSelector(
            value: rule.risk,
            onChanged: (risk) => onChanged(
              profile.withArgument(
                ArgumentRuleConfig(
                  executable: rule.executable,
                  kind: rule.kind,
                  token: rule.token,
                  risk: risk,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RiskSelector extends StatelessWidget {
  const _RiskSelector({required this.value, required this.onChanged});

  final CommandRisk value;
  final ValueChanged<CommandRisk> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SegmentedButton<CommandRisk>(
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      segments: [
        for (final risk in CommandRisk.values)
          ButtonSegment(
            value: risk,
            tooltip: _riskLabel(l10n, risk),
            icon: Icon(
              _riskIcon(risk),
              // У выбранного сегмента цвет берёт кнопка: свой тон на заливке теряется.
              color: risk == value
                  ? null
                  : toneColors(context, _riskTone(risk)).foreground,
            ),
            label: Text(
              _riskLabel(l10n, risk),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      selected: {value},
      onSelectionChanged: (selected) => onChanged(selected.first),
    );
  }
}

/// Пустое состояние поиска собирается здесь, чтобы заголовок был из локализации.
class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppEmptyState(
      icon: Icons.search_off,
      title: l10n.securityNoMatches,
      message: l10n.securityNoMatchesHint,
    );
  }
}

final _commandNamePattern = RegExp(r'^[a-z0-9][a-z0-9._+-]*$');

String _riskLabel(AppLocalizations l10n, CommandRisk risk) => switch (risk) {
  CommandRisk.auto => l10n.securityRiskAuto,
  CommandRisk.ask => l10n.securityRiskAsk,
  CommandRisk.deny => l10n.securityRiskDeny,
};

/// Молния — выполнить, рука — спросить, знак запрета — не выполнять.
IconData _riskIcon(CommandRisk risk) => switch (risk) {
  CommandRisk.auto => Icons.bolt_outlined,
  CommandRisk.ask => Icons.front_hand_outlined,
  CommandRisk.deny => Icons.block,
};

AppTone _riskTone(CommandRisk risk) => switch (risk) {
  CommandRisk.auto => AppTone.success,
  CommandRisk.ask => AppTone.warning,
  CommandRisk.deny => AppTone.danger,
};

String _categoryLabel(AppLocalizations l10n, KnowledgeCategory category) =>
    switch (category) {
      KnowledgeCategory.versionControl => l10n.securityCatVersionControl,
      KnowledgeCategory.filesystem => l10n.securityCatFilesystem,
      KnowledgeCategory.archive => l10n.securityCatArchive,
      KnowledgeCategory.compression => l10n.securityCatCompression,
      KnowledgeCategory.hash => l10n.securityCatHash,
      KnowledgeCategory.crypto => l10n.securityCatCrypto,
      KnowledgeCategory.database => l10n.securityCatDatabase,
      KnowledgeCategory.editor => l10n.securityCatEditor,
      KnowledgeCategory.packageManager => l10n.securityCatPackageManager,
      KnowledgeCategory.container => l10n.securityCatContainer,
      KnowledgeCategory.infrastructure => l10n.securityCatInfrastructure,
      KnowledgeCategory.network => l10n.securityCatNetwork,
      KnowledgeCategory.shell => l10n.securityCatShell,
      KnowledgeCategory.interpreter => l10n.securityCatInterpreter,
      KnowledgeCategory.process => l10n.securityCatProcess,
      KnowledgeCategory.system => l10n.securityCatSystem,
      KnowledgeCategory.environment => l10n.securityCatEnvironment,
      KnowledgeCategory.other => l10n.securityCatOther,
    };

Future<String?> _askCommandName(BuildContext context) => showDialog<String>(
  context: context,
  builder: (_) => const _CommandNameDialog(),
);

Future<ArgumentRuleConfig?> _askArgument(
  BuildContext context,
  String executable,
) => showDialog<ArgumentRuleConfig>(
  context: context,
  builder: (_) => _ArgumentDialog(executable: executable),
);

/// Диалог имени команды. Контроллер живёт вместе с маршрутом, а не до конца анимации закрытия.
class _CommandNameDialog extends StatefulWidget {
  const _CommandNameDialog();

  @override
  State<_CommandNameDialog> createState() => _CommandNameDialogState();
}

class _CommandNameDialogState extends State<_CommandNameDialog> {
  final _name = TextEditingController();
  var _error = '';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = AppLocalizations.of(context);
    final name = _name.text.trim().toLowerCase();
    if (!_commandNamePattern.hasMatch(name)) {
      setState(() => _error = l10n.securityCommandInvalid);
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(
        l10n.securityAddCommandTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: AppTextField(
        controller: _name,
        hint: l10n.securityAddCommandHint,
        error: _error.isEmpty ? null : _error,
        mono: true,
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            l10n.commonCancel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(
            l10n.securityAddCommand,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Диалог правила аргумента. Контроллер поля уничтожается вместе с состоянием диалога.
class _ArgumentDialog extends StatefulWidget {
  const _ArgumentDialog({required this.executable});

  final String executable;

  @override
  State<_ArgumentDialog> createState() => _ArgumentDialogState();
}

class _ArgumentDialogState extends State<_ArgumentDialog> {
  final _token = TextEditingController();
  var _kind = ArgumentMatchKind.flag;
  var _risk = CommandRisk.ask;
  var _error = '';

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = AppLocalizations.of(context);
    final value = _token.text.trim();
    if (_kind != ArgumentMatchKind.anyArgument && value.isEmpty) {
      setState(() => _error = l10n.securityCommandInvalid);
      return;
    }
    Navigator.pop(
      context,
      ArgumentRuleConfig(
        executable: widget.executable,
        kind: _kind,
        token: _kind == ArgumentMatchKind.anyArgument ? '' : value,
        risk: _risk,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(
        l10n.securityArgumentTitle(widget.executable),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppChoiceGroup<ArgumentMatchKind>(
              options: [
                AppChoiceOption(
                  value: ArgumentMatchKind.flag,
                  title: l10n.securityArgumentFlag,
                  subtitle: l10n.securityArgumentFlagHint,
                ),
                AppChoiceOption(
                  value: ArgumentMatchKind.subcommand,
                  title: l10n.securityArgumentSubcommand,
                  subtitle: l10n.securityArgumentSubcommandHint,
                ),
                AppChoiceOption(
                  value: ArgumentMatchKind.anyArgument,
                  title: l10n.securityArgumentAny,
                  subtitle: l10n.securityArgumentAnyHint,
                ),
              ],
              selected: _kind,
              onChanged: (value) => setState(() => _kind = value),
            ),
            if (_kind != ArgumentMatchKind.anyArgument) ...[
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                controller: _token,
                hint: l10n.securityArgumentToken,
                error: _error.isEmpty ? null : _error,
                mono: true,
                autofocus: true,
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            _RiskSelector(
              value: _risk,
              onChanged: (value) => setState(() => _risk = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            l10n.commonCancel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(
            l10n.securityAddArgument,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
