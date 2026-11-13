import 'dart:async';

import 'package:app_ui/app_ui.dart';
import 'package:auto_route/auto_route.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/profiles/agent_profile.dart';
import 'package:probably_works/app/profiles/profile_service.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Первый экран web-клиента: адрес сервера и токен.
///
/// Браузер не ищет локальный демон и не поднимает агент. После подключения
/// профиль сохраняется как обычный удалённый профиль.
@RoutePage()
class WebConnectPage extends StatefulWidget {
  const WebConnectPage({super.key});

  @override
  State<WebConnectPage> createState() => _WebConnectPageState();
}

class _WebConnectPageState extends State<WebConnectPage> {
  final _name = TextEditingController(text: 'ProbablyWorks');
  final _url = TextEditingController(text: 'http://127.0.0.1:7787');
  final _token = TextEditingController();
  AgentProfile? _existing;
  var _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = getIt<ProfileService>().profiles
        .where((profile) => !profile.isLocal)
        .firstOrNull;
    if (existing == null) return;
    _existing = existing;
    _name.text = existing.name;
    if (existing.baseUri case final uri?) _url.text = uri.toString();
    unawaited(_checkExisting(existing));
  }

  Future<void> _checkExisting(AgentProfile profile) async {
    final online = await getIt<ProfileService>()
        .agentApiFor(profile)
        .checkConnection();
    if (!mounted || online) return;
    setState(() => _error = AppLocalizations.of(context).webConnectUnavailable);
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final l10n = AppLocalizations.of(context);
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      setState(() => _error = l10n.webConnectInvalidUrl);
      return;
    }
    if (_token.text.trim().isEmpty) {
      setState(() => _error = l10n.webConnectTokenRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = getIt<ProfileService>();
      final name = _name.text.trim().isEmpty ? uri.host : _name.text.trim();
      final token = _token.text.trim();
      final existing = _existing;
      final AgentProfile? profile;
      if (existing == null) {
        profile = await service.addRemote(
          name: name,
          baseUri: uri,
          token: token,
        );
      } else {
        await service.updateRemote(
          existing.id,
          name: name,
          baseUri: uri,
          token: token.isEmpty ? null : token,
        );
        profile = service.byId(existing.id);
      }
      if (profile == null) throw StateError('profile is missing');
      if (!mounted) return;
      // Не блокируем вход, если сервер сейчас offline: профиль сохранён,
      // а внутри workspace будет уведомление и доступ к настройкам.
      await context.router.replace(WorkspaceRoute(profileId: profile.id));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l10n.webConnectFailed('$error');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AppScaffold(
      maxWidth: AppLayout.formMaxWidth,
      appBar: AppBar(title: Text(l10n.webConnectTitle)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Text(
            l10n.webConnectHint,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppTextField(controller: _name, label: l10n.webConnectName),
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  controller: _url,
                  label: l10n.webConnectUrl,
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  controller: _token,
                  label: l10n.webConnectToken,
                  obscure: true,
                  onSubmitted: (_) => _busy ? null : _connect(),
                ),
                if (_error case final error?) ...[
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    error,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.lg),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _busy ? null : _connect,
                    child: _busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.webConnectAction),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
