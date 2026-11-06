// Сценарии git_core на виртуальной ФС. Сокет, процесс и SSH сюда не входят.
// ignore_for_file: avoid-substring, avoid-top-level-members-in-tests, cascade_invocations, prefer_expression_function_bodies, omit_local_variable_types, always_declare_return_types, prefer_single_quotes, require_trailing_commas, avoid_types_on_closure_parameters, prefer-first, binary-expression-operand-order, avoid-redundant-async, avoid-unused-parameters
// Причина: порт сценариев референса, помощники и стиль оставлены близко к тексту.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:virtual_git/src/git_host_io.dart'
    hide GitHttp, GitHttpResponse, HttpStatus, PackageGitHttp, gitHttpBodyText;
import 'package:virtual_git/src/git_path.dart' as p;
import 'package:virtual_git/virtual_git.dart';
import 'package:virtual_host/virtual_host.dart';

void main() {
  setUp(() {
    bindGitIo(
      VirtualFs(
        InMemoryVfsStore(),
        limits: const VirtualLimits(
          quotaBytes: 256 * 1024 * 1024,
          maxFileBytes: 32 * 1024 * 1024,
        ),
      ),
    );
    _gitRoutes.clear();
    _gitHttpSerial = 0;
  });
  tearDown(clearGitIo);

  group('GitObjectId', () {
    test('accepts SHA-1 values', () {
      final objectId = GitObjectId.fromHex(
        '0123456789abcdef0123456789abcdef01234567',
      );

      expect(objectId.isSha1, isTrue);
      expect(objectId.isSha256, isFalse);
    });

    test('accepts SHA-256 values', () {
      final objectId = GitObjectId.fromHex(
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );

      expect(objectId.isSha1, isFalse);
      expect(objectId.isSha256, isTrue);
    });

    test('rejects malformed values', () {
      expect(
        () => GitObjectId.fromHex('not-a-valid-oid'),
        throwsFormatException,
      );
    });

    test('computes SHA-1 ids from loose object bytes', () {
      final object = GitObject.blob('hello'.codeUnits);

      expect(object.id().hex, 'b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0');
    });

    test('computes SHA-256 ids from loose object bytes', () {
      final object = GitObject.blob('hello'.codeUnits);

      expect(
        object.id(algorithm: GitHashAlgorithm.sha256).hex,
        '8aec4e4876f854f688d0ebfc8f37598f38e5fd6903cccc850ca36591175aeb60',
      );
    });

    test('round-trips raw digest bytes', () {
      final objectId = GitObjectId.fromHex(
        '0123456789abcdef0123456789abcdef01234567',
      );

      expect(GitObjectId.fromBytes(objectId.toBytes()), objectId);
    });
  });

  group('GitLooseObjectCodec', () {
    test('encodes a loose object header and payload', () {
      final object = GitObject.blob('hello'.codeUnits);
      final encoded = const GitLooseObjectCodec().encode(object);

      expect(
        encoded,
        orderedEquals(
          Uint8List.fromList([...'blob 5'.codeUnits, 0, ...'hello'.codeUnits]),
        ),
      );
    });

    test('decodes a loose object header and payload', () {
      final decoded = const GitLooseObjectCodec().decode([
        ...'commit 11'.codeUnits,
        0,
        ...'hello world'.codeUnits,
      ]);

      expect(decoded.type, GitObjectType.commit);
      expect(decoded.size, 11);
      expect(decoded.bytes, orderedEquals('hello world'.codeUnits));
    });

    test('rejects malformed headers', () {
      expect(
        () => const GitLooseObjectCodec().decode('blob 5hello'.codeUnits),
        throwsFormatException,
      );
    });

    test('rejects size mismatches', () {
      expect(
        () => const GitLooseObjectCodec().decode([
          ...'blob 3'.codeUnits,
          0,
          ...'hello'.codeUnits,
        ]),
        throwsFormatException,
      );
    });
  });

  group('GitTreeCodec', () {
    test('encodes and decodes tree entries', () {
      final entry = GitTreeEntry.utf8(
        mode: '100644',
        name: 'README.md',
        objectId: GitObjectId.fromHex(
          '0123456789abcdef0123456789abcdef01234567',
        ),
      );

      final encoded = const GitTreeCodec().encode([entry]);
      final decoded = const GitTreeCodec().decode(encoded);

      expect(decoded, hasLength(1));
      expect(decoded.first.mode, '100644');
      expect(decoded.first.utf8Name, 'README.md');
      expect(decoded.first.objectId, entry.objectId);
    });

    test('decodes sha256 tree entries when requested', () {
      final entry = GitTreeEntry.utf8(
        mode: '100644',
        name: 'hello.txt',
        objectId: GitObjectId.fromHex(
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        ),
      );

      final codec = const GitTreeCodec(algorithm: GitHashAlgorithm.sha256);
      final decoded = codec.decode(codec.encode([entry]));

      expect(decoded.single.objectId, entry.objectId);
    });
  });

  group('GitCommitCodec', () {
    test('decodes a commit object', () {
      final decoded = const GitCommitCodec().decode(
        utf8.encode(
          'tree 0123456789abcdef0123456789abcdef01234567\n'
          'parent 89abcdef0123456789abcdef0123456789abcdef\n'
          'author Alice Example <alice@example.com> 1700000000 +0900\n'
          'committer Bob Example <bob@example.com> 1700000001 +0900\n'
          '\n'
          'Initial commit\n',
        ),
      );

      expect(
        decoded.tree,
        GitObjectId.fromHex('0123456789abcdef0123456789abcdef01234567'),
      );
      expect(decoded.parents, [
        GitObjectId.fromHex('89abcdef0123456789abcdef0123456789abcdef'),
      ]);
      expect(decoded.author.name, 'Alice Example');
      expect(decoded.committer.email, 'bob@example.com');
      expect(decoded.message, 'Initial commit\n');
    });

    test('encodes and decodes extra multi-line headers', () {
      final commit = GitCommit(
        tree: GitObjectId.fromHex('0123456789abcdef0123456789abcdef01234567'),
        parents: const [],
        author: const GitCommitSignature(
          name: 'Alice Example',
          email: 'alice@example.com',
          timestampSeconds: 1700000000,
          timezoneOffset: '+0900',
        ),
        committer: const GitCommitSignature(
          name: 'Bob Example',
          email: 'bob@example.com',
          timestampSeconds: 1700000001,
          timezoneOffset: '+0900',
        ),
        message: 'hello\n',
        extraHeaders: const [
          GitCommitHeader('encoding', 'UTF-8'),
          GitCommitHeader('gpgsig', 'line1\nline2'),
        ],
      );

      final decoded = const GitCommitCodec().decode(
        const GitCommitCodec().encode(commit),
      );

      expect(decoded.tree, commit.tree);
      expect(decoded.author.email, commit.author.email);
      expect(decoded.extraHeaders, hasLength(2));
      expect(decoded.extraHeaders.first.name, 'encoding');
      expect(decoded.extraHeaders.first.value, 'UTF-8');
      expect(decoded.extraHeaders.last.name, 'gpgsig');
      expect(decoded.extraHeaders.last.value, 'line1\nline2');
      expect(decoded.message, 'hello\n');
    });
  });

  group('GitCommitSignature', () {
    test('builds signatures from DateTime instances', () {
      final timestamp = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final signature = GitCommitSignature.fromDateTime(
        name: 'Alice Example',
        email: 'alice@example.com',
        timestamp: timestamp,
      );

      expect(signature.name, 'Alice Example');
      expect(signature.email, 'alice@example.com');
      expect(signature.timestampSeconds, 1700000000);
      expect(signature.timezoneOffset, matches(RegExp(r'^[+-]\d{4}$')));
    });

    test('supports copyWith date overrides', () {
      const signature = GitCommitSignature(
        name: 'Alice Example',
        email: 'alice@example.com',
        timestampSeconds: 1700000000,
        timezoneOffset: '+0900',
      );

      final updated = signature.copyWith(
        name: 'Bob Example',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1700000100000),
      );

      expect(updated.name, 'Bob Example');
      expect(updated.email, 'alice@example.com');
      expect(updated.timestampSeconds, 1700000100);
      expect(updated.timezoneOffset, matches(RegExp(r'^[+-]\d{4}$')));
      expect(signature.name, 'Alice Example');
      expect(
        () => signature.copyWith(
          timestamp: DateTime.fromMillisecondsSinceEpoch(1700000200000),
          timestampSeconds: 1700000200,
        ),
        throwsArgumentError,
      );
    });
  });

  group('GitDeltaCodec', () {
    test('encodes and decodes delta instructions', () {
      final delta = GitDelta(
        baseSize: 5,
        resultSize: 11,
        instructions: [
          const GitDeltaCopyInstruction(offset: 0, size: 5),
          GitDeltaInsertInstruction(' world'.codeUnits),
        ],
      );

      final codec = const GitDeltaCodec();
      final decoded = codec.decode(codec.encode(delta));

      expect(decoded.baseSize, 5);
      expect(decoded.resultSize, 11);
      expect(decoded.instructions, hasLength(2));
      expect(decoded.instructions.first, isA<GitDeltaCopyInstruction>());
      expect(decoded.instructions.last, isA<GitDeltaInsertInstruction>());
    });

    test('applies delta instructions to reconstruct an object', () {
      final deltaBytes = const GitDeltaCodec().encode(
        GitDelta(
          baseSize: 5,
          resultSize: 11,
          instructions: [
            const GitDeltaCopyInstruction(offset: 0, size: 5),
            GitDeltaInsertInstruction(' world'.codeUnits),
          ],
        ),
      );

      final restored = const GitDeltaCodec().apply(
        'hello'.codeUnits,
        deltaBytes,
      );

      expect(restored, orderedEquals('hello world'.codeUnits));
    });
  });

  group('GitRefSpec', () {
    test('parses force-updating fetch refspecs', () {
      final refSpec = GitRefSpec.parse('+refs/heads/*:refs/remotes/origin/*');

      expect(refSpec.force, isTrue);
      expect(refSpec.source, 'refs/heads/*');
      expect(refSpec.destination, 'refs/remotes/origin/*');
      expect(refSpec.storageValue, '+refs/heads/*:refs/remotes/origin/*');
    });

    test('parses source-only refspecs', () {
      final refSpec = GitRefSpec.parse('refs/tags/v1.0');

      expect(refSpec.force, isFalse);
      expect(refSpec.source, 'refs/tags/v1.0');
      expect(refSpec.destination, isNull);
      expect(refSpec.storageValue, 'refs/tags/v1.0');
    });

    test('parses delete refspecs', () {
      final refSpec = GitRefSpec.parse(':refs/heads/feature');

      expect(refSpec.force, isFalse);
      expect(refSpec.source, isNull);
      expect(refSpec.destination, 'refs/heads/feature');
      expect(refSpec.storageValue, ':refs/heads/feature');
    });
  });

  group('GitDiffCodec', () {
    test('encodes and decodes unified diff entries', () {
      final entries = [
        GitDiffEntry(
          path: 'README.md',
          changeType: GitDiffChangeType.modified,
          oldMode: '100644',
          newMode: '100644',
          oldObjectId: GitObjectId.fromHex(
            '0123456789abcdef0123456789abcdef01234567',
          ),
          newObjectId: GitObjectId.fromHex(
            '89abcdef0123456789abcdef0123456789abcdef',
          ),
          hunks: const [
            GitDiffHunk(
              oldStart: 1,
              oldLineCount: 1,
              newStart: 1,
              newLineCount: 2,
              lines: [
                GitDiffLine(type: GitDiffLineType.context, text: 'hello\n'),
                GitDiffLine(type: GitDiffLineType.addition, text: 'world\n'),
              ],
            ),
          ],
        ),
        GitDiffEntry(
          path: 'notes.txt',
          changeType: GitDiffChangeType.added,
          newMode: '100644',
          newObjectId: GitObjectId.fromHex(
            '1111111111111111111111111111111111111111',
          ),
          hunks: const [
            GitDiffHunk(
              oldStart: 1,
              oldLineCount: 0,
              newStart: 1,
              newLineCount: 1,
              lines: [
                GitDiffLine(type: GitDiffLineType.addition, text: 'new\n'),
              ],
            ),
          ],
        ),
      ];

      final codec = const GitDiffCodec();
      final decoded = codec.decode(codec.encode(entries));

      expect(decoded, hasLength(2));
      expect(decoded.first.path, 'README.md');
      expect(decoded.first.changeType, GitDiffChangeType.modified);
      expect(decoded.first.oldMode, '100644');
      expect(decoded.first.newMode, '100644');
      expect(decoded.first.oldObjectId, entries.first.oldObjectId);
      expect(decoded.first.newObjectId, entries.first.newObjectId);
      expect(
        decoded.first.hunks.single.lines.map((line) => (line.type, line.text)),
        orderedEquals([
          (GitDiffLineType.context, 'hello\n'),
          (GitDiffLineType.addition, 'world\n'),
        ]),
      );
      expect(decoded.last.path, 'notes.txt');
      expect(decoded.last.changeType, GitDiffChangeType.added);
      expect(decoded.last.oldMode, isNull);
      expect(decoded.last.newMode, '100644');
      expect(
        decoded.last.hunks.single.lines.map((line) => (line.type, line.text)),
        orderedEquals([(GitDiffLineType.addition, 'new\n')]),
      );
    });
  });

  group('GitReflogCodec', () {
    test('encodes and decodes reflog entries', () {
      final entries = [
        GitReflogEntry(
          newObjectId: GitObjectId.fromHex(
            '0123456789abcdef0123456789abcdef01234567',
          ),
          actor: const GitCommitSignature(
            name: 'Alice Example',
            email: 'alice@example.com',
            timestampSeconds: 1700000000,
            timezoneOffset: '+0900',
          ),
          message: 'commit (initial): Initial commit',
        ),
        GitReflogEntry(
          previousObjectId: GitObjectId.fromHex(
            '0123456789abcdef0123456789abcdef01234567',
          ),
          newObjectId: GitObjectId.fromHex(
            '89abcdef0123456789abcdef0123456789abcdef',
          ),
          actor: const GitCommitSignature(
            name: 'Bob Example',
            email: 'bob@example.com',
            timestampSeconds: 1700000100,
            timezoneOffset: '+0900',
          ),
          message: 'reset: moving to HEAD^',
        ),
      ];

      final codec = const GitReflogCodec();
      final decoded = codec.decode(codec.encode(entries));

      expect(decoded, hasLength(2));
      expect(decoded.first.previousObjectId, isNull);
      expect(decoded.first.newObjectId, entries.first.newObjectId);
      expect(decoded.first.actor.name, 'Alice Example');
      expect(decoded.first.message, 'commit (initial): Initial commit');
      expect(decoded.last.previousObjectId, entries.last.previousObjectId);
      expect(decoded.last.newObjectId, entries.last.newObjectId);
      expect(decoded.last.actor.email, 'bob@example.com');
      expect(decoded.last.message, 'reset: moving to HEAD^');
    });
  });

  group('GitTagCodec', () {
    test('encodes and decodes annotated tag objects', () {
      final tag = GitTagObject(
        targetObjectId: GitObjectId.fromHex(
          '0123456789abcdef0123456789abcdef01234567',
        ),
        targetType: GitObjectType.commit,
        name: 'v1.0.0',
        tagger: const GitCommitSignature(
          name: 'Alice Example',
          email: 'alice@example.com',
          timestampSeconds: 1700000000,
          timezoneOffset: '+0900',
        ),
        message: 'Release 1.0',
      );

      final decoded = const GitTagCodec().decode(
        const GitTagCodec().encode(tag),
      );

      expect(decoded.targetObjectId, tag.targetObjectId);
      expect(decoded.targetType, GitObjectType.commit);
      expect(decoded.name, 'v1.0.0');
      expect(decoded.tagger.email, 'alice@example.com');
      expect(decoded.message, 'Release 1.0');
    });
  });

  group('GitIndexCodec', () {
    test('encodes and decodes a version 2 index with extensions', () {
      final index = GitIndex(
        entries: [
          GitIndexEntry(
            ctimeSeconds: 1700000000,
            ctimeNanoseconds: 123,
            mtimeSeconds: 1700000001,
            mtimeNanoseconds: 456,
            device: 1,
            inode: 2,
            mode: 0x81a4,
            userId: 501,
            groupId: 20,
            fileSize: 128,
            objectId: GitObjectId.fromHex(
              '0123456789abcdef0123456789abcdef01234567',
            ),
            path: 'README.md',
          ),
          GitIndexEntry(
            ctimeSeconds: 1700000002,
            ctimeNanoseconds: 789,
            mtimeSeconds: 1700000003,
            mtimeNanoseconds: 321,
            device: 3,
            inode: 4,
            mode: 0x81ed,
            userId: 501,
            groupId: 20,
            fileSize: 256,
            objectId: GitObjectId.fromHex(
              '89abcdef0123456789abcdef0123456789abcdef',
            ),
            path: 'lib/main.dart',
          ),
        ],
        extensions: [
          GitIndexExtension(signature: 'TREE', data: [1, 2, 3]),
        ],
      );

      final decoded = const GitIndexCodec().decode(
        const GitIndexCodec().encode(index),
      );

      expect(decoded.version, 2);
      expect(decoded.checksumAlgorithm, GitHashAlgorithm.sha1);
      expect(decoded.objectCount, 2);
      expect(decoded.checksum, isNotNull);
      expect(decoded.entryForPath('README.md'), isNotNull);
      expect(decoded.entryForPath('lib/main.dart')!.mode, 0x81ed);
      expect(decoded.extensions, hasLength(1));
      expect(decoded.extensions.single.signature, 'TREE');
      expect(decoded.extensions.single.data, orderedEquals([1, 2, 3]));
    });

    test('supports version 3 extended entry flags with sha256 object ids', () {
      final index = GitIndex(
        version: 3,
        checksumAlgorithm: GitHashAlgorithm.sha256,
        entries: [
          GitIndexEntry(
            ctimeSeconds: 1700000000,
            ctimeNanoseconds: 1,
            mtimeSeconds: 1700000001,
            mtimeNanoseconds: 2,
            device: 5,
            inode: 6,
            mode: 0x81a4,
            userId: 1000,
            groupId: 1000,
            fileSize: 12,
            objectId: GitObjectId.fromHex(
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
            ),
            path: 'lib/src/git_index.dart',
            skipWorktree: true,
            intentToAdd: true,
          ),
        ],
      );

      final codec = const GitIndexCodec(
        checksumAlgorithm: GitHashAlgorithm.sha256,
      );
      final decoded = codec.decode(codec.encode(index));

      expect(decoded.version, 3);
      expect(decoded.checksumAlgorithm, GitHashAlgorithm.sha256);
      expect(decoded.checksum!.isSha256, isTrue);
      expect(decoded.entries.single.skipWorktree, isTrue);
      expect(decoded.entries.single.intentToAdd, isTrue);
      expect(decoded.entries.single.objectId.isSha256, isTrue);
    });
  });

  group('GitPackCodec', () {
    test('encodes and decodes a pack with non-delta objects', () {
      final pack = GitPack(
        entries: [
          GitPackObjectEntry(GitObject.blob('hello'.codeUnits)),
          GitPackObjectEntry(
            GitObject.commit('tree deadbeef\n\nmsg\n'.codeUnits),
          ),
        ],
      );

      final encoded = const GitPackCodec().encode(pack);
      final decoded = const GitPackCodec().decode(encoded);

      expect(decoded.version, 2);
      expect(decoded.checksumAlgorithm, GitHashAlgorithm.sha1);
      expect(decoded.checksum, isNotNull);
      expect(decoded.entries, hasLength(2));
      expect(decoded.entries.first.offset, 12);
      expect(decoded.entries.last.offset, greaterThan(12));
      expect(
        (decoded.entries.first as GitPackObjectEntry).object.bytes,
        orderedEquals('hello'.codeUnits),
      );
      expect(
        (decoded.entries.last as GitPackObjectEntry).object.type,
        GitObjectType.commit,
      );
    });

    test('encodes and decodes delta pack entries', () {
      final deltaBytes = const GitDeltaCodec().encode(
        GitDelta(
          baseSize: 5,
          resultSize: 11,
          instructions: [
            const GitDeltaCopyInstruction(offset: 0, size: 5),
            GitDeltaInsertInstruction(' world'.codeUnits),
          ],
        ),
      );

      final pack = GitPack(
        entries: [
          GitPackOffsetDeltaEntry(
            baseOffsetDistance: 12,
            deltaBytes: deltaBytes,
            objectSize: 11,
          ),
          GitPackReferenceDeltaEntry(
            baseObjectId: GitObjectId.fromHex(
              '0123456789abcdef0123456789abcdef01234567',
            ),
            deltaBytes: deltaBytes,
            objectSize: 11,
          ),
        ],
      );

      final decoded = const GitPackCodec().decode(
        const GitPackCodec().encode(pack),
      );

      expect(decoded.entries, hasLength(2));

      final offsetDelta = decoded.entries.first as GitPackOffsetDeltaEntry;
      expect(offsetDelta.baseOffsetDistance, 12);
      expect(offsetDelta.deltaBytes, orderedEquals(deltaBytes));
      expect(
        const GitDeltaCodec().apply('hello'.codeUnits, offsetDelta.deltaBytes),
        orderedEquals('hello world'.codeUnits),
      );

      final referenceDelta = decoded.entries.last as GitPackReferenceDeltaEntry;
      expect(
        referenceDelta.baseObjectId,
        GitObjectId.fromHex('0123456789abcdef0123456789abcdef01234567'),
      );
      expect(referenceDelta.deltaBytes, orderedEquals(deltaBytes));
    });

    test('supports sha256 pack checksums', () {
      final pack = GitPack(
        checksumAlgorithm: GitHashAlgorithm.sha256,
        entries: [GitPackObjectEntry(GitObject.blob('hello'.codeUnits))],
      );

      final decoded =
          const GitPackCodec(checksumAlgorithm: GitHashAlgorithm.sha256).decode(
            const GitPackCodec(checksumAlgorithm: GitHashAlgorithm.sha256)
                .encode(pack),
          );

      expect(decoded.checksumAlgorithm, GitHashAlgorithm.sha256);
      expect(decoded.checksum!.isSha256, isTrue);
    });
  });

  group('GitPackIndexCodec', () {
    test('builds and round-trips an index for a pack file', () {
      final blob = GitObject.blob('hello'.codeUnits);
      final commit = GitObject.commit('tree deadbeef\n\nmsg\n'.codeUnits);
      final pack = GitPack(
        entries: [GitPackObjectEntry(blob), GitPackObjectEntry(commit)],
      );

      final packBytes = const GitPackCodec().encode(pack);
      final index = const GitPackIndexCodec().build(
        packBytes,
        objectIdsInPackOrder: [blob.id(), commit.id()],
      );
      final decoded = const GitPackIndexCodec().decode(
        const GitPackIndexCodec().encode(index),
      );

      expect(index.packChecksum, isNotNull);
      expect(index.checksum, isNotNull);
      expect(decoded.checksumAlgorithm, GitHashAlgorithm.sha1);
      expect(decoded.packChecksum, index.packChecksum);
      expect(decoded.checksum, index.checksum);
      expect(decoded.objectCount, 2);
      expect(
        decoded.entries.map((entry) => entry.objectId.hex).toList(),
        orderedEquals(([blob.id().hex, commit.id().hex]..sort())),
      );

      final blobEntry = decoded.entryForObjectId(blob.id());
      expect(blobEntry, isNotNull);
      expect(blobEntry!.offset, 12);
      expect(blobEntry.crc32, isPositive);

      final commitEntry = decoded.entryForObjectId(commit.id());
      expect(commitEntry, isNotNull);
      expect(commitEntry!.offset, greaterThan(blobEntry.offset));
      expect(commitEntry.crc32, isPositive);
    });

    test('encodes and decodes large offsets', () {
      final index = GitPackIndex(
        entries: [
          GitPackIndexEntry(
            objectId: GitObjectId.fromHex(
              '0123456789abcdef0123456789abcdef01234567',
            ),
            offset: 0x80000005,
            crc32: 0x12345678,
          ),
          GitPackIndexEntry(
            objectId: GitObjectId.fromHex(
              '89abcdef0123456789abcdef0123456789abcdef',
            ),
            offset: 12,
            crc32: 0x9abcdef0,
          ),
        ],
        packChecksum: GitObjectId.fromHex(
          'fedcba9876543210fedcba9876543210fedcba98',
        ),
      );

      final decoded = const GitPackIndexCodec().decode(
        const GitPackIndexCodec().encode(index),
      );

      expect(decoded.entries.first.offset, 0x80000005);
      expect(decoded.entries.first.crc32, 0x12345678);
      expect(decoded.entries.last.offset, 12);
      expect(decoded.entries.last.crc32, 0x9abcdef0);
    });

    test('supports sha256 pack indexes', () {
      final object = GitObject.blob('hello'.codeUnits);
      final pack = GitPack(
        checksumAlgorithm: GitHashAlgorithm.sha256,
        entries: [GitPackObjectEntry(object)],
      );

      final packBytes = const GitPackCodec(
        checksumAlgorithm: GitHashAlgorithm.sha256,
      ).encode(pack);
      final index =
          const GitPackIndexCodec(checksumAlgorithm: GitHashAlgorithm.sha256)
              .build(
                packBytes,
                objectIdsInPackOrder: [
                  object.id(algorithm: GitHashAlgorithm.sha256),
                ],
              );
      final decoded =
          const GitPackIndexCodec(
            checksumAlgorithm: GitHashAlgorithm.sha256,
          ).decode(
            const GitPackIndexCodec(checksumAlgorithm: GitHashAlgorithm.sha256)
                .encode(index),
          );

      expect(decoded.checksumAlgorithm, GitHashAlgorithm.sha256);
      expect(decoded.packChecksum!.isSha256, isTrue);
      expect(decoded.checksum!.isSha256, isTrue);
      expect(
        decoded.entryForObjectId(object.id(algorithm: GitHashAlgorithm.sha256)),
        isNotNull,
      );
    });
  });

  group('GitPackResolver', () {
    test('resolves offset deltas using decoded pack offsets', () async {
      final baseObject = GitObject.blob('hello'.codeUnits);
      final deltaBytes = const GitDeltaCodec().encode(
        GitDelta(
          baseSize: 5,
          resultSize: 11,
          instructions: [
            const GitDeltaCopyInstruction(offset: 0, size: 5),
            GitDeltaInsertInstruction(' world'.codeUnits),
          ],
        ),
      );
      final pack = GitPack(
        entries: [
          GitPackObjectEntry(baseObject, offset: 12),
          GitPackOffsetDeltaEntry(
            baseOffsetDistance: 8,
            deltaBytes: deltaBytes,
            objectSize: 11,
            offset: 20,
          ),
        ],
      );

      final resolved = await const GitPackResolver().resolve(pack);

      expect(resolved, hasLength(2));
      expect(
        resolved.last.object.bytes,
        orderedEquals('hello world'.codeUnits),
      );
      expect(resolved.last.object.type, GitObjectType.blob);
    });

    test('resolves thin packs through an external base resolver', () async {
      final baseObject = GitObject.blob('hello'.codeUnits);
      final deltaBytes = const GitDeltaCodec().encode(
        GitDelta(
          baseSize: 5,
          resultSize: 11,
          instructions: [
            const GitDeltaCopyInstruction(offset: 0, size: 5),
            GitDeltaInsertInstruction(' world'.codeUnits),
          ],
        ),
      );
      final pack = GitPack(
        entries: [
          GitPackReferenceDeltaEntry(
            baseObjectId: baseObject.id(),
            deltaBytes: deltaBytes,
            objectSize: 11,
            offset: 12,
          ),
        ],
      );

      final resolved = await const GitPackResolver().resolve(
        pack,
        externalBaseResolver: (objectId) {
          if (objectId == baseObject.id()) {
            return baseObject;
          }
          return null;
        },
      );

      expect(resolved, hasLength(1));
      expect(
        resolved.single.object.bytes,
        orderedEquals('hello world'.codeUnits),
      );
      expect(
        resolved.single.objectId,
        GitObject.blob('hello world'.codeUnits).id(),
      );
    });
  });

  group('GitRepository', () {
    test('builds work tree layout paths', () {
      final repository = GitRepository.workTree('/tmp/example');

      expect(repository.bare, isFalse);
      expect(repository.gitDirectoryPath, '/tmp/example/.git');
      expect(repository.headFilePath, '/tmp/example/.git/HEAD');
      expect(repository.indexFilePath, '/tmp/example/.git/index');
      expect(repository.objectDirectoryPath, '/tmp/example/.git/objects');
      expect(repository.referenceDirectoryPath, '/tmp/example/.git/refs');
    });

    test('builds bare layout paths', () {
      final repository = GitRepository.bare('/tmp/example.git');

      expect(repository.bare, isTrue);
      expect(repository.gitDirectoryPath, '/tmp/example.git');
      expect(repository.indexFilePath, '/tmp/example.git/index');
      expect(repository.objectDirectoryPath, '/tmp/example.git/objects');
    });

    test('validates repository layout', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'git_core_repo_valid_',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final gitDirectory = Directory(p.join(tempDirectory.path, '.git'));
      await Directory(p.join(gitDirectory.path, 'objects'))
          .create(recursive: true);
      await Directory(p.join(gitDirectory.path, 'refs'))
          .create(recursive: true);
      await File(p.join(gitDirectory.path, 'HEAD'))
          .writeAsString('ref: refs/heads/main\n');

      final repository = GitRepository.workTree(tempDirectory.path);

      expect(await repository.isValid(), isTrue);
    });

    test('discovers a work tree repository from a nested directory', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'git_core_repo_discover_',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final gitDirectory = Directory(p.join(tempDirectory.path, '.git'));
      await Directory(p.join(gitDirectory.path, 'objects'))
          .create(recursive: true);
      await Directory(p.join(gitDirectory.path, 'refs'))
          .create(recursive: true);
      await File(p.join(gitDirectory.path, 'HEAD'))
          .writeAsString('ref: refs/heads/main\n');

      final nestedDirectory = await Directory(
        p.join(tempDirectory.path, 'lib', 'src'),
      ).create(recursive: true);

      final repository = await GitRepository.discover(nestedDirectory.path);

      expect(repository, isNotNull);
      expect(repository!.bare, isFalse);
      expect(repository.path, p.normalize(p.absolute(tempDirectory.path)));
      expect(
        repository.gitDirectoryPath,
        p.join(p.normalize(p.absolute(tempDirectory.path)), '.git'),
      );
    });

    test('discovers a bare repository', () async {
      final bareDirectory = await Directory.systemTemp.createTemp(
        'git_core_bare_repo_',
      );
      addTearDown(() => bareDirectory.delete(recursive: true));

      await Directory(p.join(bareDirectory.path, 'objects'))
          .create(recursive: true);
      await Directory(p.join(bareDirectory.path, 'refs'))
          .create(recursive: true);
      await File(p.join(bareDirectory.path, 'HEAD'))
          .writeAsString('ref: refs/heads/main\n');

      final repository = await GitRepository.discover(bareDirectory.path);

      expect(repository, isNotNull);
      expect(repository!.bare, isTrue);
      expect(repository.path, p.normalize(bareDirectory.path));
    });

    test('discovers a linked work tree through a .git file', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'git_core_linked_worktree_',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final workTree = await Directory(p.join(tempDirectory.path, 'worktree'))
          .create();
      final actualGitDirectory = await Directory(
        p.join(tempDirectory.path, 'shared', 'main.git'),
      ).create(recursive: true);

      await Directory(p.join(actualGitDirectory.path, 'objects')).create();
      await Directory(p.join(actualGitDirectory.path, 'refs')).create();
      await File(p.join(actualGitDirectory.path, 'HEAD'))
          .writeAsString('ref: refs/heads/main\n');

      final relativeGitPath = p.relative(
        actualGitDirectory.path,
        from: workTree.path,
      );
      await File(p.join(workTree.path, '.git'))
          .writeAsString('gitdir: $relativeGitPath\n');

      final repository = await GitRepository.discover(workTree.path);

      expect(repository, isNotNull);
      expect(repository!.bare, isFalse);
      expect(repository.path, p.normalize(p.absolute(workTree.path)));
      expect(
        repository.gitDirectoryPath,
        p.normalize(p.absolute(actualGitDirectory.path)),
      );
      expect(
        repository.commonDirectoryPath,
        p.normalize(p.absolute(actualGitDirectory.path)),
      );
    });

    test('returns null when no repository is found', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'git_core_missing_repo_',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final repository = await GitRepository.discover(tempDirectory.path);

      expect(repository, isNull);
    });

    test('writes and reads a loose object in a work tree repository', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final object = GitObject.blob('hello'.codeUnits);

      final objectId = await repository.writeLooseObject(object);
      final objectPath = repository.resolveLooseObjectPath(objectId);
      final restored = await repository.readLooseObject(objectId);

      expect(objectId.hex, 'b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0');
      expect(await File(objectPath).exists(), isTrue);
      expect(restored, isNotNull);
      expect(restored!.type, GitObjectType.blob);
      expect(restored.bytes, orderedEquals('hello'.codeUnits));
    });

    test('returns null when a loose object file does not exist', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final missingObjectId = GitObjectId.fromHex(
        '0123456789abcdef0123456789abcdef01234567',
      );

      final restored = await repository.readLooseObject(missingObjectId);

      expect(restored, isNull);
    });

    test('reads packed objects from a repository', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final object = GitObject.blob('hello'.codeUnits);
      final objectId = await repository.writeLooseObject(object);

      await _packRepositoryObjects(repository, [objectId]);

      expect(await repository.readLooseObject(objectId), isNull);
      final restored = await repository.readObject(objectId);

      expect(restored, isNotNull);
      expect(restored!.type, GitObjectType.blob);
      expect(restored.bytes, orderedEquals('hello'.codeUnits));
    });

    test('exports and imports a pack of selected objects', () async {
      final sourceFixture = await _createWorkTreeRepository();
      final targetFixture = await _createWorkTreeRepository();
      addTearDown(() => sourceFixture.workTree.delete(recursive: true));
      addTearDown(() => targetFixture.workTree.delete(recursive: true));

      final sourceRepository = sourceFixture.repository;
      final targetRepository = targetFixture.repository;
      await File(p.join(sourceFixture.workTree.path, 'README.md'))
          .writeAsString('pack exchange\n');
      await sourceRepository.add(['README.md']);
      final commitId = await sourceRepository.commit(
        author: _signature(1700000000),
        message: 'Pack exchange\n',
      );
      final commit = const GitCommitCodec().decode(
        (await sourceRepository.readObject(commitId))!.bytes,
      );
      final treeEntries = const GitTreeCodec().decode(
        (await sourceRepository.readObject(commit.tree))!.bytes,
      );
      final blobId = treeEntries.single.objectId;

      final packBytes = await sourceRepository.exportPack([
        blobId,
        commit.tree,
        commitId,
      ]);
      final importedCount = await targetRepository.importPackBytes(packBytes);

      expect(importedCount, 3);
      expect(
        (await targetRepository.readObject(commitId))?.type,
        GitObjectType.commit,
      );
      expect(
        (await targetRepository.readObject(commit.tree))?.type,
        GitObjectType.tree,
      );
      expect(
        (await targetRepository.readObject(blobId))?.bytes,
        orderedEquals('pack exchange\n'.codeUnits),
      );
    });

    test('exports and imports pack streams in chunks', () async {
      final sourceFixture = await _createWorkTreeRepository();
      final targetFixture = await _createWorkTreeRepository();
      addTearDown(() => sourceFixture.workTree.delete(recursive: true));
      addTearDown(() => targetFixture.workTree.delete(recursive: true));

      final sourceRepository = sourceFixture.repository;
      final targetRepository = targetFixture.repository;
      await File(p.join(sourceFixture.workTree.path, 'README.md'))
          .writeAsString('stream exchange\n');
      await sourceRepository.add(['README.md']);
      final commitId = await sourceRepository.commit(
        author: _signature(1700000100),
        message: 'Pack stream\n',
      );
      final commit = const GitCommitCodec().decode(
        (await sourceRepository.readObject(commitId))!.bytes,
      );
      final treeEntries = const GitTreeCodec().decode(
        (await sourceRepository.readObject(commit.tree))!.bytes,
      );
      final blobId = treeEntries.single.objectId;

      final packStream = sourceRepository.exportPackStream([
        blobId,
        commit.tree,
        commitId,
      ], chunkSize: 11);
      final importedCount = await targetRepository.importPackStream(packStream);

      expect(importedCount, 3);
      expect(
        (await targetRepository.readObject(blobId))?.bytes,
        orderedEquals('stream exchange\n'.codeUnits),
      );
    });

    test('rejects non-positive export pack stream chunk sizes', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      await expectLater(
        fixture.repository
            .exportPackStream(const <GitObjectId>[], chunkSize: 0)
            .toList(),
        throwsArgumentError,
      );
    });

    test('supports end-to-end sha256 repositories and remotes', () async {
      final localFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createBareRepository();
      final cloneRoot = await Directory.systemTemp.createTemp(
        'git_core_sha256_clone_',
      );
      addTearDown(() => localFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.directory.delete(recursive: true));
      addTearDown(() => cloneRoot.delete(recursive: true));

      final localRepository = localFixture.repository;
      await File(p.join(localFixture.workTree.path, 'README.md'))
          .writeAsString('hello sha256\n');
      final index = await localRepository.add([
        'README.md',
      ], algorithm: GitHashAlgorithm.sha256);
      final commitId = await localRepository.commitIndex(
        index,
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );
      await localRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.directory.path),
      );

      final pushResult = await localRepository.push('origin');
      final clonePath = p.join(cloneRoot.path, 'clone');
      final cloneResult = await GitRepository.clone(
        remoteFixture.directory.path,
        clonePath,
      );
      final clonedRepository = (await GitRepository.discover(clonePath))!;

      expect(index.checksumAlgorithm, GitHashAlgorithm.sha256);
      expect(commitId.isSha256, isTrue);
      expect(pushResult.references.single.objectId, commitId);
      expect(cloneResult.objectId, commitId);
      expect(await clonedRepository.revParse('HEAD'), commitId);
      expect(
        (await clonedRepository.readObject(commitId))?.type,
        GitObjectType.commit,
      );
    });

    test('writes and reads a direct reference', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final objectId = GitObjectId.fromHex(
        '0123456789abcdef0123456789abcdef01234567',
      );
      final reference = GitReference.direct('refs/heads/main', objectId);

      await repository.writeReference(reference);
      final restored = await repository.readReference('refs/heads/main');

      expect(restored, isNotNull);
      expect(restored!.isDirect, isTrue);
      expect(restored.objectId, objectId);
    });

    test('writes and reads a git index file', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final index = GitIndex(
        entries: [
          GitIndexEntry(
            ctimeSeconds: 1700000000,
            ctimeNanoseconds: 10,
            mtimeSeconds: 1700000001,
            mtimeNanoseconds: 20,
            device: 1,
            inode: 2,
            mode: 0x81a4,
            userId: 501,
            groupId: 20,
            fileSize: 5,
            objectId: GitObjectId.fromHex(
              '0123456789abcdef0123456789abcdef01234567',
            ),
            path: 'README.md',
          ),
        ],
      );

      await repository.writeIndex(index);
      final restored = await repository.readIndex();

      expect(await File(repository.indexFilePath).exists(), isTrue);
      expect(restored, isNotNull);
      expect(restored!.entryForPath('README.md'), isNotNull);
      expect(restored.checksum, isNotNull);
    });

    test('returns null when the git index file does not exist', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;

      expect(await repository.readIndex(), isNull);
    });

    test('creates an index entry from a working tree file', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello');

      final entry = await repository.createIndexEntryFromWorkTreePath(
        'README.md',
      );

      expect(entry.path, 'README.md');
      expect(entry.mode, GitIndexEntry.regularFileMode);
      expect(entry.fileSize, 5);
      expect(entry.objectId.hex, 'b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0');
      expect(
        await File(repository.resolveLooseObjectPath(entry.objectId)).exists(),
        isTrue,
      );
    });

    test('stages a working tree file into the git index', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello');

      final index = await repository.stageWorkTreePath('README.md');
      final restored = await repository.readIndex();

      expect(index.entryForPath('README.md'), isNotNull);
      expect(restored, isNotNull);
      expect(
        restored!.entryForPath('README.md')!.objectId,
        index.entries.single.objectId,
      );
    });

    test('writes a tree object from staged index entries', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello');
      await Directory(p.join(fixture.workTree.path, 'lib')).create();
      await File(p.join(fixture.workTree.path, 'lib', 'main.dart'))
          .writeAsString('void main() {}\n');

      await repository.stageWorkTreePath('README.md');
      final index = await repository.stageWorkTreePath('lib/main.dart');
      final rootTreeId = await repository.writeTreeFromIndex(index);

      final rootTreeObject = await repository.readLooseObject(rootTreeId);
      final rootEntries = const GitTreeCodec().decode(rootTreeObject!.bytes);

      expect(rootEntries, hasLength(2));
      expect(rootEntries.first.utf8Name, 'README.md');
      expect(rootEntries.last.utf8Name, 'lib');
      expect(rootEntries.last.mode, '040000');

      final nestedTreeObject = await repository.readLooseObject(
        rootEntries.last.objectId,
      );
      final nestedEntries = const GitTreeCodec().decode(
        nestedTreeObject!.bytes,
      );

      expect(nestedEntries, hasLength(1));
      expect(nestedEntries.single.utf8Name, 'main.dart');
      expect(nestedEntries.single.mode, '100644');
    });

    test(
      'reports conflicted paths before writing a tree from the index',
      () async {
        final fixture = await _createTextMergeConflictRepository();
        addTearDown(() => fixture.workTree.delete(recursive: true));

        final index = await fixture.repository.readIndex();
        final checkResult = fixture.repository.checkWriteTreeFromIndex(index!);

        expect(checkResult.canWrite, isFalse);
        expect(checkResult.conflicts, hasLength(1));
        expect(checkResult.conflicts.single.path, 'README.md');
        expect(checkResult.conflicts.single.stages, [1, 2, 3]);
        expect(
          () => fixture.repository.writeTreeFromIndex(index),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('README.md (stages 1, 2, 3)'),
            ),
          ),
        );
      },
    );

    test('writes a commit object from a tree', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello');

      final index = await repository.stageWorkTreePath('README.md');
      final treeId = await repository.writeTreeFromIndex(index);
      final commitId = await repository.writeCommitFromTree(
        treeId,
        author: const GitCommitSignature(
          name: 'Alice Example',
          email: 'alice@example.com',
          timestampSeconds: 1700000000,
          timezoneOffset: '+0900',
        ),
        message: 'Initial commit\n',
      );

      final commitObject = await repository.readLooseObject(commitId);
      final commit = const GitCommitCodec().decode(commitObject!.bytes);

      expect(commit.tree, treeId);
      expect(commit.parents, isEmpty);
      expect(commit.author.name, 'Alice Example');
      expect(commit.message, 'Initial commit\n');
    });

    test(
      'commits staged index entries and updates the current branch',
      () async {
        final fixture = await _createWorkTreeRepository();
        addTearDown(() => fixture.workTree.delete(recursive: true));

        final repository = fixture.repository;
        const signature = GitCommitSignature(
          name: 'Alice Example',
          email: 'alice@example.com',
          timestampSeconds: 1700000000,
          timezoneOffset: '+0900',
        );

        await File(p.join(fixture.workTree.path, 'README.md'))
            .writeAsString('hello');
        final firstIndex = await repository.stageWorkTreePath('README.md');
        final firstCommitId = await repository.commitIndex(
          firstIndex,
          author: signature,
          message: 'Initial commit\n',
        );

        await File(p.join(fixture.workTree.path, 'README.md'))
            .writeAsString('hello world');
        final secondIndex = await repository.stageWorkTreePath('README.md');
        final secondCommitId = await repository.commitIndex(
          secondIndex,
          author: const GitCommitSignature(
            name: 'Alice Example',
            email: 'alice@example.com',
            timestampSeconds: 1700000100,
            timezoneOffset: '+0900',
          ),
          message: 'Update README\n',
        );

        final headCommitId = await repository.resolveReferenceObjectId('HEAD');
        final branchReference = await repository.readReference(
          'refs/heads/main',
        );
        final secondCommitObject = await repository.readLooseObject(
          secondCommitId,
        );
        final secondCommit = const GitCommitCodec().decode(
          secondCommitObject!.bytes,
        );

        expect(headCommitId, secondCommitId);
        expect(branchReference, isNotNull);
        expect(branchReference!.objectId, secondCommitId);
        expect(secondCommit.parents, [firstCommitId]);
        expect(secondCommit.message, 'Update README\n');
      },
    );

    test('adds directories and tracked deletions to the index', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await Directory(p.join(fixture.workTree.path, 'lib', 'src'))
          .create(recursive: true);
      await File(p.join(fixture.workTree.path, 'lib', 'main.dart'))
          .writeAsString('void main() {}\n');
      await File(p.join(fixture.workTree.path, 'lib', 'src', 'helper.dart'))
          .writeAsString('final answer = 42;\n');
      await File(p.join(fixture.workTree.path, 'obsolete.txt'))
          .writeAsString('old\n');

      await repository.add(['lib', 'obsolete.txt']);
      await File(p.join(fixture.workTree.path, 'obsolete.txt')).delete();
      final index = await repository.add(['obsolete.txt']);

      expect(index.entryForPath('lib/main.dart'), isNotNull);
      expect(index.entryForPath('lib/src/helper.dart'), isNotNull);
      expect(index.entryForPath('obsolete.txt'), isNull);
    });

    test(
      'supports wildcard pathspecs and optional ignored files when adding',
      () async {
        final fixture = await _createWorkTreeRepository();
        addTearDown(() => fixture.workTree.delete(recursive: true));

        final repository = fixture.repository;
        await Directory(p.join(fixture.workTree.path, 'lib', 'src'))
            .create(recursive: true);
        await File(p.join(fixture.workTree.path, '.gitignore'))
            .writeAsString('*.log\n');
        await File(p.join(fixture.workTree.path, 'lib', 'main.dart'))
            .writeAsString('void main() {}\n');
        await File(p.join(fixture.workTree.path, 'lib', 'src', 'helper.dart'))
            .writeAsString('final answer = 42;\n');
        await File(p.join(fixture.workTree.path, 'build.log'))
            .writeAsString('ignored\n');

        var index = await repository.add(['*.dart', '*.log']);

        expect(index.entryForPath('lib/main.dart'), isNotNull);
        expect(index.entryForPath('lib/src/helper.dart'), isNotNull);
        expect(index.entryForPath('build.log'), isNull);

        index = await repository.add(['*.log'], includeIgnored: true);

        expect(index.entryForPath('build.log'), isNotNull);
      },
    );

    test('reports staged, unstaged, and untracked status entries', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      const author = GitCommitSignature(
        name: 'Alice Example',
        email: 'alice@example.com',
        timestampSeconds: 1700000000,
        timezoneOffset: '+0900',
      );

      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');
      await File(p.join(fixture.workTree.path, 'obsolete.txt'))
          .writeAsString('old\n');
      await repository.add(['README.md', 'obsolete.txt']);
      await repository.commit(author: author, message: 'Initial commit\n');

      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello staged\n');
      await repository.add(['README.md']);
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello staged and unstaged\n');
      await File(p.join(fixture.workTree.path, 'obsolete.txt')).delete();
      await repository.add(['obsolete.txt']);
      await File(p.join(fixture.workTree.path, 'notes.txt'))
          .writeAsString('untracked\n');

      final status = await repository.status();

      expect(status.isClean, isFalse);
      expect(status.hasStagedChanges, isTrue);
      expect(status.hasUnstagedChanges, isTrue);
      expect(
        status.entries,
        orderedEquals([
          isA<GitStatusEntry>()
              .having((entry) => entry.path, 'path', 'README.md')
              .having(
                (entry) => entry.indexStatus,
                'indexStatus',
                GitFileStatus.modified,
              )
              .having(
                (entry) => entry.workTreeStatus,
                'workTreeStatus',
                GitFileStatus.modified,
              ),
          isA<GitStatusEntry>()
              .having((entry) => entry.path, 'path', 'notes.txt')
              .having(
                (entry) => entry.indexStatus,
                'indexStatus',
                GitFileStatus.unchanged,
              )
              .having(
                (entry) => entry.workTreeStatus,
                'workTreeStatus',
                GitFileStatus.untracked,
              ),
          isA<GitStatusEntry>()
              .having((entry) => entry.path, 'path', 'obsolete.txt')
              .having(
                (entry) => entry.indexStatus,
                'indexStatus',
                GitFileStatus.deleted,
              )
              .having(
                (entry) => entry.workTreeStatus,
                'workTreeStatus',
                GitFileStatus.unchanged,
              ),
        ]),
      );
    });

    test('filters status by pathspec and can surface ignored files', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await Directory(p.join(fixture.workTree.path, 'lib')).create();
      await File(p.join(fixture.workTree.path, '.gitignore'))
          .writeAsString('*.log\n');
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');
      await File(p.join(fixture.workTree.path, 'lib', 'main.dart'))
          .writeAsString('void main() {}\n');
      await repository.add(['README.md', 'lib/main.dart']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello world\n');
      await File(p.join(fixture.workTree.path, 'lib', 'main.dart'))
          .writeAsString('void main() => print(42);\n');
      await File(p.join(fixture.workTree.path, 'lib', 'build.log'))
          .writeAsString('ignored\n');

      final ignoredOnlyStatus = await repository.status(
        pathspecs: ['*.log'],
        includeIgnored: true,
      );
      final scopedStatus = await repository.status(
        pathspecs: ['lib'],
        includeIgnored: true,
      );

      expect(ignoredOnlyStatus.isClean, isTrue);
      expect(ignoredOnlyStatus.hasUnstagedChanges, isFalse);
      expect(
        ignoredOnlyStatus.entries,
        orderedEquals([
          isA<GitStatusEntry>()
              .having((entry) => entry.path, 'path', 'lib/build.log')
              .having(
                (entry) => entry.indexStatus,
                'indexStatus',
                GitFileStatus.unchanged,
              )
              .having(
                (entry) => entry.workTreeStatus,
                'workTreeStatus',
                GitFileStatus.ignored,
              ),
        ]),
      );
      expect(scopedStatus.entries.map((entry) => entry.path), [
        'lib/build.log',
        'lib/main.dart',
      ]);
      expect(scopedStatus.entries.first.workTreeStatus, GitFileStatus.ignored);
      expect(scopedStatus.entries.last.workTreeStatus, GitFileStatus.modified);
    });

    test('reports conflicted index entries in status', () async {
      final fixture = await _createTextMergeConflictRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final status = await fixture.repository.status();
      final entry = status.entries.single;

      expect(status.isClean, isFalse);
      expect(status.hasStagedChanges, isTrue);
      expect(status.hasUnstagedChanges, isTrue);
      expect(entry.path, 'README.md');
      expect(entry.indexStatus, GitFileStatus.conflicted);
      expect(entry.workTreeStatus, GitFileStatus.unchanged);
      expect(entry.conflict, isNotNull);
      expect(entry.conflict!.base, isNotNull);
      expect(entry.conflict!.ours, isNotNull);
      expect(entry.conflict!.theirs, isNotNull);

      await fixture.readme.writeAsString('one\ntwo resolved\nthree\n');

      final modifiedStatus = await fixture.repository.status();
      expect(
        modifiedStatus.entries.single.indexStatus,
        GitFileStatus.conflicted,
      );
      expect(
        modifiedStatus.entries.single.workTreeStatus,
        GitFileStatus.modified,
      );
    });

    test('commits the current index through the porcelain helper', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      const author = GitCommitSignature(
        name: 'Alice Example',
        email: 'alice@example.com',
        timestampSeconds: 1700000000,
        timezoneOffset: '+0900',
      );

      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');
      await repository.add(['README.md']);

      final commitId = await repository.commit(
        author: author,
        message: 'Initial commit\n',
      );
      final headCommitId = await repository.resolveReferenceObjectId('HEAD');
      final status = await repository.status();

      expect(commitId, headCommitId);
      expect(status.isClean, isTrue);
    });

    test('rejects porcelain commits without staged changes', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: const GitCommitSignature(
          name: 'Alice Example',
          email: 'alice@example.com',
          timestampSeconds: 1700000000,
          timezoneOffset: '+0900',
        ),
        message: 'Initial commit\n',
      );

      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');

      expect(
        repository.commit(
          author: const GitCommitSignature(
            name: 'Alice Example',
            email: 'alice@example.com',
            timestampSeconds: 1700000100,
            timezoneOffset: '+0900',
          ),
          message: 'No-op commit\n',
        ),
        throwsStateError,
      );
    });

    test('lists tracked and untracked files', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await Directory(p.join(fixture.workTree.path, 'lib')).create();
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');
      await File(p.join(fixture.workTree.path, 'lib', 'main.dart'))
          .writeAsString('void main() {}\n');
      await File(p.join(fixture.workTree.path, 'notes.txt'))
          .writeAsString('untracked\n');

      await repository.add(['README.md', 'lib/main.dart']);
      final entries = await repository.lsFiles(includeUntracked: true);

      expect(
        entries,
        orderedEquals([
          isA<GitLsFilesEntry>()
              .having((entry) => entry.path, 'path', 'README.md')
              .having((entry) => entry.tracked, 'tracked', isTrue)
              .having((entry) => entry.untracked, 'untracked', isFalse),
          isA<GitLsFilesEntry>()
              .having((entry) => entry.path, 'path', 'lib/main.dart')
              .having((entry) => entry.tracked, 'tracked', isTrue)
              .having((entry) => entry.untracked, 'untracked', isFalse),
          isA<GitLsFilesEntry>()
              .having((entry) => entry.path, 'path', 'notes.txt')
              .having((entry) => entry.tracked, 'tracked', isFalse)
              .having((entry) => entry.untracked, 'untracked', isTrue),
        ]),
      );
    });

    test('filters ls-files output and can include ignored entries', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await Directory(p.join(fixture.workTree.path, 'lib')).create();
      await File(p.join(fixture.workTree.path, '.gitignore'))
          .writeAsString('*.log\n');
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');
      await File(p.join(fixture.workTree.path, 'lib', 'main.dart'))
          .writeAsString('void main() {}\n');
      await File(p.join(fixture.workTree.path, 'lib', 'notes.txt'))
          .writeAsString('untracked\n');
      await File(p.join(fixture.workTree.path, 'lib', 'build.log'))
          .writeAsString('ignored\n');

      await repository.add(['README.md', 'lib/main.dart']);
      final entries = await repository.lsFiles(
        includeUntracked: true,
        includeIgnored: true,
        pathspecs: ['lib'],
      );

      expect(entries.map((entry) => entry.path), [
        'lib/build.log',
        'lib/main.dart',
        'lib/notes.txt',
      ]);
      expect(entries[0].ignored, isTrue);
      expect(entries[1].tracked, isTrue);
      expect(entries[2].untracked, isTrue);
    });

    test('resolves revisions and parent traversals', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      const author = GitCommitSignature(
        name: 'Alice Example',
        email: 'alice@example.com',
        timestampSeconds: 1700000000,
        timezoneOffset: '+0900',
      );

      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');
      await repository.add(['README.md']);
      final firstCommitId = await repository.commit(
        author: author,
        message: 'Initial commit\n',
      );

      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello world\n');
      await repository.add(['README.md']);
      final secondCommitId = await repository.commit(
        author: const GitCommitSignature(
          name: 'Alice Example',
          email: 'alice@example.com',
          timestampSeconds: 1700000100,
          timezoneOffset: '+0900',
        ),
        message: 'Update README\n',
      );

      expect(await repository.revParse('HEAD'), secondCommitId);
      expect(await repository.revParse('main'), secondCommitId);
      expect(await repository.revParse('HEAD^'), firstCommitId);
      expect(await repository.revParse('HEAD~1'), firstCommitId);
      expect(await repository.revParse('HEAD~2'), isNull);
    });

    test('supports reflog selectors and tag peeling in revParse', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');
      await repository.add(['README.md']);
      final firstCommitId = await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello world\n');
      await repository.add(['README.md']);
      final secondCommitId = await repository.commit(
        author: _signature(1700000100),
        message: 'Update README\n',
      );

      final annotatedTag = await repository.tag(
        'v2',
        message: 'Release 2',
        tagger: _signature(1700000200),
      );

      expect(await repository.revParse('@{1}'), firstCommitId);
      expect(await repository.revParse('main@{1}'), firstCommitId);
      expect(await repository.revParse('v2'), annotatedTag.objectId);
      expect(await repository.revParse('v2^0'), secondCommitId);
    });

    test(
      'creates, lists, and resolves lightweight and annotated tags',
      () async {
        final fixture = await _createWorkTreeRepository();
        addTearDown(() => fixture.workTree.delete(recursive: true));

        final repository = fixture.repository;
        await File(p.join(fixture.workTree.path, 'README.md'))
            .writeAsString('hello\n');
        await repository.add(['README.md']);
        final commitId = await repository.commit(
          author: _signature(1700000000),
          message: 'Initial commit\n',
        );

        final lightweightTag = await repository.tag('v1');
        final annotatedTag = await repository.tag(
          'release/v1.0',
          message: 'Release 1.0',
          tagger: _signature(1700000100),
        );
        final tags = await repository.tags();
        final references = await repository.references(
          prefix: 'refs/tags',
          peelTags: true,
        );

        expect(lightweightTag.annotated, isFalse);
        expect(lightweightTag.objectId, commitId);
        expect(annotatedTag.annotated, isTrue);
        expect(annotatedTag.targetObjectId, commitId);
        expect(annotatedTag.objectId, isNot(commitId));
        expect(tags.map((tag) => tag.referenceName), [
          'refs/tags/release/v1.0',
          'refs/tags/v1',
        ]);
        expect(
          tags.firstWhere((tag) => tag.name == 'release/v1.0').targetObjectId,
          commitId,
        );
        expect(
          references
              .firstWhere(
                (reference) =>
                    reference.referenceName == 'refs/tags/release/v1.0',
              )
              .peeledObjectId,
          commitId,
        );
        expect(
          references
              .firstWhere(
                (reference) => reference.referenceName == 'refs/tags/v1',
              )
              .peeledObjectId,
          commitId,
        );
      },
    );

    test('shows a resolved revision object', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');
      await repository.add(['README.md']);
      final commitId = await repository.commit(
        author: const GitCommitSignature(
          name: 'Alice Example',
          email: 'alice@example.com',
          timestampSeconds: 1700000000,
          timezoneOffset: '+0900',
        ),
        message: 'Initial commit\n',
      );

      final object = await repository.show('HEAD');

      expect(object, isNotNull);
      expect(object!.id(), commitId);
      expect(object.type, GitObjectType.commit);
    });

    test('builds a staged diff against HEAD', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello\nworld\n');
      await repository.add(['README.md']);

      final entries = await repository.diff(staged: true);

      expect(entries, hasLength(1));
      expect(entries.single.path, 'README.md');
      expect(entries.single.changeType, GitDiffChangeType.modified);
      expect(entries.single.binary, isFalse);
      expect(entries.single.hunks, hasLength(1));
      expect(
        entries.single.hunks.single.lines.map((line) => (line.type, line.text)),
        orderedEquals([
          (GitDiffLineType.context, 'hello\n'),
          (GitDiffLineType.addition, 'world\n'),
        ]),
      );
    });

    test(
      'returns conflict metadata in staged diffs for unmerged index paths',
      () async {
        final fixture = await _createTextMergeConflictRepository();
        addTearDown(() => fixture.workTree.delete(recursive: true));

        final entries = await fixture.repository.diff(staged: true);
        final entry = entries.single;

        expect(entries, hasLength(1));
        expect(entry.path, 'README.md');
        expect(entry.changeType, GitDiffChangeType.modified);
        expect(entry.conflicted, isTrue);
        expect(entry.conflict, isNotNull);
        expect(entry.conflict!.base, isNotNull);
        expect(entry.conflict!.ours, isNotNull);
        expect(entry.conflict!.theirs, isNotNull);
        expect(
          entry.hunks.single.lines.map((line) => (line.type, line.text)),
          orderedEquals([
            (GitDiffLineType.context, 'one\n'),
            (GitDiffLineType.deletion, 'two ours\n'),
            (GitDiffLineType.addition, 'two incoming\n'),
            (GitDiffLineType.context, 'three\n'),
          ]),
        );
      },
    );

    test('builds an unstaged diff against the index', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('goodbye\n');

      final entries = await repository.diff();

      expect(entries, hasLength(1));
      expect(entries.single.path, 'README.md');
      expect(entries.single.changeType, GitDiffChangeType.modified);
      expect(entries.single.binary, isFalse);
      expect(
        entries.single.hunks.single.lines.map((line) => (line.type, line.text)),
        orderedEquals([
          (GitDiffLineType.deletion, 'hello\n'),
          (GitDiffLineType.addition, 'goodbye\n'),
        ]),
      );
    });

    test(
      'returns conflict metadata in unstaged diffs for manual resolutions',
      () async {
        final fixture = await _createTextMergeConflictRepository();
        addTearDown(() => fixture.workTree.delete(recursive: true));

        await fixture.readme.writeAsString('one\ntwo resolved\nthree\n');

        final entries = await fixture.repository.diff();
        final entry = entries.single;

        expect(entries, hasLength(1));
        expect(entry.path, 'README.md');
        expect(entry.changeType, GitDiffChangeType.modified);
        expect(entry.conflicted, isTrue);
        expect(entry.conflict, isNotNull);
        expect(
          entry.hunks.single.lines.map((line) => (line.type, line.text)),
          orderedEquals([
            (GitDiffLineType.context, 'one\n'),
            (GitDiffLineType.deletion, 'two ours\n'),
            (GitDiffLineType.addition, 'two resolved\n'),
            (GitDiffLineType.context, 'three\n'),
          ]),
        );
      },
    );

    test('optionally includes untracked files in work tree diffs', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(p.join(fixture.workTree.path, 'notes.txt'))
          .writeAsString('untracked\n');

      expect(await repository.diff(), isEmpty);

      final entries = await repository.diff(includeUntracked: true);

      expect(entries, hasLength(1));
      expect(entries.single.path, 'notes.txt');
      expect(entries.single.changeType, GitDiffChangeType.added);
      expect(
        entries.single.hunks.single.lines.map((line) => (line.type, line.text)),
        orderedEquals([(GitDiffLineType.addition, 'untracked\n')]),
      );
    });

    test('filters diffs by pathspec and can include ignored files', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await Directory(p.join(fixture.workTree.path, 'lib')).create();
      await File(p.join(fixture.workTree.path, '.gitignore'))
          .writeAsString('*.log\n');
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');
      await File(p.join(fixture.workTree.path, 'lib', 'main.dart'))
          .writeAsString('void main() {}\n');
      await repository.add(['README.md', 'lib/main.dart']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello world\n');
      await File(p.join(fixture.workTree.path, 'lib', 'main.dart'))
          .writeAsString('void main() => print(42);\n');
      await File(p.join(fixture.workTree.path, 'notes.txt'))
          .writeAsString('untracked\n');
      await File(p.join(fixture.workTree.path, 'lib', 'build.log'))
          .writeAsString('ignored\n');

      final scopedEntries = await repository.diff(
        includeUntracked: true,
        pathspecs: ['lib'],
      );
      final ignoredEntries = await repository.diff(
        includeUntracked: true,
        includeIgnored: true,
        pathspecs: ['lib'],
      );

      expect(scopedEntries.map((entry) => entry.path), ['lib/main.dart']);
      expect(ignoredEntries.map((entry) => entry.path), [
        'lib/build.log',
        'lib/main.dart',
      ]);
      expect(ignoredEntries.first.changeType, GitDiffChangeType.added);
      expect(ignoredEntries.last.changeType, GitDiffChangeType.modified);
    });

    test('marks binary changes without generating hunks', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final file = File(p.join(fixture.workTree.path, 'image.bin'));
      await file.writeAsBytes([0, 1, 2, 3]);
      await repository.add(['image.bin']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Add binary file\n',
      );

      await file.writeAsBytes([0, 1, 2, 4]);

      final entries = await repository.diff();

      expect(entries, hasLength(1));
      expect(entries.single.path, 'image.bin');
      expect(entries.single.binary, isTrue);
      expect(entries.single.hunks, isEmpty);
    });

    test('applies binary diffs using captured blob bytes', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final file = File(p.join(fixture.workTree.path, 'image.bin'));
      await file.writeAsBytes([0, 1, 2, 3]);
      await repository.add(['image.bin']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Add binary file\n',
      );

      await file.writeAsBytes([0, 1, 2, 4]);
      final patch = await repository.diff();

      await file.writeAsBytes([0, 1, 2, 3]);
      final result = await repository.apply(patch);

      expect(result.success, isTrue);
      expect(await file.readAsBytes(), [0, 1, 2, 4]);
    });

    test('returns conflicts instead of unsupported for text patches on binary files', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final file = File(p.join(fixture.workTree.path, 'README.md'));
      await file.writeAsBytes([0, 1, 2, 3]);

      final result = await repository.apply([
        GitDiffEntry(
          path: 'README.md',
          changeType: GitDiffChangeType.modified,
          oldMode: '100644',
          newMode: '100644',
          hunks: const [
            GitDiffHunk(
              oldStart: 1,
              oldLineCount: 1,
              newStart: 1,
              newLineCount: 1,
              lines: [
                GitDiffLine(type: GitDiffLineType.deletion, text: 'hello\n'),
                GitDiffLine(type: GitDiffLineType.addition, text: 'world\n'),
              ],
            ),
          ],
        ),
      ]);

      expect(result.hasConflicts, isTrue);
      expect(result.hasUnsupported, isFalse);
      expect(result.files.single.status, GitApplyStatus.conflict);
      expect(result.files.single.message, contains('interpreted as text'));
    });

    test('returns conflicts instead of unsupported when binary patch data is missing', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final file = File(p.join(fixture.workTree.path, 'image.bin'));
      await file.writeAsBytes([0, 1, 2, 3]);

      final result = await repository.apply([
        const GitDiffEntry(
          path: 'image.bin',
          changeType: GitDiffChangeType.modified,
          oldMode: '100644',
          newMode: '100644',
          binary: true,
        ),
      ]);

      expect(result.hasConflicts, isTrue);
      expect(result.hasUnsupported, isFalse);
      expect(result.files.single.status, GitApplyStatus.conflict);
      expect(result.files.single.message, contains('Binary patch data'));
    });

    test('applies a modified text patch to the working tree', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('hello\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await readme.writeAsString('hello\nworld\n');
      final patch = await repository.diff();

      await readme.writeAsString('hello\n');
      final result = await repository.apply(patch);

      expect(result.success, isTrue);
      expect(await readme.readAsString(), 'hello\nworld\n');
    });

    test('applies added and deleted file patches atomically', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final obsolete = File(p.join(fixture.workTree.path, 'obsolete.txt'));
      final notes = File(p.join(fixture.workTree.path, 'notes.txt'));
      await obsolete.writeAsString('old\n');
      await repository.add(['obsolete.txt']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Track obsolete file\n',
      );

      await obsolete.delete();
      await notes.writeAsString('new\n');
      final patch = await repository.diff(includeUntracked: true);

      await obsolete.writeAsString('old\n');
      await notes.delete();
      final result = await repository.apply(patch);

      expect(result.success, isTrue);
      expect(await obsolete.exists(), isFalse);
      expect(await notes.readAsString(), 'new\n');
    });

    test('reports conflicts without partially writing files', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      final notes = File(p.join(fixture.workTree.path, 'notes.txt'));
      await readme.writeAsString('hello\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await readme.writeAsString('hello\nworld\n');
      await notes.writeAsString('new\n');
      final patch = await repository.diff(includeUntracked: true);

      await readme.writeAsString('different\n');
      await notes.delete();
      final result = await repository.apply(
        patch,
        recordConflictsInIndex: true,
      );
      final conflicts = await repository.conflicts();

      expect(result.success, isFalse);
      expect(result.hasConflicts, isTrue);
      expect(
        result.files.firstWhere((file) => file.path == 'README.md').status,
        GitApplyStatus.conflict,
      );
      expect(conflicts, hasLength(1));
      expect(conflicts.single.path, 'README.md');
      expect(conflicts.single.base, isNotNull);
      expect(conflicts.single.ours, isNotNull);
      expect(conflicts.single.theirs, isNotNull);
      expect(await readme.readAsString(), 'different\n');
      expect(await notes.exists(), isFalse);
    });

    test(
      'aborts a recorded apply conflict and restores the original index',
      () async {
        final fixture = await _createWorkTreeRepository();
        addTearDown(() => fixture.workTree.delete(recursive: true));

        final repository = fixture.repository;
        final readme = File(p.join(fixture.workTree.path, 'README.md'));
        final notes = File(p.join(fixture.workTree.path, 'notes.txt'));
        await readme.writeAsString('hello\n');
        await repository.add(['README.md']);
        await repository.commit(
          author: _signature(1700000000),
          message: 'Initial commit\n',
        );

        await notes.writeAsString('staged\n');
        await repository.add(['notes.txt']);

        await readme.writeAsString('hello\nworld\n');
        final patch = await repository.diff();

        await readme.writeAsString('different\n');
        final result = await repository.apply(
          patch,
          recordConflictsInIndex: true,
        );
        final abortResult = await repository.applyAbort();
        final lsFiles = await repository.lsFiles();

        expect(result.hasConflicts, isTrue);
        expect(abortResult.indexRestored, isTrue);
        expect(abortResult.conflictPaths, ['README.md']);
        expect(
          lsFiles
              .where((entry) => entry.path == 'README.md')
              .map((entry) => (entry.path, entry.stage)),
          orderedEquals([('README.md', 0)]),
        );
        expect(
          lsFiles
              .where((entry) => entry.path == 'notes.txt')
              .map((entry) => (entry.path, entry.stage)),
          orderedEquals([('notes.txt', 0)]),
        );
        expect(await File(repository.applyStateFilePath).exists(), isFalse);
      },
    );

    test('supports check-only patch validation', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('hello\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await readme.writeAsString('hello\nworld\n');
      final patch = await repository.diff();

      await readme.writeAsString('hello\n');
      final result = await repository.apply(patch, check: true);

      expect(result.success, isTrue);
      expect(result.check, isTrue);
      expect(await readme.readAsString(), 'hello\n');
    });

    test(
      'supports clean 3-way patch application for non-overlapping edits',
      () async {
        final fixture = await _createWorkTreeRepository();
        addTearDown(() => fixture.workTree.delete(recursive: true));

        final repository = fixture.repository;
        final readme = File(p.join(fixture.workTree.path, 'README.md'));
        await readme.writeAsString('one\ntwo\nthree\n');
        await repository.add(['README.md']);
        await repository.commit(
          author: _signature(1700000000),
          message: 'Initial commit\n',
        );

        await readme.writeAsString('one\ntwo incoming\nthree\n');
        final patch = await repository.diff();

        await readme.writeAsString('one\ntwo\nthree ours\n');
        final result = await repository.apply(patch, threeWay: true);

        expect(result.success, isTrue);
        expect(
          result.files.single.mergedText,
          'one\ntwo incoming\nthree ours\n',
        );
        expect(await readme.readAsString(), 'one\ntwo incoming\nthree ours\n');
      },
    );

    test('returns structured conflicts for overlapping 3-way edits', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('one\ntwo\nthree\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await readme.writeAsString('one\ntwo incoming\nthree\n');
      final patch = await repository.diff();

      await readme.writeAsString('one\ntwo ours\nthree\n');
      final result = await repository.apply(patch, threeWay: true);

      expect(result.success, isFalse);
      expect(result.hasConflicts, isTrue);
      expect(result.files.single.conflicts, hasLength(1));
      expect(result.files.single.conflicts.single.startLine, 2);
      expect(result.files.single.conflicts.single.baseText, 'two\n');
      expect(result.files.single.conflicts.single.currentText, 'two ours\n');
      expect(
        result.files.single.conflicts.single.incomingText,
        'two incoming\n',
      );
      expect(await readme.readAsString(), 'one\ntwo ours\nthree\n');
    });

    test('applies a raw unified diff patch string', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final codec = const GitDiffCodec();
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('hello\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await readme.writeAsString('hello\nworld\n');
      final patchText = codec.encode(await repository.diff());

      await readme.writeAsString('hello\n');
      final result = await repository.applyPatch(patchText);

      expect(result.success, isTrue);
      expect(await readme.readAsString(), 'hello\nworld\n');
    });

    test('reports matching root gitignore rules', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(p.join(fixture.workTree.path, '.gitignore'))
          .writeAsString('*.log\n');

      final matches = await repository.checkIgnore(['debug.log', 'README.md']);

      expect(matches, hasLength(1));
      expect(matches.single.path, 'debug.log');
      expect(matches.single.pattern, '*.log');
      expect(matches.single.source, '.gitignore');
      expect(matches.single.lineNumber, 1);
    });

    test(
      'respects nested gitignore rules relative to their directory',
      () async {
        final fixture = await _createWorkTreeRepository();
        addTearDown(() => fixture.workTree.delete(recursive: true));

        final repository = fixture.repository;
        await Directory(p.join(fixture.workTree.path, 'lib')).create();
        await File(p.join(fixture.workTree.path, 'lib', '.gitignore'))
            .writeAsString('generated.dart\n');

        final matches = await repository.checkIgnore([
          'lib/generated.dart',
          'generated.dart',
        ]);

        expect(matches, hasLength(1));
        expect(matches.single.path, 'lib/generated.dart');
        expect(matches.single.pattern, 'generated.dart');
        expect(matches.single.source, 'lib/.gitignore');
        expect(matches.single.lineNumber, 1);
      },
    );

    test('supports negation overriding info exclude rules', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(p.join(fixture.workTree.path, '.gitignore'))
          .writeAsString('!keep.tmp\n');
      await File(p.join(fixture.workTree.path, '.git', 'info', 'exclude'))
          .writeAsString('*.tmp\n');

      final matches = await repository.checkIgnore(['drop.tmp', 'keep.tmp']);

      expect(matches, hasLength(1));
      expect(matches.single.path, 'drop.tmp');
      expect(matches.single.pattern, '*.tmp');
      expect(matches.single.source, '.git/info/exclude');
      expect(matches.single.lineNumber, 1);
    });

    test(
      'keeps descendants ignored when their parent directory is ignored',
      () async {
        final fixture = await _createWorkTreeRepository();
        addTearDown(() => fixture.workTree.delete(recursive: true));

        final repository = fixture.repository;
        await File(p.join(fixture.workTree.path, '.gitignore'))
            .writeAsString('build/\n!build/keep.txt\n');

        final matches = await repository.checkIgnore(['build/keep.txt']);

        expect(matches, hasLength(1));
        expect(matches.single.path, 'build/keep.txt');
        expect(matches.single.pattern, 'build/');
        expect(matches.single.source, '.gitignore');
        expect(matches.single.lineNumber, 1);
      },
    );

    test('logs reachable commits from a revision', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');
      await repository.add(['README.md']);
      final firstCommitId = await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello world\n');
      await repository.add(['README.md']);
      final secondCommitId = await repository.commit(
        author: _signature(1700000100),
        message: 'Update README\n',
      );

      final entries = await repository.log('HEAD');
      final limitedEntries = await repository.log('HEAD', maxCount: 1);

      expect(
        entries.map((entry) => entry.objectId),
        orderedEquals([secondCommitId, firstCommitId]),
      );
      expect(entries.first.commit.message, 'Update README\n');
      expect(
        limitedEntries.map((entry) => entry.objectId),
        orderedEquals([secondCommitId]),
      );
    });

    test('walks first-parent history and resolves merge bases', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('base\n');
      await repository.add(['README.md']);
      final baseCommitId = await repository.commit(
        author: _signature(1700000000),
        message: 'Base commit\n',
      );

      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('main\n');
      final mainIndex = await repository.add(['README.md']);
      final mainCommitId = await repository.commitIndex(
        mainIndex,
        author: _signature(1700000100),
        message: 'Main change\n',
        parents: [baseCommitId],
      );

      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('feature\n');
      final featureIndex = await repository.add(['README.md']);
      final featureCommitId = await repository.commitIndex(
        featureIndex,
        author: _signature(1700000200),
        message: 'Feature change\n',
        referenceName: 'refs/heads/feature',
        parents: [baseCommitId],
      );

      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('merged\n');
      final mergeIndex = await repository.add(['README.md']);
      final mergeCommitId = await repository.commitIndex(
        mergeIndex,
        author: _signature(1700000300),
        message: 'Merge feature\n',
        referenceName: 'refs/heads/main',
        parents: [mainCommitId, featureCommitId],
      );

      final logEntries = await repository.log('main');
      final firstParentEntries = await repository.log(
        'main',
        firstParent: true,
      );

      expect(
        logEntries.map((entry) => entry.objectId),
        orderedEquals([
          mergeCommitId,
          mainCommitId,
          featureCommitId,
          baseCommitId,
        ]),
      );
      expect(
        firstParentEntries.map((entry) => entry.objectId),
        orderedEquals([mergeCommitId, mainCommitId, baseCommitId]),
      );
      expect(
        await repository.mergeBase(mainCommitId.hex, featureCommitId.hex),
        baseCommitId,
      );
      expect(await repository.mergeBase('main', 'feature'), featureCommitId);
    });

    test(
      'creates branches from a requested start point and lists them',
      () async {
        final fixture = await _createWorkTreeRepository();
        addTearDown(() => fixture.workTree.delete(recursive: true));

        final repository = fixture.repository;
        final readme = File(p.join(fixture.workTree.path, 'README.md'));
        await readme.writeAsString('base\n');
        await repository.add(['README.md']);
        final firstCommitId = await repository.commit(
          author: _signature(1700000000),
          message: 'Initial commit\n',
        );

        await readme.writeAsString('main\n');
        await repository.add(['README.md']);
        final secondCommitId = await repository.commit(
          author: _signature(1700000100),
          message: 'Main update\n',
        );

        final featureBranch = await repository.branch(
          'feature',
          startPoint: firstCommitId.hex,
        );
        final branches = await repository.branches();

        expect(featureBranch.name, 'feature');
        expect(featureBranch.referenceName, 'refs/heads/feature');
        expect(featureBranch.objectId, firstCommitId);
        expect(featureBranch.current, isFalse);
        expect(branches.map((branch) => branch.name), ['feature', 'main']);
        expect(
          branches.firstWhere((branch) => branch.name == 'feature').objectId,
          firstCommitId,
        );
        expect(
          branches.firstWhere((branch) => branch.name == 'main').objectId,
          secondCommitId,
        );
        expect(
          branches.firstWhere((branch) => branch.name == 'main').current,
          isTrue,
        );
      },
    );

    test('checks out an existing branch and refreshes the work tree', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('main\n');
      await repository.add(['README.md']);
      final baseCommitId = await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await repository.branch('feature');
      await readme.writeAsString('feature\n');
      final featureIndex = await repository.add(['README.md']);
      final featureCommitId = await repository.commitIndex(
        featureIndex,
        author: _signature(1700000100),
        message: 'Feature commit\n',
        referenceName: 'refs/heads/feature',
        parents: [baseCommitId],
      );

      await readme.writeAsString('main\n');
      await repository.add(['README.md']);

      final result = await repository.checkout('feature');
      final headReference = await repository.readReference('HEAD');
      final status = await repository.status();

      expect(result.objectId, featureCommitId);
      expect(result.referenceName, 'refs/heads/feature');
      expect(result.detached, isFalse);
      expect(headReference, isNotNull);
      expect(headReference!.targetReferenceName, 'refs/heads/feature');
      expect(
        await repository.resolveReferenceObjectId('HEAD'),
        featureCommitId,
      );
      expect(await readme.readAsString(), 'feature\n');
      expect(status.isClean, isTrue);
    });

    test('creates and checks out a new branch from HEAD', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');
      await repository.add(['README.md']);
      final commitId = await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      final result = await repository.checkout('topic', create: true);
      final headReference = await repository.readReference('HEAD');
      final topicReference = await repository.readReference('refs/heads/topic');

      expect(result.objectId, commitId);
      expect(result.referenceName, 'refs/heads/topic');
      expect(result.detached, isFalse);
      expect(headReference, isNotNull);
      expect(headReference!.targetReferenceName, 'refs/heads/topic');
      expect(topicReference, isNotNull);
      expect(topicReference!.objectId, commitId);
    });

    test(
      'creates a tracking branch from a remote-tracking start point',
      () async {
        final fixture = await _createWorkTreeRepository();
        addTearDown(() => fixture.workTree.delete(recursive: true));

        final repository = fixture.repository;
        await File(p.join(fixture.workTree.path, 'README.md'))
            .writeAsString('hello\n');
        await repository.add(['README.md']);
        final commitId = await repository.commit(
          author: _signature(1700000000),
          message: 'Initial commit\n',
        );
        await repository.writeRemoteReference('origin', 'main', commitId);

        await repository.checkout(
          'topic',
          create: true,
          startPoint: 'refs/remotes/origin/main',
          track: true,
        );
        final tracking = await repository.branchTracking('topic');

        expect(tracking, isNotNull);
        expect(tracking!.remoteName, 'origin');
        expect(tracking.mergeReferenceName, 'refs/heads/main');
      },
    );

    test('supports detached HEAD checkouts', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');
      await repository.add(['README.md']);
      final commitId = await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      final result = await repository.checkout(commitId.hex);
      final headReference = await repository.readReference('HEAD');

      expect(result.objectId, commitId);
      expect(result.referenceName, isNull);
      expect(result.detached, isTrue);
      expect(headReference, isNotNull);
      expect(headReference!.isDirect, isTrue);
      expect(headReference.objectId, commitId);
    });

    test('records reflog entries for branch updates and HEAD moves', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('main\n');
      await repository.add(['README.md']);
      final initialCommitId = await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await repository.branch('feature', reflogActor: _signature(1700000100));
      await repository.checkout('feature', reflogActor: _signature(1700000200));

      await readme.writeAsString('feature\n');
      await repository.add(['README.md']);
      final featureCommitId = await repository.commit(
        author: _signature(1700000300),
        message: 'Feature commit\n',
      );

      await repository.reset('HEAD^', reflogActor: _signature(1700000400));

      final headEntries = await repository.reflog();
      final featureEntries = await repository.reflog(referenceName: 'feature');
      final mainEntries = await repository.reflog(referenceName: 'main');

      expect(headEntries.map((entry) => entry.message), [
        'reset: moving to HEAD^',
        'commit: Feature commit',
        'checkout: moving from main to feature',
        'commit (initial): Initial commit',
      ]);
      expect(featureEntries.map((entry) => entry.message), [
        'reset: moving to HEAD^',
        'commit: Feature commit',
        'branch: Created from main',
      ]);
      expect(mainEntries.map((entry) => entry.message), [
        'commit (initial): Initial commit',
      ]);
      expect(headEntries.first.previousObjectId, featureCommitId);
      expect(headEntries.first.newObjectId, initialCommitId);
      expect(headEntries.first.actor.timestampSeconds, 1700000400);
      expect(featureEntries.first.previousObjectId, featureCommitId);
      expect(featureEntries.first.newObjectId, initialCommitId);
      expect(featureEntries[1].newObjectId, featureCommitId);
      expect(featureEntries.last.newObjectId, initialCommitId);
    });

    test('rejects checkout when tracked changes are present', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('hello\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );
      await repository.branch('feature');

      await readme.writeAsString('dirty\n');

      expect(repository.checkout('feature'), throwsStateError);
      expect(
        (await repository.readReference('HEAD'))!.targetReferenceName,
        'refs/heads/main',
      );
      expect(await readme.readAsString(), 'dirty\n');
    });

    test(
      'rejects checkout when untracked paths would be overwritten',
      () async {
        final fixture = await _createWorkTreeRepository();
        addTearDown(() => fixture.workTree.delete(recursive: true));

        final repository = fixture.repository;
        final readme = File(p.join(fixture.workTree.path, 'README.md'));
        final notes = File(p.join(fixture.workTree.path, 'notes.txt'));
        await readme.writeAsString('hello\n');
        await repository.add(['README.md']);
        final baseCommitId = await repository.commit(
          author: _signature(1700000000),
          message: 'Initial commit\n',
        );
        await repository.branch('feature');

        await notes.writeAsString('tracked on feature\n');
        final featureIndex = await repository.add(['notes.txt']);
        await repository.commitIndex(
          featureIndex,
          author: _signature(1700000100),
          message: 'Add notes on feature\n',
          referenceName: 'refs/heads/feature',
          parents: [baseCommitId],
        );

        await notes.delete();
        await repository.add(['notes.txt']);
        await notes.writeAsString('untracked local file\n');

        expect(repository.checkout('feature'), throwsStateError);
        expect(
          (await repository.readReference('HEAD'))!.targetReferenceName,
          'refs/heads/main',
        );
        expect(await notes.readAsString(), 'untracked local file\n');
      },
    );

    test('supports soft reset by moving HEAD only', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('one\n');
      await repository.add(['README.md']);
      final firstCommitId = await repository.commit(
        author: _signature(1700000000),
        message: 'First commit\n',
      );

      await readme.writeAsString('two\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000100),
        message: 'Second commit\n',
      );

      final result = await repository.reset(
        firstCommitId.hex,
        mode: GitResetMode.soft,
      );
      final status = await repository.status();

      expect(result.objectId, firstCommitId);
      expect(result.referenceName, 'refs/heads/main');
      expect(result.mode, GitResetMode.soft);
      expect(await repository.resolveReferenceObjectId('HEAD'), firstCommitId);
      expect(await readme.readAsString(), 'two\n');
      expect(status.hasStagedChanges, isTrue);
      expect(status.hasUnstagedChanges, isFalse);
    });

    test('supports mixed reset by updating HEAD and the index', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('one\n');
      await repository.add(['README.md']);
      final firstCommitId = await repository.commit(
        author: _signature(1700000000),
        message: 'First commit\n',
      );

      await readme.writeAsString('two\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000100),
        message: 'Second commit\n',
      );

      final result = await repository.reset(
        firstCommitId.hex,
        mode: GitResetMode.mixed,
      );
      final status = await repository.status();

      expect(result.objectId, firstCommitId);
      expect(result.mode, GitResetMode.mixed);
      expect(await repository.resolveReferenceObjectId('HEAD'), firstCommitId);
      expect(await readme.readAsString(), 'two\n');
      expect(status.hasStagedChanges, isFalse);
      expect(status.hasUnstagedChanges, isTrue);
      expect(status.entries.single.path, 'README.md');
      expect(status.entries.single.workTreeStatus, GitFileStatus.modified);
    });

    test(
      'supports hard reset while keeping unrelated untracked files',
      () async {
        final fixture = await _createWorkTreeRepository();
        addTearDown(() => fixture.workTree.delete(recursive: true));

        final repository = fixture.repository;
        final readme = File(p.join(fixture.workTree.path, 'README.md'));
        final notes = File(p.join(fixture.workTree.path, 'notes.txt'));
        await readme.writeAsString('one\n');
        await repository.add(['README.md']);
        final firstCommitId = await repository.commit(
          author: _signature(1700000000),
          message: 'First commit\n',
        );

        await readme.writeAsString('two\n');
        await repository.add(['README.md']);
        await repository.commit(
          author: _signature(1700000100),
          message: 'Second commit\n',
        );

        await readme.writeAsString('dirty\n');
        await notes.writeAsString('untracked\n');
        final result = await repository.reset(
          firstCommitId.hex,
          mode: GitResetMode.hard,
        );
        final status = await repository.status();

        expect(result.objectId, firstCommitId);
        expect(result.mode, GitResetMode.hard);
        expect(
          await repository.resolveReferenceObjectId('HEAD'),
          firstCommitId,
        );
        expect(await readme.readAsString(), 'one\n');
        expect(await notes.readAsString(), 'untracked\n');
        expect(
          status.entries,
          orderedEquals([
            isA<GitStatusEntry>()
                .having((entry) => entry.path, 'path', 'notes.txt')
                .having(
                  (entry) => entry.workTreeStatus,
                  'workTreeStatus',
                  GitFileStatus.untracked,
                ),
          ]),
        );
      },
    );

    test('restores work tree changes from the index by default', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('hello\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await readme.writeAsString('dirty\n');

      final result = await repository.restore(['README.md']);
      final status = await repository.status();

      expect(result.paths, ['README.md']);
      expect(result.source, isNull);
      expect(result.staged, isFalse);
      expect(result.workTree, isTrue);
      expect(await readme.readAsString(), 'hello\n');
      expect(status.isClean, isTrue);
    });

    test(
      'restores staged entries from HEAD without touching the work tree',
      () async {
        final fixture = await _createWorkTreeRepository();
        addTearDown(() => fixture.workTree.delete(recursive: true));

        final repository = fixture.repository;
        final readme = File(p.join(fixture.workTree.path, 'README.md'));
        await readme.writeAsString('hello\n');
        await repository.add(['README.md']);
        await repository.commit(
          author: _signature(1700000000),
          message: 'Initial commit\n',
        );

        await readme.writeAsString('staged\n');
        await repository.add(['README.md']);

        final result = await repository.restore(
          ['README.md'],
          staged: true,
          workTree: false,
        );
        final status = await repository.status();

        expect(result.paths, ['README.md']);
        expect(result.source, 'HEAD');
        expect(result.staged, isTrue);
        expect(result.workTree, isFalse);
        expect(await readme.readAsString(), 'staged\n');
        expect(status.hasStagedChanges, isFalse);
        expect(status.hasUnstagedChanges, isTrue);
        expect(status.entries.single.workTreeStatus, GitFileStatus.modified);
      },
    );

    test('restores the index and work tree from an explicit source', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('one\n');
      await repository.add(['README.md']);
      final firstCommitId = await repository.commit(
        author: _signature(1700000000),
        message: 'First commit\n',
      );

      await readme.writeAsString('two\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000100),
        message: 'Second commit\n',
      );

      await readme.writeAsString('dirty\n');
      await repository.add(['README.md']);
      await readme.writeAsString('dirty again\n');

      final result = await repository.restore(
        ['README.md'],
        source: firstCommitId.hex,
        staged: true,
      );
      final status = await repository.status();

      expect(result.paths, ['README.md']);
      expect(result.source, firstCommitId.hex);
      expect(result.staged, isTrue);
      expect(result.workTree, isTrue);
      expect(await readme.readAsString(), 'one\n');
      expect(status.hasStagedChanges, isTrue);
      expect(status.hasUnstagedChanges, isFalse);
    });

    test('restores work tree deletions to match a staged removal', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('hello\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await readme.delete();
      await repository.add(['README.md']);
      await readme.writeAsString('recreated\n');

      final result = await repository.restore(['README.md']);
      final status = await repository.status();

      expect(result.paths, ['README.md']);
      expect(await readme.exists(), isFalse);
      expect(status.hasStagedChanges, isTrue);
      expect(status.hasUnstagedChanges, isFalse);
      expect(status.entries.single.indexStatus, GitFileStatus.deleted);
    });

    test('stashes tracked and untracked changes and reapplies them', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      final notes = File(p.join(fixture.workTree.path, 'notes.txt'));
      await readme.writeAsString('base\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await readme.writeAsString('staged\n');
      await repository.add(['README.md']);
      await readme.writeAsString('staged and unstaged\n');
      await notes.writeAsString('untracked\n');

      final stashResult = await repository.stash(
        includeUntracked: true,
        author: _signature(1700000100),
      );
      final stashReflog = await repository.reflog(referenceName: 'stash');
      final statusAfterStash = await repository.status();

      expect(stashResult.created, isTrue);
      expect(stashResult.referenceName, 'refs/stash');
      expect(stashResult.message, 'WIP on main: 25b8733 Initial commit');
      expect(
        stashReflog.first.message,
        'stash: WIP on main: 25b8733 Initial commit',
      );
      expect(await readme.readAsString(), 'base\n');
      expect(await notes.exists(), isFalse);
      expect(statusAfterStash.isClean, isTrue);

      final applyResult = await repository.stashApply(reinstateIndex: true);
      final statusAfterApply = await repository.status();

      expect(applyResult.applied, isTrue);
      expect(applyResult.indexRestored, isTrue);
      expect(applyResult.restoredUntrackedPaths, ['notes.txt']);
      expect(await readme.readAsString(), 'staged and unstaged\n');
      expect(await notes.readAsString(), 'untracked\n');
      expect(
        statusAfterApply.entries,
        orderedEquals([
          isA<GitStatusEntry>()
              .having((entry) => entry.path, 'path', 'README.md')
              .having(
                (entry) => entry.indexStatus,
                'indexStatus',
                GitFileStatus.modified,
              )
              .having(
                (entry) => entry.workTreeStatus,
                'workTreeStatus',
                GitFileStatus.modified,
              ),
          isA<GitStatusEntry>()
              .having((entry) => entry.path, 'path', 'notes.txt')
              .having(
                (entry) => entry.workTreeStatus,
                'workTreeStatus',
                GitFileStatus.untracked,
              ),
        ]),
      );
    });

    test('supports keep-index stashes', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('base\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await readme.writeAsString('staged\n');
      await repository.add(['README.md']);
      await readme.writeAsString('staged and unstaged\n');

      final stashResult = await repository.stash(
        keepIndex: true,
        author: _signature(1700000100),
      );
      final statusAfterStash = await repository.status();

      expect(stashResult.created, isTrue);
      expect(await readme.readAsString(), 'staged\n');
      expect(statusAfterStash.hasStagedChanges, isTrue);
      expect(statusAfterStash.hasUnstagedChanges, isFalse);
      expect(
        statusAfterStash.entries.single.indexStatus,
        GitFileStatus.modified,
      );
    });

    test('stashes and reapplies symlink targets', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      final notes = File(p.join(fixture.workTree.path, 'notes.txt'));
      final linkPath = p.join(fixture.workTree.path, 'current');
      await readme.writeAsString('base\n');
      await notes.writeAsString('notes\n');
      await Link(linkPath).create('README.md');
      await repository.add(['README.md', 'notes.txt', 'current']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await Link(linkPath).delete();
      await Link(linkPath).create('notes.txt');

      final stashResult = await repository.stash(
        author: _signature(1700000100),
      );
      final applyResult = await repository.stashApply();

      expect(stashResult.created, isTrue);
      expect(applyResult.applied, isTrue);
      expect(await Link(linkPath).target(), 'notes.txt');
    }, skip: Platform.isWindows);

    test(
      'lists stash entries, applies selectors, and drops older entries',
      () async {
        final fixture = await _createWorkTreeRepository();
        addTearDown(() => fixture.workTree.delete(recursive: true));

        final repository = fixture.repository;
        final readme = File(p.join(fixture.workTree.path, 'README.md'));
        final notes = File(p.join(fixture.workTree.path, 'notes.txt'));
        await readme.writeAsString('base\n');
        await repository.add(['README.md']);
        await repository.commit(
          author: _signature(1700000000),
          message: 'Initial commit\n',
        );

        await notes.writeAsString('first stash\n');
        await repository.stash(
          message: 'first stash',
          includeUntracked: true,
          author: _signature(1700000100),
        );

        await readme.writeAsString('second stash\n');
        await repository.stash(
          message: 'second stash',
          author: _signature(1700000200),
        );

        final entries = await repository.stashList();
        final applyOlderResult = await repository.stashApply(
          revision: 'stash@{1}',
        );
        final dropped = await repository.stashDrop(revision: 'stash@{1}');
        final remainingEntries = await repository.stashList();

        expect(entries, hasLength(2));
        expect(entries[0].revision, 'stash@{0}');
        expect(entries[0].message, 'On main: second stash');
        expect(entries[1].revision, 'stash@{1}');
        expect(entries[1].message, 'On main: first stash');
        expect(applyOlderResult.applied, isTrue);
        expect(await notes.readAsString(), 'first stash\n');
        expect(dropped.revision, 'stash@{1}');
        expect(dropped.remainingCount, 1);
        expect(remainingEntries, hasLength(1));
        expect(remainingEntries.single.revision, 'stash@{0}');
        expect(remainingEntries.single.message, 'On main: second stash');
      },
    );

    test('pops a stash and removes it from refs/stash', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('base\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await readme.writeAsString('stashed\n');
      await repository.stash(author: _signature(1700000100));

      final popResult = await repository.stashPop();

      expect(popResult.applied, isTrue);
      expect(popResult.dropped, isTrue);
      expect(await readme.readAsString(), 'stashed\n');
      expect(await repository.stashList(), isEmpty);
      expect(await repository.resolveReferenceObjectId('refs/stash'), isNull);
    });

    test('keeps the stash when pop encounters a conflict', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('base\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await readme.writeAsString('stashed\n');
      await repository.stash(author: _signature(1700000100));
      await readme.writeAsString('conflicting\n');

      final popResult = await repository.stashPop();
      final conflicts = await repository.conflicts();

      expect(popResult.status, GitStashPopStatus.conflict);
      expect(popResult.dropped, isFalse);
      expect(conflicts, hasLength(1));
      expect(conflicts.single.path, 'README.md');
      expect(conflicts.single.base, isNotNull);
      expect(conflicts.single.ours, isNotNull);
      expect(conflicts.single.theirs, isNotNull);
      expect(await readme.readAsString(), 'conflicting\n');
      expect(await repository.stashList(), hasLength(1));
    });

    test('writes and reads a symbolic reference', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final reference = GitReference.symbolic('HEAD', 'refs/heads/main');

      await repository.writeReference(reference);
      final restored = await repository.readReference('HEAD');

      expect(restored, isNotNull);
      expect(restored!.isSymbolic, isTrue);
      expect(restored.targetReferenceName, 'refs/heads/main');
    });

    test('resolves a symbolic reference chain to an object id', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final objectId = GitObjectId.fromHex(
        '0123456789abcdef0123456789abcdef01234567',
      );

      await repository.writeReference(
        GitReference.direct('refs/heads/main', objectId),
      );
      await repository.writeReference(
        GitReference.symbolic('HEAD', 'refs/heads/main'),
      );

      final resolved = await repository.resolveReferenceObjectId('HEAD');

      expect(resolved, objectId);
    });

    test('deletes a stored reference', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await repository.writeReference(
        GitReference.symbolic('HEAD', 'refs/heads/main'),
      );

      final deleted = await repository.deleteReference('HEAD');
      final restored = await repository.readReference('HEAD');

      expect(deleted, isTrue);
      expect(restored, isNull);
    });

    test('returns false when deleting a missing reference', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;

      expect(await repository.deleteReference('refs/heads/missing'), isFalse);
    });

    test('writes, reads, lists, and deletes remotes from config', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final origin = await repository.setRemote(
        GitRemote(
          name: 'origin',
          url: 'https://example.com/origin.git',
          fetchRefSpecs: [
            GitRefSpec.parse('+refs/heads/*:refs/remotes/origin/*'),
          ],
        ),
      );
      await repository.setRemote(
        GitRemote(
          name: 'upstream',
          url: 'https://example.com/upstream.git',
          pushUrl: 'ssh://example.com/upstream.git',
          fetchRefSpecs: [
            GitRefSpec.parse('+refs/heads/*:refs/remotes/upstream/*'),
          ],
        ),
      );

      final remotes = await repository.remotes();
      final restoredOrigin = await repository.remote('origin');
      final deleted = await repository.deleteRemote('upstream');
      final configContents = await File(repository.configFilePath)
          .readAsString();

      expect(origin.name, 'origin');
      expect(origin.url, 'https://example.com/origin.git');
      expect(remotes.map((remote) => remote.name), ['origin', 'upstream']);
      expect(restoredOrigin, isNotNull);
      expect(
        restoredOrigin!.fetchRefSpecs.single.storageValue,
        '+refs/heads/*:refs/remotes/origin/*',
      );
      expect(deleted, isTrue);
      expect(await repository.remote('upstream'), isNull);
      expect(configContents, contains('[remote "origin"]'));
      expect(configContents, contains('url = https://example.com/origin.git'));
      expect(configContents, isNot(contains('[remote "upstream"]')));
    });

    test('round-trips extended SSH remote settings in config', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final remote = await repository.setRemote(
        GitRemote(
          name: 'origin',
          url: 'ssh://127.0.0.1/repo.git',
          sshPrivateKeyPath: '/tmp/id_ed25519',
          sshPrivateKey: 'PRIVATE KEY DATA',
          sshPrivateKeyPassphrase: 'secret',
          sshPassword: 'password',
          sshKnownHostsPath: '/tmp/known_hosts',
          sshHostKeyFingerprints: const [
            'aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99',
          ],
        ),
      );
      final restoredRemote = await repository.remote('origin');

      expect(remote.sshPrivateKeyPath, '/tmp/id_ed25519');
      expect(restoredRemote, isNotNull);
      expect(restoredRemote!.sshPrivateKey, 'PRIVATE KEY DATA');
      expect(restoredRemote.sshPrivateKeyPassphrase, 'secret');
      expect(restoredRemote.sshPassword, 'password');
      expect(restoredRemote.sshKnownHostsPath, '/tmp/known_hosts');
      expect(restoredRemote.sshHostKeyFingerprints, [
        'aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99',
      ]);
    });

    test('preserves unrelated config sections when updating remotes', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(repository.configFilePath).writeAsString(
        '[core]\n'
        '\trepositoryformatversion = 0\n',
      );

      await repository.setRemote(
        GitRemote(name: 'origin', url: 'https://example.com/origin.git'),
      );

      final configContents = await File(repository.configFilePath)
          .readAsString();

      expect(configContents, contains('[core]'));
      expect(configContents, contains('repositoryformatversion = 0'));
      expect(configContents, contains('[remote "origin"]'));
    });

    test('writes, reads, and deletes branch tracking config', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final tracking = await repository.setBranchTracking(
        const GitBranchTracking(
          branchName: 'main',
          referenceName: 'refs/heads/main',
          remoteName: 'origin',
          mergeReferenceName: 'refs/heads/main',
        ),
      );
      final restored = await repository.branchTracking('main');
      final deleted = await repository.deleteBranchTracking('main');
      final configContents = await File(repository.configFilePath)
          .readAsString();

      expect(tracking.referenceName, 'refs/heads/main');
      expect(restored, isNotNull);
      expect(restored!.remoteName, 'origin');
      expect(restored.mergeReferenceName, 'refs/heads/main');
      expect(deleted, isTrue);
      expect(await repository.branchTracking('main'), isNull);
      expect(configContents, isNot(contains('[branch "main"]')));
    });

    test('writes, lists, and deletes remote tracking references', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');
      await repository.add(['README.md']);
      final commitId = await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      final writtenReference = await repository.writeRemoteReference(
        'origin',
        'main',
        commitId,
      );
      await repository.writeRemoteReference('origin', 'topic/demo', commitId);

      final originReferences = await repository.remoteReferences('origin');
      final allReferences = await repository.remoteReferences();
      final deleted = await repository.deleteRemoteReference('origin', 'main');

      expect(writtenReference.referenceName, 'refs/remotes/origin/main');
      expect(
        originReferences.map((reference) => reference.referenceName),
        orderedEquals([
          'refs/remotes/origin/main',
          'refs/remotes/origin/topic/demo',
        ]),
      );
      expect(allReferences, hasLength(2));
      expect(deleted, isTrue);
      expect(await repository.remoteReferences('origin'), hasLength(1));
    });

    test('fetches branches from a configured filesystem remote', () async {
      final localFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createWorkTreeRepository();
      addTearDown(() => localFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.workTree.delete(recursive: true));

      final localRepository = localFixture.repository;
      final remoteRepository = remoteFixture.repository;
      final remoteReadme = File(
        p.join(remoteFixture.workTree.path, 'README.md'),
      );

      await remoteReadme.writeAsString('base\n');
      await remoteRepository.add(['README.md']);
      final baseCommitId = await remoteRepository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );
      await remoteRepository.branch('feature');

      await remoteReadme.writeAsString('feature\n');
      final featureIndex = await remoteRepository.add(['README.md']);
      final featureCommitId = await remoteRepository.commitIndex(
        featureIndex,
        author: _signature(1700000100),
        message: 'Feature commit\n',
        referenceName: 'refs/heads/feature',
        parents: [baseCommitId],
      );

      await localRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.workTree.path),
      );

      final firstFetch = await localRepository.fetch('origin');
      final secondFetch = await localRepository.fetch('origin');
      final trackedReferences = await localRepository.remoteReferences(
        'origin',
      );

      expect(firstFetch.remoteName, 'origin');
      expect(firstFetch.remoteUrl, remoteFixture.workTree.path);
      expect(
        firstFetch.references.map(
          (reference) => reference.destinationReferenceName,
        ),
        orderedEquals([
          'refs/remotes/origin/feature',
          'refs/remotes/origin/main',
        ]),
      );
      expect(
        firstFetch.references.map((reference) => reference.status),
        everyElement(GitFetchReferenceStatus.updated),
      );
      expect(firstFetch.objectsFetched, greaterThan(0));
      expect(
        trackedReferences.map((reference) => reference.referenceName),
        orderedEquals([
          'refs/remotes/origin/feature',
          'refs/remotes/origin/main',
        ]),
      );
      expect(
        trackedReferences
            .firstWhere((reference) => reference.name == 'feature')
            .objectId,
        featureCommitId,
      );
      expect(
        trackedReferences
            .firstWhere((reference) => reference.name == 'main')
            .objectId,
        baseCommitId,
      );
      expect(
        (await localRepository.show('refs/remotes/origin/feature'))?.type,
        GitObjectType.commit,
      );
      // Пакет с сети разбирается в loose-объекты и в VFS целиком не остаётся.
      expect(await localRepository.readLooseObject(featureCommitId), isNotNull);
      expect(
        (await localRepository.readObject(featureCommitId))?.type,
        GitObjectType.commit,
      );
      expect(
        secondFetch.references.map((reference) => reference.status),
        everyElement(GitFetchReferenceStatus.upToDate),
      );
      expect(secondFetch.objectsFetched, 0);
    });

    test('supports dry-run fetches without writing refs or objects', () async {
      final localFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createWorkTreeRepository();
      addTearDown(() => localFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.workTree.delete(recursive: true));

      final localRepository = localFixture.repository;
      final remoteRepository = remoteFixture.repository;
      final remoteReadme = File(
        p.join(remoteFixture.workTree.path, 'README.md'),
      );

      await remoteReadme.writeAsString('hello\n');
      await remoteRepository.add(['README.md']);
      final commitId = await remoteRepository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await localRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.workTree.path),
      );

      final result = await localRepository.fetch('origin', dryRun: true);

      expect(result.dryRun, isTrue);
      expect(result.references, hasLength(1));
      expect(
        result.references.single.destinationReferenceName,
        'refs/remotes/origin/main',
      );
      expect(result.references.single.status, GitFetchReferenceStatus.updated);
      expect(result.objectsFetched, greaterThan(0));
      expect(await localRepository.remoteReferences('origin'), isEmpty);
      expect(await localRepository.readLooseObject(commitId), isNull);
    });

    test(
      'fetches packed objects from a configured filesystem remote',
      () async {
        final localFixture = await _createWorkTreeRepository();
        final remoteFixture = await _createWorkTreeRepository();
        addTearDown(() => localFixture.workTree.delete(recursive: true));
        addTearDown(() => remoteFixture.workTree.delete(recursive: true));

        final localRepository = localFixture.repository;
        final remoteRepository = remoteFixture.repository;
        final remoteReadme = File(
          p.join(remoteFixture.workTree.path, 'README.md'),
        );

        await remoteReadme.writeAsString('packed\n');
        await remoteRepository.add(['README.md']);
        final commitId = await remoteRepository.commit(
          author: _signature(1700000000),
          message: 'Packed commit\n',
        );
        final commit = const GitCommitCodec().decode(
          (await remoteRepository.readLooseObject(commitId))!.bytes,
        );
        final treeEntries = const GitTreeCodec().decode(
          (await remoteRepository.readLooseObject(commit.tree))!.bytes,
        );
        await _packRepositoryObjects(remoteRepository, [
          treeEntries.single.objectId,
          commit.tree,
          commitId,
        ]);

        await localRepository.setRemote(
          GitRemote(name: 'origin', url: remoteFixture.workTree.path),
        );

        final result = await localRepository.fetch('origin');

        expect(result.references, hasLength(1));
        expect(
          result.references.single.status,
          GitFetchReferenceStatus.updated,
        );
        expect(
          await localRepository.resolveReferenceObjectId(
            'refs/remotes/origin/main',
          ),
          commitId,
        );
        expect(
          (await localRepository.readObject(commitId))?.type,
          GitObjectType.commit,
        );
      },
    );

    test('fetches packed objects from a configured HTTP remote', () async {
      final localFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createWorkTreeRepository();
      addTearDown(() => localFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.workTree.delete(recursive: true));

      final localRepository = localFixture.repository;
      final remoteRepository = remoteFixture.repository;
      final remoteReadme = File(
        p.join(remoteFixture.workTree.path, 'README.md'),
      );

      await remoteReadme.writeAsString('packed http\n');
      await remoteRepository.add(['README.md']);
      final commitId = await remoteRepository.commit(
        author: _signature(1700000000),
        message: 'Packed HTTP commit\n',
      );
      await _packAllLooseObjects(remoteRepository);
      await _writeHttpServerInfo(remoteRepository);
      final serverInfo = await _serveGitDirectory(
        remoteRepository.gitDirectoryPath,
      );
      addTearDown(() => serverInfo.server.close(force: true));

      await localRepository.setRemote(
        GitRemote(name: 'origin', url: serverInfo.baseUrl),
      );

      final result = await localRepository.fetch('origin');

      expect(result.references, hasLength(1));
      expect(result.references.single.status, GitFetchReferenceStatus.updated);
      expect(
        await localRepository.resolveReferenceObjectId(
          'refs/remotes/origin/main',
        ),
        commitId,
      );
      expect(
        (await localRepository.readObject(commitId))?.type,
        GitObjectType.commit,
      );
    });

    test(
      'fetches from a smart HTTP remote with configured auth headers',
      () async {
        final localFixture = await _createWorkTreeRepository();
        final remoteFixture = await _createWorkTreeRepository();
        addTearDown(() => localFixture.workTree.delete(recursive: true));
        addTearDown(() => remoteFixture.workTree.delete(recursive: true));

        final localRepository = localFixture.repository;
        final remoteRepository = remoteFixture.repository;
        await File(p.join(remoteFixture.workTree.path, 'README.md'))
            .writeAsString('smart fetch\n');
        await remoteRepository.add(['README.md']);
        final commitId = await remoteRepository.commit(
          author: _signature(1700000000),
          message: 'Smart HTTP commit\n',
        );
        final serverInfo = await _serveSmartHttpRepository(
          remoteRepository,
          requiredHeaders: const {'Authorization': 'Bearer test-token'},
        );
        addTearDown(() => serverInfo.server.close(force: true));

        await localRepository.setRemote(
          GitRemote(name: 'origin', url: serverInfo.baseUrl),
        );

        await expectLater(localRepository.fetch('origin'), throwsStateError);

        await localRepository.setRemote(
          GitRemote(
            name: 'origin',
            url: serverInfo.baseUrl,
            httpHeaders: const {'Authorization': 'Bearer test-token'},
          ),
        );

        final result = await localRepository.fetch('origin');

        expect(
          result.references.single.status,
          GitFetchReferenceStatus.updated,
        );
        expect(
          await localRepository.resolveReferenceObjectId(
            'refs/remotes/origin/main',
          ),
          commitId,
        );
        expect(
          (await localRepository.readObject(commitId))?.type,
          GitObjectType.commit,
        );
      },
    );

    test('fetches larger packed histories from filesystem remotes', () async {
      final localFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createWorkTreeRepository();
      addTearDown(() => localFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.workTree.delete(recursive: true));

      final localRepository = localFixture.repository;
      final remoteRepository = remoteFixture.repository;
      final remoteReadme = File(
        p.join(remoteFixture.workTree.path, 'README.md'),
      );

      GitObjectId? headCommitId;
      for (var index = 0; index < 12; index++) {
        await remoteReadme.writeAsString('commit $index\n');
        await remoteRepository.add(['README.md']);
        headCommitId = await remoteRepository.commit(
          author: _signature(1700000000 + index),
          message: 'Commit $index\n',
        );
      }
      await _packAllLooseObjects(remoteRepository);

      await localRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.workTree.path),
      );

      final fetchResult = await localRepository.fetch('origin');
      final logEntries = await localRepository.log(
        'refs/remotes/origin/main',
        maxCount: 20,
      );

      expect(
        fetchResult.references.single.status,
        GitFetchReferenceStatus.updated,
      );
      expect(logEntries, hasLength(12));
      expect(logEntries.first.objectId, headCommitId);
    });

    test('fetches larger packed histories from a smart HTTP remote', () async {
      final localFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createWorkTreeRepository();
      addTearDown(() => localFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.workTree.delete(recursive: true));

      final localRepository = localFixture.repository;
      final remoteRepository = remoteFixture.repository;
      final remoteReadme = File(
        p.join(remoteFixture.workTree.path, 'README.md'),
      );

      GitObjectId? headCommitId;
      for (var index = 0; index < 12; index++) {
        await remoteReadme.writeAsString('smart commit $index\n');
        await remoteRepository.add(['README.md']);
        headCommitId = await remoteRepository.commit(
          author: _signature(1700001000 + index),
          message: 'Smart commit $index\n',
        );
      }
      await _packAllLooseObjects(remoteRepository);
      final serverInfo = await _serveSmartHttpRepository(remoteRepository);
      addTearDown(() => serverInfo.server.close(force: true));

      await localRepository.setRemote(
        GitRemote(name: 'origin', url: serverInfo.baseUrl),
      );

      final fetchResult = await localRepository.fetch('origin');
      final logEntries = await localRepository.log(
        'refs/remotes/origin/main',
        maxCount: 20,
      );

      expect(
        fetchResult.references.single.status,
        GitFetchReferenceStatus.updated,
      );
      expect(logEntries, hasLength(12));
      expect(logEntries.first.objectId, headCommitId);
    });

    test('supports multiple wildcard fetch refspecs', () async {
      final localFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createWorkTreeRepository();
      addTearDown(() => localFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.workTree.delete(recursive: true));

      final localRepository = localFixture.repository;
      final remoteRepository = remoteFixture.repository;
      final remoteReadme = File(
        p.join(remoteFixture.workTree.path, 'README.md'),
      );

      await remoteReadme.writeAsString('hello\n');
      await remoteRepository.add(['README.md']);
      final commitId = await remoteRepository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );
      await remoteRepository.branch('releases/alpha/one');
      await remoteRepository.branch('releases/beta/two');

      await localRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.workTree.path),
      );

      final result = await localRepository.fetch(
        'origin',
        refSpecs: [
          GitRefSpec.parse(
            'refs/heads/releases/*/*:refs/remotes/origin/releases/*/*',
          ),
        ],
      );

      expect(
        result.references.map(
          (reference) => reference.destinationReferenceName,
        ),
        orderedEquals([
          'refs/remotes/origin/releases/alpha/one',
          'refs/remotes/origin/releases/beta/two',
        ]),
      );
      expect(
        await localRepository.resolveReferenceObjectId(
          'refs/remotes/origin/releases/alpha/one',
        ),
        commitId,
      );
      expect(
        await localRepository.resolveReferenceObjectId(
          'refs/remotes/origin/releases/beta/two',
        ),
        commitId,
      );
    });

    test(
      'pushes the current branch to a configured bare filesystem remote',
      () async {
        final localFixture = await _createWorkTreeRepository();
        final remoteFixture = await _createBareRepository();
        addTearDown(() => localFixture.workTree.delete(recursive: true));
        addTearDown(() => remoteFixture.directory.delete(recursive: true));

        final localRepository = localFixture.repository;
        final remoteRepository = remoteFixture.repository;
        await File(p.join(localFixture.workTree.path, 'README.md'))
            .writeAsString('hello\n');
        await localRepository.add(['README.md']);
        final commitId = await localRepository.commit(
          author: _signature(1700000000),
          message: 'Initial commit\n',
        );

        await localRepository.setRemote(
          GitRemote(name: 'origin', url: remoteFixture.directory.path),
        );

        final firstPush = await localRepository.push('origin');
        final secondPush = await localRepository.push('origin');

        expect(firstPush.references, hasLength(1));
        expect(
          firstPush.references.single.destinationReferenceName,
          'refs/heads/main',
        );
        expect(
          firstPush.references.single.status,
          GitPushReferenceStatus.updated,
        );
        expect(firstPush.objectsPushed, greaterThan(0));
        expect(
          await remoteRepository.resolveReferenceObjectId('refs/heads/main'),
          commitId,
        );
        // Пакет с сети разбирается в loose-объекты и в VFS целиком не остаётся.
        expect(await remoteRepository.readLooseObject(commitId), isNotNull);
        expect(
          (await remoteRepository.readObject(commitId))?.type,
          GitObjectType.commit,
        );
        expect(
          secondPush.references.single.status,
          GitPushReferenceStatus.upToDate,
        );
        expect(secondPush.objectsPushed, 0);
      },
    );

    test('supports dry-run pushes without writing refs or objects', () async {
      final localFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createBareRepository();
      addTearDown(() => localFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.directory.delete(recursive: true));

      final localRepository = localFixture.repository;
      final remoteRepository = remoteFixture.repository;
      await File(p.join(localFixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');
      await localRepository.add(['README.md']);
      final commitId = await localRepository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await localRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.directory.path),
      );

      final result = await localRepository.push('origin', dryRun: true);

      expect(result.dryRun, isTrue);
      expect(result.references.single.status, GitPushReferenceStatus.updated);
      expect(result.objectsPushed, greaterThan(0));
      expect(
        await remoteRepository.resolveReferenceObjectId('refs/heads/main'),
        isNull,
      );
      expect(await remoteRepository.readLooseObject(commitId), isNull);
    });

    test('supports deleting remote refs through push refspecs', () async {
      final localFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createBareRepository();
      addTearDown(() => localFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.directory.delete(recursive: true));

      final localRepository = localFixture.repository;
      final remoteRepository = remoteFixture.repository;
      final readme = File(p.join(localFixture.workTree.path, 'README.md'));

      await readme.writeAsString('hello\n');
      await localRepository.add(['README.md']);
      final commitId = await localRepository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );
      await localRepository.branch('feature');
      await localRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.directory.path),
      );

      await localRepository.push(
        'origin',
        refSpecs: [
          GitRefSpec.parse('refs/heads/main:refs/heads/main'),
          GitRefSpec.parse('refs/heads/feature:refs/heads/feature'),
        ],
      );

      final deleteResult = await localRepository.push(
        'origin',
        refSpecs: [GitRefSpec.parse(':refs/heads/feature')],
      );
      final secondDeleteResult = await localRepository.push(
        'origin',
        refSpecs: [GitRefSpec.parse(':refs/heads/feature')],
      );

      expect(
        await remoteRepository.resolveReferenceObjectId('refs/heads/main'),
        commitId,
      );
      expect(
        deleteResult.references.single.status,
        GitPushReferenceStatus.deleted,
      );
      expect(deleteResult.references.single.sourceReferenceName, isNull);
      expect(deleteResult.references.single.objectId, isNull);
      expect(
        await remoteRepository.resolveReferenceObjectId('refs/heads/feature'),
        isNull,
      );
      expect(
        secondDeleteResult.references.single.status,
        GitPushReferenceStatus.upToDate,
      );
    });

    test('supports wildcard delete push refspecs', () async {
      final localFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createBareRepository();
      addTearDown(() => localFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.directory.delete(recursive: true));

      final localRepository = localFixture.repository;
      final remoteRepository = remoteFixture.repository;
      final readme = File(p.join(localFixture.workTree.path, 'README.md'));

      await readme.writeAsString('hello\n');
      await localRepository.add(['README.md']);
      await localRepository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );
      await localRepository.branch('releases/alpha/one');
      await localRepository.branch('releases/beta/two');
      await localRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.directory.path),
      );

      await localRepository.push(
        'origin',
        refSpecs: [
          GitRefSpec.parse('refs/heads/releases/*/*:refs/heads/releases/*/*'),
        ],
      );

      final deleteResult = await localRepository.push(
        'origin',
        refSpecs: [GitRefSpec.parse(':refs/heads/releases/*/*')],
      );

      expect(deleteResult.references, hasLength(2));
      expect(
        deleteResult.references.map((reference) => reference.status),
        everyElement(GitPushReferenceStatus.deleted),
      );
      expect(
        await remoteRepository.resolveReferenceObjectId(
          'refs/heads/releases/alpha/one',
        ),
        isNull,
      );
      expect(
        await remoteRepository.resolveReferenceObjectId(
          'refs/heads/releases/beta/two',
        ),
        isNull,
      );
    });

    test('supports wildcard push refspecs', () async {
      final localFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createBareRepository();
      addTearDown(() => localFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.directory.delete(recursive: true));

      final localRepository = localFixture.repository;
      final remoteRepository = remoteFixture.repository;
      final readme = File(p.join(localFixture.workTree.path, 'README.md'));

      await readme.writeAsString('base\n');
      await localRepository.add(['README.md']);
      final baseCommitId = await localRepository.commit(
        author: _signature(1700000000),
        message: 'Base commit\n',
      );
      await localRepository.branch('feature');

      await readme.writeAsString('feature\n');
      final featureIndex = await localRepository.add(['README.md']);
      final featureCommitId = await localRepository.commitIndex(
        featureIndex,
        author: _signature(1700000100),
        message: 'Feature commit\n',
        referenceName: 'refs/heads/feature',
        parents: [baseCommitId],
      );

      await localRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.directory.path),
      );

      final result = await localRepository.push(
        'origin',
        refSpecs: [GitRefSpec.parse('refs/heads/*:refs/heads/*')],
      );

      expect(
        result.references.map(
          (reference) => reference.destinationReferenceName,
        ),
        orderedEquals(['refs/heads/feature', 'refs/heads/main']),
      );
      expect(
        result.references.map((reference) => reference.status),
        everyElement(GitPushReferenceStatus.updated),
      );
      expect(
        await remoteRepository.resolveReferenceObjectId('refs/heads/main'),
        baseCommitId,
      );
      expect(
        await remoteRepository.resolveReferenceObjectId('refs/heads/feature'),
        featureCommitId,
      );
    });

    test('supports multiple wildcard push refspecs', () async {
      final localFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createBareRepository();
      addTearDown(() => localFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.directory.delete(recursive: true));

      final localRepository = localFixture.repository;
      final remoteRepository = remoteFixture.repository;
      final readme = File(p.join(localFixture.workTree.path, 'README.md'));

      await readme.writeAsString('base\n');
      await localRepository.add(['README.md']);
      final commitId = await localRepository.commit(
        author: _signature(1700000000),
        message: 'Base commit\n',
      );
      await localRepository.branch('releases/alpha/one');
      await localRepository.branch('releases/beta/two');
      await localRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.directory.path),
      );

      final result = await localRepository.push(
        'origin',
        refSpecs: [
          GitRefSpec.parse('refs/heads/releases/*/*:refs/heads/archive/*/*'),
        ],
      );

      expect(
        result.references.map(
          (reference) => reference.destinationReferenceName,
        ),
        orderedEquals([
          'refs/heads/archive/alpha/one',
          'refs/heads/archive/beta/two',
        ]),
      );
      expect(
        await remoteRepository.resolveReferenceObjectId(
          'refs/heads/archive/alpha/one',
        ),
        commitId,
      );
      expect(
        await remoteRepository.resolveReferenceObjectId(
          'refs/heads/archive/beta/two',
        ),
        commitId,
      );
    });

    test('uses pushUrl when pushing to a configured remote', () async {
      final localFixture = await _createWorkTreeRepository();
      final fetchRemoteFixture = await _createBareRepository();
      final pushRemoteFixture = await _createBareRepository();
      addTearDown(() => localFixture.workTree.delete(recursive: true));
      addTearDown(() => fetchRemoteFixture.directory.delete(recursive: true));
      addTearDown(() => pushRemoteFixture.directory.delete(recursive: true));

      final localRepository = localFixture.repository;
      await File(p.join(localFixture.workTree.path, 'README.md'))
          .writeAsString('hello\n');
      await localRepository.add(['README.md']);
      final commitId = await localRepository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      await localRepository.setRemote(
        GitRemote(
          name: 'origin',
          url: fetchRemoteFixture.directory.path,
          pushUrl: pushRemoteFixture.directory.path,
        ),
      );

      final result = await localRepository.push('origin');

      expect(result.remoteUrl, pushRemoteFixture.directory.path);
      expect(
        await pushRemoteFixture.repository.resolveReferenceObjectId(
          'refs/heads/main',
        ),
        commitId,
      );
      expect(
        await fetchRemoteFixture.repository.resolveReferenceObjectId(
          'refs/heads/main',
        ),
        isNull,
      );
    });

    test('pushes to a smart HTTP remote', () async {
      final localFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createBareRepository();
      addTearDown(() => localFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.directory.delete(recursive: true));

      final localRepository = localFixture.repository;
      await File(p.join(localFixture.workTree.path, 'README.md'))
          .writeAsString('smart push\n');
      await localRepository.add(['README.md']);
      final commitId = await localRepository.commit(
        author: _signature(1700000000),
        message: 'Smart push\n',
      );
      final serverInfo = await _serveSmartHttpRepository(
        remoteFixture.repository,
        requiredHeaders: const {'Authorization': 'Bearer smart-push'},
        allowPush: true,
      );
      addTearDown(() => serverInfo.server.close(force: true));

      await localRepository.setRemote(
        GitRemote(
          name: 'origin',
          url: serverInfo.baseUrl,
          httpHeaders: const {'Authorization': 'Bearer smart-push'},
        ),
      );

      final result = await localRepository.push('origin');

      expect(result.references.single.status, GitPushReferenceStatus.updated);
      expect(
        await remoteFixture.repository.resolveReferenceObjectId(
          'refs/heads/main',
        ),
        commitId,
      );
      expect(
        (await remoteFixture.repository.readObject(commitId))?.type,
        GitObjectType.commit,
      );
    });

    test('deletes remote refs through a smart HTTP push', () async {
      final localFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createBareRepository();
      addTearDown(() => localFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.directory.delete(recursive: true));

      final localRepository = localFixture.repository;
      await File(p.join(localFixture.workTree.path, 'README.md'))
          .writeAsString('smart delete\n');
      await localRepository.add(['README.md']);
      await localRepository.commit(
        author: _signature(1700000000),
        message: 'Smart delete\n',
      );
      final headObjectId = await localRepository.revParse('HEAD');
      await remoteFixture.repository.writeReference(
        GitReference.direct('refs/heads/topic', headObjectId!),
      );
      final serverInfo = await _serveSmartHttpRepository(
        remoteFixture.repository,
        allowPush: true,
      );
      addTearDown(() => serverInfo.server.close(force: true));

      await localRepository.setRemote(
        GitRemote(name: 'origin', url: serverInfo.baseUrl),
      );

      final result = await localRepository.push(
        'origin',
        refSpecs: [GitRefSpec.parse(':refs/heads/topic')],
      );

      expect(result.references.single.status, GitPushReferenceStatus.deleted);
      expect(
        await remoteFixture.repository.resolveReferenceObjectId(
          'refs/heads/topic',
        ),
        isNull,
      );
    });

    test('sets upstream tracking when requested during push', () async {
      final localFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createBareRepository();
      addTearDown(() => localFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.directory.delete(recursive: true));

      final localRepository = localFixture.repository;
      await File(p.join(localFixture.workTree.path, 'README.md'))
          .writeAsString('push upstream\n');
      await localRepository.add(['README.md']);
      await localRepository.commit(
        author: _signature(1700000000),
        message: 'Push upstream\n',
      );
      await localRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.directory.path),
      );

      final result = await localRepository.push('origin', setUpstream: true);
      final tracking = await localRepository.branchTracking('main');

      expect(result.tracking, isNotNull);
      expect(result.tracking!.remoteName, 'origin');
      expect(tracking, isNotNull);
      expect(tracking!.mergeReferenceName, 'refs/heads/main');
    });

    test('rejects non-fast-forward pushes unless forced', () async {
      final localFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createBareRepository();
      final otherFixture = await _createWorkTreeRepository();
      addTearDown(() => localFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.directory.delete(recursive: true));
      addTearDown(() => otherFixture.workTree.delete(recursive: true));

      final localRepository = localFixture.repository;
      final remoteRepository = remoteFixture.repository;
      final otherRepository = otherFixture.repository;
      final localReadme = File(p.join(localFixture.workTree.path, 'README.md'));
      final otherReadme = File(p.join(otherFixture.workTree.path, 'README.md'));

      await localReadme.writeAsString('base\n');
      await localRepository.add(['README.md']);
      final baseCommitId = await localRepository.commit(
        author: _signature(1700000000),
        message: 'Base commit\n',
      );

      await localRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.directory.path),
      );
      await otherRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.directory.path),
      );

      await localRepository.push('origin');

      await otherRepository.fetch('origin');
      await otherRepository.checkout(
        'main',
        create: true,
        startPoint: 'refs/remotes/origin/main',
        force: true,
      );
      await otherReadme.writeAsString('remote change\n');
      await otherRepository.add(['README.md']);
      final remoteCommitId = await otherRepository.commit(
        author: _signature(1700000100),
        message: 'Remote change\n',
      );
      await otherRepository.push('origin');

      await localReadme.writeAsString('local change\n');
      await localRepository.add(['README.md']);
      final localCommitId = await localRepository.commit(
        author: _signature(1700000200),
        message: 'Local change\n',
      );

      final rejectedPush = await localRepository.push('origin');
      final rejectedRemoteHead = await remoteRepository
          .resolveReferenceObjectId('refs/heads/main');
      final forcedPush = await localRepository.push('origin', force: true);

      expect(baseCommitId, isNot(remoteCommitId));
      expect(
        rejectedPush.references.single.status,
        GitPushReferenceStatus.rejected,
      );
      expect(rejectedRemoteHead, remoteCommitId);
      expect(
        forcedPush.references.single.status,
        GitPushReferenceStatus.updated,
      );
      expect(forcedPush.references.single.forced, isTrue);
      expect(
        await remoteRepository.resolveReferenceObjectId('refs/heads/main'),
        localCommitId,
      );
    });

    test(
      'pull fast-forwards the current branch and updates the work tree',
      () async {
        final sourceFixture = await _createWorkTreeRepository();
        final remoteFixture = await _createBareRepository();
        final localFixture = await _createWorkTreeRepository();
        addTearDown(() => sourceFixture.workTree.delete(recursive: true));
        addTearDown(() => remoteFixture.directory.delete(recursive: true));
        addTearDown(() => localFixture.workTree.delete(recursive: true));

        final sourceRepository = sourceFixture.repository;
        final localRepository = localFixture.repository;
        final sourceReadme = File(
          p.join(sourceFixture.workTree.path, 'README.md'),
        );
        final localReadme = File(
          p.join(localFixture.workTree.path, 'README.md'),
        );

        await sourceRepository.setRemote(
          GitRemote(name: 'origin', url: remoteFixture.directory.path),
        );
        await localRepository.setRemote(
          GitRemote(name: 'origin', url: remoteFixture.directory.path),
        );

        await sourceReadme.writeAsString('base\n');
        await sourceRepository.add(['README.md']);
        await sourceRepository.commit(
          author: _signature(1700000000),
          message: 'Base commit\n',
        );
        await sourceRepository.push('origin');
        await localRepository.pull('origin');

        await sourceReadme.writeAsString('remote update\n');
        await sourceRepository.add(['README.md']);
        final remoteCommitId = await sourceRepository.commit(
          author: _signature(1700000100),
          message: 'Remote update\n',
        );
        await sourceRepository.push('origin');

        final result = await localRepository.pull('origin');

        expect(result.status, GitPullStatus.updated);
        expect(result.currentObjectId, isNotNull);
        expect(result.targetObjectId, remoteCommitId);
        expect(
          await localRepository.resolveReferenceObjectId('refs/heads/main'),
          remoteCommitId,
        );
        expect(
          await localRepository.resolveReferenceObjectId(
            'refs/remotes/origin/main',
          ),
          remoteCommitId,
        );
        expect(await localReadme.readAsString(), 'remote update\n');
      },
    );

    test('pull fast-forwards from a smart HTTP remote', () async {
      final sourceFixture = await _createWorkTreeRepository();
      final cloneRoot = await Directory.systemTemp.createTemp(
        'git_core_smart_http_pull_fixture_',
      );
      addTearDown(() => sourceFixture.workTree.delete(recursive: true));
      addTearDown(() => cloneRoot.delete(recursive: true));

      final sourceRepository = sourceFixture.repository;
      final sourceReadme = File(
        p.join(sourceFixture.workTree.path, 'README.md'),
      );

      await sourceReadme.writeAsString('base\n');
      await sourceRepository.add(['README.md']);
      await sourceRepository.commit(
        author: _signature(1700000000),
        message: 'Base commit\n',
      );
      final serverInfo = await _serveSmartHttpRepository(sourceRepository);
      addTearDown(() => serverInfo.server.close(force: true));

      final clonePath = p.join(cloneRoot.path, 'clone');
      await GitRepository.clone(serverInfo.baseUrl, clonePath);
      final localRepository = (await GitRepository.discover(clonePath))!;

      await sourceReadme.writeAsString('remote change\n');
      await sourceRepository.add(['README.md']);
      final remoteCommitId = await sourceRepository.commit(
        author: _signature(1700000100),
        message: 'Remote change\n',
      );

      final result = await localRepository.pull('origin');

      expect(result.status, GitPullStatus.updated);
      expect(result.targetObjectId, remoteCommitId);
      expect(
        await localRepository.resolveReferenceObjectId('refs/heads/main'),
        remoteCommitId,
      );
      expect(
        await File(p.join(clonePath, 'README.md')).readAsString(),
        'remote change\n',
      );
    });

    test(
      'supports dry-run pulls without writing refs, objects, or work tree',
      () async {
        final sourceFixture = await _createWorkTreeRepository();
        final remoteFixture = await _createBareRepository();
        final localFixture = await _createWorkTreeRepository();
        addTearDown(() => sourceFixture.workTree.delete(recursive: true));
        addTearDown(() => remoteFixture.directory.delete(recursive: true));
        addTearDown(() => localFixture.workTree.delete(recursive: true));

        final sourceRepository = sourceFixture.repository;
        final localRepository = localFixture.repository;
        final sourceReadme = File(
          p.join(sourceFixture.workTree.path, 'README.md'),
        );

        await sourceRepository.setRemote(
          GitRemote(name: 'origin', url: remoteFixture.directory.path),
        );
        await localRepository.setRemote(
          GitRemote(name: 'origin', url: remoteFixture.directory.path),
        );

        await sourceReadme.writeAsString('base\n');
        await sourceRepository.add(['README.md']);
        final remoteCommitId = await sourceRepository.commit(
          author: _signature(1700000000),
          message: 'Base commit\n',
        );
        await sourceRepository.push('origin');

        final result = await localRepository.pull('origin', dryRun: true);

        expect(result.dryRun, isTrue);
        expect(result.status, GitPullStatus.updated);
        expect(result.currentObjectId, isNull);
        expect(result.targetObjectId, remoteCommitId);
        expect(
          await localRepository.resolveReferenceObjectId('refs/heads/main'),
          isNull,
        );
        expect(await localRepository.remoteReferences('origin'), isEmpty);
        expect(await localRepository.readLooseObject(remoteCommitId), isNull);
        expect(
          await File(p.join(localFixture.workTree.path, 'README.md')).exists(),
          isFalse,
        );
      },
    );

    test('reports local-ahead pulls without integrating', () async {
      final sourceFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createBareRepository();
      final localFixture = await _createWorkTreeRepository();
      addTearDown(() => sourceFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.directory.delete(recursive: true));
      addTearDown(() => localFixture.workTree.delete(recursive: true));

      final sourceRepository = sourceFixture.repository;
      final localRepository = localFixture.repository;
      final sourceReadme = File(
        p.join(sourceFixture.workTree.path, 'README.md'),
      );
      final localReadme = File(p.join(localFixture.workTree.path, 'README.md'));

      await sourceRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.directory.path),
      );
      await localRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.directory.path),
      );

      await sourceReadme.writeAsString('base\n');
      await sourceRepository.add(['README.md']);
      final baseCommitId = await sourceRepository.commit(
        author: _signature(1700000000),
        message: 'Base commit\n',
      );
      await sourceRepository.push('origin');
      await localRepository.pull('origin');

      await localReadme.writeAsString('local only\n');
      await localRepository.add(['README.md']);
      final localCommitId = await localRepository.commit(
        author: _signature(1700000100),
        message: 'Local only\n',
      );

      final result = await localRepository.pull('origin');

      expect(result.status, GitPullStatus.localAhead);
      expect(result.currentObjectId, localCommitId);
      expect(result.targetObjectId, baseCommitId);
      expect(
        await localRepository.resolveReferenceObjectId('refs/heads/main'),
        localCommitId,
      );
      expect(await localReadme.readAsString(), 'local only\n');
    });

    test('reports divergent pulls without integrating', () async {
      final sourceFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createBareRepository();
      final localFixture = await _createWorkTreeRepository();
      addTearDown(() => sourceFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.directory.delete(recursive: true));
      addTearDown(() => localFixture.workTree.delete(recursive: true));

      final sourceRepository = sourceFixture.repository;
      final localRepository = localFixture.repository;
      final sourceReadme = File(
        p.join(sourceFixture.workTree.path, 'README.md'),
      );
      final localReadme = File(p.join(localFixture.workTree.path, 'README.md'));

      await sourceRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.directory.path),
      );
      await localRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.directory.path),
      );

      await sourceReadme.writeAsString('base\n');
      await sourceRepository.add(['README.md']);
      await sourceRepository.commit(
        author: _signature(1700000000),
        message: 'Base commit\n',
      );
      await sourceRepository.push('origin');
      await localRepository.pull('origin');

      await sourceReadme.writeAsString('remote only\n');
      await sourceRepository.add(['README.md']);
      final remoteCommitId = await sourceRepository.commit(
        author: _signature(1700000100),
        message: 'Remote only\n',
      );
      await sourceRepository.push('origin');

      await localReadme.writeAsString('local only\n');
      await localRepository.add(['README.md']);
      final localCommitId = await localRepository.commit(
        author: _signature(1700000200),
        message: 'Local only\n',
      );

      final result = await localRepository.pull('origin');

      expect(result.status, GitPullStatus.divergent);
      expect(result.currentObjectId, localCommitId);
      expect(result.targetObjectId, remoteCommitId);
      expect(
        await localRepository.resolveReferenceObjectId('refs/heads/main'),
        localCommitId,
      );
      expect(
        await localRepository.resolveReferenceObjectId(
          'refs/remotes/origin/main',
        ),
        remoteCommitId,
      );
      expect(await localReadme.readAsString(), 'local only\n');
    });

    test('pull merges divergent histories through branch tracking', () async {
      final sourceFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createBareRepository();
      final cloneRoot = await Directory.systemTemp.createTemp(
        'git_core_pull_merge_fixture_',
      );
      addTearDown(() => sourceFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.directory.delete(recursive: true));
      addTearDown(() => cloneRoot.delete(recursive: true));

      final sourceRepository = sourceFixture.repository;
      final sourceReadme = File(
        p.join(sourceFixture.workTree.path, 'README.md'),
      );

      await sourceRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.directory.path),
      );
      await sourceReadme.writeAsString('one\ntwo\nthree\n');
      await sourceRepository.add(['README.md']);
      await sourceRepository.commit(
        author: _signature(1700000000),
        message: 'Base commit\n',
      );
      await sourceRepository.push('origin');

      final clonePath = p.join(cloneRoot.path, 'clone');
      await GitRepository.clone(remoteFixture.directory.path, clonePath);
      final localRepository = (await GitRepository.discover(clonePath))!;
      final localReadme = File(p.join(clonePath, 'README.md'));

      await sourceReadme.writeAsString('one\ntwo\nthree remote\n');
      await sourceRepository.add(['README.md']);
      final remoteCommitId = await sourceRepository.commit(
        author: _signature(1700000100),
        message: 'Remote commit\n',
      );
      await sourceRepository.push('origin');

      await localReadme.writeAsString('one local\ntwo\nthree\n');
      await localRepository.add(['README.md']);
      final localCommitId = await localRepository.commit(
        author: _signature(1700000200),
        message: 'Local commit\n',
      );

      final result = await localRepository.pullCurrent(
        strategy: GitPullStrategy.merge,
        author: _signature(1700000300),
      );

      expect(result.status, GitPullStatus.merged);
      expect(result.strategy, GitPullStrategy.merge);
      expect(result.mergeResult, isNotNull);
      expect(result.mergeResult!.status, GitMergeStatus.merged);
      expect(result.currentObjectId, localCommitId);
      expect(result.targetObjectId, remoteCommitId);
      expect(
        await File(p.join(clonePath, 'README.md')).readAsString(),
        'one local\ntwo\nthree remote\n',
      );
    });

    test('clones a filesystem remote and checks out its head branch', () async {
      final sourceFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createBareRepository();
      final cloneRoot = await Directory.systemTemp.createTemp(
        'git_core_clone_fixture_',
      );
      addTearDown(() => sourceFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.directory.delete(recursive: true));
      addTearDown(() => cloneRoot.delete(recursive: true));

      final sourceRepository = sourceFixture.repository;
      final sourceReadme = File(
        p.join(sourceFixture.workTree.path, 'README.md'),
      );
      final clonePath = p.join(cloneRoot.path, 'clone');

      await sourceRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.directory.path),
      );
      await sourceReadme.writeAsString('base\n');
      await sourceRepository.add(['README.md']);
      final commitId = await sourceRepository.commit(
        author: _signature(1700000000),
        message: 'Base commit\n',
      );
      await sourceRepository.push('origin');

      final result = await GitRepository.clone(
        remoteFixture.directory.path,
        clonePath,
      );
      final repository = (await GitRepository.discover(result.path))!;
      final tracking = await repository.branchTracking('main');

      expect(result.referenceName, 'refs/heads/main');
      expect(result.objectId, commitId);
      expect(
        await File(p.join(result.path, 'README.md')).readAsString(),
        'base\n',
      );
      expect(
        await repository.resolveReferenceObjectId('refs/heads/main'),
        commitId,
      );
      expect(
        await repository.resolveReferenceObjectId('refs/remotes/origin/main'),
        commitId,
      );
      expect(
        (await repository.remote('origin'))?.url,
        remoteFixture.directory.path,
      );
      expect(tracking, isNotNull);
      expect(tracking!.remoteName, 'origin');
      expect(tracking.mergeReferenceName, 'refs/heads/main');
    });

    test('clones an explicit remote branch', () async {
      final sourceFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createBareRepository();
      final cloneRoot = await Directory.systemTemp.createTemp(
        'git_core_clone_branch_fixture_',
      );
      addTearDown(() => sourceFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.directory.delete(recursive: true));
      addTearDown(() => cloneRoot.delete(recursive: true));

      final sourceRepository = sourceFixture.repository;
      final sourceReadme = File(
        p.join(sourceFixture.workTree.path, 'README.md'),
      );
      final clonePath = p.join(cloneRoot.path, 'clone');

      await sourceRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.directory.path),
      );
      await sourceReadme.writeAsString('main\n');
      await sourceRepository.add(['README.md']);
      await sourceRepository.commit(
        author: _signature(1700000000),
        message: 'Main commit\n',
      );
      await sourceRepository.push('origin');

      await sourceRepository.checkout('topic', create: true, force: true);
      await sourceReadme.writeAsString('topic\n');
      await sourceRepository.add(['README.md']);
      final topicCommitId = await sourceRepository.commit(
        author: _signature(1700000100),
        message: 'Topic commit\n',
      );
      await sourceRepository.push('origin');

      final result = await GitRepository.clone(
        remoteFixture.directory.path,
        clonePath,
        branchName: 'topic',
      );
      final repository = (await GitRepository.discover(result.path))!;

      expect(result.referenceName, 'refs/heads/topic');
      expect(result.objectId, topicCommitId);
      expect(
        await File(p.join(result.path, 'README.md')).readAsString(),
        'topic\n',
      );
      expect(
        await repository.resolveReferenceObjectId('refs/remotes/origin/main'),
        isNotNull,
      );
      expect(
        await repository.resolveReferenceObjectId('refs/remotes/origin/topic'),
        topicCommitId,
      );
    });

    test('clones packed-only filesystem remotes', () async {
      final sourceFixture = await _createWorkTreeRepository();
      final cloneRoot = await Directory.systemTemp.createTemp(
        'git_core_clone_packed_fixture_',
      );
      addTearDown(() => sourceFixture.workTree.delete(recursive: true));
      addTearDown(() => cloneRoot.delete(recursive: true));

      final sourceRepository = sourceFixture.repository;
      final sourceReadme = File(
        p.join(sourceFixture.workTree.path, 'README.md'),
      );
      await sourceReadme.writeAsString('packed clone\n');
      await sourceRepository.add(['README.md']);
      final commitId = await sourceRepository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );
      await _packAllLooseObjects(sourceRepository);

      final clonePath = p.join(cloneRoot.path, 'clone');
      final result = await GitRepository.clone(
        sourceFixture.workTree.path,
        clonePath,
      );

      expect(result.objectId, commitId);
      expect(await sourceRepository.readLooseObject(commitId), isNull);
      expect(
        await File(p.join(clonePath, 'README.md')).readAsString(),
        'packed clone\n',
      );
    });

    test(
      'clones a static HTTP remote and checks out its head branch',
      () async {
        final sourceFixture = await _createWorkTreeRepository();
        final cloneRoot = await Directory.systemTemp.createTemp(
          'git_core_http_clone_fixture_',
        );
        addTearDown(() => sourceFixture.workTree.delete(recursive: true));
        addTearDown(() => cloneRoot.delete(recursive: true));

        final sourceRepository = sourceFixture.repository;
        final sourceReadme = File(
          p.join(sourceFixture.workTree.path, 'README.md'),
        );
        await sourceReadme.writeAsString('http clone\n');
        final sourceIndex = await sourceRepository.add(['README.md']);
        final commitId = await sourceRepository.commitIndex(
          sourceIndex,
          author: _signature(1700000000),
          message: 'Initial commit\n',
        );
        await _writeHttpServerInfo(sourceRepository);
        final serverInfo = await _serveGitDirectory(
          sourceRepository.gitDirectoryPath,
        );
        addTearDown(() => serverInfo.server.close(force: true));

        final clonePath = p.join(cloneRoot.path, 'clone');
        final result = await GitRepository.clone(serverInfo.baseUrl, clonePath);

        expect(result.referenceName, 'refs/heads/main');
        expect(result.objectId, commitId);
        expect(
          await File(p.join(clonePath, 'README.md')).readAsString(),
          'http clone\n',
        );
      },
    );

    test('clones a smart HTTP remote and checks out its head branch', () async {
      final sourceFixture = await _createWorkTreeRepository();
      final cloneRoot = await Directory.systemTemp.createTemp(
        'git_core_smart_http_clone_fixture_',
      );
      addTearDown(() => sourceFixture.workTree.delete(recursive: true));
      addTearDown(() => cloneRoot.delete(recursive: true));

      final sourceRepository = sourceFixture.repository;
      final sourceReadme = File(
        p.join(sourceFixture.workTree.path, 'README.md'),
      );
      await sourceReadme.writeAsString('smart http clone\n');
      final sourceIndex = await sourceRepository.add(['README.md']);
      final commitId = await sourceRepository.commitIndex(
        sourceIndex,
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );
      final serverInfo = await _serveSmartHttpRepository(
        sourceRepository,
        requiredHeaders: const {'Authorization': 'Bearer smart-clone'},
      );
      addTearDown(() => serverInfo.server.close(force: true));

      final clonePath = p.join(cloneRoot.path, 'clone');
      final result = await GitRepository.clone(
        serverInfo.baseUrl,
        clonePath,
        httpHeaders: const {'Authorization': 'Bearer smart-clone'},
      );

      expect(result.referenceName, 'refs/heads/main');
      expect(result.objectId, commitId);
      expect(
        await File(p.join(clonePath, 'README.md')).readAsString(),
        'smart http clone\n',
      );
      expect(
        (await (await GitRepository.discover(clonePath))!.remote('origin'))
            ?.httpHeaders['Authorization'],
        'Bearer smart-clone',
      );
    });

    test('rejects cloning into a non-empty target directory', () async {
      final sourceFixture = await _createWorkTreeRepository();
      final remoteFixture = await _createBareRepository();
      final cloneRoot = await Directory.systemTemp.createTemp(
        'git_core_clone_nonempty_fixture_',
      );
      final clonePath = p.join(cloneRoot.path, 'clone');
      addTearDown(() => sourceFixture.workTree.delete(recursive: true));
      addTearDown(() => remoteFixture.directory.delete(recursive: true));
      addTearDown(() => cloneRoot.delete(recursive: true));

      final sourceRepository = sourceFixture.repository;
      final sourceReadme = File(
        p.join(sourceFixture.workTree.path, 'README.md'),
      );

      await sourceRepository.setRemote(
        GitRemote(name: 'origin', url: remoteFixture.directory.path),
      );
      await sourceReadme.writeAsString('base\n');
      await sourceRepository.add(['README.md']);
      await sourceRepository.commit(
        author: _signature(1700000000),
        message: 'Base commit\n',
      );
      await sourceRepository.push('origin');

      await Directory(clonePath).create(recursive: true);
      await File(p.join(clonePath, 'placeholder.txt')).writeAsString('busy\n');

      expect(
        GitRepository.clone(remoteFixture.directory.path, clonePath),
        throwsStateError,
      );
    });

    test('reports already-up-to-date merges without changing HEAD', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await File(p.join(fixture.workTree.path, 'README.md'))
          .writeAsString('base\n');
      await repository.add(['README.md']);
      final commitId = await repository.commit(
        author: _signature(1700000000),
        message: 'Base commit\n',
      );
      await repository.branch('feature');

      final result = await repository.merge('feature');

      expect(result.status, GitMergeStatus.alreadyUpToDate);
      expect(result.currentObjectId, commitId);
      expect(result.resultObjectId, commitId);
      expect(
        await repository.resolveReferenceObjectId('refs/heads/main'),
        commitId,
      );
    });

    test('fast-forwards a branch merge and refreshes the work tree', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('base\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Base commit\n',
      );

      await repository.checkout('feature', create: true, force: true);
      await readme.writeAsString('feature\n');
      await repository.add(['README.md']);
      final featureCommitId = await repository.commit(
        author: _signature(1700000100),
        message: 'Feature commit\n',
      );
      await repository.checkout('main', force: true);

      final result = await repository.merge('feature');

      expect(result.status, GitMergeStatus.fastForward);
      expect(result.resultObjectId, featureCommitId);
      expect(
        await repository.resolveReferenceObjectId('refs/heads/main'),
        featureCommitId,
      );
      expect(await readme.readAsString(), 'feature\n');
    });

    test(
      'creates a merge commit for clean non-overlapping text changes',
      () async {
        final fixture = await _createWorkTreeRepository();
        addTearDown(() => fixture.workTree.delete(recursive: true));

        final repository = fixture.repository;
        final readme = File(p.join(fixture.workTree.path, 'README.md'));
        await readme.writeAsString('one\ntwo\nthree\n');
        await repository.add(['README.md']);
        await repository.commit(
          author: _signature(1700000000),
          message: 'Base commit\n',
        );

        await repository.checkout('feature', create: true, force: true);
        await readme.writeAsString('one\ntwo\nthree incoming\n');
        await repository.add(['README.md']);
        final featureCommitId = await repository.commit(
          author: _signature(1700000100),
          message: 'Feature commit\n',
        );

        await repository.checkout('main', force: true);
        await readme.writeAsString('one ours\ntwo\nthree\n');
        await repository.add(['README.md']);
        final mainCommitId = await repository.commit(
          author: _signature(1700000200),
          message: 'Main commit\n',
        );

        final result = await repository.merge(
          'feature',
          author: _signature(1700000300),
          message: 'Merge feature\n',
        );
        final mergeObject = await repository.show(result.resultObjectId!.hex);
        final mergeCommit = const GitCommitCodec().decode(mergeObject!.bytes);

        expect(result.status, GitMergeStatus.merged);
        expect(result.files, hasLength(1));
        expect(result.files.single.status, GitMergeFileStatus.merged);
        expect(await readme.readAsString(), 'one ours\ntwo\nthree incoming\n');
        expect(mergeCommit.parents, [mainCommitId, featureCommitId]);
        expect(mergeCommit.message, 'Merge feature\n');
        expect(
          await repository.resolveReferenceObjectId('refs/heads/main'),
          result.resultObjectId,
        );
      },
    );

    test('returns structured conflicts for overlapping merges', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('one\ntwo\nthree\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Base commit\n',
      );

      await repository.checkout('feature', create: true, force: true);
      await readme.writeAsString('one\ntwo incoming\nthree\n');
      await repository.add(['README.md']);
      final featureCommitId = await repository.commit(
        author: _signature(1700000100),
        message: 'Feature commit\n',
      );

      await repository.checkout('main', force: true);
      await readme.writeAsString('one\ntwo ours\nthree\n');
      await repository.add(['README.md']);
      final mainCommitId = await repository.commit(
        author: _signature(1700000200),
        message: 'Main commit\n',
      );

      final result = await repository.merge('feature');
      final conflicts = await repository.conflicts();
      final lsFiles = await repository.lsFiles();

      expect(result.status, GitMergeStatus.conflict);
      expect(result.resultObjectId, mainCommitId);
      expect(result.hasConflicts, isTrue);
      expect(result.files, hasLength(1));
      expect(result.files.single.path, 'README.md');
      expect(result.files.single.status, GitMergeFileStatus.conflict);
      expect(result.files.single.conflicts, hasLength(1));
      expect(result.files.single.conflicts.single.startLine, 2);
      expect(result.files.single.conflicts.single.baseText, 'two\n');
      expect(result.files.single.conflicts.single.currentText, 'two ours\n');
      expect(
        result.files.single.conflicts.single.incomingText,
        'two incoming\n',
      );
      expect(conflicts, hasLength(1));
      expect(conflicts.single.path, 'README.md');
      expect(conflicts.single.base, isNotNull);
      expect(conflicts.single.ours, isNotNull);
      expect(conflicts.single.theirs, isNotNull);
      expect(
        lsFiles
            .where((entry) => entry.path == 'README.md')
            .map((entry) => entry.stage),
        orderedEquals([1, 2, 3]),
      );
      expect(
        await repository.resolveReferenceObjectId('refs/heads/main'),
        mainCommitId,
      );
      expect(
        await repository.resolveReferenceObjectId('refs/heads/feature'),
        featureCommitId,
      );
      expect(await readme.readAsString(), 'one\ntwo ours\nthree\n');
    });

    test('continues a conflicted merge after staging a resolution', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('one\ntwo\nthree\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Base commit\n',
      );

      await repository.checkout('feature', create: true, force: true);
      await readme.writeAsString('one\ntwo incoming\nthree\n');
      await repository.add(['README.md']);
      final featureCommitId = await repository.commit(
        author: _signature(1700000100),
        message: 'Feature commit\n',
      );

      await repository.checkout('main', force: true);
      await readme.writeAsString('one\ntwo ours\nthree\n');
      await repository.add(['README.md']);
      final mainCommitId = await repository.commit(
        author: _signature(1700000200),
        message: 'Main commit\n',
      );

      final conflictResult = await repository.merge(
        'feature',
        message: 'Merge feature with resolution\n',
      );
      await readme.writeAsString('one\ntwo resolved\nthree\n');
      await repository.add(['README.md']);
      final continueResult = await repository.mergeContinue(
        author: _signature(1700000300),
      );
      final mergeObject = await repository.show(
        continueResult.resultObjectId!.hex,
      );
      final mergeCommit = const GitCommitCodec().decode(mergeObject!.bytes);

      expect(conflictResult.status, GitMergeStatus.conflict);
      expect(continueResult.status, GitMergeStatus.merged);
      expect(mergeCommit.parents, [mainCommitId, featureCommitId]);
      expect(mergeCommit.message, 'Merge feature with resolution\n');
      expect(await readme.readAsString(), 'one\ntwo resolved\nthree\n');
      expect(
        await repository.resolveReferenceObjectId('refs/heads/main'),
        continueResult.resultObjectId,
      );
      expect(await File(repository.mergeHeadFilePath).exists(), isFalse);
      expect(await File(repository.mergeStateFilePath).exists(), isFalse);
    });

    test('aborts a conflicted merge and restores the original tree', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      await readme.writeAsString('one\ntwo\nthree\n');
      await repository.add(['README.md']);
      await repository.commit(
        author: _signature(1700000000),
        message: 'Base commit\n',
      );

      await repository.checkout('feature', create: true, force: true);
      await readme.writeAsString('one\ntwo incoming\nthree\n');
      await repository.add(['README.md']);
      final featureCommitId = await repository.commit(
        author: _signature(1700000100),
        message: 'Feature commit\n',
      );

      await repository.checkout('main', force: true);
      await readme.writeAsString('one\ntwo ours\nthree\n');
      await repository.add(['README.md']);
      final mainCommitId = await repository.commit(
        author: _signature(1700000200),
        message: 'Main commit\n',
      );

      final conflictResult = await repository.merge('feature');
      final abortResult = await repository.mergeAbort();
      final conflicts = await repository.conflicts();
      final lsFiles = await repository.lsFiles();

      expect(conflictResult.status, GitMergeStatus.conflict);
      expect(abortResult.referenceName, 'refs/heads/main');
      expect(abortResult.originalObjectId, mainCommitId);
      expect(abortResult.incomingObjectId, featureCommitId);
      expect(await readme.readAsString(), 'one\ntwo ours\nthree\n');
      expect(conflicts, isEmpty);
      expect(
        lsFiles
            .where((entry) => entry.path == 'README.md')
            .map((entry) => (entry.path, entry.stage)),
        orderedEquals([('README.md', 0)]),
      );
      expect(
        await repository.resolveReferenceObjectId('refs/heads/main'),
        mainCommitId,
      );
      expect(await File(repository.mergeHeadFilePath).exists(), isFalse);
      expect(await File(repository.mergeStateFilePath).exists(), isFalse);
    });

    test('merges unrelated histories when paths do not overlap', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      final readme = File(p.join(fixture.workTree.path, 'README.md'));
      final notes = File(p.join(fixture.workTree.path, 'NOTES.md'));
      await readme.writeAsString('main\n');
      await repository.add(['README.md']);
      final mainCommitId = await repository.commit(
        author: _signature(1700000000),
        message: 'Main root\n',
      );

      await notes.writeAsString('side\n');
      final notesEntry = await repository.createIndexEntryFromWorkTreePath(
        'NOTES.md',
      );
      final sideCommitId = await repository.commitIndex(
        GitIndex(
          checksumAlgorithm: notesEntry.objectId.algorithm,
          entries: [notesEntry],
        ),
        author: _signature(1700000100),
        message: 'Side root\n',
        referenceName: 'refs/heads/side',
        parents: const [],
      );
      await notes.delete();

      final result = await repository.merge(
        'side',
        author: _signature(1700000200),
      );
      final mergeObject = await repository.show(result.resultObjectId!.hex);
      final mergeCommit = const GitCommitCodec().decode(mergeObject!.bytes);

      expect(result.status, GitMergeStatus.merged);
      expect(result.baseObjectId, isNull);
      expect(result.currentObjectId, mainCommitId);
      expect(result.incomingObjectId, sideCommitId);
      expect(mergeCommit.parents, [mainCommitId, sideCommitId]);
      expect(await readme.readAsString(), 'main\n');
      expect(await notes.readAsString(), 'side\n');
    });

    test(
      'returns conflicts instead of unsupported for binary merges',
      () async {
        final fixture = await _createWorkTreeRepository();
        addTearDown(() => fixture.workTree.delete(recursive: true));

        final repository = fixture.repository;
        final image = File(p.join(fixture.workTree.path, 'image.bin'));
        await image.writeAsBytes([0, 1, 2]);
        await repository.add(['image.bin']);
        final baseCommitId = await repository.commit(
          author: _signature(1700000000),
          message: 'Base image\n',
        );

        await repository.branch('feature');
        await image.writeAsBytes([0, 1, 3]);
        final featureIndex = await repository.add(['image.bin']);
        await repository.commitIndex(
          featureIndex,
          author: _signature(1700000100),
          message: 'Feature image\n',
          referenceName: 'refs/heads/feature',
          parents: [baseCommitId],
        );

        await image.writeAsBytes([0, 1, 4]);
        await repository.add(['image.bin']);
        await repository.commit(
          author: _signature(1700000200),
          message: 'Main image\n',
        );

        final result = await repository.merge(
          'feature',
          author: _signature(1700000300),
        );

        expect(result.status, GitMergeStatus.conflict);
        expect(result.hasUnsupported, isFalse);
        expect(result.files.single.status, GitMergeFileStatus.conflict);
        expect(result.files.single.message, contains('non-text'));
      },
    );

    test('creates a linked worktree with a new branch', () async {
      final rootDirectory = await Directory.systemTemp.createTemp(
        'git_core_worktree_add_',
      );
      addTearDown(() => rootDirectory.delete(recursive: true));

      final mainWorkTree = await Directory(p.join(rootDirectory.path, 'main'))
          .create();
      await _createRepositoryLayout(p.join(mainWorkTree.path, '.git'));

      final repository = GitRepository.workTree(mainWorkTree.path);
      await File(p.join(mainWorkTree.path, 'README.md'))
          .writeAsString('hello\n');
      await repository.add(['README.md']);
      final commitId = await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      final result = await repository.worktree(
        p.join(rootDirectory.path, 'topic'),
        branchName: 'topic',
      );
      final linkedRepository = (await GitRepository.discover(
        result.workTreePath,
      ))!;
      final headReference = await linkedRepository.readReference('HEAD');
      final linkedStatus = await linkedRepository.status();

      expect(result.objectId, commitId);
      expect(result.referenceName, 'refs/heads/topic');
      expect(result.detached, isFalse);
      expect(result.dryRun, isFalse);
      expect(
        await File(p.join(result.workTreePath, 'README.md')).readAsString(),
        'hello\n',
      );
      expect(headReference, isNotNull);
      expect(headReference!.targetReferenceName, 'refs/heads/topic');
      expect(linkedRepository.gitDirectoryPath, result.gitDirectoryPath);
      expect(
        linkedRepository.commonDirectoryPath,
        repository.commonDirectoryPath,
      );
      expect(
        (await repository.readReference('refs/heads/topic'))!.objectId,
        commitId,
      );
      expect(linkedStatus.isClean, isTrue);
      expect(
        await File(p.join(result.gitDirectoryPath, 'commondir')).readAsString(),
        isNotEmpty,
      );
    });

    test('supports dry-run worktree planning without writing files', () async {
      final rootDirectory = await Directory.systemTemp.createTemp(
        'git_core_worktree_dry_run_',
      );
      addTearDown(() => rootDirectory.delete(recursive: true));

      final mainWorkTree = await Directory(p.join(rootDirectory.path, 'main'))
          .create();
      await _createRepositoryLayout(p.join(mainWorkTree.path, '.git'));

      final repository = GitRepository.workTree(mainWorkTree.path);
      await File(p.join(mainWorkTree.path, 'README.md'))
          .writeAsString('hello\n');
      await repository.add(['README.md']);
      final commitId = await repository.commit(
        author: _signature(1700000000),
        message: 'Initial commit\n',
      );

      final result = await repository.worktree(
        p.join(rootDirectory.path, 'preview'),
        branchName: 'preview',
        dryRun: true,
      );

      expect(result.objectId, commitId);
      expect(result.referenceName, 'refs/heads/preview');
      expect(result.detached, isFalse);
      expect(result.dryRun, isTrue);
      expect(await Directory(result.workTreePath).exists(), isFalse);
      expect(await repository.readReference('refs/heads/preview'), isNull);
      expect(
        result.operations.map((operation) => operation.kind),
        containsAll([
          GitWorktreeOperationKind.createDirectory,
          GitWorktreeOperationKind.writeMetadataFile,
          GitWorktreeOperationKind.writeReference,
          GitWorktreeOperationKind.writeWorkTreeFile,
          GitWorktreeOperationKind.writeIndex,
        ]),
      );
      expect(
        result.operations.any(
          (operation) => operation.path == p.join(result.workTreePath, '.git'),
        ),
        isTrue,
      );
    });

    test('detects symbolic reference cycles during resolution', () async {
      final fixture = await _createWorkTreeRepository();
      addTearDown(() => fixture.workTree.delete(recursive: true));

      final repository = fixture.repository;
      await repository.writeReference(
        GitReference.symbolic('HEAD', 'refs/heads/main'),
      );
      await repository.writeReference(
        GitReference.symbolic('refs/heads/main', 'HEAD'),
      );

      expect(repository.resolveReferenceObjectId('HEAD'), throwsStateError);
    });
  });

  group('GitReference', () {
    test('builds direct references', () {
      final objectId = GitObjectId.fromHex(
        '0123456789abcdef0123456789abcdef01234567',
      );
      final reference = GitReference.direct('refs/heads/main', objectId);

      expect(reference.isDirect, isTrue);
      expect(reference.isSymbolic, isFalse);
    });

    test('builds symbolic references', () {
      final reference = GitReference.symbolic('HEAD', 'refs/heads/main');

      expect(reference.isDirect, isFalse);
      expect(reference.isSymbolic, isTrue);
      expect(reference.name, 'HEAD');
    });

    test('normalizes reference names', () {
      final reference = GitReference.symbolic(' HEAD ', 'refs/heads/main');

      expect(reference.name, 'HEAD');
    });
  });
}

