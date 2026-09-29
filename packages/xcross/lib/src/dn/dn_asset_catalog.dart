import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Pure-Dart replacement for `actool` (Asset Catalog compiler), which is
/// macOS-only.
///
/// Standard `dn`/`xcodebuild` compiles `ios/Runner/Assets.xcassets` into
/// `Assets.car`. That binary format has no Linux implementation, so xcross
/// reaches the same on-device result through the documented bundle
/// mechanisms iOS honors without a `.car`:
///
/// * **App icon** — the 1024px universal source from `AppIcon.appiconset` is
///   resized to every required iPhone/iPad slot, written as loose PNGs into
///   the bundle root, and referenced from `CFBundleIcons` /
///   `CFBundleIcons~ipad` (the same keys `actool` generates).
/// * **Launch images** — `LaunchImage.imageset` / `LaunchBackground.imageset`
///   PNGs are staged into the bundle and referenced from `UILaunchImages`,
///   so the splash appears even though `LaunchScreen.storyboard` cannot be
///   compiled without `ibtool` (the Runner's storyboard fallback in
///   `DnRunnerShim` stays as a safety net).
///
/// Returns the `Info.plist` fragment keys to merge, or null when the project
/// has no asset catalog (icon stays default, splash skipped — same as before).
abstract final class DnAssetCatalog {
  /// Required icon slots as (points, scale): the set `actool` emits for a
  /// universal iOS app icon.
  static const _iconSlots = [
    (20, 2),
    (20, 3),
    (29, 2),
    (29, 3),
    (40, 2),
    (40, 3),
    (60, 2),
    (60, 3),
    (76, 2),
    (83.5, 2),
    (1024, 1),
  ];

  /// Compile `Assets.xcassets` from [projectRoot] into [bundleDir].
  ///
  /// Returns plist XML fragments for `CFBundleIcons`, `CFBundleIcons~ipad`
  /// and `UILaunchImages` to splice into `Info.plist`, or null when there is
  /// nothing to compile.
  static Future<DnCompiledAssets?> compile({
    required String projectRoot,
    required String bundleDir,
  }) async {
    final catalog = _findCatalog(projectRoot);
    if (catalog == null) return null;

    final iconFiles = await _compileAppIcon(catalog, bundleDir);
    final launchImages = await _stageLaunchImages(catalog, bundleDir);
    if (iconFiles == null && launchImages == null) return null;
    return DnCompiledAssets(
      iconFiles: iconFiles ?? const [],
      launchImages: launchImages ?? const [],
    );
  }

  static String? _findCatalog(String projectRoot) {
    final runner = p.join(projectRoot, 'ios', 'Runner', 'Assets.xcassets');
    if (Directory(runner).existsSync()) return runner;
    final ios = Directory(p.join(projectRoot, 'ios'));
    if (!ios.existsSync()) return null;
    for (final entity in ios.listSync(recursive: true, followLinks: false)) {
      if (entity is Directory && p.extension(entity.path) == '.xcassets') {
        return entity.path;
      }
    }
    return null;
  }

  /// Resize the appiconset source to all [iconFiles] slots.
  ///
  /// Returns the bundle-relative basenames (without extension) for
  /// `CFBundleIconFiles`, or null when no usable source exists.
  static Future<List<String>?> _compileAppIcon(
    String catalog,
    String bundleDir,
  ) =>
      Log.logStep('Compiling AppIcon', () async {
        final setDir = p.join(catalog, 'AppIcon.appiconset');
        final manifest = File(p.join(setDir, 'Contents.json'));
        if (!manifest.existsSync()) return null;
        final source = _appIconSource(setDir, manifest.readAsStringSync());
        if (source == null) return null;
        final decoded = img.decodeImage(await File(source).readAsBytes());
        if (decoded == null) {
          Log.logWarn('could not decode AppIcon source $source; icon skipped.');
          return null;
        }
        final names = <String>[];
        for (final (points, scale) in _iconSlots) {
          final px = (points * scale).round();
          // The 1024 marketing icon is copied at native resolution when the
          // source is smaller (never upscale beyond source quality); every
          // device slot is resized exactly.
          final resized = px == 1024 && decoded.width < 1024
              ? decoded
              : img.copyResize(
                  decoded,
                  width: px,
                  height: px,
                  interpolation: img.Interpolation.cubic,
                );
          final base =
              'AppIcon${points % 1 == 0 ? points.toInt() : points}x$points@${scale}x';
          final file = File(p.join(bundleDir, '$base.png'));
          await file.writeAsBytes(img.encodePng(resized));
          names.add(base);
        }
        return names;
      });

