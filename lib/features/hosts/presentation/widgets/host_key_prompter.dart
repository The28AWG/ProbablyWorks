import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/host/ssh_connection_pool.dart';

/// Показывает диалог подтверждения SSH host key поверх любого экрана.
/// Первое подключение — обычный запрос; смена ключа — предупреждение (по умолчанию отказ).
class HostKeyPrompter extends StatefulWidget {
  const HostKeyPrompter({
    required this.navigatorKey,
    required this.child,
    super.key,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<HostKeyPrompter> createState() => _HostKeyPrompterState();
}

class _HostKeyPrompterState extends State<HostKeyPrompter> {
  late final StreamSubscription<HostKeyRequest> _sub;
  final _queue = <HostKeyRequest>[];
  var _showing = false;

  @override
  void initState() {
    super.initState();
    _sub = getIt<HostKeyConfirmations>().requests.listen((request) {
      _queue.add(request);
      unawaited(_showNext());
    });
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }

  Future<void> _showNext() async {
    if (_showing || _queue.isEmpty) return;
    final context = widget.navigatorKey.currentContext;
    if (context == null) return;
    _showing = true;
    final request = _queue.removeAt(0);
    final l10n = AppLocalizations.of(context);
    final host = request.host.address ?? request.host.name;
    final trusted = await ConfirmDialog.confirm(
      context,
      title: request.isChanged
          ? l10n.hostKeyChangedTitle
          : l10n.hostKeyFirstUseTitle,
      message: request.isChanged
          ? l10n.hostKeyChangedBody(host, request.fingerprint)
          : l10n.hostKeyFirstUseBody(host, request.fingerprint),
      cancelLabel: l10n.hostKeyReject,
      confirmLabel: l10n.hostKeyTrust,
      destructive: request.isChanged,
      barrierDismissible: false,
    );
    getIt<HostKeyConfirmations>().resolve(request.id, trusted: trusted);
    _showing = false;
    unawaited(_showNext());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
