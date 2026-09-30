import 'dart:io';

import 'package:test/test.dart';
import 'package:xcross/src/dn/dn_injected_defines.dart';

const _frontendLine =
    '[   +4 ms] /home/u/zero/bin/cache/dart-sdk/bin/dartaotruntime '
    '/home/u/zero/bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot '
    '--sdk-root /home/u/zero/bin/cache/artifacts/engine/common/flutter_patched_sdk/ '
    '--target=flutter --no-print-incremental-dependencies '
    '-DDN_LICENSE_KEY=dnk_testkey0123456789abcdef0000000000 '
    '-DFLUTTER_VERSION=3.45.0-0.1.pre -DFLUTTER_CHANNEL=stable '
    '-DFLUTTER_GIT_URL=unknown source -DFLUTTER_FRAMEWORK_REVISION=fe815c53cd '
    '-DFLUTTER_ENGINE_REVISION=2baa73665c '
    '-DFLUTTER_DART_VERSION=3.12.0 (build 3.12.0-192.0.dev) '
    '-Ddart.vm.profile=false -Ddart.vm.product=false --enable-asserts '
    '--track-widget-creation --packages /proj/.dart_tool/package_config.json '
    '--output-dill /proj/.dart_tool/flutter_build/abc/app.dill '
    '--incremental package:my_app/main.dart';

void main() {
  group('DnInjectedDefines.extractFromBuildLog', () {
    test('scrapes license and FLUTTER_* flags, skips toolchain flags', () {
      expect(
        DnInjectedDefines.extractFromBuildLog(_frontendLine),
        [
          'DN_LICENSE_KEY=dnk_testkey0123456789abcdef0000000000',
          'FLUTTER_VERSION=3.45.0-0.1.pre',
          'FLUTTER_CHANNEL=stable',
          'FLUTTER_GIT_URL=unknown source',
          'FLUTTER_FRAMEWORK_REVISION=fe815c53cd',
          'FLUTTER_ENGINE_REVISION=2baa73665c',
          'FLUTTER_DART_VERSION=3.12.0 (build 3.12.0-192.0.dev)',
        ],
      );
    });

    test('ignores non-frontend_server lines and user -D args elsewhere', () {
      const log =
          '[   +1 ms] running: dn build bundle -D A=1\n'
          'some other line -DFLUTTER_VERSION=9.9.9\n'
          '$_frontendLine\n';
      final found = DnInjectedDefines.extractFromBuildLog(log);
      expect(
        found.where((d) => d.startsWith('FLUTTER_VERSION=')),
        ['FLUTTER_VERSION=3.45.0-0.1.pre'],
      );
      expect(found.any((d) => d.startsWith('A=')), isFalse);
    });

    test('returns empty when dn skipped the kernel compile', () {
      expect(
        DnInjectedDefines.extractFromBuildLog(
          '[ +10 ms] Skipping kernel compile: up-to-date.\n',
        ),
        isEmpty,
      );
    });

    test('handles token and trial flags', () {
      const log =
          'x dartaotruntime frontend_server_aot.dart.snapshot '
          '-DDART_NATIVE_LICENSE_TOKEN=eyABC123 -DDN_TRIAL_ENDED=true '
          '--output-dill out/app.dill';
      expect(
        DnInjectedDefines.extractFromBuildLog(log),
        ['DART_NATIVE_LICENSE_TOKEN=eyABC123', 'DN_TRIAL_ENDED=true'],
      );
    });
  });

  group('DnInjectedDefines.merge', () {
    test('explicit user defines win over injected ones', () {
      expect(
        DnInjectedDefines.merge(
          user: ['DN_LICENSE_KEY=user-key', 'A=1'],
          injected: ['DN_LICENSE_KEY=dnk_injected', 'FLUTTER_VERSION=3.0'],
        ),
        ['DN_LICENSE_KEY=user-key', 'A=1', 'FLUTTER_VERSION=3.0'],
      );
    });
  });

  group('DnInjectedDefines cache', () {
    test('roundtrips through the cache file', () async {
      final project = Directory.systemTemp.createTempSync('dn-defines-');
      try {
        expect(DnInjectedDefines.readCache(project.path), isEmpty);
        await DnInjectedDefines.writeCache(project.path, ['DN_LICENSE_KEY=k']);
        expect(
          DnInjectedDefines.readCache(project.path),
          ['DN_LICENSE_KEY=k'],
        );
        expect(
          File(DnInjectedDefines.cachePath(project.path)).existsSync(),
          isTrue,
        );
      } finally {
        project.deleteSync(recursive: true);
      }
    });
  });

  group('DnInjectedDefines.keyOf', () {
    test('splits KEY=value and bare KEY', () {
      expect(DnInjectedDefines.keyOf('A=1'), 'A');
      expect(DnInjectedDefines.keyOf('A='), 'A');
      expect(DnInjectedDefines.keyOf('A'), 'A');
      expect(DnInjectedDefines.keyOf('A=b=c'), 'A');
    });
  });
}
