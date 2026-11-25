import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/push_api.dart';
import 'package:pw_agent/core/notify/push_service.dart';

/// Настройки push-уведомлений внутри процесса агента.
@LazySingleton(as: PushApi)
final class LocalPushApi implements PushApi {
  LocalPushApi(this._service);

  final PushService _service;

  @override
  Future<PushSettings> pushSettings() => _service.load();

  @override
  Future<void> savePush(
    PushSettings settings, {
    String? token,
    bool clearToken = false,
    int? expectedRevision,
  }) => _service.save(
    settings,
    token: token,
    clearToken: clearToken,
    expectedRevision: expectedRevision,
  );

  @override
  Future<void> testPush() => _service.test();
}