Future<({GitRepository repository, Directory workTree})>
_createWorkTreeRepository() async {
  final tempDirectory = await Directory.systemTemp.createTemp(
    'git_core_repo_fixture_',
  );
  await _createRepositoryLayout(p.join(tempDirectory.path, '.git'));
  return (
    repository: GitRepository.workTree(tempDirectory.path),
    workTree: tempDirectory,
  );
}

Future<({GitRepository repository, Directory directory})>
_createBareRepository() async {
  final tempDirectory = await Directory.systemTemp.createTemp(
    'git_core_bare_repo_fixture_',
  );
  await _createRepositoryLayout(tempDirectory.path);
  return (
    repository: GitRepository.bare(tempDirectory.path),
    directory: tempDirectory,
  );
}

Future<void> _createRepositoryLayout(String gitDirectoryPath) async {
  final gitDirectory = Directory(gitDirectoryPath);
  await Directory(p.join(gitDirectory.path, 'objects')).create(recursive: true);
  await Directory(p.join(gitDirectory.path, 'refs')).create(recursive: true);
  await Directory(p.join(gitDirectory.path, 'info')).create(recursive: true);
  await File(p.join(gitDirectory.path, 'HEAD'))
      .writeAsString('ref: refs/heads/main\n');
}

Future<void> _packRepositoryObjects(
  GitRepository repository,
  List<GitObjectId> objectIds,
) async {
  final objects = <GitObject>[];
  for (final objectId in objectIds) {
    final object = await repository.readLooseObject(objectId);
    if (object == null) {
      throw StateError('Missing loose object for packing: $objectId.');
    }
    objects.add(object);
  }

  final packBytes = const GitPackCodec().encode(
    GitPack(
      entries: [for (final object in objects) GitPackObjectEntry(object)],
    ),
  );
  final index = const GitPackIndexCodec().build(
    packBytes,
    objectIdsInPackOrder: objectIds,
  );
  final packDirectory = await Directory(
    p.join(repository.objectDirectoryPath, 'pack'),
  ).create(recursive: true);
  final packBaseName = 'pack-${index.packChecksum!.hex}';
  await File(p.join(packDirectory.path, '$packBaseName.pack'))
      .writeAsBytes(packBytes, flush: true);
  await File(p.join(packDirectory.path, '$packBaseName.idx'))
      .writeAsBytes(const GitPackIndexCodec().encode(index), flush: true);

  for (final objectId in objectIds) {
    final loosePath = repository.resolveLooseObjectPath(objectId);
    final looseFile = File(loosePath);
    if (await looseFile.exists()) {
      await looseFile.delete();
    }
  }
}

