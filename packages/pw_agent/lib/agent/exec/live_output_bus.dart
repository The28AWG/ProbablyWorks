import 'dart:async';

import 'package:injectable/injectable.dart';

/// Живой вывод команд для UI. Не хранит историю: подписчик видит только новые чанки.
/// Троттлинг отрисовки — на стороне ChatBloc, здесь только маршрутизация.
@singleton
class LiveOutputBus {
  final StreamController<LiveChunk> _controller =
      StreamController<LiveChunk>.broadcast();

  Stream<LiveChunk> get stream => _controller.stream;

  void publish(String toolCallId, String chatId, String text) {
    if (text.isEmpty || _controller.isClosed) return;
    _controller.add(
      LiveChunk(toolCallId: toolCallId, chatId: chatId, text: text),
    );
  }
}

class LiveChunk {
  const LiveChunk({
    required this.toolCallId,
    required this.chatId,
    required this.text,
  });

  final String toolCallId;
  final String chatId;
  final String text;
}
