import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/security/security_audit.dart';
import 'package:probably_works/core/security/security_audit_service.dart';
import 'package:probably_works/core/util/short_time.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Секция настроек с детерминированным аудитом окружения.
class SecurityAuditSection extends StatefulWidget {
  const SecurityAuditSection({super.key});

  @override
  State<SecurityAuditSection> createState() => _SecurityAuditSectionState();
}

class _SecurityAuditSectionState extends State<SecurityAuditSection> {
  final _service = getIt<SecurityAuditService>();
  SecurityReport? _report;
  var _running = false;
  String? _error;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final report = await _service.run();
      if (!mounted) return;
      setState(() => _report = report);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppSection(
      title: l10n.securityAuditTitle,
      description: l10n.securityAuditHint,
      trailing: FilledButton.icon(
        onPressed: _running ? null : _run,
        icon: _running
            ? const SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.security),
        label: Text(
          _running ? l10n.securityAuditRunning : l10n.securityAuditRun,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      children: [
        if (_error case final error?)
          AppBanner(message: l10n.commonError(error), tone: AppTone.danger),
        if (_report case final report?) _ReportView(report: report),
      ],
    );
  }
}

class _ReportView extends StatelessWidget {
  const _ReportView({required this.report});

  final SecurityReport report;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final status = _status(l10n, report.status);
    final findings = sortFindingsBySeverity(report.findings);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppBanner(
          title: status.label,
          message: status.hint,
          tone: status.tone,
          icon: status.icon,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '${l10n.securityAuditCheckedAt(formatShortTime(report.generatedAt))}'
          ' · ${l10n.securityAuditPlatform(report.platform)}',
          style: theme.textTheme.labelSmall,
        ),
        const SizedBox(height: AppSpacing.md),
        for (final finding in findings) ...[
          _FindingCard(finding: finding),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }

  static ({String label, String hint, AppTone tone, IconData icon}) _status(
    AppLocalizations l10n,
    SecurityStatus status,
  ) => switch (status) {
    SecurityStatus.unsafe => (
      label: l10n.securityAuditStatusUnsafe,
      hint: l10n.securityAuditUnsafeHint,
      tone: AppTone.danger,
      icon: Icons.gpp_maybe_outlined,
    ),
    SecurityStatus.baseline => (
      label: l10n.securityAuditStatusBaseline,
      hint: l10n.securityAuditBaselineHint,
      tone: AppTone.warning,
      icon: Icons.shield_outlined,
    ),
    SecurityStatus.unknown => (
      label: l10n.securityAuditStatusUnknown,
      hint: l10n.securityAuditUnknownHint,
      tone: AppTone.neutral,
      icon: Icons.help_outline,
    ),
    SecurityStatus.isolated => (
      label: l10n.securityAuditStatusIsolated,
      hint: l10n.securityAuditIsolatedHint,
      tone: AppTone.success,
      icon: Icons.verified_user_outlined,
    ),
  };
}

class _FindingCard extends StatelessWidget {
  const _FindingCard({required this.finding});