Future<void> _packAllLooseObjects(GitRepository repository) async {
  final objectIds = <GitObjectId>[];
  final objectDirectory = Directory(repository.objectDirectoryPath);
  await for (final entity in objectDirectory.list(followLinks: false)) {
    if (entity is! Directory) {
      continue;
    }
    final directoryName = p.basename(entity.path);
    if (directoryName == 'pack' || directoryName.length != 2) {
      continue;
    }

    await for (final child in entity.list(followLinks: false)) {
      if (child is! File) {
        continue;
      }
      final hex = '$directoryName${p.basename(child.path)}';
      if (GitObjectId.isValidHex(hex)) {
        objectIds.add(GitObjectId.fromHex(hex));
      }
    }
  }

  if (objectIds.isEmpty) {
    return;
  }
  await _packRepositoryObjects(repository, objectIds);
}

Future<void> _writeHttpServerInfo(GitRepository repository) async {
  final infoDirectory = await Directory(
    p.join(repository.gitDirectoryPath, 'info'),
  ).create(recursive: true);
  final references = await repository.references(prefix: 'refs');
  await File(p.join(infoDirectory.path, 'refs')).writeAsString(
    [
      for (final reference in references)
        '${reference.objectId.hex}\t${reference.referenceName}\n',
    ].join(),
    flush: true,
  );

  final objectsInfoDirectory = await Directory(
    p.join(repository.objectDirectoryPath, 'info'),
  ).create(recursive: true);
  final packDirectory = Directory(
    p.join(repository.objectDirectoryPath, 'pack'),
  );
  final packNames = <String>[];
  if (await packDirectory.exists()) {
    await for (final entity in packDirectory.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.pack')) {
        packNames.add(p.basename(entity.path));
      }
    }
    packNames.sort();
  }
  await File(p.join(objectsInfoDirectory.path, 'packs')).writeAsString(
    [for (final packName in packNames) 'P $packName\n'].join(),
    flush: true,
  );
}

