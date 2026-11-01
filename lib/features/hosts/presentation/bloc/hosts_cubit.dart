import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/host/host_capture.dart';
import 'package:probably_works/host/host_runtime_factory.dart';
import 'package:probably_works/host/shell_adapter.dart';

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
  HostsCubit(this._hosts, this._secrets, this._runtimes)
    : super(const HostsState()) {
    _sub = _hosts.watchAll().listen(
      (hosts) => emit(state.copyWith(hosts: hosts)),
    );
  }

  final HostRepository _hosts;
  final SecretStore _secrets;
  final HostRuntimeFactory _runtimes;
  late final StreamSubscription<List<Host>> _sub;

  /// Сохраняет хост. Секрет (пароль или passphrase) уходит в secure storage, а не в БД.
  /// Пустой секрет при редактировании оставляет прежний.
  Future<void> save(Host host, {String? secret}) async {
    await _hosts.save(host);
    if (secret != null && secret.isNotEmpty) {
      final key = host.authType == SshAuthType.password
          ? hostPasswordKey(host.id)
          : hostPassphraseKey(host.id);
      await _secrets.write(key, secret);
    }
  }

  Future<void> delete(String id) async {
    await _hosts.delete(id);
    await _secrets.delete(hostPasswordKey(id));
    await _secrets.delete(hostPassphraseKey(id));
  }

  /// Проверка подключения: безопасная команда host_info, без изменения состояния Host.
  /// Результат (время, задержка или ошибка) сохраняется в Host и показывается в списке.
  Future<void> test(Host host) async {
    emit(state.copyWith(testing: {...state.testing, host.id}));
    final clock = Stopwatch()..start();
    String? error;
    try {
      final run = await captureRun(
        _runtimes.forHost(host),
        ShellAdapter(host.os).hostInfo(),
        timeout: const Duration(seconds: 30),
      );
      if (!run.ok) {
        error = run.stderr.trim().isEmpty
            ? 'exit ${run.exitCode}'
            : run.stderr.trim();
      }
    } on Object catch (caught) {
      error = '$caught';
    }
    clock.stop();
    await _hosts.recordCheck(
      host.id,
      at: DateTime.now(),
      latencyMs: error == null ? clock.elapsedMilliseconds : null,
      error: error,
    );
    emit(state.copyWith(testing: {...state.testing}..remove(host.id)));
  }

  @override
  Future<void> close() async {
    await _sub.cancel();
    return super.close();
  }
}
