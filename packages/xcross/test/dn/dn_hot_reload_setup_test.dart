import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/composition/dn/dn_context.dart';
import 'package:xcross/src/composition/dn/dn_hot_reload_setup.dart';
import 'package:xcross/src/composition/dn/dn_project.dart';

import '../cli/runtime_fixture.dart';

void main() {
  final dnAvailable = DnProject.resolveDnExecutable() != null;

  group('DnHotReloadSetup', () {
    test('resolves dn frontend_server and mirrors injected defines', () async {
      final project = Directory.systemTemp.createTempSync('dn-hot-reload-');
      try {
        File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync(
          'name: demo\ndependencies:\n  dartnative: ^1.0.0\n',
        );
        Directory(p.join(project.path, '.dart_tool')).createSync();
        File(
          p.join(project.path, '.dart_tool', 'package_config.json'),
        ).writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {
                'name': 'demo',
                'rootUri': '../',
                'packageUri': 'lib/',
                'languageVersion': '3.0',
              },
            ],
          }),
        );
        final runtime = testRuntime(environment: Platform.environment);
        final config = await DnHotReloadSetup.buildHotReloadConfig(
          context: DnContext(
            runner: runtime.runner,
            projectRoot: project.path,
            sdkRepository: runtime.sdkRepository,
            toolchainResolver: runtime.darwinToolchain,
            downloader: runtime.downloader,
            sdkInstall: runtime.sdkInstall,
          ),
          target: 'lib/main.dart',
          dartDefines: const ['A=1'],
          injectedDefines: const ['DN_LICENSE_KEY=k', 'FLUTTER_VERSION=9'],
        );
        expect(config, isNotNull);
        expect(config!.frontendServer, contains('frontend_server'));
        expect(config.dartDefines, [
          'A=1',
          'DN_LICENSE_KEY=k',
          'FLUTTER_VERSION=9',
        ]);
      } finally {
        project.deleteSync(recursive: true);
      }
    });
  }, skip: dnAvailable ? false : 'dn SDK is not installed');
}