int _gitHttpSerial = 0;

typedef _GitHttpHandler = Future<GitHttpResponse> Function(
  Uri uri,
  String method,
  Map<String, String> headers,
  List<int>? body,
);

final _gitRoutes = <String, _GitHttpHandler>{};

final class _QuietServer {
  _QuietServer(this.base);

  final String base;

  Future<void> close({bool force = false}) async {
    _gitRoutes.remove(base);
  }
}

final class _ScenarioGitHttp implements GitHttp {
  @override
  Future<GitHttpResponse> send({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    for (final entry in _gitRoutes.entries) {
      if (uri.toString().startsWith(entry.key)) {
        return entry.value(uri, method, headers, body);
      }
    }
    return const GitHttpResponse(statusCode: HttpStatus.notFound, body: []);
  }
}

String _mountGitRoute(_GitHttpHandler handler) {
  _gitHttpSerial += 1;
  final base = 'http://git.test/$_gitHttpSerial/';
  _gitRoutes[base] = handler;
  attachGitHttp(_ScenarioGitHttp());
  return base;
}

String _mountedPath(String base, Uri uri) {
  final prefix = Uri.parse(base).path;
  final path = uri.path;
  if (!path.startsWith(prefix)) return path;
  final relative = path.substring(prefix.length - 1);
  return relative.isEmpty ? '/' : relative;
}

bool _headersMatch(
  Map<String, String> actual,
  Map<String, String> requiredHeaders,
) {
  final lowered = {
    for (final entry in actual.entries) entry.key.toLowerCase(): entry.value,
  };
  for (final entry in requiredHeaders.entries) {
    if (lowered[entry.key.toLowerCase()] != entry.value) return false;
  }
  return true;
}

Future<({_QuietServer server, String baseUrl})> _serveGitDirectory(
  String gitDirectoryPath,
) async {
  final rootPath = p.normalize(gitDirectoryPath);
  late final String baseUrl;
  baseUrl = _mountGitRoute((uri, method, headers, body) async {
    final targetPath = p.normalize(
      p.join(rootPath, _mountedPath(baseUrl, uri).replaceFirst('/', '')),
    );
    final withinRoot =
        targetPath == rootPath || p.isWithin(rootPath, targetPath);
    if (!withinRoot) {
      return const GitHttpResponse(statusCode: HttpStatus.forbidden, body: []);
    }
    final file = File(targetPath);
    if (!await file.exists()) {
      return const GitHttpResponse(statusCode: HttpStatus.notFound, body: []);
    }
    return GitHttpResponse(
      statusCode: HttpStatus.ok,
      body: await file.readAsBytes(),
    );
  });
  return (server: _QuietServer(baseUrl), baseUrl: baseUrl);
}

Future<({_QuietServer server, String baseUrl})> _serveSmartHttpRepository(
  GitRepository repository, {
  Map<String, String> requiredHeaders = const {},
  bool allowPush = false,
}) async {
  late final String baseUrl;
  baseUrl = _mountGitRoute((uri, method, headers, body) async {
    if (!_headersMatch(headers, requiredHeaders)) {
      return GitHttpResponse(
        statusCode: HttpStatus.unauthorized,
        body: utf8.encode('missing required headers'),
      );
    }
    final path = _mountedPath(baseUrl, uri);
    if (path == '/info/refs' &&
        uri.queryParameters['service'] == 'git-upload-pack') {
      final bytes = await _buildSmartHttpAdvertisement(
        repository,
        service: 'git-upload-pack',
      );
      return GitHttpResponse(statusCode: HttpStatus.ok, body: bytes);
    }
    if (allowPush &&
        path == '/info/refs' &&
        uri.queryParameters['service'] == 'git-receive-pack') {
      final bytes = await _buildSmartHttpAdvertisement(
        repository,
        service: 'git-receive-pack',
      );
      return GitHttpResponse(statusCode: HttpStatus.ok, body: bytes);
    }
    if (path == '/git-upload-pack' && method == 'POST') {
      final parsedRequest = _parseSmartUploadPackRequest(body ?? const <int>[]);
      final objectIds = await _collectReachableObjectIdsFromRepository(
        repository,
        parsedRequest.wants,
        excludeRoots: parsedRequest.haves,
      );
      final packBytes = await repository.exportPack(objectIds);
      return GitHttpResponse(
        statusCode: HttpStatus.ok,
        body: <int>[..._encodePktLine('NAK\n'), ...packBytes],
      );
    }
    if (allowPush && path == '/git-receive-pack' && method == 'POST') {
      final parsedRequest = _parseSmartReceivePackRequest(
        body ?? const <int>[],
      );
      if (parsedRequest.packBytes.isNotEmpty) {
        await repository.importPackBytes(parsedRequest.packBytes);
      }
      for (final command in parsedRequest.commands) {
        if (command.nextObjectId == null) {
          await repository.deleteReference(command.referenceName);
        } else {
          await repository.writeReference(
            GitReference.direct(command.referenceName, command.nextObjectId!),
          );
        }
      }
      return GitHttpResponse(
        statusCode: HttpStatus.ok,
        body: <int>[
          ..._encodePktLine('unpack ok\n'),
          for (final command in parsedRequest.commands)
            ..._encodePktLine('ok ${command.referenceName}\n'),
          ..._pktFlush(),
        ],
      );
    }
    return const GitHttpResponse(statusCode: HttpStatus.notFound, body: []);
  });
  return (server: _QuietServer(baseUrl), baseUrl: baseUrl);
}

Future<List<int>> _buildSmartHttpAdvertisement(
  GitRepository repository, {
  required String service,
}) async {
  final responseBytes = <int>[
    ..._encodePktLine('# service=$service\n'),
    ..._pktFlush(),
  ];
  final references = await _listStoredReferences(repository);
  final headReference = await repository.readReference('HEAD');
  final headObjectId = await repository.resolveReferenceObjectId('HEAD');
  final headTargetReferenceName = headReference?.targetReferenceName;

  var wroteFirstLine = false;
  if (headObjectId != null) {
    responseBytes.addAll(
      _encodePktLine(
        '${headObjectId.hex} HEAD'
        '${headTargetReferenceName == null ? '' : '\u0000symref=HEAD:$headTargetReferenceName'}\n',
      ),
    );
    wroteFirstLine = true;
  }

  for (final reference in references) {
    final suffix = !wroteFirstLine && headTargetReferenceName != null
        ? '\u0000symref=HEAD:$headTargetReferenceName'
        : '';
    responseBytes.addAll(
      _encodePktLine(
        '${reference.objectId.hex} ${reference.referenceName}$suffix\n',
      ),
    );
    wroteFirstLine = true;
  }
  responseBytes.addAll(_pktFlush());
  return responseBytes;
}

Future<List<GitReferenceInfo>> _listStoredReferences(
  GitRepository repository,
) async {
  final references = <GitReferenceInfo>[];
  final refsDirectory = Directory(repository.referenceDirectoryPath);
  if (!await refsDirectory.exists()) {
    return references;
  }

  await for (final entity in refsDirectory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) {
      continue;
    }
    final relativePath = p.posix.joinAll(
      p.split(p.relative(entity.path, from: refsDirectory.path)),
    );
    final referenceName = 'refs/$relativePath';
    final objectId = await repository.resolveReferenceObjectId(referenceName);
    if (objectId == null) {
      continue;
    }
    references.add(
      GitReferenceInfo(
        referenceName: referenceName,
        name: p.posix.basename(referenceName),
        objectId: objectId,
      ),
    );
  }

