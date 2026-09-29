import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/dn/dn_native_deps.dart';

void main() {
  group('DnNativeDeps', () {
    test('cache dir is version-pinned', () {
      expect(
        DnNativeDeps.cacheDir(cacheRoot: '/cache'),
        p.join('/cache', 'FlexLayout-${DnNativeDeps.flexLayoutVersion}'),
      );
      expect(DnNativeDeps.flexLayoutVersion, '2.0.10');
    });
  });
}
