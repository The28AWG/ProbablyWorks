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
  }) => _service.save(settings, token: token, clearToken: clearToken);

  @override
  Future<void> testPush() => _service.test();
}
