import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/hosts_api.dart';
import 'package:pw_agent/agent/state/domain_change_bus.dart';
import 'package:pw_agent/agent/state/shared_state.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/virtual_host_provisioner.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/host/host_diagnostics.dart';

/// Локальные хосты: БД, secure storage, виртуальная ФС и проверка соединения.
@LazySingleton(as: HostsApi)
final class LocalHostsApi implements HostsApi {
  LocalHostsApi(
    this._hosts,
    this._secrets,
    this._diagnostics,
    this._virtual, [
    this._changes,
  ]);

  final HostRepository _hosts;
  final SecretStore _secrets;
  final HostDiagnostics _diagnostics;
  final VirtualHostProvisioner _virtual;
  final DomainChangeBus? _changes;

  @override
  Future<List<Host>> hosts() => _hosts.all();

  @override
  Stream<List<Host>> watchHosts() => _hosts.watchAll();

  @override
  Future<void> saveHost(
    Host host, {
    String? secret,
    String? privateKeyPem,
    Map<String, String>? environment,
    int? expectedRevision,
  }) async {
    await _hosts.save(
      environment == null ? host : host.copyWith(environment: environment),
      expectedRevision: expectedRevision,
    );
    if (host.kind == HostKind.virtual) await _virtual.provision(host);
    if (secret != null && secret.isNotEmpty) {
      final key = host.authType == SshAuthType.password
          ? hostPasswordKey(host.id)
          : hostPassphraseKey(host.id);
      await _secrets.write(key, secret);
    }
    if (privateKeyPem != null && privateKeyPem.isNotEmpty) {
      await _secrets.write(hostPrivateKeyKey(host.id), privateKeyPem);
    }
    _changes?.publish(SharedResource.hosts);
  }

  @override
  Future<void> deleteHost(String id) async {
    await _hosts.delete(id);
    await _secrets.delete(hostPasswordKey(id));
    await _secrets.delete(hostPassphraseKey(id));
    await _secrets.delete(hostPrivateKeyKey(id));
    _changes?.publish(SharedResource.hosts);
  }

  @override
  Future<void> testHost(Host host) async {
    await _diagnostics.test(host);
    // Результат проверки сохраняется в хосте: список в других окнах должен
    // показать новую задержку или ошибку, а не жить до ручного обновления.
    _changes?.publish(SharedResource.hosts);
  }
}
