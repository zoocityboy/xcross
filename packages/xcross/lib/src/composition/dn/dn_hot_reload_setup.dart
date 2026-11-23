import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/composition/dn/dn_context.dart';
import 'package:xcross/src/composition/dn/dn_injected_defines.dart';
import 'package:xcross/src/composition/dn/dn_project.dart';
import 'package:xcross/src/shared/flutter/models/hot_reload_config.dart';
import 'package:xcross/src/shared/packages/package_config_resolver.dart';

/// Resolve hot-reload configuration for DartNative projects, mirroring
/// `HotReloadSetup` but against the `dn` SDK instead of the Flutter SDK.
///
/// The DN SDK layout mirrors Flutter's: `bin/cache/dart-sdk/bin/snapshots/`
/// holds `frontend_server_aot.dart.snapshot`, `bin/cache/dart-sdk/bin` holds
/// `dart`/`dartaotruntime`, and `bin/cache/artifacts/engine/common/`
/// holds `flutter_patched_sdk`. The DN kernel from `dn build bundle` is
/// compiled by DN's Dart fork, so incremental reloads must also run through
/// DN's `frontend_server` — a stock Flutter one would emit an incompatible
/// kernel version.
@internal
abstract final class DnHotReloadSetup {
  /// Resolve the paths a persistent DN `frontend_server` needs for hot reload.
  ///
  /// Returns null (with a warning) if a required artifact is missing —
  /// callers then launch without hot reload, exactly like the Flutter path.
  ///
  /// [injectedDefines] are dn's own build defines (license key, `FLUTTER_*`)
  /// scraped from the bundle build; they merge under explicit [dartDefines]
  /// so a restarted isolate boots with the same constants as the bundle.
  static Future<HotReloadConfig?> buildHotReloadConfig({
    required DnContext context,
    required String target,
    required List<String> dartDefines,
    List<String> injectedDefines = const [],
    bool verbose = false,
  }) async {
    final projectRoot = context.projectRoot;
    final log = context.log;
    final dn = DnProject.resolveDnExecutable();
    if (dn == null) {
      log.logWarn('dn executable not found; hot reload disabled.');
      return null;
    }
    final dnRoot = p.dirname(p.dirname(File(dn).resolveSymbolicLinksSync()));

    final snapshotsDir = p.join(
      dnRoot,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      'snapshots',
    );
    String? frontendServer;
    for (final name in [
      'frontend_server_aot.dart.snapshot',
      'frontend_server.dart.snapshot',
    ]) {
      final candidate = p.join(snapshotsDir, name);
      if (File(candidate).existsSync()) {
        frontendServer = candidate;
        break;
      }
    }
    if (frontendServer == null) {
      log.logWarn(
        'dn frontend_server snapshot missing under $snapshotsDir; '
        'hot reload disabled.',
      );
      return null;
    }

    final sdkRoot = p.join(
      dnRoot,
      'bin',
      'cache',
      'artifacts',
      'engine',
      'common',
      'flutter_patched_sdk',
    );
    if (!Directory(sdkRoot).existsSync()) {
      log.logWarn(
        'dn patched SDK missing at $sdkRoot; hot reload disabled. '
        'Run `dn precache --ios` first.',
      );
      return null;
    }

    final packageConfig = await PackageConfigResolver(
      fileSystem: context.host.fileSystem,
      paths: context.paths,
    ).require(projectRoot);
    final entrypoint = p.isAbsolute(target)
        ? target
        : p.join(projectRoot, target);

    final dartSdkBin = p.join(dnRoot, 'bin', 'cache', 'dart-sdk', 'bin');
    final isAot = p.basename(frontendServer).contains('_aot');
    final dart = p.join(
      dartSdkBin,
      context.runner.hostExecutableName(isAot ? 'dartaotruntime' : 'dart'),
    );

    final outputDill = p.join(
      projectRoot,
      'build',
      'xcross-dn-debug',
      '.hotreload',
      'app.dill',
    );
    await Directory(p.dirname(outputDill)).create(recursive: true);

    return HotReloadConfig(
      dart: dart,
      frontendServer: frontendServer,
      sdkRoot: sdkRoot,
      packageConfig: packageConfig,
      entrypoint: entrypoint,
      projectRoot: projectRoot,
      outputDill: outputDill,
      dartDefines: DnInjectedDefines.merge(
        user: dartDefines,
        injected: injectedDefines,
      ),
      verbose: verbose,
    );
  }
}
