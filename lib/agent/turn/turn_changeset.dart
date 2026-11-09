import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:probably_works/agent/turn/turn_file_kind.dart';

/// Изменение одного пути в ходе агента (от пользовательского сообщения до ответа).
final class TurnFileChange extends Equatable {
  const TurnFileChange({
    required this.path,
    required this.kind,
    this.backupName,
  });

  factory TurnFileChange.fromJson(Map<String, dynamic> json) => TurnFileChange(
    path: json['path'] as String,
    kind: TurnFileKind.values.byName(json['kind'] as String),
    backupName: json['backupName'] as String?,
  );

  final String path;
  final TurnFileKind kind;

  /// Имя файла в `backups/` каталога хода. Null только у [TurnFileKind.created]
  /// до первой записи; после записи снимок не нужен, откат — удаление.
  final String? backupName;

  TurnFileChange copyWith({
    String? path,
    TurnFileKind? kind,
    String? backupName,
    bool clearBackupName = false,
  }) => TurnFileChange(
    path: path ?? this.path,
    kind: kind ?? this.kind,
    backupName: clearBackupName ? null : (backupName ?? this.backupName),
  );

  Map<String, dynamic> toJson() => {
    'path': path,
    'kind': kind.name,
    if (backupName != null) 'backupName': backupName,
  };

  @override
  List<Object?> get props => [path, kind, backupName];
}

/// Снимок изменений файлов одного хода агента.
final class TurnChangeset extends Equatable {
  const TurnChangeset({
    required this.chatId,
    required this.turnId,
    this.files = const {},
    this.nonRecoverable = false,
    this.shellMutationToolRunIds = const [],
    this.rolledBack = false,
    required this.updatedAt,
  });

  factory TurnChangeset.fromJson(Map<String, dynamic> json) {
    final rawFiles = json['files'] as List<dynamic>? ?? const [];
    final files = <String, TurnFileChange>{};
    for (final item in rawFiles) {
      final change = TurnFileChange.fromJson(item as Map<String, dynamic>);
      files[change.path] = change;
    }
    return TurnChangeset(
      chatId: json['chatId'] as String,
      turnId: json['turnId'] as String,
      files: files,
      nonRecoverable: json['nonRecoverable'] as bool? ?? false,
      shellMutationToolRunIds: [
        for (final id in json['shellMutationToolRunIds'] as List? ?? const [])
          id as String,
      ],
      rolledBack: json['rolledBack'] as bool? ?? false,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  factory TurnChangeset.fromEncoded(String raw) =>
      TurnChangeset.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  final String chatId;

  /// Id пользовательского сообщения, которым начался ход.
  final String turnId;
  final Map<String, TurnFileChange> files;
  final bool nonRecoverable;
  final List<String> shellMutationToolRunIds;
  final bool rolledBack;
  final DateTime updatedAt;

  bool get isEmpty => files.isEmpty && !nonRecoverable;

  /// Откат файлов write_file/edit_file возможен, даже если shell помечен частично.
  bool get canRollback => !rolledBack && files.isNotEmpty;

  TurnChangeset copyWith({
    String? chatId,
    String? turnId,
    Map<String, TurnFileChange>? files,
    bool? nonRecoverable,
    List<String>? shellMutationToolRunIds,
    bool? rolledBack,
    DateTime? updatedAt,
  }) => TurnChangeset(
    chatId: chatId ?? this.chatId,
    turnId: turnId ?? this.turnId,
    files: files ?? this.files,
    nonRecoverable: nonRecoverable ?? this.nonRecoverable,
    shellMutationToolRunIds:
        shellMutationToolRunIds ?? this.shellMutationToolRunIds,
    rolledBack: rolledBack ?? this.rolledBack,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'chatId': chatId,
    'turnId': turnId,
    'files': [for (final f in files.values) f.toJson()],
    'nonRecoverable': nonRecoverable,
    'shellMutationToolRunIds': shellMutationToolRunIds,
    'rolledBack': rolledBack,
    'updatedAt': updatedAt.toIso8601String(),
  };

  String encode() => jsonEncode(toJson());

  @override
  List<Object?> get props => [
    chatId,
    turnId,
    files,
    nonRecoverable,
    shellMutationToolRunIds,
    rolledBack,
    updatedAt,
  ];
}
