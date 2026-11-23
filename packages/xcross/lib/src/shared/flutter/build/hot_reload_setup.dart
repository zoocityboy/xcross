import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:frontend_server_kit/shared/compiler/package_uris.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/build/dart_plugin_registrant.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/flutter_kernel_compiler.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';
import 'package:xcross/src/shared/flutter/models/hot_reload_config.dart';

/// Groups hot-reload configuration setup.
@internal
abstract final class HotReloadSetup {
  /// Resolve the paths a persistent `frontend_server` needs for hot reload.
  /// [dartDefines] must be the debug build's complete defines
  /// (`PackResult.dartDefines`).
  ///
  /// Returns null (with a warning) if a required artifact is missing —
  /// callers then launch without hot reload.
  static Future<HotReloadConfig?>
  buildHotReloadConfig<T extends PlatformHostInterface>({
    required FlutterBuildRuntime<T> runtime,
    required String projectRoot,
    required String target,
    required List<String> dartDefines,
    bool verbose = false,
  }) async {
    final paths = runtime.host.paths.context;
    final flutterRoot = await runtime.resolveFlutterRoot(
      projectRoot: projectRoot,
    );
    final engineCache = runtime.engineCache(flutterRoot);

    final frontendServer = engineCache.frontendServer;
    final frontendServerExists = runtime.host.fileSystem
        .file(frontendServer)
        .existsSync();
    if (!frontendServerExists) {
      runtime.runner.log.logWarn(
        'frontend_server snapshot missing at $frontendServer; '
        'hot reload disabled.',
      );
      return null;
    }

    final sdkRoot = engineCache.patchedSdkRoot;
    final packageConfig = await runtime.packageConfigs.require(projectRoot);
    final entrypoint = paths.isAbsolute(target)
        ? target
        : paths.join(projectRoot, target);

    // frontend_server is AOT (dartaotruntime) or a kernel snapshot (dart).
    final dartSdkBin = paths.join(
      flutterRoot,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
    );
    final isAot = paths.basename(frontendServer).contains('_aot');
    final dart = paths.join(
      dartSdkBin,
      runtime.runner.hostExecutableName(isAot ? 'dartaotruntime' : 'dart'),
    );

    // The bundle compile writes (or removes) this during pack; referencing
    // the same URI keeps a restarted isolate's plugin registrant identical
    // to the one the installed kernel used.
    final registrantPath = DartPluginRegistrant.pathFor(projectRoot);
    final registrantUri = await _registrantUri(
      runtime: runtime,
      projectRoot: projectRoot,
      packageConfig: packageConfig,
      entrypoint: entrypoint,
      flutterRoot: flutterRoot,
      registrantPath: registrantPath,
    );

    // Persistent dill output for incremental reloads.
    final intermediates = runtime.policy.buildDirectory(
      projectRoot,
      FlutterBuildMode.debug.intermediatesDirectory,
    );
    final outputDill = paths.join(intermediates, '.hotreload', 'app.dill');
    await runtime.host.fileSystem
        .directory(paths.dirname(outputDill))
        .create(recursive: true);

    return HotReloadConfig(
      dart: dart,
      frontendServer: frontendServer,
      sdkRoot: sdkRoot,
      packageConfig: packageConfig,
      entrypoint: entrypoint,
      projectRoot: projectRoot,
      outputDill: outputDill,
      dartDefines: dartDefines,
      extraSources: [
        if (registrantUri != null) ...[
          registrantUri,
          'package:flutter/src/dart_plugin_registrant.dart',
        ],
      ],
      warmDill: paths.join(intermediates, '.kernel', 'app.dill'),
      verbose: verbose,
    );
  }

  /// URI of the Dart plugin registrant the bundle compile generated, using
  /// the same `package:`/`file:` form so the VM can bind it.
  static Future<String?> _registrantUri<T extends PlatformHostInterface>({
    required FlutterBuildRuntime<T> runtime,
    required String projectRoot,
    required String packageConfig,
    required String entrypoint,
    required String flutterRoot,
    required String registrantPath,
  }) async {
    final paths = runtime.host.paths.context;
    if (!runtime.host.fileSystem.file(registrantPath).existsSync()) {
      return null;
    }
    // Regenerate first: a plugin added since the last pack must register in
    // reloaded isolates too, and generate() owns the on-disk file.
    final registrant = DartPluginRegistrant(
      runtime.host.fileSystem,
      paths,
      onWarning: runtime.runner.log.logWarn,
    );
    final generated = await registrant.generate(
      projectRoot: projectRoot,
      packageConfigPath: packageConfig,
      entrypoint: paths.isAbsolute(entrypoint)
          ? entrypoint
          : paths.join(projectRoot, entrypoint),
      flutterRoot: flutterRoot,
    );
    if (generated == null) return null;
    final packageUris = await PackageUriLoader(
      fileSystem: runtime.host.fileSystem,
      paths: paths,
    ).load(packageConfig);
    return FlutterKernelCompiler.dartPluginRegistrantUri(
      generated,
      packageUris,
      paths: paths,
    );
  }
}
