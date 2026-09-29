import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/models/pack_result.dart';

/// Resolves an already-built DartNative iOS `.app` into a [PackResult].
///
/// xcross does not reimplement the DartNative/Zero build: `dn build`
/// produces the `.app` (on macOS today), and xcross reuses its own
/// signing, install, and CoreDevice launch pipeline from there.
abstract final class DnAppResolver {
  static final _bundleIdPattern = RegExp(
    r'<key>CFBundleIdentifier</key>\s*<string>([^<]*)</string>',
  );

  /// Locate the `.app` to deploy.
  ///
  /// Precedence: explicit `--app-path`, then `build/ios/iphoneos/*.app`
  /// (newest first). Throws [XcrossError] when nothing is found.
  static PackResult resolve({required String projectRoot, String? appPath, String? bundleIdOverride}) {
    final app = appPath != null && appPath.isNotEmpty
        ? appPath
        : _findBuiltApp(projectRoot);
    if (app == null) {
      throw XcrossError(
        'No DartNative .app found. Run `dn build ios` first (on macOS) or '
        'pass --app-path <YourApp.app>.',
      );
    }
    final dir = Directory(app);
    if (!dir.existsSync()) {
      throw XcrossError('DartNative .app not found at $app.');
    }
    final bundleId = bundleIdOverride?.isNotEmpty == true
        ? bundleIdOverride!
        : readBundleId(app) ??
            (() => throw XcrossError(
                  'Could not read CFBundleIdentifier from $app/Info.plist. '
                  'Pass --bundle-id.',
                ))();
    return PackResult(outputPath: app, bundleId: bundleId, projectRoot: projectRoot);
  }

  /// Newest `build/ios/iphoneos/*.app`, or null when there is none.
  static String? findBuiltApp(String projectRoot) => _findBuiltApp(projectRoot);

  static String? _findBuiltApp(String projectRoot) {
    for (final candidate in [
      p.join(projectRoot, 'build', 'ios', 'iphoneos'),
      p.join(projectRoot, 'build', 'ios'),
    ]) {
      final dir = Directory(candidate);
      if (!dir.existsSync()) continue;
      final apps = dir
          .listSync()
          .whereType<Directory>()
          .where((e) => e.path.endsWith('.app'))
          .toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      if (apps.isNotEmpty) return apps.first.path;
    }
    return null;
  }

  /// Read `CFBundleIdentifier` from `<app>/Info.plist`, or null when absent.
  static String? readBundleId(String appPath) {
    final plist = File(p.join(appPath, 'Info.plist'));
    if (!plist.existsSync()) return null;
    final match = _bundleIdPattern.firstMatch(plist.readAsStringSync());
    final value = match?.group(1)?.trim();
    if (value == null || value.isEmpty || value.contains(r'$')) return null;
    return value;
  }
}
