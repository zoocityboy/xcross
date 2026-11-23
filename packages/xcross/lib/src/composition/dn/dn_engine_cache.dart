import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/errors/errors.dart';

/// Locates the DartNative iOS engine artifacts (`Flutter.xcframework`)
/// inside the `dn` SDK.
///
/// The DN kernel (`dn build bundle`) is compiled by DN's Dart fork, so its
/// kernel format version only loads in the matching DN engine — never in a
/// stock Flutter engine, whose Dart version differs. The engine ships with
/// the `dn` SDK and is materialized by `dn precache --ios` (works on Linux).
@internal
final class DnEngineCache<T extends PlatformHostInterface> {
  DnEngineCache(this.dnExecutable, {required this.runner});

  final String dnExecutable;
  final ProcessRunner<T> runner;

  /// The `dn` SDK root (`~/zero` for the documented install).
  String get dnRoot =>
      p.dirname(p.dirname(File(dnExecutable).resolveSymbolicLinksSync()));

  /// Directory holding the debug/JIT iOS engine artifacts.
  String get engineDir =>
      p.join(dnRoot, 'bin', 'cache', 'artifacts', 'engine', 'ios');

  /// `Flutter.xcframework` inside [engineDir].
  String get flutterXcframework => p.join(engineDir, 'Flutter.xcframework');

  /// Device slice (`ios-arm64`) of [flutterXcframework], verified present.
  String get flutterDeviceFramework {
    final framework = p.join(
      flutterXcframework,
      'ios-arm64',
      'Flutter.framework',
    );
    if (!Directory(framework).existsSync()) {
      throw XcrossError(
        'DartNative iOS engine not found at $framework. '
        'Run `dn precache --ios` first.',
      );
    }
    return framework;
  }

  /// Ensure the iOS engine artifacts exist, running `dn precache --ios`
  /// when the `Flutter.xcframework` is missing. Safe to call repeatedly.
  Future<void> ensureArtifactsAvailable() async {
    if (Directory(
      p.join(flutterXcframework, 'ios-arm64', 'Flutter.framework'),
    ).existsSync()) {
      return;
    }
    await runner.log.logStep(
      'Precaching DartNative iOS engine',
      () => runner.runChecked(
        dnExecutable,
        ['precache', '--ios'],
        inheritStdio: runner.log.isVerbose,
        label: 'dn',
      ),
    );
    // Surface a precise error instead of a missing-file crash downstream.
    flutterDeviceFramework;
  }
}
