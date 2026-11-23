import 'dart:io';

import 'package:darwin_sdk_kit/target/iphone/iphone_build_platform.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/composition/dn/dn_asset_catalog.dart';
import 'package:xcross/src/composition/dn/dn_context.dart';
import 'package:xcross/src/composition/dn/dn_engine_cache.dart';
import 'package:xcross/src/composition/dn/dn_info_plist.dart';
import 'package:xcross/src/composition/dn/dn_injected_defines.dart';
import 'package:xcross/src/composition/dn/dn_native_deps.dart';
import 'package:xcross/src/composition/dn/dn_project.dart';
import 'package:xcross/src/composition/dn/dn_runner_shim.dart';
import 'package:xcross/src/shared/artifact/plist_mutations.dart';
import 'package:xcross/src/shared/artifact/plist_storyboard_policy.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/flutter/build/flutter_debug_bundler.dart';
import 'package:xcross/src/shared/flutter/build/info_plist.dart';
import 'package:xcross/src/shared/flutter/build/internal/toolchain.dart';
import 'package:xcross/src/shared/flutter/build/ios_bundle_id.dart';
import 'package:xcross/src/shared/flutter/build/ios_bundle_resources.dart';
import 'package:xcross/src/shared/flutter/build/ios_bundle_versions.dart';
import 'package:xcross/src/shared/flutter/constants.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/models/flutter/dart_defines.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/shared/flutter/project/ios_bundle_versions_resolver.dart';
import 'package:xcross/src/shared/flutter/project/ios_deployment_target_resolver.dart';
import 'package:xcross/src/shared/flutter/project/pbx_project_reader.dart';
import 'package:xcross/src/shared/flutter/project/pubspec_info_reader.dart';
import 'package:xcross/src/shared/models/pack_result.dart';
import 'package:xcross/src/shared/swiftpm/ios_deployment_target.dart';
import 'package:xcross/src/shared/swiftpm/recursive_directory_copy.dart';

/// Builds a DartNative iOS `.app` on any host with a Darwin SDK, mirroring
/// the Flutter pipeline: the Dart kernel/assets come from
/// `dn build bundle` (which runs on Linux), the `Runner` binary is compiled
/// with the xcross cross-toolchain, and the bundle is assembled into
/// `build/xcross-ios/<appName>.app`.
///
/// Debug/JIT only — signing happens later in `DeviceRunOperation`, exactly
/// like the Flutter path.
@internal
abstract final class DnPackOperation {
  /// Build the DartNative iOS app, optionally overriding the resolved id.
  static Future<PackResult> pack({
    required DnContext context,
    required FlutterBuildOptions options,
    String? bundleIdOverride,
  }) async {
    final projectRoot = context.projectRoot;
    final paths = context.paths;
    final fs = context.host.fileSystem;
    if (!DnProject.isDartNativeProject(projectRoot)) {
      throw XcrossError(
        '$projectRoot is not a DartNative project '
        '(pubspec.yaml does not depend on dartnative, dartnative_ios, or '
        'dartnative_android). cd into your app directory first.',
      );
    }
    final dn = DnProject.resolveDnExecutable();
    if (dn == null) {
      throw XcrossError(
        'dn executable not found. Install it with '
        '`curl -fsSL https://cdn.dartnative.com/install.sh | sh` (see '
        'https://github.com/DartNative/dartnative).',
      );
    }

    final projects = PbxProjectReader(fs, paths);
    final appName = PubspecInfoReader(fs, paths).loadSync(projectRoot).name;
    final bundleId = bundleIdOverride?.isNotEmpty == true
        ? bundleIdOverride!
        : _resolveBundleId(projectRoot, IosBundleId(fs, paths, projects));
    final deploymentTarget = IosDeploymentTargetResolver(
      fs,
      paths,
    ).resolve(projectRoot, platform: const IPhoneBuildPlatform());
    context.log.logTrace('iOS deployment target: ${deploymentTarget.version}');
    final versions = IosBundleVersionsResolver(fs, projects).resolve(
      projectRoot,
      buildName: options.buildName,
      buildNumber: options.buildNumber,
    );

    final bundle = await _buildDnBundle(
      context: context,
      dn: dn,
      options: options,
    );
    final assetDir = bundle.assetDir;

    final engineCache = DnEngineCache(dn, runner: context.runner);
    await context.log.logStep(
      'Fetching DartNative iOS engine',
      engineCache.ensureArtifactsAvailable,
    );

    final appFramework = await _buildAppFramework(
      context: context,
      assetDir: assetDir,
      deploymentTarget: deploymentTarget,
    );
    final runnerBinary = await _buildRunnerBinary(
      context: context,
      engineCache: engineCache,
      deploymentTarget: deploymentTarget,
    );
    final appPath = await _assembleBundle(
      context: context,
      appName: appName,
      bundleId: bundleId,
      versions: versions,
      deploymentTarget: deploymentTarget,
      appFramework: appFramework,
      flutterXcframework: engineCache.flutterXcframework,
      runnerBinary: runnerBinary,
    );
    return PackResult(
      outputPath: appPath,
      bundleId: bundleId,
      projectRoot: projectRoot,
      dartDefines: bundle.injectedDefines.isEmpty
          ? options.dartDefines
          : DartDefines.mergeFallback(
              base: options.dartDefines,
              fallback: bundle.injectedDefines,
            ),
    );
  }

