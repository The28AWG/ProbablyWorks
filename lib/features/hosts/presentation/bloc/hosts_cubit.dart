import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pw_agent/agent/api/hosts_api.dart';
import 'package:pw_agent/core/domain/host.dart';

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
  HostsCubit(this._api) : super(const HostsState()) {
    _sub = _api.watchHosts().listen(
      (hosts) => emit(state.copyWith(hosts: hosts)),
    );
  }

  final HostsApi _api;
  late final StreamSubscription<List<Host>> _sub;

  /// Сохраняет хост. Секреты (пароль, passphrase, PEM приватного ключа) уходят в secure storage, а не в БД.
  /// Пустой секрет при редактировании оставляет прежний.
  ///
  /// Виртуальный Host заполняет свою ФС после записи самого хоста: узлы ФС ссылаются на него внешним ключом.
  Future<void> save(Host host, {String? secret, String? privateKeyPem}) =>
      _api.saveHost(host, secret: secret, privateKeyPem: privateKeyPem);

  Future<void> delete(String id) => _api.deleteHost(id);

  /// Проверка подключения (см. HostDiagnostics): результат сохраняется в Host и показывается в списке.
  Future<void> test(Host host) async {
    emit(state.copyWith(testing: {...state.testing, host.id}));
    await _api.testHost(host);
    emit(state.copyWith(testing: {...state.testing}..remove(host.id)));
  }

  @override
  Future<void> close() async {
    await _sub.cancel();
    return super.close();
  }
}
