import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/dn/dn_asset_catalog.dart';
import 'package:xcross/src/dn/dn_build_options.dart';
import 'package:xcross/src/dn/dn_engine_cache.dart';
import 'package:xcross/src/dn/dn_native_deps.dart';
import 'package:xcross/src/dn/dn_project.dart';
import 'package:xcross/src/dn/dn_runner_shim.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/flutter/build/flutter_debug_bundler.dart';
import 'package:xcross/src/flutter/build/info_plist.dart';
import 'package:xcross/src/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/flutter/build/internal/toolchain.dart';
import 'package:xcross/src/flutter/build/ios_bundle_id.dart';
import 'package:xcross/src/flutter/build/ios_bundle_resources.dart';
import 'package:xcross/src/flutter/build/ios_bundle_versions.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/constants.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/flutter/models/pubspec_info.dart';
import 'package:xcross/src/models/pack_result.dart';

/// Builds a DartNative iOS `.app` on any host with a Darwin SDK, mirroring
/// [FlutterPackOperation]: the Dart kernel/assets come from
/// `dn build bundle` (which runs on Linux), the `Runner` binary is compiled
/// with the xcross cross-toolchain, and the bundle is assembled into
/// `build/xcross-ios/<appName>.app`.
///
/// Debug/JIT only — signing happens later in `DeviceRunOperation`, exactly
/// like the Flutter path.
abstract final class DnPackOperation {
  /// Build the DartNative iOS app, optionally overriding the resolved id.
  static Future<PackResult> pack({
    required DnBuildOptions options,
    String? bundleIdOverride,
  }) async {
    final projectRoot = Directory.current.path;
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

    final appName = PubspecInfo.loadSync(projectRoot).name;
    final bundleId = bundleIdOverride?.isNotEmpty == true
        ? bundleIdOverride!
        : _resolveBundleId(projectRoot);
    final deploymentTarget = IosDeploymentTarget.resolve(projectRoot);
    Log.logTrace('iOS deployment target: ${deploymentTarget.version}');
    final versions = IosBundleVersions.resolve(
      projectRoot,
      buildName: options.buildName,
      buildNumber: options.buildNumber,
    );

    final assetDir = await _buildDnBundle(
      dn: dn,
      projectRoot: projectRoot,
      options: options,
    );

    final engineCache = DnEngineCache(dnExecutable: dn);
    await Log.logStep(
      'Fetching DartNative iOS engine',
      engineCache.ensureArtifactsAvailable,
    );

    final appFramework = await _buildAppFramework(
      projectRoot: projectRoot,
      assetDir: assetDir,
      deploymentTarget: deploymentTarget,
    );
    final runnerBinary = await _buildRunnerBinary(
      projectRoot: projectRoot,
      engineCache: engineCache,
      deploymentTarget: deploymentTarget,
    );
    final appPath = await _assembleBundle(
      projectRoot: projectRoot,
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
    );
  }

  static String _resolveBundleId(String projectRoot) {
    try {
      return IosBundleId.resolve(projectRoot);
    } on FlutterBuildError catch (e) {
      throw XcrossError(
        'Could not resolve iOS bundle identifier: ${e.message} '
        'Pass --bundle-id.',
      );
    }
  }

  /// Run `dn build bundle --target-platform ios` and return the asset dir.
  static Future<String> _buildDnBundle({
    required String dn,
    required String projectRoot,
    required DnBuildOptions options,
  }) => Log.logStep('Building Dart bundle', () async {
    final assetDir = p.join(
      projectRoot,
      'build',
      'xcross-dn-assets',
      'flutter_assets',
    );
    final dir = Directory(assetDir);
    if (dir.existsSync()) await dir.delete(recursive: true);
    await dir.create(recursive: true);

    await ProcessRunner.runChecked(
      dn,
      bundleArgs(options: options, assetDir: assetDir),
      workingDirectory: projectRoot,
      inheritStdio: Log.isVerbose,
      label: 'dn',
    );
    if (!File(p.join(assetDir, 'kernel_blob.bin')).existsSync()) {
      throw XcrossError(
        'DnPackOperation: dn build bundle did not produce '
        '$assetDir/kernel_blob.bin',
      );
    }
    return assetDir;
  });

  /// Effective dart-defines for `dn build bundle`, appending the flavor
  /// define unless the caller already set `FLUTTER_APP_FLAVOR=` explicitly.
  static List<String> _effectiveDefines(DnBuildOptions options) => [
    ...options.dartDefines,
    if (options.flavor != null &&
        !options.dartDefines.any((d) => d.startsWith('FLUTTER_APP_FLAVOR=')))
      'FLUTTER_APP_FLAVOR=${options.flavor}',
  ];

  /// Argument list for `dn build bundle --target-platform ios`.
  static List<String> bundleArgs({
    required DnBuildOptions options,
    required String assetDir,
  }) => [
    'build',
    'bundle',
    '-t',
    options.target,
    '--target-platform',
    'ios',
    '--asset-dir',
    assetDir,
    if (options.buildNumber != null)
      '--build-number=${options.buildNumber}',
    for (final define in _effectiveDefines(options)) ...['-D', define],
    if (!options.pub) '--no-pub',
  ];

