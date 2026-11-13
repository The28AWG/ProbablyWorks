import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/app/router/app_router.dart';

void main() {
  test('normalizes trailing slash and empty query in deep links', () async {
    expect(
      (await normalizeAppDeepLink(Uri.parse('/a/p1/settings/'))).toString(),
      '/a/p1/settings',
    );
    expect(
      (await normalizeAppDeepLink(Uri.parse('/a/p1/settings/?'))).toString(),
      '/a/p1/settings',
    );
    expect((await normalizeAppDeepLink(Uri.parse('/'))).toString(), '/');
  });
}
