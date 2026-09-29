import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/doctor_project_checks.dart';
import 'package:xcross/src/cli/dn/dn_command.dart';
import 'package:xcross/src/cli/runner.dart';
import 'package:xcross/src/dn/dn_app_resolver.dart';
import 'package:xcross/src/dn/dn_project.dart';

void main() {
  group('DnProject', () {
    test('detects dartnative dependency', () {
      final dir = Directory.systemTemp.createTempSync('dn-detect');
      try {
        File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(
          'name: demo\ndependencies:\n  dartnative: ^1.0.0\n',
        );
        expect(DnProject.isDartNativeProject(dir.path), isTrue);
        expect(DoctorProjectChecks.detect(dir.path)?.kind.name, 'dartnative');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('plain flutter project is not dartnative', () {
      final dir = Directory.systemTemp.createTempSync('dn-plain');
      try {
        File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(
          'name: demo\ndependencies:\n  flutter:\n    sdk: flutter\n',
        );
        expect(DnProject.isDartNativeProject(dir.path), isFalse);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('DnAppResolver', () {
    test('reads bundle id and honors override', () {
      final dir = Directory.systemTemp.createTempSync('dn-app');
      try {
        final app = Directory(p.join(dir.path, 'Demo.app'))..createSync();
        File(p.join(app.path, 'Info.plist')).writeAsStringSync(
          '<?xml version="1.0"?><plist><dict> '
          '<key>CFBundleIdentifier</key><string>com.example.demo</string>'
          '</dict></plist>',
        );
        expect(DnAppResolver.readBundleId(app.path), 'com.example.demo');
        final pack = DnAppResolver.resolve(
          projectRoot: dir.path,
          appPath: app.path,
        );
        expect(pack.bundleId, 'com.example.demo');
        final overridden = DnAppResolver.resolve(
          projectRoot: dir.path,
          appPath: app.path,
          bundleIdOverride: 'com.example.other',
        );
        expect(overridden.bundleId, 'com.example.other');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('DnCommand registration', () {
    test('runner exposes dn with build and run', () {
      final runner = XcrossCli.buildRunner();
      final dn = runner.commands['dn'];
      expect(dn, isA<DnCommand>());
      expect(dn!.subcommands.containsKey('build'), isTrue);
      expect(dn.subcommands.containsKey('run'), isTrue);
    });
  });
}