  /// Pick the 1024px universal source, falling back to the largest available.
  static String? _appIconSource(String setDir, String contentsJson) {
    try {
      final doc = jsonDecode(contentsJson) as Map<String, dynamic>;
      final images = (doc['images'] as List).cast<Map<String, dynamic>>();
      String? fallback;
      var fallbackPx = 0;
      for (final entry in images) {
        final filename = entry['filename'] as String?;
        if (filename == null || filename.isEmpty) continue;
        final candidate = p.join(setDir, filename);
        if (!File(candidate).existsSync()) continue;
        final size = (entry['size'] as String?) ?? '';
        if (size.startsWith('1024')) return candidate;
        final px = int.tryParse(size.split('x').first) ?? 0;
        if (px > fallbackPx) {
          fallbackPx = px;
          fallback = candidate;
        }
      }
      if (fallback != null) return fallback;
      // Manifest without filenames: any PNG in the directory.
      for (final entity in Directory(setDir).listSync()) {
        if (entity is File && p.extension(entity.path) == '.png') {
          return entity.path;
        }
      }
      return null;
    } on Object {
      return null;
    }
  }

  /// Stage launch images into the bundle; returns UILaunchImages entries.
  static Future<List<DnLaunchImage>?> _stageLaunchImages(
    String catalog,
    String bundleDir,
  ) async {
    final entries = <DnLaunchImage>[];
    for (final setName in ['LaunchImage', 'LaunchBackground']) {
      final setDir = p.join(catalog, '$setName.imageset');
      final manifest = File(p.join(setDir, 'Contents.json'));
      if (!manifest.existsSync()) continue;
      try {
        final doc = jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
        for (final entry in ((doc['images'] as List?) ?? [])
            .cast<Map<String, dynamic>>()) {
          final filename = entry['filename'] as String?;
          if (filename == null || filename.isEmpty) continue;
          final source = File(p.join(setDir, filename));
          if (!source.existsSync()) continue;
          final destName = '$setName-${p.basenameWithoutExtension(filename)}.png';
          await source.copy(p.join(bundleDir, destName));
          entries.add(
            DnLaunchImage(
              name: p.basenameWithoutExtension(destName),
              scale: (entry['scale'] as String?) ?? '1x',
            ),
          );
        }
      } on Object {
        continue;
      }
    }
    return entries.isEmpty ? null : entries;
  }

  /// `CFBundleIcons` (+ `~ipad`) dict fragment for [iconFiles].
  static String cfbundleIconsFragment(List<String> iconFiles) {
    final files = iconFiles.map((f) => '<string>$f</string>').join();
    String dict(String files) =>
        '<dict><key>CFBundlePrimaryIcon</key><dict>'
        '<key>CFBundleIconFiles</key><array>$files</array>'
        '<key>UIPrerenderedIcon</key><false/>'
        '</dict></dict>';
    return '<key>CFBundleIcons</key>${dict(files)}'
        '<key>CFBundleIcons~ipad</key>${dict(files)}';
  }

  /// `UILaunchImages` array fragment for [images].
  static String uiLaunchImagesFragment(List<DnLaunchImage> images) {
    final items = StringBuffer();
    for (final e in images) {
      items.write('<dict><key>UILaunchImageName</key><string>${e.name}</string><key>UILaunchImageSize</key><string>{320, 480}</string><key>UILaunchImageOrientation</key><string>Portrait</string><key>UILaunchImageMinimumOSVersion</key><string>7.0</string><key>UILaunchImageScale</key><string>${e.scale}</string></dict>');
    }
    return '<key>UILaunchImages</key><array>$items</array>';
  }
}

/// Result of [DnAssetCatalog.compile].
final class DnCompiledAssets {
  const DnCompiledAssets({required this.iconFiles, required this.launchImages});

  /// Bundle basenames for `CFBundleIconFiles`.
  final List<String> iconFiles;

  /// Staged launch images for `UILaunchImages`.
  final List<DnLaunchImage> launchImages;

  bool get hasIcons => iconFiles.isNotEmpty;
  bool get hasLaunchImages => launchImages.isNotEmpty;
}

/// One staged launch image.
final class DnLaunchImage {
  const DnLaunchImage({required this.name, required this.scale});

  final String name;
  final String scale;
}
