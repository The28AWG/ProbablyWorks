import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:probably_works/agent/domain/project.dart';
import 'package:probably_works/agent/policy/security_profile.dart';
import 'package:probably_works/core/db/app_database.dart';

/// Именованные профили политики. Проект может ссылаться на профиль вместо глобального.
@lazySingleton
class PolicyProfileRepository {
  PolicyProfileRepository(this._db);

  final AppDatabase _db;

  $PolicyProfilesTable get _profiles => _db.policyProfiles;

  Stream<List<PolicyProfile>> watchAll() =>
      (_db.select(_profiles)..orderBy([(t) => OrderingTerm.asc(t.name)]))
          .watch()
          .map((rows) => rows.map(_profile).toList());

  Future<List<PolicyProfile>> all() async => (await (_db.select(
    _profiles,
  )..orderBy([(t) => OrderingTerm.asc(t.name)])).get()).map(_profile).toList();

  Future<PolicyProfile?> byId(String id) async {
    final row = await (_db.select(
      _profiles,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _profile(row);
  }

  Future<void> save(PolicyProfile profile) => _db
      .into(_profiles)
      .insertOnConflictUpdate(
        PolicyProfilesCompanion.insert(
          id: profile.id,
          name: profile.name,
          description: Value(profile.description),
          profileJson: profile.profile.encode(),
          createdAt: profile.createdAt,
          updatedAt: profile.updatedAt,
        ),
      );

  Future<void> delete(String id) =>
      (_db.delete(_profiles)..where((t) => t.id.equals(id))).go();

  PolicyProfile _profile(PolicyProfileRow row) => PolicyProfile(
    id: row.id,
    name: row.name,
    description: row.description,
    profile: SecurityProfile.decode(row.profileJson),
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );
}
