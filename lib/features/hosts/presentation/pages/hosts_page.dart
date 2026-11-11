import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/profiles/profile_scope.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/hosts/presentation/bloc/hosts_cubit.dart';
import 'package:probably_works/features/hosts/presentation/widgets/host_card.dart';
import 'package:probably_works/features/hosts/presentation/widgets/host_form_dialog.dart';
import 'package:probably_works/features/workspace/presentation/widgets/workspace_shell.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/hosts_api.dart';
import 'package:pw_agent/core/domain/host.dart';

@RoutePage()
class HostsPage extends StatelessWidget {
  const HostsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BlocProvider(
      create: (_) => HostsCubit(
        ProfileScope.maybeOf(context)?.hostsApi ?? getIt<HostsApi>(),
      ),
      child: AppScaffold(
        appBar: AppBar(
          leading: context.workspaceLayout == .compact
              ? const WorkspaceLeadingButton()
              : null,
          title: Text(
            l10n.hostsTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        maxWidth: AppLayout.pageMaxWidth,
        floatingActionButton: Builder(
          builder: (context) => FloatingActionButton.extended(
            heroTag: 'hosts-add-fab',
            icon: const Icon(Icons.add),
            label: Text(
              l10n.hostsAdd,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: () => _openForm(context, null),
          ),
        ),
        body: BlocBuilder<HostsCubit, HostsState>(
          builder: (context, state) {
            if (state.hosts.isEmpty) {
              return AppEmptyState(
                icon: Icons.dns_outlined,
                title: l10n.hostsEmptyTitle,
                message: l10n.hostsEmptyMessage,
                action: FilledButton(
                  onPressed: () => _openForm(context, null),
                  child: Text(
                    l10n.hostsAdd,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              );
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                96,
              ),
              children: [
                for (final host in state.hosts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: HostCard(
                      host: host,
                      testing: state.testing.contains(host.id),
                      onTest: () => context.read<HostsCubit>().test(host),
                      onEdit: () => _openForm(context, host),
                      onDelete: () => _confirmDelete(context, host),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, Host host) async {
    final l10n = AppLocalizations.of(context);
    final cubit = context.read<HostsCubit>();
    final ok = await ConfirmDialog.confirm(
      context,
      title: l10n.commonDelete,
      message: l10n.hostDeleteConfirm,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonDelete,
      destructive: true,
    );
    if (ok) await cubit.delete(host.id);
  }

  Future<void> _openForm(BuildContext context, Host? existing) =>
      showHostFormDialog(context, existing: existing);
}
