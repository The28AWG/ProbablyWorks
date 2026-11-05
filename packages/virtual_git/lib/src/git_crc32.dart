// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
final List<int> _crc32Table = List<int>.unmodifiable(
  List<int>.generate(256, _buildCrc32TableEntry, growable: false),
);

int computeGitCrc32(List<int> bytes) {
  var crc = 0xffffffff;

  for (final byte in bytes) {
    crc = _crc32Table[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  }

  return (crc ^ 0xffffffff) & 0xffffffff;
}

int _buildCrc32TableEntry(int index) {
  var value = index;

  for (var bit = 0; bit < 8; bit++) {
    value = (value & 1) != 0 ? (value >>> 1) ^ 0xedb88320 : value >>> 1;
  }

  return value;
}
