import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/platform/client_info.dart';

void main() {
  test('client info provides headers for the remote API', () {
    const info = ClientInfo(
      appName: 'ProbablyWorks',
      packageName: 'probably_works',
      version: '1.2.3',
      buildNumber: '42',
    );

    expect(info.headers, containsPair('x-client-app', 'ProbablyWorks'));
    expect(info.headers, containsPair('x-client-package', 'probably_works'));
    expect(info.headers, containsPair('x-client-version', '1.2.3'));
    expect(info.headers, containsPair('x-client-build', '42'));
    expect(info.headers['x-client-platform'], Platform.operatingSystem);
  });
}
