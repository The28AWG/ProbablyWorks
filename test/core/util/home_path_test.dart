import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/core/util/home_path.dart';

void main() {
  final env = {'HOME': '/home/me'};

  group('expandHomePath', () {
    test('expands ~ and ~/ with the app machine home', () {
      expect(
        expandHomePath('~/.ssh/id_ed25519', environment: env),
        '/home/me/.ssh/id_ed25519',
      );
      expect(expandHomePath('~', environment: env), '/home/me');
    });

    test('leaves other forms untouched', () {
      expect(expandHomePath('~bob/.ssh/id', environment: env), '~bob/.ssh/id');
      expect(
        expandHomePath(r'$HOME/.ssh/id', environment: env),
        r'$HOME/.ssh/id',
      );
      expect(expandHomePath('/abs/id', environment: env), '/abs/id');
    });
  });

  group('isSupportedKeyPath', () {
    test('accepts absolute and ~/ paths', () {
      expect(isSupportedKeyPath('/home/me/.ssh/id'), isTrue);
      expect(isSupportedKeyPath('~/.ssh/id'), isTrue);
      expect(isSupportedKeyPath(r'C:\keys\id'), isTrue);
    });

    test(r'rejects relative, ~user and $HOME forms', () {
      expect(isSupportedKeyPath('keys/id'), isFalse);
      expect(isSupportedKeyPath('~bob/.ssh/id'), isFalse);
      expect(isSupportedKeyPath(r'$HOME/.ssh/id'), isFalse);
    });
  });
}
