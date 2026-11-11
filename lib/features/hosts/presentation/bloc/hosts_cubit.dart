import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/virtual_host_provisioner.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/host/host_diagnostics.dart';

class HostsState extends Equatable {
  const HostsState({this.hosts = const [], this.testing = const {}});

  final List<Host> hosts;

  /// Id хостов, для которых идёт проверка подключения.
  final Set<String> testing;

  HostsState copyWith({List<Host>? hosts, Set<String>? testing}) =>
      HostsState(hosts: hosts ?? this.hosts, testing: testing ?? this.testing);

  @override
  List<Object?> get props => [hosts, testing];
}

class HostsCubit extends Cubit<HostsState> {
  HostsCubit(this._hosts, this._secrets, this._diagnostics, this._virtual)
    : super(const HostsState()) {
    _sub = _hosts.watchAll().listen(
      (hosts) => emit(state.copyWith(hosts: hosts)),
    );
  }

  final HostRepository _hosts;
  final SecretStore _secrets;
  final HostDiagnostics _diagnostics;
  final VirtualHostProvisioner _virtual;
  late final StreamSubscription<List<Host>> _sub;

  /// Сохраняет хост. Секреты (пароль, passphrase, PEM приватного ключа) уходят в secure storage, а не в БД.
  /// Пустой секрет при редактировании оставляет прежний.
  ///
  /// Виртуальный Host заполняет свою ФС после записи самого хоста: узлы ФС ссылаются на него внешним ключом.
  Future<void> save(Host host, {String? secret, String? privateKeyPem}) async {
    await _hosts.save(host);
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
  }

  Future<void> delete(String id) async {
    await _hosts.delete(id);
    await _secrets.delete(hostPasswordKey(id));
    await _secrets.delete(hostPassphraseKey(id));
    await _secrets.delete(hostPrivateKeyKey(id));
  }

  /// Проверка подключения (см. HostDiagnostics): результат сохраняется в Host и показывается в списке.
  Future<void> test(Host host) async {
    emit(state.copyWith(testing: {...state.testing, host.id}));
    await _diagnostics.test(host);
    emit(state.copyWith(testing: {...state.testing}..remove(host.id)));
  }

  @override
  Future<void> close() async {
    await _sub.cancel();
    return super.close();
  }
}
