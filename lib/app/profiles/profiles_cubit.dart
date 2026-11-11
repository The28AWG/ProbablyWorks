import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:probably_works/app/profiles/agent_profile.dart';
import 'package:probably_works/app/profiles/profile_service.dart';
import 'package:pw_agent/agent/api/agent_api.dart';

/// Список профилей и их статусы для rail и настроек. Активный профиль — в маршруте.
class ProfilesState extends Equatable {
  const ProfilesState({required this.profiles, required this.statuses});

  final List<AgentProfile> profiles;
  final Map<String, AgentStatus> statuses;

  @override
  List<Object?> get props => [profiles, statuses];
}

class ProfilesCubit extends Cubit<ProfilesState> {
  ProfilesCubit(this._service)
    : super(
        ProfilesState(
          profiles: _service.profiles,
          statuses: {
            for (final profile in _service.profiles)
              profile.id: _service.statusFor(profile),
          },
        ),
      ) {
    _serviceSub = _service.changes.listen((_) => _sync());
    _bindStatuses();
  }

  final ProfileService _service;
  late final StreamSubscription<void> _serviceSub;
  final _statusSubs = <String, StreamSubscription<AgentStatus>>{};

  Future<void> addRemote({
    required String name,
    required Uri baseUri,
    required String token,
  }) => _service.addRemote(name: name, baseUri: baseUri, token: token);

  Future<void> updateRemote(
    String id, {
    required String name,
    required Uri baseUri,
    String? token,
  }) => _service.updateRemote(id, name: name, baseUri: baseUri, token: token);

  Future<void> removeRemote(String id) => _service.removeRemote(id);

  void _sync() {
    emit(
      ProfilesState(
        profiles: _service.profiles,
        statuses: {
          for (final profile in _service.profiles)
            profile.id: _service.statusFor(profile),
        },
      ),
    );
    _bindStatuses();
  }

  void _bindStatuses() {
    for (final sub in _statusSubs.values) {
      unawaited(sub.cancel());
    }
    _statusSubs.clear();
    for (final profile in _service.profiles) {
      _statusSubs[profile.id] = _service
          .statusChangesFor(profile)
          .listen((status) => _setStatus(profile.id, status));
    }
  }

  void _setStatus(String id, AgentStatus status) {
    if (isClosed) return;
    emit(
      ProfilesState(
        profiles: state.profiles,
        statuses: {...state.statuses, id: status},
      ),
    );
  }

  @override
  Future<void> close() async {
    await _serviceSub.cancel();
    for (final sub in _statusSubs.values) {
      await sub.cancel();
    }
    return super.close();
  }
}