  references.sort(
    (left, right) => left.referenceName.compareTo(right.referenceName),
  );
  return references;
}

({List<GitObjectId> wants, List<GitObjectId> haves})
_parseSmartUploadPackRequest(List<int> bytes) {
  final wants = <GitObjectId>[];
  final haves = <GitObjectId>[];
  var offset = 0;
  while (offset + 4 <= bytes.length) {
    final length = _decodePktLineLength(bytes, offset);
    if (length == null) {
      break;
    }
    offset += 4;
    if (length == 0) {
      continue;
    }
    final payloadLength = length - 4;
    if (payloadLength < 0 || offset + payloadLength > bytes.length) {
      break;
    }
    final line = utf8
        .decode(
          bytes.sublist(offset, offset + payloadLength),
          allowMalformed: true,
        )
        .trimRight();
    offset += payloadLength;

    if (line.startsWith('want ')) {
      final parts = line.split(' ');
      if (parts.length > 1 && GitObjectId.isValidHex(parts[1])) {
        wants.add(GitObjectId.fromHex(parts[1]));
      }
    } else if (line.startsWith('have ')) {
      final parts = line.split(' ');
      if (parts.length > 1 && GitObjectId.isValidHex(parts[1])) {
        haves.add(GitObjectId.fromHex(parts[1]));
      }
    }
  }
  return (wants: wants, haves: haves);
}

