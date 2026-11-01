import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';

void main() {
  final now = DateTime(2026, 11, 1);

  Chat chat(String id, String hostId) => Chat(
    id: id,
    hostId: hostId,
    title: id,
    createdAt: now,
    updatedAt: now,
    policyMode: PolicyMode.ask,
  );

  test('host filter narrows the visible chats and null shows all', () {
    final state = ChatListState(
      chats: [chat('a', 'local'), chat('b', 'srv'), chat('c', 'local')],
    );

    expect([for (final c in state.visibleChats) c.id], ['a', 'b', 'c']);
    expect(
      [for (final c in state.copyWith(hostFilter: 'local').visibleChats) c.id],
      ['a', 'c'],
    );
    expect(
      [
        for (final c
            in state
                .copyWith(hostFilter: 'srv', clearHostFilter: false)
                .visibleChats)
          c.id,
      ],
      ['b'],
    );
    expect(
      state
          .copyWith(hostFilter: 'srv')
          .copyWith(clearHostFilter: true)
          .hostFilter,
      isNull,
    );
  });
}
