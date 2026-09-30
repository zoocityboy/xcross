import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/dap/xcross_dap.dart';

void main() {
  group('XcrossDap.runArguments', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('xcross-dap-run-args-');
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    Directory projectWith(String pubspec) {
      final dir = Directory(p.join(temp.path, 'proj_${temp.listSync().length}'))
        ..createSync();
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(pubspec);
      return dir;
    }

    test('selects dn run for a DartNative project', () {
      final dir = projectWith(
        'name: demo\ndependencies:\n  dartnative: ^1.0.0\n',
      );
      expect(
        XcrossDap.runArguments(cwd: dir.path, target: 'lib/main.dart'),
        ['dn', 'run', '--target', 'lib/main.dart'],
      );
    });

    test('selects flutter run for a plain Flutter project', () {
      final dir = projectWith(
        'name: demo\ndependencies:\n  flutter:\n    sdk: flutter\n',
      );
      expect(
        XcrossDap.runArguments(cwd: dir.path, target: 'lib/main.dart'),
        ['flutter', 'run', '--target', 'lib/main.dart'],
      );
    });

    test('selects flutter run without a pubspec and passes args through', () {
      expect(
        XcrossDap.runArguments(
          cwd: temp.path,
          target: 'lib/main.dart',
          args: ['--udid', 'ABC'],
        ),
        ['flutter', 'run', '--target', 'lib/main.dart', '--udid', 'ABC'],
      );
    });

    test('passes launch args through for dn projects', () {
      final dir = projectWith(
        'name: demo\ndependencies:\n  dartnative_ios: ^1.0.0\n',
      );
      expect(
        XcrossDap.runArguments(
          cwd: dir.path,
          target: 'lib/main.dart',
          args: ['--udid', 'ABC'],
        ),
        ['dn', 'run', '--target', 'lib/main.dart', '--udid', 'ABC'],
      );
    });
  });
}
