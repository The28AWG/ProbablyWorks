import 'package:app_ui/app_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/features/hosts/presentation/widgets/host_card.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/core/domain/host.dart';

final _local = Host(
  id: 'local',
  name: 'Local',
  kind: HostKind.local,
  os: HostOs.posix,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

final _ssh = Host(
  id: 'mini',
  name: 'mini',
  kind: HostKind.ssh,
  address: '192.168.0.140',
  port: 22,
  username: 'the28awg',
  os: HostOs.macos,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

final _virtual = Host(
  id: 'sandbox',
  name: 'Sandbox',
  kind: HostKind.virtual,
  os: HostOs.posix,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// Записывает действия карточки в [log]: так видно, какая кнопка что вызвала.
Future<AppLocalizations> _pump(
  WidgetTester tester,
  Host host,
  List<String> log, {
  double width = 800,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('en'),
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: HostCard(
            host: host,
            testing: false,
            onTest: () => log.add('test'),
            onEdit: () => log.add('edit'),
            onDelete: () => log.add('delete'),
          ),
        ),
      ),
    ),
  );
  return AppLocalizations.of(tester.element(find.byType(HostCard)));
}

void main() {
  testWidgets('the local computer has no connection test and no status', (
    tester,
  ) async {
    final log = <String>[];
    final l10n = await _pump(tester, _local, log);

    expect(find.byTooltip(l10n.hostTest), findsNothing);
    expect(find.text(l10n.hostStatusUnknown), findsNothing);
    expect(find.text(l10n.hostNeverChecked), findsNothing);
  });

  testWidgets('the local computer shows its system name, not the raw code', (
    tester,
  ) async {
    final log = <String>[];
    final l10n = await _pump(tester, _local, log);

    expect(find.text(l10n.hostOsPosix), findsOneWidget);
    expect(find.text('posix'), findsNothing);
  });

  testWidgets('the local computer can still be edited but not deleted', (
    tester,
  ) async {
    final log = <String>[];
    final l10n = await _pump(tester, _local, log);

    expect(find.byTooltip(l10n.commonDelete), findsNothing);

    await tester.tap(find.byTooltip(l10n.commonEdit));
    expect(log, ['edit']);
  });

  testWidgets('an SSH host keeps the test button and the status', (
    tester,
  ) async {
    final log = <String>[];
    final l10n = await _pump(tester, _ssh, log);

    expect(find.byTooltip(l10n.hostTest), findsOneWidget);
    expect(find.text(l10n.hostStatusUnknown), findsOneWidget);
    expect(find.text('the28awg@192.168.0.140:22'), findsOneWidget);
    expect(find.byTooltip(l10n.commonDelete), findsOneWidget);

    await tester.tap(find.byTooltip(l10n.hostTest));
    expect(log, ['test']);
  });

  testWidgets('a virtual host shows its sandbox line and the memory icon', (
    tester,
  ) async {
    final log = <String>[];
    final l10n = await _pump(tester, _virtual, log);

    expect(find.text(l10n.hostVirtualSubtitle), findsOneWidget);
    expect(find.textContaining('@'), findsNothing);
    expect(find.byIcon(Icons.memory_outlined), findsOneWidget);
    expect(find.byIcon(Icons.dns_outlined), findsNothing);
  });

  testWidgets('a virtual host keeps the check and the delete actions', (
    tester,
  ) async {
    final log = <String>[];
    final l10n = await _pump(tester, _virtual, log);

    expect(find.byTooltip(l10n.hostTest), findsOneWidget);
    expect(find.text(l10n.hostStatusUnknown), findsOneWidget);
    expect(find.byTooltip(l10n.commonDelete), findsOneWidget);

    await tester.tap(find.byTooltip(l10n.hostTest));
    expect(log, ['test']);
  });

  testWidgets(
    'a narrow card moves the actions under the text without overflow',
    (tester) async {
      final long = _ssh.copyWith(
        name: 'очень длинное название сервера для проверки переноса на узком экране',
        notes:
            'примечание, которое тоже достаточно длинное, чтобы занять строку',
      );
      final log = <String>[];
      final l10n = await _pump(tester, long, log, width: 300);

      final address = tester.getBottomLeft(
        find.textContaining('192.168.0.140'),
      );
      expect(
        tester.getTopLeft(find.byTooltip(l10n.commonEdit)).dy,
        greaterThan(address.dy),
      );

      await tester.tap(find.byTooltip(l10n.hostTest));
      expect(log, ['test']);
    },
  );

  testWidgets('a wide card keeps the actions in the same row as the text', (
    tester,
  ) async {
    final log = <String>[];
    final l10n = await _pump(tester, _ssh, log, width: 700);

    final address = tester.getBottomLeft(find.textContaining('192.168.0.140'));
    expect(
      tester.getTopLeft(find.byTooltip(l10n.commonEdit)).dy,
      lessThan(address.dy),
    );
  });

  testWidgets('the host avatar shrinks on a narrow card', (tester) async {
    await _pump(tester, _ssh, [], width: 300);
    expect(tester.getSize(find.byIcon(Icons.dns_outlined)).width, 20);

    await _pump(tester, _ssh, [], width: 700);
    expect(tester.getSize(find.byIcon(Icons.dns_outlined)).width, 24);
  });
}