  static String _resolveBundleId(String projectRoot, IosBundleId bundleIds) {
    try {
      return bundleIds.resolve(projectRoot);
    } on FlutterBuildError catch (e) {
      throw XcrossError(
        'Could not resolve iOS bundle identifier: ${e.message} '
        'Pass --bundle-id.',
      );
    }
  }

  /// Run `dn build bundle --target-platform ios` and return the asset dir plus
  /// the defines dn itself injected (license key, `FLUTTER_*`).
  ///
  /// The build always runs verbose with captured output: the effective
  /// frontend_server command line is the only plaintext source of dn's
  /// injected defines (`dn config --list` masks them). When dn skips the
  /// kernel compile as up-to-date (no frontend_server line), the previous
  /// run's cache fills in.
  static Future<({String assetDir, List<String> injectedDefines})>
  _buildDnBundle({
    required DnContext context,
    required String dn,
    required FlutterBuildOptions options,
  }) => context.log.logStep('Building Dart bundle', () async {
    final projectRoot = context.projectRoot;
    final assetDir = p.join(
      projectRoot,
      'build',
      'xcross-dn-assets',
      'flutter_assets',
    );
    final dir = Directory(assetDir);
    if (dir.existsSync()) await dir.delete(recursive: true);
    await dir.create(recursive: true);

    final result = await context.runner.run(
      dn,
      bundleArgs(options: options, assetDir: assetDir),
      workingDirectory: projectRoot,
    );
    if (context.log.isVerbose) {
      stdout.write(result.stdout);
      stderr.write(result.stderr);
    }
    if (result.exitCode != 0) {
      throw XcrossError(
        'dn build bundle failed (exit ${result.exitCode}):\n'
        '${result.stdout}\n${result.stderr}',
      );
    }
    if (!File(p.join(assetDir, 'kernel_blob.bin')).existsSync()) {
      throw XcrossError(
        'DnPackOperation: dn build bundle did not produce '
        '$assetDir/kernel_blob.bin',
      );
    }
    final injected = DnInjectedDefines.extractFromBuildLog(
      '${result.stdout}\n${result.stderr}',
    );
    if (injected.isNotEmpty) {
      // Key names only: values are secrets (dn masks them everywhere).
      context.log.logTrace(
        'dn injected defines: '
        '${[for (final d in injected) DnInjectedDefines.keyOf(d)]}',
      );
      await DnInjectedDefines.writeCache(
        projectRoot,
        injected,
        log: context.log,
      );
      return (assetDir: assetDir, injectedDefines: injected);
    }
    final cached = DnInjectedDefines.readCache(projectRoot, log: context.log);
    if (cached.isNotEmpty) {
      context.log.logTrace(
        'dn skipped the kernel compile; reusing cached injected defines',
      );
    }
    return (assetDir: assetDir, injectedDefines: cached);
  });

  /// Effective dart-defines for `dn build bundle`, appending the flavor
  /// define unless the caller already set `FLUTTER_APP_FLAVOR=` explicitly.
  static List<String> _effectiveDefines(FlutterBuildOptions options) =>
      DartDefines.withFlavorDefine(options.dartDefines, options.flavor);

  /// Argument list for `dn build bundle --target-platform ios`.
  ///
  /// Always verbose with captured output: the frontend_server command line
  /// is the only plaintext source of dn's injected defines (license key,
  /// `FLUTTER_*`), which hot reload mirrors (see [DnInjectedDefines]).
  static List<String> bundleArgs({
    required FlutterBuildOptions options,
    required String assetDir,
  }) => [
    'build',
    'bundle',
    '-v',
    '-t',
    options.target,
    '--target-platform',
    'ios',
    '--asset-dir',
    assetDir,
    if (options.buildNumber != null) '--build-number=${options.buildNumber}',
    for (final define in _effectiveDefines(options)) ...['-D', define],
    if (!options.pub) '--no-pub',
  ];

