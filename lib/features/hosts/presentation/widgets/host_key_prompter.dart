import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/host/ssh_connection_pool.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

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
    final trusted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          request.isChanged
              ? l10n.hostKeyChangedTitle
              : l10n.hostKeyFirstUseTitle,
        ),
        content: Text(
          request.isChanged
              ? l10n.hostKeyChangedBody(
                  request.host.address ?? request.host.name,
                  request.fingerprint,
                )
              : l10n.hostKeyFirstUseBody(
                  request.host.address ?? request.host.name,
                  request.fingerprint,
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.hostKeyReject),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.hostKeyTrust),
          ),
        ],
      ),
    );
    getIt<HostKeyConfirmations>().resolve(
      request.id,
      trusted: trusted ?? false,
    );
    _showing = false;
    unawaited(_showNext());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