({List<_TestSmartReceivePackCommand> commands, List<int> packBytes})
_parseSmartReceivePackRequest(List<int> bytes) {
  final commands = <_TestSmartReceivePackCommand>[];
  var offset = 0;
  while (offset + 4 <= bytes.length) {
    final length = _decodePktLineLength(bytes, offset);
    if (length == null) {
      break;
    }
    offset += 4;
    if (length == 0) {
      break;
    }
    final payloadLength = length - 4;
    if (payloadLength < 0 || offset + payloadLength > bytes.length) {
      break;
    }
    final payload = bytes.sublist(offset, offset + payloadLength);
    offset += payloadLength;

    final nulIndex = payload.indexOf(0);
    final line = utf8
        .decode(
          nulIndex == -1 ? payload : payload.sublist(0, nulIndex),
          allowMalformed: true,
        )
        .trimRight();
    final parts = line.split(' ');
    if (parts.length < 3) {
      continue;
    }
    final previousObjectId = _parseObjectIdOrNull(parts[0]);
    final nextObjectId = _parseObjectIdOrNull(parts[1]);
    commands.add(
      _TestSmartReceivePackCommand(
        referenceName: parts[2],
        previousObjectId: previousObjectId,
        nextObjectId: nextObjectId,
      ),
    );
  }

  return (
    commands: commands,
    packBytes: offset < bytes.length ? bytes.sublist(offset) : const <int>[],
  );
}

