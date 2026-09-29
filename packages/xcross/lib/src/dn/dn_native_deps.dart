import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/cli/basic/sdk_install.dart';
import 'package:xcross/src/flutter/errors.dart';

/// Fetches and cross-builds the third-party native dependencies of the
/// DartNative iOS runtime that CocoaPods would otherwise vendor on macOS.
///
/// Today that is exactly one pod: `FlexLayout 2.0.10`
/// (`dartnative_ios.podspec`: `s.dependency 'FlexLayout', '2.0.10'`), the
/// Yoga-based layout engine the runtime's views are built on. Its upstream
/// `Package.swift` already declares the Yoga (C++20) / YogaKit (ObjC) /
/// FlexLayout (Swift) targets, so a plain `swift build` with the xcross
/// Darwin Swift SDK produces the objects; the paths are handed to
/// `DnRunnerShim`, which links them straight into `Runner`.
abstract final class DnNativeDeps {
  /// Pinned FlexLayout version matching `dartnative_ios.podspec`.
  static const flexLayoutVersion = '2.0.10';

  static String get _tarballUrl =>
      'https://github.com/layoutBox/FlexLayout/archive/refs/tags/'
      '$flexLayoutVersion.tar.gz';

  /// `<cache>/FlexLayout-<version>`; sources + SwiftPM scratch live here,
  /// so rebuilds are incremental.
  static String cacheDir({String? cacheRoot}) =>
      p.join(cacheRoot ?? _defaultCacheRoot, 'FlexLayout-$flexLayoutVersion');

  /// Object files (`.o`) of every built target, ready for the Runner link.
  ///
  /// Downloads + builds on first use; reuses the cache afterwards. Throws
  /// [FlutterBuildError] when the Swift cross-toolchain is unusable.
  static Future<List<String>> ensureBuilt({
    required DarwinSdk sdk,
    String? cacheRoot,
  }) async {
    final dir = cacheDir(cacheRoot: cacheRoot);
    final marker = File(p.join(dir, '.built'));
    if (marker.existsSync() && marker.readAsStringSync().trim() == _marker) {
      final cached = _collectObjects(dir);
      if (cached.isNotEmpty) return cached;
    }

    await _fetchSources(dir);
    await _swiftBuild(sdk: sdk, dir: dir);

    final objects = _collectObjects(dir);
    if (objects.isEmpty) {
      throw FlutterBuildError(
        'DnNativeDeps: swift build produced no objects in $dir.',
      );
    }
    await marker.writeAsString(_marker, flush: true);
    return objects;
  }

  static String get _marker => 'flexlayout-$flexLayoutVersion-evo-ok';

  /// Download + extract the FlexLayout sources (skipped when present).
  static Future<void> _fetchSources(String dir) async {
    final packageDir = p.join(dir, 'FlexLayout-$flexLayoutVersion');
    if (Directory(p.join(packageDir, 'Sources')).existsSync()) return;
    await Directory(dir).create(recursive: true);
    final tmp = await Directory.systemTemp.createTemp('dn-flexlayout-');
    try {
      final tarball = File(p.join(tmp.path, 'flex.tar.gz'));
      await Downloader.downloadToFile(
        _tarballUrl,
        tarball,
        maxAttempts: 5,
        label: 'FlexLayout $flexLayoutVersion',
      );
      await Log.logStep(
        'Extracting FlexLayout',
        () async {
          final bytes = await tarball.readAsBytes();
          final archive = TarDecoder().decodeBytes(
            const GZipDecoder().decodeBytes(bytes),
          );
          await extractArchiveToDisk(archive, dir);
        },
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  /// Cross-build the package with the host Swift + xcross Darwin Swift SDK.
  static Future<void> _swiftBuild({
    required DarwinSdk sdk,
    required String dir,
  }) async {
    final mismatch = await SdkInstall.hostToolchainMismatch(sdk.swiftSdkPath);
    if (mismatch != null) {
      throw FlutterBuildError(SdkInstall.mismatchGuidance(mismatch));
    }
    final swift = await ProcessRunner.locateTool('swift');
    final packageDir = p.join(dir, 'FlexLayout-$flexLayoutVersion');
    final scratch = p.join(dir, 'scratch');
    final iosSdk = sdk.iPhoneOSSdk();
    await Log.logStep(
      'Building FlexLayout $flexLayoutVersion',
      () => ProcessRunner.runChecked(
        swift,
        [
          'build',
          '--package-path',
          packageDir,
          '--build-system',
          'native',
          '--configuration',
          'release',
          '--swift-sdks-path',
          p.dirname(sdk.swiftSdkPath),
          '--swift-sdk',
          'arm64-apple-ios',
          '--scratch-path',
          scratch,
          '-debug-info-format',
          'none',
          // Library evolution forces the compiler to emit the full public
          // ABI (enum case constructors, synthesized ==) instead of
          // inlining them away: dartnative_ios was built against a
          // library-evolution FlexLayout and references those symbols.
          '-Xswiftc',
          '-enable-library-evolution',
          '-Xswiftc',
          '-sdk',
          '-Xswiftc',
          iosSdk,
          '-Xcc',
          '-isysroot',
          '-Xcc',
          iosSdk,
        ],
        inheritStdio: Log.isVerbose,
        label: 'swift build',
      ),
    );
  }

  /// Every built target object, excluding test targets.
  static List<String> _collectObjects(String dir) {
    final objects = <String>[];
    final release = Directory(p.join(dir, 'scratch', 'arm64-apple-ios', 'release'));
    if (!release.existsSync()) return const [];
    for (final entity in release.listSync(recursive: true)) {
      if (entity is! File || p.extension(entity.path) != '.o') continue;
      if (entity.path.contains('Tests.build')) continue;
      objects.add(entity.path);
    }
    objects.sort();
    return objects;
  }

  /// Per-user cache root, mirroring the engine artifact caches.
  static String get _defaultCacheRoot {
    final xdg = Platform.environment['XDG_CACHE_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      return p.join(xdg, 'xcross', 'dn-deps');
    }
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return p.join(home, '.cache', 'xcross', 'dn-deps');
  }
}
