/// Длительность без склонений и локали: `0s`, `3m 40s`, `1h 5s`, `2d 3h`.
/// Выводятся только ненулевые единицы по порядку от дней к секундам; нулевая длительность — `0s`.
/// Дробные секунды отбрасываются, отрицательная длительность считается нулевой.
String formatElapsed(Duration elapsed) {
  final total = elapsed.isNegative ? 0 : elapsed.inSeconds;
  final parts = [
    total ~/ Duration.secondsPerDay,
    total % Duration.secondsPerDay ~/ Duration.secondsPerHour,
    total % Duration.secondsPerHour ~/ Duration.secondsPerMinute,
    total % Duration.secondsPerMinute,
  ];
  const suffixes = ['d', 'h', 'm', 's'];
  final shown = [
    for (var i = 0; i < parts.length; i++)
      if (parts[i] > 0) '${parts[i]}${suffixes[i]}',
  ];
  return shown.isEmpty ? '0s' : shown.join(' ');
}