Future<List<GitObjectId>> _collectReachableObjectIdsFromRepository(
  GitRepository repository,
  Iterable<GitObjectId> rootObjectIds, {
  Iterable<GitObjectId> excludeRoots = const <GitObjectId>[],
}) async {
  final excluded = await _collectReachableObjectIdsWithoutExclusions(
    repository,
    excludeRoots,
  );
  final reachable = await _collectReachableObjectIdsWithoutExclusions(
    repository,
    rootObjectIds,
  );
  return [
    for (final objectId in reachable)
      if (!excluded.contains(objectId)) objectId,
  ];
}

Future<Set<GitObjectId>> _collectReachableObjectIdsWithoutExclusions(
  GitRepository repository,
  Iterable<GitObjectId> rootObjectIds,
) async {
  final reachable = <GitObjectId>[];
  final queue = <GitObjectId>[for (final objectId in rootObjectIds) objectId];
  final visited = <GitObjectId>{};

  while (queue.isNotEmpty) {
    final objectId = queue.removeLast();
    if (!visited.add(objectId)) {
      continue;
    }
    final object = await repository.readObject(objectId);
    if (object == null) {
      continue;
    }
    reachable.add(objectId);
    switch (object.type) {
      case GitObjectType.blob:
        break;
      case GitObjectType.commit:
        final commit = const GitCommitCodec().decode(object.bytes);
        queue
          ..add(commit.tree)
          ..addAll(commit.parents);
      case GitObjectType.tree:
        final entries = const GitTreeCodec().decode(object.bytes);
        queue.addAll(entries.map((entry) => entry.objectId));
      case GitObjectType.tag:
        final tag = const GitTagCodec().decode(object.bytes);
        queue.add(tag.targetObjectId);
    }
  }

  return reachable.toSet();
}

