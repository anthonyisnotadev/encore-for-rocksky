import 'dart:io';

import 'package:encore_for_rocksky/services/portable_mode.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers the disk layout that decides where settings live.
///
/// The redirect itself is not exercised — it mutates a plugin singleton that
/// only exists in a real Windows app — but the detection is what a packaging
/// mistake would break, and it is pure filesystem logic.
void main() {
  late Directory appDir;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('portable_mode_test');
  });

  tearDown(() {
    if (appDir.existsSync()) appDir.deleteSync(recursive: true);
  });

  test('an ordinary build directory is not portable', () {
    expect(PortableMode.settingsPathIn(appDir.path), isNull);
  });

  test("Flutter's own lowercase `data` directory does not trigger "
      'portable mode', () {
    // Windows paths are case-insensitive, so a marker named `Data` would
    // collide with the asset bundle the runner always ships and portable mode
    // could never be off. This is the regression test for that.
    Directory('${appDir.path}${Platform.pathSeparator}data')
        .createSync(recursive: true);

    expect(PortableMode.settingsPathIn(appDir.path), isNull);
  });

  test('a PortableData directory beside the executable selects a settings '
      'directory', () {
    Directory('${appDir.path}${Platform.pathSeparator}PortableData')
        .createSync();

    final sep = Platform.pathSeparator;
    expect(
      PortableMode.settingsPathIn(appDir.path),
      '${appDir.path}${sep}PortableData${sep}settings',
    );
  });

  test('a file named PortableData is not a portable layout', () {
    File('${appDir.path}${Platform.pathSeparator}PortableData')
        .writeAsStringSync('');

    expect(PortableMode.settingsPathIn(appDir.path), isNull);
  });

  test('the settings directory is not created before it is written to', () {
    Directory('${appDir.path}${Platform.pathSeparator}PortableData')
        .createSync();

    final path = PortableMode.settingsPathIn(appDir.path)!;

    // Creating it eagerly would throw on a read-only stick; the preference
    // store creates it recursively on first write instead.
    expect(Directory(path).existsSync(), isFalse);
  });

  group('the directory portable state is looked for in', () {
    const env = 'ENCORE_PORTABLE_HOST_DIR';
    final sep = Platform.pathSeparator;

    test("is the running executable's own directory by default", () {
      expect(
        PortableMode.appDirectoryFrom(const {}, 'C:${sep}app${sep}a.exe'),
        'C:${sep}app',
      );
    });

    test("is the launcher's host directory when it sets one", () {
      // The single-file build runs the app out of %TEMP%, so its own directory
      // is the wrong answer and is about to be deleted. Only the launcher knows
      // where the distributed .exe really is.
      expect(
        PortableMode.appDirectoryFrom(
          {env: 'E:${sep}sticks'},
          'C:${sep}Temp${sep}efr-1${sep}a.exe',
        ),
        'E:${sep}sticks',
      );
    });

    test('falls back when the variable is set but empty', () {
      expect(
        PortableMode.appDirectoryFrom({env: ''}, 'C:${sep}app${sep}a.exe'),
        'C:${sep}app',
      );
    });
  });
}
