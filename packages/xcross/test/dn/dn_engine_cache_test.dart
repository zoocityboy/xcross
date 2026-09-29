import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/dn/dn_engine_cache.dart';
import 'package:xcross/src/errors.dart';

void main() {
  group('DnEngineCache', () {
    test('derives sdk root and engine paths from the dn executable', () {
      final dir = Directory.systemTemp.createTempSync('dn-engine');
      try {
        final dn = File(p.join(dir.path, 'zero', 'bin', 'dn'))
          ..createSync(recursive: true);
        final cache = DnEngineCache(dnExecutable: dn.path);
        expect(cache.dnRoot, p.join(dir.path, 'zero'));
        expect(
          cache.flutterXcframework,
          p.join(
            dir.path,
            'zero',
            'bin',
            'cache',
            'artifacts',
            'engine',
            'ios',
            'Flutter.xcframework',
          ),
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('flutterDeviceFramework throws when the engine is missing', () {
      final dir = Directory.systemTemp.createTempSync('dn-engine-missing');
      try {
        final dn = File(p.join(dir.path, 'zero', 'bin', 'dn'))
          ..createSync(recursive: true);
        final cache = DnEngineCache(dnExecutable: dn.path);
        expect(
          () => cache.flutterDeviceFramework,
          throwsA(
            isA<XcrossError>().having(
              (e) => e.message,
              'message',
              contains('dn precache --ios'),
            ),
          ),
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('flutterDeviceFramework resolves a precached engine', () {
      final dir = Directory.systemTemp.createTempSync('dn-engine-present');
      try {
        final framework = Directory(
          p.join(
            dir.path,
            'zero',
            'bin',
            'cache',
            'artifacts',
            'engine',
            'ios',
            'Flutter.xcframework',
            'ios-arm64',
            'Flutter.framework',
          ),
        )..createSync(recursive: true);
        final dn = File(p.join(dir.path, 'zero', 'bin', 'dn'))
          ..createSync(recursive: true);
        final cache = DnEngineCache(dnExecutable: dn.path);
        expect(cache.flutterDeviceFramework, framework.path);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}
