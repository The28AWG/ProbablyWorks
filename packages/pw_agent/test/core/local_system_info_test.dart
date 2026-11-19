import 'package:pw_agent/core/platform/local_system_info.dart';
import 'package:test/test.dart';

void main() {
  LocalSystemInfo? detect({
    bool hasLocalHost = true,
    required String operatingSystem,
    String operatingSystemVersion = '',
    Map<String, String> files = const {},
    Map<String, String?> commands = const {},
  }) => detectLocalSystem(
    hasLocalHost: hasLocalHost,
    operatingSystem: operatingSystem,
    operatingSystemVersion: operatingSystemVersion,
    readFile: (path) => files[path],
    run: (executable, arguments) =>
        commands['$executable ${arguments.join(' ')}'],
  );

  test('iOS has no local system because there is no local Host', () {
    expect(detect(hasLocalHost: false, operatingSystem: 'ios'), isNull);
  });

  test('Android takes the release from the system property', () {
    final info = detect(
      operatingSystem: 'android',
      operatingSystemVersion: 'UP1A.231005.007',
      commands: const {'getprop ro.build.version.release': '14'},
    );

    expect(info?.displayName, 'Android 14');
  });

  test('Android without getprop still has a readable name', () {
    final info = detect(operatingSystem: 'android');

    expect(info?.displayName, 'Android');
  });

  test('Linux shows PRETTY_NAME with the distribution and version', () {
    final info = detect(
      operatingSystem: 'linux',
      files: const {
        '/etc/os-release': '''
NAME="Ubuntu"
VERSION="24.04.1 LTS (Noble Numbat)"
VERSION_ID="24.04"
PRETTY_NAME="Ubuntu 24.04.1 LTS"
''',
      },
    );

    expect(info?.displayName, 'Ubuntu 24.04.1 LTS');
  });

  test('Linux falls back to NAME and VERSION_ID without PRETTY_NAME', () {
    final info = detect(
      operatingSystem: 'linux',
      files: const {'/etc/os-release': 'NAME=Fedora\nVERSION_ID=40\n'},
    );

    expect(info?.displayName, 'Fedora 40');
  });

  test('Linux without os-release shows the kernel release', () {
    final info = detect(
      operatingSystem: 'linux',
      operatingSystemVersion: 'Linux 6.8.0-45-generic #45-Ubuntu SMP',
    );

    expect(info?.displayName, 'Linux 6.8.0-45-generic');
  });

  test('macOS reads the system version plist', () {
    final info = detect(
      operatingSystem: 'macos',
      files: const {
        '/System/Library/CoreServices/SystemVersion.plist': '''
<plist version="1.0">
<dict>
  <key>ProductName</key>
  <string>macOS</string>
  <key>ProductVersion</key>
  <string>15.1.1</string>
</dict>
</plist>
''',
      },
    );

    expect(info?.displayName, 'macOS 15.1.1');
  });

  test('macOS falls back to sw_vers', () {
    final info = detect(
      operatingSystem: 'macos',
      commands: const {
        'sw_vers -productName': 'macOS',
        'sw_vers -productVersion': '14.6.1',
      },
    );

    expect(info?.displayName, 'macOS 14.6.1');
  });

  test('Windows shows the edition, marketing version and build', () {
    final info = detect(
      operatingSystem: 'windows',
      operatingSystemVersion: '"Windows 11 Pro" 10.0 (Build 22631)',
      commands: const {
        r'reg query HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion /v DisplayVersion':
            '    DisplayVersion    REG_SZ    23H2',
      },
    );

    expect(info?.displayName, 'Windows 11 Pro 23H2');
  });

  test('Windows 11 is recognised by the build even if the name says 10', () {
    final info = detect(
      operatingSystem: 'windows',
      operatingSystemVersion: '"Windows 10 Pro" 10.0 (Build 22631)',
    );

    expect(info?.displayName, 'Windows 11 Pro (Build 22631)');
  });

  test(
    'Windows falls back to the platform version when the format changes',
    () {
      final info = detect(
        operatingSystem: 'windows',
        operatingSystemVersion: 'Windows Server 2022',
      );

      expect(info?.displayName, 'Windows Server 2022');
    },
  );

  test('an unknown system still gets a readable name', () {
    final info = detect(
      operatingSystem: 'fuchsia',
      operatingSystemVersion: '1.0',
    );

    expect(info?.displayName, 'Fuchsia 1.0');
  });
}
