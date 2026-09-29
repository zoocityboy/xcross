import 'package:test/test.dart';
import 'package:xcross/src/dn/dn_build_options.dart';
import 'package:xcross/src/dn/dn_pack_operation.dart';

void main() {
  group('DnBuildOptions', () {
    test('resolve merges dart-define-from-file under explicit defines', () async {
      final options = await DnBuildOptions.resolve(
        target: 'lib/main.dart',
        dartDefine: ['B=2'],
        dartDefineFromFile: [],
        pub: true,
      );
      expect(options.dartDefines, ['B=2']);
      expect(options.target, 'lib/main.dart');
      expect(options.pub, isTrue);
    });
  });

  group('DnPackOperation.bundleArgs', () {
    test('builds ios bundle args with defines and build-number', () {
      final args = DnPackOperation.bundleArgs(
        options: const DnBuildOptions(
          // ignore: avoid_redundant_argument_values
          target: 'lib/main.dart',
          dartDefines: ['A=1'],
          buildNumber: '7',
        ),
        assetDir: '/tmp/assets',
      );
      expect(
        args,
        [
          'build',
          'bundle',
          '-t',
          'lib/main.dart',
          '--target-platform',
          'ios',
          '--asset-dir',
          '/tmp/assets',
          '--build-number=7',
          '-D',
          'A=1',
        ],
      );
    });

    test('adds --no-pub and flavor define', () {
      final args = DnPackOperation.bundleArgs(
        options: const DnBuildOptions(pub: false, flavor: 'dev'),
        assetDir: '/tmp/assets',
      );
      expect(args, contains('--no-pub'));
      expect(args, contains('FLUTTER_APP_FLAVOR=dev'));
    });

    test('explicit flavor define wins over --flavor', () {
      final args = DnPackOperation.bundleArgs(
        options: const DnBuildOptions(
          dartDefines: ['FLUTTER_APP_FLAVOR=prod'],
          flavor: 'dev',
        ),
        assetDir: '/tmp/assets',
      );
      expect(
        args.where((a) => a.startsWith('FLUTTER_APP_FLAVOR=')).toList(),
        ['FLUTTER_APP_FLAVOR=prod'],
      );
    });
  });
}
