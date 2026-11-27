import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';

/// Переносит общее непрочитанное из [ChatListCubit] на поверхности платформы.
///
/// Число приходит с сервера, поэтому окна не считают его сами: прочтение на
/// телефоне уменьшает бейдж на десктопе и на вкладке браузера. Синхронизация
/// живёт в оболочке, а не в каждом экране: бейдж должен обновляться и когда
/// открыт раздел настроек, и когда чат свернут.
class UnreadBadgeSync extends StatefulWidget {
  const UnreadBadgeSync({required this.child, super.key});

  final Widget child;

  @override
  State<UnreadBadgeSync> createState() => _UnreadBadgeSyncState();
}

class _UnreadBadgeSyncState extends State<UnreadBadgeSync> {
  @override
  void initState() {
    super.initState();
    // `BlocListener` не вызывает слушателя для начального состояния, а после
    // перезапуска приложения бейдж мог остаться с прошлого запуска. Поэтому
    // применяем снимок сразу, ещё до первого события.
    _apply(context.read<ChatListCubit>().state.unreadCount);
  }

  @override
  Widget build(BuildContext context) =>
      BlocListener<ChatListCubit, ChatListState>(
        listenWhen: (previous, next) =>
            previous.unreadCount != next.unreadCount,
        listener: (context, state) => _apply(state.unreadCount),
        child: widget.child,
      );

  /// Ошибка бейджа не должна ломать оболочку: число — подсказка, а не данные.
  ///
  /// Ошибку гасим здесь, а не только внутри реализации: у web-бейджа отказ
  /// приходит отклонённым промисом, и без обработчика он всплыл бы как
  /// необработанная асинхронная ошибка.
  void _apply(int count) {
    unawaited(_setUnreadCount(count));
  }

  Future<void> _setUnreadCount(int count) async {
    try {
      await getIt<AppNotifier>().setUnreadCount(count);
    } on Object {
      // Бейдж — подсказка, а не данные: сбой платформы не ломает оболочку.
    }
  }
}