  final SecurityFinding finding;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final text = _text(l10n, finding);
    final severity = _severity(l10n, finding.severity);
    return AppCard(
      accent: toneColors(context, severity.tone).foreground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(severity.icon, size: 16, color: severity.color(context)),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(text.title, style: theme.textTheme.titleSmall),
              ),
              Text(
                severity.label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: severity.color(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(text.detail, style: theme.textTheme.bodySmall),
          const SizedBox(height: AppSpacing.xs),
          Text(
            text.recommendation,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  static ({String title, String detail, String recommendation}) _text(
    AppLocalizations l10n,
    SecurityFinding finding,
  ) => switch (finding.code) {
    SecurityFindingCode.guiMode => (
      title: l10n.securityAuditGuiTitle,
      detail: l10n.securityAuditGuiDetail,
      recommendation: l10n.securityAuditGuiRecommendation,
    ),
    SecurityFindingCode.rootUser => (
      title: l10n.securityAuditRootTitle,
      detail: l10n.securityAuditRootDetail,
      recommendation: l10n.securityAuditRootRecommendation,
    ),
    SecurityFindingCode.secretStore => (
      title: l10n.securityAuditSecretStoreTitle,
      detail: l10n.securityAuditSecretStoreDetail(
        finding.params['backend'] ?? 'unknown',
      ),
      recommendation: l10n.securityAuditSecretStoreRecommendation,
    ),
    SecurityFindingCode.dataPermissions => (
      title: l10n.securityAuditPermissionsTitle,
      detail: l10n.securityAuditPermissionsDetail(
        finding.params['path'] ?? '?',
        finding.params['mode'] ?? '?',
        finding.params['expected'] ?? '?',
      ),
      recommendation: l10n.securityAuditPermissionsRecommendation,
    ),
    SecurityFindingCode.permissionsUnknown => (
      title: l10n.securityAuditPermissionsUnknownTitle,
      detail: l10n.securityAuditPermissionsUnknownDetail,
      recommendation: l10n.securityAuditPermissionsUnknownRecommendation,
    ),
    SecurityFindingCode.sandboxedStorage => (
      title: l10n.securityAuditSandboxTitle,
      detail: l10n.securityAuditSandboxDetail,
      recommendation: l10n.securityAuditSandboxRecommendation,
    ),
    SecurityFindingCode.environmentSecrets => (
      title: l10n.securityAuditEnvTitle,
      detail: l10n.securityAuditEnvDetail(finding.params['keys'] ?? '?'),
      recommendation: l10n.securityAuditEnvRecommendation,
    ),
    SecurityFindingCode.policyYolo => (
      title: l10n.securityAuditPolicyTitle,
      detail: l10n.securityAuditPolicyDetail,
      recommendation: l10n.securityAuditPolicyRecommendation,
    ),
    SecurityFindingCode.emptyDenylist => (
      title: l10n.securityAuditDenylistTitle,
      detail: l10n.securityAuditDenylistDetail,
      recommendation: l10n.securityAuditDenylistRecommendation,
    ),
    SecurityFindingCode.externalTools => (
      title: l10n.securityAuditExternalTitle,
      detail: l10n.securityAuditExternalDetail(
        finding.params['plugins']?.isEmpty ?? true
            ? '—'
            : finding.params['plugins']!,
        finding.params['servers']?.isEmpty ?? true
            ? '—'
            : finding.params['servers']!,
      ),
      recommendation: l10n.securityAuditExternalRecommendation,
    ),
    SecurityFindingCode.headlessApi => (
      title: l10n.securityAuditApiTitle,
      detail: l10n.securityAuditApiDetail,
      recommendation: l10n.securityAuditApiRecommendation,
    ),
    SecurityFindingCode.singleInstance => (
      title: l10n.securityAuditSingleTitle,
      detail: l10n.securityAuditSingleDetail(finding.params['path'] ?? '?'),
      recommendation: l10n.securityAuditSingleRecommendation,
    ),
  };

  static ({
    String label,
    AppTone tone,
    IconData icon,
    Color Function(BuildContext) color,
  })
  _severity(AppLocalizations l10n, SecuritySeverity severity) =>
      switch (severity) {
        SecuritySeverity.critical => (
          label: l10n.securityAuditSeverityCritical,
          tone: AppTone.danger,
          icon: Icons.error_outline,
          color: (context) => Theme.of(context).colorScheme.error,
        ),
        SecuritySeverity.warning => (
          label: l10n.securityAuditSeverityWarning,
          tone: AppTone.warning,
          icon: Icons.warning_amber_outlined,
          color: (context) => toneColors(context, AppTone.warning).foreground,
        ),
        SecuritySeverity.info => (
          label: l10n.securityAuditSeverityInfo,
          tone: AppTone.info,
          icon: Icons.info_outline,
          color: (context) => toneColors(context, AppTone.info).foreground,
        ),
      };
}
