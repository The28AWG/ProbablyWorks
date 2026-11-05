// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
enum GitHashAlgorithm {
  sha1('sha1', 20),
  sha256('sha256', 32);

  const GitHashAlgorithm(this.wireName, this.digestLength);

  final String wireName;
  final int digestLength;

  int get hexLength => digestLength * 2;
}
