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
    final launchSets = await _stageLaunchImages(catalog, bundleDir);
    if (iconFiles == null && launchSets == null) return null;
    return DnCompiledAssets(
      iconFiles: iconFiles ?? const [],
      launchSets: launchSets ?? const [],
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

  /// Stage launch images into the bundle with scale-aware names so
  /// `UIImage imageNamed:` scale lookup works (`<base>.png`, `<base>@2x.png`,
  /// `<base>@3x.png`).
  ///
  /// Returns the staged sets (base name + available scales), or null when the
  /// catalog has no launch imageset with files.
  static Future<List<DnLaunchImageSet>?> _stageLaunchImages(
    String catalog,
    String bundleDir,
  ) async {
    final sets = <DnLaunchImageSet>[];
    for (final setName in ['LaunchImage', 'LaunchBackground']) {
      final setDir = p.join(catalog, '$setName.imageset');
      final manifest = File(p.join(setDir, 'Contents.json'));
      if (!manifest.existsSync()) continue;
      try {
        final doc =
            jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
        final scales = <String>[];
        for (final entry in ((doc['images'] as List?) ?? [])
            .cast<Map<String, dynamic>>()) {
          final filename = entry['filename'] as String?;
          if (filename == null || filename.isEmpty) continue;
          final source = File(p.join(setDir, filename));
          if (!source.existsSync()) continue;
          final scale = (entry['scale'] as String?) ?? '1x';
          final suffix = switch (scale) {
            '2x' => '@2x',
            '3x' => '@3x',
            _ => '',
          };
          await source.copy(p.join(bundleDir, '$setName$suffix.png'));
          scales.add(scale);
        }
        if (scales.isNotEmpty) {
          sets.add(DnLaunchImageSet(name: setName, scales: scales));
        }
      } on Object {
        continue;
      }
    }
    return sets.isEmpty ? null : sets;
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

  /// Splash image base name for `UILaunchScreen.UIImageName`: prefers the
  /// `LaunchImage` set (full-screen splash with all scales), falling back to
  /// `LaunchBackground` and then any staged set.
  static String? splashImageName(List<DnLaunchImageSet> sets) {
    for (final preferred in ['LaunchImage', 'LaunchBackground']) {
      for (final set in sets) {
        if (set.name == preferred) return set.name;
      }
    }
    return sets.isEmpty ? null : sets.first.name;
  }
}

/// Result of [DnAssetCatalog.compile].
final class DnCompiledAssets {
  const DnCompiledAssets({required this.iconFiles, required this.launchSets});

  /// Bundle basenames for `CFBundleIconFiles`.
  final List<String> iconFiles;

  /// Staged launch imagesets (scale-aware bundle PNGs).
  final List<DnLaunchImageSet> launchSets;

  bool get hasIcons => iconFiles.isNotEmpty;
  bool get hasLaunchImages => launchSets.isNotEmpty;

  /// Base name for `UILaunchScreen.UIImageName`, or null when no launch
  /// imageset was staged.
  String? get splashImageName => DnAssetCatalog.splashImageName(launchSets);
}

/// One staged launch imageset: `<name>.png` / `<name>@2x.png` /
/// `<name>@3x.png` in the bundle root, per the scales present in the
/// imageset manifest.
final class DnLaunchImageSet {
  const DnLaunchImageSet({required this.name, required this.scales});

  final String name;
  final List<String> scales;
}
