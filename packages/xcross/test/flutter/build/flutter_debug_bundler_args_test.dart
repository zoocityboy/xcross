import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/flutter_debug_bundler.dart';

void main() {
  group('FlutterDebugBundler.toolDefineFlags', () {
    test('appends tool defines under user defines', () {
      expect(
        FlutterDebugBundler.toolDefineFlags(
          userDefines: ['A=1'],
          flavor: null,
          toolDefines: ['FLUTTER_VERSION=3.0', 'FLUTTER_BUILD_NAME=1.0.0'],
        ),
        ['-DFLUTTER_VERSION=3.0', '-DFLUTTER_BUILD_NAME=1.0.0'],
      );
    });

    test('explicit keys (incl. flavor) win over tool defines', () {
      expect(
        FlutterDebugBundler.toolDefineFlags(
          userDefines: ['FLUTTER_VERSION=9.9', 'FLUTTER_APP_FLAVOR=prod'],
          flavor: 'dev',
          toolDefines: ['FLUTTER_VERSION=3.0', 'FLUTTER_BUILD_NAME=1.0.0'],
        ),
        ['-DFLUTTER_BUILD_NAME=1.0.0'],
      );
    });

    test('adds the flavor define when missing', () {
      expect(
        FlutterDebugBundler.toolDefineFlags(
          userDefines: [],
          flavor: 'dev',
          toolDefines: ['FLUTTER_APP_FLAVOR=dev', 'FLUTTER_VERSION=3.0'],
        ),
        // The flavor slot is already taken by the derived define, so the
        // tool copy is dropped and only genuinely new keys are emitted.
        ['-DFLUTTER_VERSION=3.0'],
      );
    });
  });
}
