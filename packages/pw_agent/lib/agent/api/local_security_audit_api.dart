import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/security_audit_api.dart';
import 'package:pw_agent/core/security/security_audit.dart';
import 'package:pw_agent/core/security/security_audit_service.dart';

/// Аудит внутри процесса агента: GUI для локального профиля и демон для
/// удалённых профилей.
@LazySingleton(as: SecurityAuditApi)
final class LocalSecurityAuditApi implements SecurityAuditApi {
  LocalSecurityAuditApi(this._service);

  final SecurityAuditService _service;

  @override
  Future<SecurityReport> run({SecurityRunMode mode = SecurityRunMode.gui}) =>
      _service.run(mode: mode);
}
