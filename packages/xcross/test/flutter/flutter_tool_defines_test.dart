import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/flutter_tool_defines.dart';

void main() {
  group('FlutterToolDefines.sdkDefinesFromJson', () {
    test('maps --version --machine fields, truncating revisions', () {
      expect(
        FlutterToolDefines.sdkDefinesFromJson({
          'frameworkVersion': '3.47.5',
          'channel': 'stable',
          'repositoryUrl': 'https://github.com/flutter/flutter.git',
          'frameworkRevision': '6a19cca56475dbfba1478ee68d7bd0c2ef891da1',
          'engineRevision': 'af7e796e161ae0bb1ff0758c71a7105418bd9ded',
          'dartSdkVersion': '3.13.4',
        }),
        [
          'FLUTTER_VERSION=3.47.5',
          'FLUTTER_CHANNEL=stable',
          'FLUTTER_GIT_URL=https://github.com/flutter/flutter.git',
          'FLUTTER_FRAMEWORK_REVISION=6a19cca564',
          'FLUTTER_ENGINE_REVISION=af7e796e16',
          'FLUTTER_DART_VERSION=3.13.4',
        ],
      );
    });

    test('tolerates missing fields as empty values', () {
      expect(
        FlutterToolDefines.sdkDefinesFromJson({}),
        [
          'FLUTTER_VERSION=',
          'FLUTTER_CHANNEL=',
          'FLUTTER_GIT_URL=',
          'FLUTTER_FRAMEWORK_REVISION=',
          'FLUTTER_ENGINE_REVISION=',
          'FLUTTER_DART_VERSION=',
        ],
      );
    });
  });

  group('FlutterToolDefines.parsePubspecVersion', () {
    test('splits name+build on the first plus', () {
      expect(
        FlutterToolDefines.parsePubspecVersion('1.0.0+1'),
        ('1.0.0', '1'),
      );
      expect(
        FlutterToolDefines.parsePubspecVersion('2.0.0-rc.1+42'),
        ('2.0.0-rc.1', '42'),
      );
    });

    test('handles missing build, blank, and null', () {
      expect(FlutterToolDefines.parsePubspecVersion('1.0.0'), ('1.0.0', null));
      expect(FlutterToolDefines.parsePubspecVersion(''), (null, null));
      expect(FlutterToolDefines.parsePubspecVersion(null), (null, null));
      expect(FlutterToolDefines.parsePubspecVersion('1.0.0+'), ('1.0.0', null));
    });
  });

  group('FlutterToolDefines.buildDefines', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('xcross-tool-defines-');
    });

    tearDown(() => tmp.delete(recursive: true));

    Future<void> writePubspec(String content) =>
        File(p.join(tmp.path, 'pubspec.yaml')).writeAsString(content);

    test('explicit flags win over pubspec version', () async {
      await writePubspec('name: demo\nversion: 1.0.0+1\n');
      expect(
        FlutterToolDefines.buildDefines(
          projectRoot: tmp.path,
          buildName: '2.0',
          buildNumber: '7',
        ),
        ['FLUTTER_BUILD_NAME=2.0', 'FLUTTER_BUILD_NUMBER=7'],
      );
    });

    test('falls back to pubspec version, then to 1.0.0/1', () async {
      await writePubspec('name: demo\nversion: 1.0.0+1\n');
      expect(
        FlutterToolDefines.buildDefines(projectRoot: tmp.path),
        ['FLUTTER_BUILD_NAME=1.0.0', 'FLUTTER_BUILD_NUMBER=1'],
      );

      await writePubspec('name: demo\n');
      expect(
        FlutterToolDefines.buildDefines(projectRoot: tmp.path),
        ['FLUTTER_BUILD_NAME=1.0.0', 'FLUTTER_BUILD_NUMBER=1'],
      );
    });
  });
}