  /// Stage `App.framework` from the `dn build bundle` assets + a stub dylib.
  static Future<String> _buildAppFramework({
    required DnContext context,
    required String assetDir,
    required IosDeploymentTarget deploymentTarget,
  }) async {
    final assembleOut = p.join(context.projectRoot, 'build', 'xcross-dn-debug');
    final assembleDir = Directory(assembleOut);
    if (assembleDir.existsSync()) await assembleDir.delete(recursive: true);
    await assembleDir.create(recursive: true);

    final copier = RecursiveDirectoryCopier(
      fileSystem: context.host.fileSystem,
      paths: context.paths,
    );
    final appFramework = p.join(assembleOut, 'App.framework');
    await Directory(
      p.join(appFramework, 'flutter_assets'),
    ).create(recursive: true);
    await copier.copy(assetDir, p.join(appFramework, 'flutter_assets'));
    await _buildAppStub(context, appFramework, deploymentTarget);
    File(p.join(appFramework, 'Info.plist')).writeAsStringSync(
      FlutterDebugBundler.appFrameworkInfoPlist(deploymentTarget.version),
    );
    return appFramework;
  }

  static Future<void> _buildAppStub(
    DnContext context,
    String appFramework,
    IosDeploymentTarget deploymentTarget,
  ) => context.log.logStep('Building App.framework', () async {
    final iosSdk = context.requireIosSdk();
    final toolchain = Toolchain(
      clang: await context.toolchainResolver.resolveDarwinClang(iosSdk),
      iosSdk: iosSdk,
      linker: await context.toolchainResolver.resolveLd64Lld(),
    );
    final tmp = await Directory.systemTemp.createTemp('xcross-dn-stub-');
    try {
      final stubSource = p.join(tmp.path, 'debug_app.c');
      await File(stubSource).writeAsString('static const int Moo = 88;\n');
      final outputBinary = p.join(appFramework, 'App');
      await context.runner.runChecked(
        toolchain.clang,
        FlutterDebugBundler.appStubClangArgs(
          toolchain: toolchain,
          stubSource: stubSource,
          outputBinary: outputBinary,
          deploymentTarget: deploymentTarget,
        ),
        inheritStdio: context.log.isVerbose,
        label: 'clang',
      );
      if (!File(outputBinary).existsSync()) {
        throw XcrossError(
          'DnPackOperation: clang did not produce $outputBinary',
        );
      }
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  /// The DN kernel only loads in the matching DN engine (never in a stock
  /// Flutter engine, whose Dart version differs), so the engine always comes
  /// from the `dn` SDK — see [DnEngineCache].
  static Future<String> _buildRunnerBinary({
    required DnContext context,
    required DnEngineCache engineCache,
    required IosDeploymentTarget deploymentTarget,
  }) async {
    final nativeObjects = await DnNativeDeps.ensureBuilt(context: context);
    final binary = await DnRunnerShim.buildRunnerBinary(
      context: context,
      dnEngine: engineCache,
      flutterXcframework: engineCache.flutterXcframework,
      outputDir: p.join(context.projectRoot, 'build', 'xcross-dn-runner-bin'),
      deploymentTarget: deploymentTarget,
      nativeObjects: nativeObjects,
      verbose: context.log.isVerbose,
    );
    return binary;
  }

  static Future<String> _assembleBundle({
    required DnContext context,
    required String appName,
    required String bundleId,
    required IosBundleVersions versions,
    required IosDeploymentTarget deploymentTarget,
    required String appFramework,
    required String flutterXcframework,
    required String runnerBinary,
  }) async {
    final projectRoot = context.projectRoot;
    final paths = context.paths;
    final fs = context.host.fileSystem;
    final copier = RecursiveDirectoryCopier(fileSystem: fs, paths: paths);
    final tmp = await Directory.systemTemp.createTemp('${appName}_app_bundle-');
    try {
      final runnerDest = p.join(tmp.path, 'Runner');
      await File(runnerBinary).copy(runnerDest);
      context.runner.makeExecutable(runnerDest);
      await copier.copy(
        p.join(flutterXcframework, 'ios-arm64', 'Flutter.framework'),
        p.join(tmp.path, 'Frameworks', 'Flutter.framework'),
      );
      await copier.copy(
        appFramework,
        p.join(tmp.path, 'Frameworks', 'App.framework'),
      );
      final projects = PbxProjectReader(fs, paths);
      await IosBundleResources(
        fs,
        paths,
        projects,
        copier: copier,
      ).stage(projectRoot: projectRoot, bundleDir: tmp.path);
      // actool replacement: compile the asset catalog (icons + launch
      // images) without macOS; the resulting plist keys are merged in
      // _writeInfoPlist below.
      final compiledAssets = await DnAssetCatalog.compile(
        projectRoot: projectRoot,
        bundleDir: tmp.path,
        log: context.log,
      );
      await _writeInfoPlist(
        context: context,
        bundleDir: tmp.path,
        bundleId: bundleId,
        versions: versions,
        deploymentTarget: deploymentTarget,
        compiledAssets: compiledAssets,
      );

      final dest = p.join(projectRoot, 'build', 'xcross-ios', '$appName.app');
      final destDir = Directory(dest);
      if (destDir.existsSync()) await destDir.delete(recursive: true);
      await Directory(p.dirname(dest)).create(recursive: true);
      await copier.copy(tmp.path, dest);
      return dest;
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  static Future<void> _writeInfoPlist({
    required DnContext context,
    required String bundleDir,
    required String bundleId,
    required IosBundleVersions versions,
    required IosDeploymentTarget deploymentTarget,
    DnCompiledAssets? compiledAssets,
  }) async {
    final projectRoot = context.projectRoot;
    var plistXml = _loadPlistTemplate(projectRoot);
    plistXml = InfoPlist.expandXmlVars(plistXml, {
      'EXECUTABLE_NAME': PlistDefaults.executable,
      'PRODUCT_NAME': PlistDefaults.executable,
      'PRODUCT_MODULE_NAME': PlistDefaults.executable,
      'PRODUCT_BUNDLE_IDENTIFIER': bundleId,
      'DEVELOPMENT_LANGUAGE': 'en',
      'FLUTTER_BUILD_NAME': versions.shortVersion,
      'FLUTTER_BUILD_NUMBER': versions.bundleVersion,
      'MARKETING_VERSION': versions.shortVersion,
      'CURRENT_PROJECT_VERSION': versions.bundleVersion,
      'DN_BUILD_NAME': versions.shortVersion,
      'DN_BUILD_NUMBER': versions.bundleVersion,
    });
    plistXml = InfoPlist.applyIosRequiredKeys(
      plistXml,
      bundleId: bundleId,
      deploymentTarget: deploymentTarget,
    );
    plistXml = InfoPlist.applyDebugVmServiceDiscovery(plistXml);
    plistXml = PlistStoryboardPolicy(
      context.host.fileSystem,
      context.paths,
    ).stripUnsatisfiableStoryboards(plistXml, bundleDir);
    if (compiledAssets != null) {
      if (compiledAssets.hasIcons) {
        plistXml = DnInfoPlist.insertFragment(
          plistXml,
          DnAssetCatalog.cfbundleIconsFragment(compiledAssets.iconFiles),
        );
      }
      // Legacy UILaunchImages are ignored on iOS 13+ once UILaunchScreen (or
      // UILaunchStoryboardName) is present, so the splash goes through the
      // programmatic launch screen instead: UIImageName resolves the staged
      // scale-aware bundle PNGs via UIImage imageNamed:.
      final splash = compiledAssets.splashImageName;
      if (splash != null) {
        plistXml = DnInfoPlist.setUILaunchScreen(plistXml, splash);
      }
    }
    // NOTE: no applySceneLifecycle — the DN template already declares its
    // scene manifest, and the Flutter rewrite would point the scene at a
    // `SceneDelegate` class this bundle does not contain. The scene is
    // served by the native runtime instead (see below).
    plistXml = InfoPlist.normalizeObjCClassNames(plistXml);
    // The window scene is built by the statically-linked DartNative runtime,
    // not by a project-local class: point the manifest at it explicitly.
    // (The template value `$(PRODUCT_MODULE_NAME).SceneDelegate` normalizes
    // to a bare `SceneDelegate` that resolves to nothing.)
    plistXml = PlistMutations.setPlistString(
      plistXml,
      'UISceneDelegateClassName',
      DnRunnerShim.sceneDelegateClassName,
    );
    await File(p.join(bundleDir, 'Info.plist')).writeAsString(plistXml);
  }

  static String _loadPlistTemplate(String projectRoot) {
    final plistFile = File(p.join(projectRoot, 'ios', 'Runner', 'Info.plist'));
    if (plistFile.existsSync()) return plistFile.readAsStringSync();
    return InfoPlist.fallback;
  }
}
