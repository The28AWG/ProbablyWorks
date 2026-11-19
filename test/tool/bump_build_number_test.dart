import 'package:flutter_test/flutter_test.dart';

import '../../tool/release/bump_build_number.dart';

void main() {
  group('bumpBuildNumber', () {
    test('увеличивает номер сборки и сохраняет остальной файл', () {
      const pubspec =
          'name: probably_works\n'
          'version: 1.0.2+120\n'
          'environment:\n'
          '  sdk: ^3.0.0\n';

      final result = bumpBuildNumber(pubspec);

      expect(
        result,
        'name: probably_works\n'
        'version: 1.0.2+121\n'
        'environment:\n'
        '  sdk: ^3.0.0\n',
      );
    });

    test('заменяет маркетинговую версию при явном аргументе', () {
      final result = bumpBuildNumber(
        'version: 1.0.2+7\n',
        marketingVersion: '1.1.0',
      );

      expect(result, 'version: 1.1.0+8\n');
    });

    test('сохраняет CRLF-окончания строк', () {
      const pubspec = 'name: app\r\nversion: 1.0.0+1\r\nsdk: any\r\n';

      expect(
        bumpBuildNumber(pubspec),
        'name: app\r\nversion: 1.0.0+2\r\nsdk: any\r\n',
      );
    });

    test('бросает ошибку, если строки version нет', () {
      expect(
        () => bumpBuildNumber('name: app\n'),
        throwsA(isA<FormatException>()),
      );
    });

    test('бросает ошибку, если номера сборки нет', () {
      expect(
        () => bumpBuildNumber('version: 1.0.2\n'),
        throwsA(isA<FormatException>()),
      );
    });

    test('бросает ошибку при некорректной маркетинговой версии', () {
      expect(
        () => bumpBuildNumber('version: 1.0.2+1\n', marketingVersion: '1.0'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