List<int> _encodePktLine(String text) {
  final payload = utf8.encode(text);
  final length = payload.length + 4;
  return <int>[
    ...ascii.encode(length.toRadixString(16).padLeft(4, '0')),
    ...payload,
  ];
}

List<int> _pktFlush() => const <int>[0x30, 0x30, 0x30, 0x30];

int? _decodePktLineLength(List<int> bytes, int offset) {
  if (offset + 4 > bytes.length) {
    return null;
  }
  final text = ascii.decode(
    bytes.sublist(offset, offset + 4),
    allowInvalid: true,
  );
  return int.tryParse(text, radix: 16);
}

GitObjectId? _parseObjectIdOrNull(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || RegExp(r'^0+$').hasMatch(trimmed)) {
    return null;
  }
  return GitObjectId.isValidHex(trimmed) ? GitObjectId.fromHex(trimmed) : null;
}

final class _TestSmartReceivePackCommand {
  const _TestSmartReceivePackCommand({
    required this.referenceName,
    required this.previousObjectId,
    required this.nextObjectId,
  });

  final String referenceName;
  final GitObjectId? previousObjectId;
  final GitObjectId? nextObjectId;
}

Future<({GitRepository repository, Directory workTree, File readme})>
_createTextMergeConflictRepository() async {
  final fixture = await _createWorkTreeRepository();
  final repository = fixture.repository;
  final readme = File(p.join(fixture.workTree.path, 'README.md'));

  await readme.writeAsString('one\ntwo\nthree\n');
  await repository.add(['README.md']);
  await repository.commit(
    author: _signature(1700000000),
    message: 'Base commit\n',
  );

  await repository.checkout('feature', create: true, force: true);
  await readme.writeAsString('one\ntwo incoming\nthree\n');
  await repository.add(['README.md']);
  await repository.commit(
    author: _signature(1700000100),
    message: 'Feature commit\n',
  );

  await repository.checkout('main', force: true);
  await readme.writeAsString('one\ntwo ours\nthree\n');
  await repository.add(['README.md']);
  await repository.commit(
    author: _signature(1700000200),
    message: 'Main commit\n',
  );

  final mergeResult = await repository.merge('feature');
  if (mergeResult.status != GitMergeStatus.conflict) {
    throw StateError('Expected merge conflict fixture to produce a conflict.');
  }

  return (repository: repository, workTree: fixture.workTree, readme: readme);
}

GitCommitSignature _signature(int timestampSeconds) => GitCommitSignature(
  name: 'Alice Example',
  email: 'alice@example.com',
  timestampSeconds: timestampSeconds,
  timezoneOffset: '+0900',
);
