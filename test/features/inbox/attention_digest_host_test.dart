import 'package:app_ui/app_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/features/inbox/presentation/widgets/attention_digest_host.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/attention_digest_api.dart';
import 'package:pw_agent/agent/domain/attention_digest.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/core/data/chat_draft_store.dart';
import 'package:pw_agent/core/domain/host.dart';

void main() {
  final now = DateTime.utc(2026, 11, 27, 12);

  testWidgets('shows the digest after a long absence', (tester) async {
    final settings = MemoryClientSettings({
      '${ClientSettingsKeys.attentionDigestLastActiveAt}.default': now
          .subtract(const Duration(hours: 2))
          .toIso8601String(),
    });
    final api = _DigestApi();
    final cubit = ChatListCubit(api, ChatDraftStore.unbound());
    addTearDown(cubit.close);
    await _pump(tester, cubit, settings, now);

    expect(find.text('While you were away'), findsOneWidget);
    expect(find.text('2 new messages'), findsOneWidget);
  });

  testWidgets('does not show the digest after a short pause', (tester) async {
    final settings = MemoryClientSettings({
      '${ClientSettingsKeys.attentionDigestLastActiveAt}.default': now
          .subtract(const Duration(minutes: 5))
          .toIso8601String(),
    });
    final api = _DigestApi();
    final cubit = ChatListCubit(api, ChatDraftStore.unbound());
    addTearDown(cubit.close);
    await _pump(tester, cubit, settings, now);

    expect(find.text('While you were away'), findsNothing);
    expect(api.digestCalls, 0);
  });
}

Future<void> _pump(
  WidgetTester tester,
  ChatListCubit cubit,
  ClientSettings settings,
  DateTime now,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('en'),
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BlocProvider.value(
        value: cubit,
        child: AttentionDigestHost(settings: settings, now: () => now),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final class _DigestApi implements AgentApi, AttentionDigestApi {
  var digestCalls = 0;

  @override
  Future<AttentionDigest> attentionDigest() async {
    digestCalls++;
    return const AttentionDigest(
      items: [
        AttentionDigestItem(
          chatId: 'c1',
          hostId: 'local',
          title: 'Chat',
          unreadMessages: 2,
        ),
      ],
    );
  }

  @override
  AgentStatus get status => AgentStatus.online;

  @override
  Stream<AgentStatus> get statusChanges => const Stream.empty();

  @override
  Stream<List<Chat>> watchChats() => const Stream.empty();

  @override
  Stream<List<Host>> watchHosts() => const Stream.empty();

  @override
  Stream<AgentEvent> get events => const Stream.empty();

  @override
  Stream<ApprovalRequest> get approvals => const Stream.empty();

  @override
  Stream<UserQuestion> get questions => const Stream.empty();

  @override
  Stream<EditFileChangesRequest> get editChanges => const Stream.empty();

  @override
  Set<String> get runningChatIds => const {};

  @override
  Set<String> get waitingChatIds => const {};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('AgentApi is not used in this test');
}
