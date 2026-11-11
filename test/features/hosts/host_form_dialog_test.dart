import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/features/hosts/presentation/widgets/host_form_dialog.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Кнопка открывает [HostFormDialog]; сохранённые хосты уходят в [saved].
class _Host extends StatelessWidget {
  const _Host({required this.saved, this.existing});

  final List<Host> saved;
  final Host? existing;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => HostFormDialog(
                existing: existing,
                onSave: (host, {secret, privateKeyPem}) async =>
                    saved.add(host),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

Future<AppLocalizations> _open(WidgetTester tester, {Host? existing}) async {
  await tester.pumpWidget(_Host(saved: [], existing: existing));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return AppLocalizations.of(tester.element(find.byType(AlertDialog)));
}

final _local = Host(
  id: 'local',
  name: 'This computer',
  kind: HostKind.local,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  testWidgets('a local host edits only the environment', (tester) async {
    final l10n = await _open(tester, existing: _local);

    expect(find.text(l10n.hostAddressLabel), findsNothing);
    expect(find.text(l10n.hostAuthKey), findsNothing);
    expect(find.text(l10n.hostDefaultWorkspaceLabel), findsOneWidget);
    expect(find.text(l10n.hostShellLabel), findsOneWidget);
  });

  testWidgets('a new SSH host starts with key auth and shows the key rows', (
    tester,
  ) async {
    final l10n = await _open(tester);

    expect(find.byType(AppChoiceGroup<SshAuthType>), findsOneWidget);
    expect(find.text(l10n.hostPrivateKeyLabel), findsOneWidget);
  });

  testWidgets('switching to password hides the private key row', (
    tester,
  ) async {
    final l10n = await _open(tester);

    // Секция системы стоит выше аутентификации, поэтому группа может быть вне прокрутки.
    await tester.ensureVisible(find.text(l10n.hostAuthPassword));
    await tester.tap(find.text(l10n.hostAuthPassword));
    await tester.pumpAndSettle();

    expect(find.text(l10n.hostPrivateKeyLabel), findsNothing);
    expect(find.text(l10n.hostSecretLabel), findsOneWidget);
  });

  testWidgets('an empty address is refused and keeps the dialog open', (
    tester,
  ) async {
    final l10n = await _open(tester);

    await tester.tap(find.text(l10n.commonSave));
    await tester.pumpAndSettle();

    expect(find.text(l10n.hostAddressRequired), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('a valid SSH host is saved with the address as its name', (
    tester,
  ) async {
    final saved = <Host>[];
    await tester.pumpWidget(_Host(saved: saved));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(AlertDialog)));

    final address = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == l10n.hostAddressHint,
    );
    await tester.enterText(address, 'example.com');
    await tester.tap(find.text(l10n.commonSave));
    await tester.pumpAndSettle();

    expect(saved, hasLength(1));
    expect(saved.single.name, 'example.com');
    expect(saved.single.address, 'example.com');
    expect(saved.single.port, 22);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('the remote system is chosen with cards and saved', (
    tester,
  ) async {
    final saved = <Host>[];
    await tester.pumpWidget(_Host(saved: saved));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(AlertDialog)));

    expect(find.byType(AppChoiceGroup<HostOs>), findsOneWidget);
    expect(find.byType(AppSvgIcon), findsNWidgets(3));

    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == l10n.hostAddressHint,
      ),
      'example.com',
    );
    await tester.ensureVisible(find.text(l10n.hostOsMacos));
    await tester.tap(find.text(l10n.hostOsMacos));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(l10n.commonSave));
    await tester.tap(find.text(l10n.commonSave));
    await tester.pumpAndSettle();

    expect(saved.single.os, HostOs.macos);
  });

  testWidgets('the form content is capped at the form width on a wide window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _open(tester);

    // Измеряем форму: сам диалог растягивается на окно, а форма — нет.
    final content = tester.getSize(
      find.byKey(const ValueKey('host-form-content')),
    );
    expect(content.width, lessThanOrEqualTo(AppLayout.formMaxWidth));
  });

  testWidgets('the scroll area spans the dialog edge to edge', (tester) async {
    await _open(tester);

    // Полоса прокрутки стоит на правом краю прокрутки; она должна совпадать с видимым краем диалога.
    // Dialog включает внешние отступы (insetPadding), поэтому меряем Material внутри него — саму карточку.
    final scroll = tester.getSize(find.byType(SingleChildScrollView).first);
    final dialog = tester.getSize(
      find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first,
    );
    expect(scroll.width, closeTo(dialog.width, 0.5));
  });

  testWidgets('a new host offers the SSH and virtual kinds', (tester) async {
    final l10n = await _open(tester);

    expect(find.byType(AppChoiceGroup<HostKind>), findsOneWidget);
    expect(find.text(l10n.hostKindSsh), findsOneWidget);
    expect(find.text(l10n.hostKindVirtual), findsOneWidget);
  });

  testWidgets('an existing host has no kind choice: its kind is fixed', (
    tester,
  ) async {
    await _open(tester, existing: _virtual);

    expect(find.byType(AppChoiceGroup<HostKind>), findsNothing);
  });

  testWidgets('a virtual host hides the SSH-only fields', (tester) async {
    final l10n = await _open(tester);

    await tester.tap(find.text(l10n.hostKindVirtual));
    await tester.pumpAndSettle();

    expect(find.text(l10n.hostAddressLabel), findsNothing);
    expect(find.text(l10n.hostPortLabel), findsNothing);
    expect(find.text(l10n.hostUserLabel), findsNothing);
    expect(find.text(l10n.hostOsLabel), findsNothing);
    expect(find.text(l10n.hostFormSectionAuth), findsNothing);
    expect(find.text(l10n.hostShellLabel), findsNothing);
    expect(find.text(l10n.hostTimeoutLabel), findsNothing);
    expect(find.text(l10n.hostNameLabel), findsOneWidget);
    expect(find.text(l10n.hostNotesLabel), findsOneWidget);
  });

  testWidgets('a virtual host is saved with the default name and no SSH data', (
    tester,
  ) async {
    final saved = <Host>[];
    await tester.pumpWidget(_Host(saved: saved));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(AlertDialog)));

    await tester.tap(find.text(l10n.hostKindVirtual));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.commonSave));
    await tester.pumpAndSettle();

    expect(saved, hasLength(1));
    final host = saved.single;
    expect(host.kind, HostKind.virtual);
    expect(host.name, l10n.hostVirtualDefaultName);
    expect(host.address, isNull);
    expect(host.username, isNull);
    expect(host.shellOverride, isNull);
    expect(host.connectTimeoutSeconds, isNull);
    expect(host.os, HostOs.posix);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a virtual host ignores an address typed before switching', (
    tester,
  ) async {
    final saved = <Host>[];
    await tester.pumpWidget(_Host(saved: saved));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(AlertDialog)));

    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == l10n.hostAddressHint,
      ),
      'example.com',
    );
    await tester.tap(find.text(l10n.hostKindVirtual));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.commonSave));
    await tester.pumpAndSettle();

    expect(saved.single.kind, HostKind.virtual);
    expect(saved.single.address, isNull);
  });

  testWidgets('environment rows save a valid pair and reject a bad name', (
    tester,
  ) async {
    final saved = <Host>[];
    await tester.pumpWidget(_Host(saved: saved, existing: _local));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(AlertDialog)));

    await tester.ensureVisible(find.text(l10n.hostEnvironmentAdd));
    await tester.tap(find.text(l10n.hostEnvironmentAdd));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == l10n.hostEnvironmentNameHint,
      ),
      '1BAD',
    );
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == l10n.hostEnvironmentValueHint,
      ),
      'secret-value',
    );
    await tester.ensureVisible(find.text(l10n.commonSave));
    await tester.tap(find.text(l10n.commonSave));
    await tester.pumpAndSettle();

    expect(saved, isEmpty);
    expect(find.text(l10n.hostEnvironmentNameInvalid), findsOneWidget);

    final nameField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == l10n.hostEnvironmentNameHint,
    );
    final valueField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == l10n.hostEnvironmentValueHint,
    );
    final nameBox = tester.getRect(nameField);
    final valueBox = tester.getRect(valueField);
    final content = tester.getSize(
      find.byKey(const ValueKey('host-form-content')),
    );
    final row = find.ancestor(of: nameField, matching: find.byType(Row)).first;

    expect(nameBox.top, closeTo(valueBox.top, 1));
    expect(tester.getSize(row).width, closeTo(content.width, 1));
    expect(
      tester
          .renderObject<RenderParagraph>(
            find.text(l10n.hostEnvironmentNameInvalid),
          )
          .didExceedMaxLines,
      isFalse,
    );

    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == l10n.hostEnvironmentNameHint,
      ),
      'TOKEN',
    );
    await tester.ensureVisible(find.text(l10n.hostEnvironmentAdd));
    await tester.tap(find.text(l10n.hostEnvironmentAdd));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(l10n.commonSave));
    await tester.tap(find.text(l10n.commonSave));
    await tester.pumpAndSettle();

    expect(saved, hasLength(1));
    expect(saved.single.environment, {'TOKEN': 'secret-value'});
  });
}

final _virtual = Host(
  id: 'sandbox',
  name: 'Sandbox',
  kind: HostKind.virtual,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);
