// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_refspec.dart';

final class GitRemote {
  GitRemote({
    required this.name,
    required this.url,
    List<GitRefSpec> fetchRefSpecs = const [],
    this.pushUrl,
    Map<String, String> httpHeaders = const {},
    this.sshPrivateKeyPath,
    this.sshPrivateKey,
    this.sshPrivateKeyPassphrase,
    this.sshPassword,
    this.sshKnownHostsPath,
    List<String> sshHostKeyFingerprints = const [],
  }) : fetchRefSpecs = List.unmodifiable(fetchRefSpecs),
       httpHeaders = Map.unmodifiable(httpHeaders),
       sshHostKeyFingerprints = List.unmodifiable(sshHostKeyFingerprints);

  final String name;
  final String url;
  final List<GitRefSpec> fetchRefSpecs;
  final String? pushUrl;
  final Map<String, String> httpHeaders;
  final String? sshPrivateKeyPath;
  final String? sshPrivateKey;
  final String? sshPrivateKeyPassphrase;
  final String? sshPassword;
  final String? sshKnownHostsPath;
  final List<String> sshHostKeyFingerprints;
}