  /// Stage `App.framework` from the `dn build bundle` assets + a stub dylib.
  static Future<String> _buildAppFramework({
    required String projectRoot,
    required String assetDir,
    required IosDeploymentTarget deploymentTarget,
  }) async {
    final assembleOut = p.join(projectRoot, 'build', 'xcross-dn-debug');
    final assembleDir = Directory(assembleOut);
    if (assembleDir.existsSync()) await assembleDir.delete(recursive: true);
    await assembleDir.create(recursive: true);

    final appFramework = p.join(assembleOut, 'App.framework');
    await Directory(p.join(appFramework, 'flutter_assets')).create(
      recursive: true,
    );
    await copyDirectoryPreservingSymlinks(
      assetDir,
      p.join(appFramework, 'flutter_assets'),
    );
    await _buildAppStub(appFramework, deploymentTarget);
    File(
      p.join(appFramework, 'Info.plist'),
    ).writeAsStringSync(
      FlutterDebugBundler.appFrameworkInfoPlist(deploymentTarget),
    );
    return appFramework;
  }

  static Future<void> _buildAppStub(
    String appFramework,
    IosDeploymentTarget deploymentTarget,
  ) => Log.logStep('Building App.framework', () async {
    final darwin = DarwinSdk.current();
    if (darwin == null) {
      throw FlutterBuildError(
        'DnPackOperation: Darwin SDK not found. '
        'Install with `xcross sdk install <Xcode.xip|Xcode.app>`.',
      );
    }
    final toolchain = Toolchain(
      clang: await DarwinSdk.resolveDarwinClang(darwin),
      iosSdk: darwin.iPhoneOSSdk(),
      linker: await DarwinSdk.resolveLd64Lld(darwin),
    );
    final tmp = await Directory.systemTemp.createTemp('xcross-dn-stub-');
    try {
      final stubSource = p.join(tmp.path, 'debug_app.c');
      await File(stubSource).writeAsString('static const int Moo = 88;\n');
      final outputBinary = p.join(appFramework, 'App');
      await ProcessRunner.runChecked(
        toolchain.clang,
        FlutterDebugBundler.appStubClangArgs(
          toolchain: toolchain,
          stubSource: stubSource,
          outputBinary: outputBinary,
          deploymentTarget: deploymentTarget,
        ),
        inheritStdio: Log.isVerbose,
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
    required String projectRoot,
    required DnEngineCache engineCache,
    required IosDeploymentTarget deploymentTarget,
    // ignore: unnecessary_async
  }) async {
    final darwin = DarwinSdk.current();
    if (darwin == null) {
      throw FlutterBuildError(
        'DnPackOperation: Darwin SDK not found. '
        'Install with `xcross sdk install <Xcode.xip|Xcode.app>`.',
      );
    }
    final nativeObjects = await DnNativeDeps.ensureBuilt(sdk: darwin);
    return DnRunnerShim.buildRunnerBinary(
      projectRoot: projectRoot,
      sdk: darwin,
      dnEngine: engineCache,
      flutterXcframework: engineCache.flutterXcframework,
      outputDir: p.join(projectRoot, 'build', 'xcross-dn-runner-bin'),
      deploymentTarget: deploymentTarget,
      nativeObjects: nativeObjects,
      verbose: Log.isVerbose,
    );
  }

  static Future<String> _assembleBundle({
    required String projectRoot,
    required String appName,
    required String bundleId,
    required IosBundleVersions versions,
    required IosDeploymentTarget deploymentTarget,
    required String appFramework,
    required String flutterXcframework,
    required String runnerBinary,
  }) async {
    final tmp = await Directory.systemTemp.createTemp('${appName}_app_bundle-');
    try {
      final runnerDest = p.join(tmp.path, 'Runner');
      await File(runnerBinary).copy(runnerDest);
      ProcessRunner.makeExecutable(runnerDest);
      await copyDirectoryPreservingSymlinks(
        p.join(flutterXcframework, 'ios-arm64', 'Flutter.framework'),
        p.join(tmp.path, 'Frameworks', 'Flutter.framework'),
      );
      await copyDirectoryPreservingSymlinks(
        appFramework,
        p.join(tmp.path, 'Frameworks', 'App.framework'),
      );
      await stageIosBundleResources(
        projectRoot: projectRoot,
        bundleDir: tmp.path,
      );
      // actool replacement: compile the asset catalog (icons + launch
      // images) without macOS; the resulting plist keys are merged in
      // _writeInfoPlist below.
      final compiledAssets = await DnAssetCatalog.compile(
        projectRoot: projectRoot,
        bundleDir: tmp.path,
      );
      await _writeInfoPlist(
        projectRoot: projectRoot,
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
      await copyDirectoryPreservingSymlinks(tmp.path, dest);
      return dest;
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  static Future<void> _writeInfoPlist({
    required String projectRoot,
    required String bundleDir,
    required String bundleId,
    required IosBundleVersions versions,
    required IosDeploymentTarget deploymentTarget,
    DnCompiledAssets? compiledAssets,
  }) async {
    var plistXml = _loadPlistTemplate(projectRoot);
    plistXml = InfoPlist.expandXmlVars(
      plistXml,
      {
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
      },
    );
    plistXml = InfoPlist.applyIosRequiredKeys(
      plistXml,
      bundleId: bundleId,
      deploymentTarget: deploymentTarget,
    );
    plistXml = InfoPlist.applyDebugVmServiceDiscovery(plistXml);
    plistXml = InfoPlist.stripUnsatisfiableStoryboards(plistXml, bundleDir);
    if (compiledAssets != null) {
      if (compiledAssets.hasIcons) {
        plistXml = InfoPlist.insertFragment(
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
        plistXml = InfoPlist.setUILaunchScreen(plistXml, splash);
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
    plistXml = InfoPlist.setPlistString(
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
