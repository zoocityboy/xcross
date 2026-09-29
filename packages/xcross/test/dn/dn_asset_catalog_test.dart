import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/dn/dn_asset_catalog.dart';

void main() {
  group('DnAssetCatalog', () {
    late Directory project;
    late Directory bundle;

    setUp(() {
      project = Directory.systemTemp.createTempSync('dn-assets-proj');
      bundle = Directory.systemTemp.createTempSync('dn-assets-bundle');
      final setDir = Directory(
        p.join(project.path, 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset'),
      )..createSync(recursive: true);
      // 1024px red source like a real DN template icon.
      final source = img.Image(width: 1024, height: 1024);
      img.fill(source, color: img.ColorRgb8(200, 30, 30));
      File(p.join(setDir.path, 'AppIcon.png'))
          .writeAsBytesSync(img.encodePng(source));
      File(p.join(setDir.path, 'Contents.json')).writeAsStringSync(
        jsonEncode({
          'images': [
            {'filename': 'AppIcon.png', 'idiom': 'universal', 'size': '1024x1024'},
          ],
          'info': {'author': 'xcode', 'version': 1},
        }),
      );
      final launchDir = Directory(
        p.join(project.path, 'ios', 'Runner', 'Assets.xcassets', 'LaunchImage.imageset'),
      )..createSync(recursive: true);
      final splash = img.Image(width: 100, height: 100);
      File(p.join(launchDir.path, 'LaunchImage.png'))
          .writeAsBytesSync(img.encodePng(splash));
      File(p.join(launchDir.path, 'Contents.json')).writeAsStringSync(
        jsonEncode({
          'images': [
            {'filename': 'LaunchImage.png', 'idiom': 'universal', 'scale': '1x'},
          ],
          'info': {'author': 'dartnative_splash', 'version': 1},
        }),
      );
    });

    tearDown(() {
      project.deleteSync(recursive: true);
      bundle.deleteSync(recursive: true);
    });

    test('compiles icons to all slots and stages launch images', () async {
      final compiled = await DnAssetCatalog.compile(
        projectRoot: project.path,
        bundleDir: bundle.path,
      );
      expect(compiled, isNotNull);
      expect(compiled!.hasIcons, isTrue);
      expect(compiled.hasLaunchImages, isTrue);
      // Every icon slot exists on disk at the exact pixel size.
      for (final base in compiled.iconFiles) {
        final file = File(p.join(bundle.path, '$base.png'));
        expect(file.existsSync(), isTrue, reason: base);
        final decoded = img.decodeImage(file.readAsBytesSync())!;
        final m = RegExp(r'(\d+(?:\.\d+)?)x\d+(?:\.\d+)?@(\d)x').firstMatch(base)!;
        final expected = (double.parse(m.group(1)!) * int.parse(m.group(2)!)).round();
        expect(decoded.width, expected, reason: base);
        expect(decoded.height, expected, reason: base);
      }
      expect(
        File(p.join(bundle.path, 'LaunchImage-LaunchImage.png')).existsSync(),
        isTrue,
      );
    });

    test('plist fragments reference staged files', () async {
      final compiled = await DnAssetCatalog.compile(
        projectRoot: project.path,
        bundleDir: bundle.path,
      );
      final icons = DnAssetCatalog.cfbundleIconsFragment(compiled!.iconFiles);
      expect(icons, contains('CFBundleIcons'));
      expect(icons, contains('CFBundleIcons~ipad'));
      expect(icons, contains(compiled.iconFiles.first));
      final launch =
          DnAssetCatalog.uiLaunchImagesFragment(compiled.launchImages);
      expect(launch, contains('UILaunchImages'));
      expect(launch, contains('LaunchImage-LaunchImage'));
    });

    test('returns null without a catalog', () async {
      final empty = Directory.systemTemp.createTempSync('dn-assets-empty');
      try {
        Directory(p.join(empty.path, 'ios')).createSync();
        expect(
          await DnAssetCatalog.compile(
            projectRoot: empty.path,
            bundleDir: bundle.path,
          ),
          isNull,
        );
      } finally {
        empty.deleteSync(recursive: true);
      }
    });
  });
}
