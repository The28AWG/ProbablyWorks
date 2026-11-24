// ignore_for_file: avoid-unused-parameters, no-empty-block, вне web вкладок нет
/// Обработчик закрытия web-вкладки.
typedef PageCloseCallback = Future<void> Function();

/// На платформах без вкладок закрытие окна завершает процесс, и отдельный
/// сигнал не нужен: сессию закроет `dispose` или TTL.
void listenForPageClose(PageCloseCallback callback) {}
