import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/dn/dn_engine_cache.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/errors.dart';

/// Builds the `Runner` executable for a DartNative iOS `.app`.
///
/// Unlike the Flutter shim (which boots a `FlutterViewController`), a
/// DartNative app is driven by the native runtime in `dartnative_ios`:
/// `DartNativeAppDelegate` creates the engine and `DartNativeSceneDelegate`
/// builds the window and installs the runtime. The shim's `main` therefore
/// only names the app delegate — the classes come from the
/// statically-linked `dartnative_ios` object, and the scene manifest in
/// `Info.plist` must name the scene delegate (see `DnPackOperation`).
final class DnRunnerShim {
  /// ObjC runtime names of the native runtime's delegate classes.
  ///
  /// Swift exposes them to ObjC under their MANGLED names (see
  /// `SWIFT_CLASS`/`objc_runtime_name` in `dartnative_ios-Swift.h`); the
  /// friendly `DartNative*` names only exist at compile time. Anything that
  /// resolves by string — `UIApplicationMain`, the scene manifest — must
  /// use these.
  static const appDelegateClassName =
      '_TtC14dartnative_ios21DartNativeAppDelegate';
  static const sceneDelegateClassName =
      '_TtC14dartnative_ios23DartNativeSceneDelegate';
  /// Compile and link the Runner binary.
  ///
  /// [dnEngine] provides the DartNative SDK paths (engine + binding
  /// natives). [flutterXcframework] is the DN `Flutter.xcframework`
  /// (see [DnEngineCache.flutterXcframework]). [nativeObjects] are extra
  /// object files linked in — the third-party native dependencies from
  /// [DnNativeDeps] (FlexLayout/Yoga).
  ///
  /// Returns path to the linked `Runner` executable.
  static Future<String> buildRunnerBinary({
    required String projectRoot,
    required DarwinSdk sdk,
    required DnEngineCache dnEngine,
    required String flutterXcframework,
    required String outputDir,
    required IosDeploymentTarget deploymentTarget,
    List<String> nativeObjects = const [],
    bool verbose = false,
  }) => Log.logStep('Compiling DN Runner', () async {
    final clang = await DarwinSdk.resolveDarwinClang(sdk);
    final iosSdk = _resolveIPhoneOsSDK(sdk);
    final compilerRt = compilerRtIos(sdk.bundle);
    final swiftIphoneosLibDir = _swiftIphoneosLibDir(sdk.bundle);
    final flutterSlice = _deviceSlice(
      flutterXcframework,
      p.join('Flutter.framework'),
    );
    final dnSlice = _dnDeviceSlice(dnEngine);
    final dnObject = p.join(
      dnSlice,
      'dartnative_ios.framework',
      'dartnative_ios',
    );
    final subframeworks = p.join(iosSdk, 'System', 'Library', 'SubFrameworks');

    await Directory(outputDir).create(recursive: true);
    final sourcePath = p.join(outputDir, 'Runner.m');
    final objectPath = p.join(outputDir, 'Runner.o');
    final outputPath = p.join(outputDir, 'Runner');

    await File(sourcePath).writeAsString(
      runnerObjcSource(verbose: verbose),
    );

    Log.logTrace('[clang] compile Runner.m → Runner.o');
    await ProcessRunner.runChecked(
      clang,
      compileArguments(
        sourcePath: sourcePath,
        objectPath: objectPath,
        iosSdk: iosSdk,
        subframeworks: subframeworks,
        flutterSlice: flutterSlice,
        deploymentTarget: deploymentTarget,
      ),
      inheritStdio: Log.isVerbose,
      label: 'clang',
    );

    final sdkVersion = _sdkVersion(iosSdk) ?? '26.5';
    final ld64lld = await DarwinSdk.resolveLd64Lld(sdk);
    Log.logTrace('[ld64.lld] link Runner.o + dartnative_ios → Runner');
    await TbdLinkerDiagnostic.explainFailures(
      bundle: sdk.swiftSdkPath,
      wrap: FlutterBuildError.new,
      () => ProcessRunner.runChecked(
        ld64lld,
        linkArguments(
          objectPath: objectPath,
          outputPath: outputPath,
          iosSdk: iosSdk,
          flutterSlice: flutterSlice,
          subframeworks: subframeworks,
          sdkVersion: sdkVersion,
          deploymentTarget: deploymentTarget,
          dnObject: dnObject,
          nativeObjects: nativeObjects,
          compilerRt: compilerRt,
          swiftIphoneosLibDir: swiftIphoneosLibDir,
        ),
        inheritStdio: Log.isVerbose,
        label: 'ld64.lld',
      ),
    );

    if (!File(outputPath).existsSync()) {
      throw FlutterBuildError(
        'DnRunnerShim: clang/ld64.lld did not produce '
        'Runner at $outputPath',
      );
    }

    ProcessRunner.makeExecutable(outputPath);
    final size = await File(outputPath).length();
    Log.logTrace('DN Runner binary produced: $outputPath (${size ~/ 1024} KB)');

    return outputPath;
  });

  /// Device (`ios-arm64`) slice of the `dartnative_ios` binding natives.
  ///
  /// These only exist after `dn precache --ios --all-platforms` — the iOS
  /// xcframeworks are macOS-filtered by default.
  static String _dnDeviceSlice(DnEngineCache dnEngine) {
    final slice = p.join(
      dnEngine.dnRoot,
      'bin',
      'cache',
      'pkg',
      'dartnative_ios',
      'ios',
      'dartnative_ios.xcframework',
      'ios-arm64',
    );
    final object = File(
      p.join(slice, 'dartnative_ios.framework', 'dartnative_ios'),
    );
    if (!object.existsSync()) {
      throw FlutterBuildError(
        'DnRunnerShim: DartNative iOS binding natives not found at '
        '${object.path}.\n'
        'Run `dn precache --ios --all-platforms` first.',
      );
    }
    return slice;
  }

  @visibleForTesting
  static List<String> compileArguments({
    required String sourcePath,
    required String objectPath,
    required String iosSdk,
    required String subframeworks,
    required String flutterSlice,
    required IosDeploymentTarget deploymentTarget,
  }) => [
    '-target',
    deploymentTarget.buildTriple,
    '-isysroot',
    iosSdk,
    '-F',
    subframeworks,
    '-F',
    flutterSlice,
    '-I',
    p.join(flutterSlice, 'Flutter.framework', 'Headers'),
    '-fobjc-arc',
    '-miphoneos-version-min=${deploymentTarget.version}',
    '-c',
    sourcePath,
    '-o',
    objectPath,
  ];

  @visibleForTesting
  static List<String> linkArguments({
    required String objectPath,
    required String outputPath,
    required String iosSdk,
    required String flutterSlice,
    required String subframeworks,
    required String sdkVersion,
    required IosDeploymentTarget deploymentTarget,
    required String dnObject,
    List<String> nativeObjects = const [],
    String? compilerRt,
    String? swiftIphoneosLibDir,
  }) => [
    '-arch',
    'arm64',
    '-platform_version',
    'ios',
    deploymentTarget.version,
    sdkVersion,
    '-syslibroot',
    iosSdk,
    '-o',
    outputPath,
    objectPath,
    // The DartNative native runtime (statically linked): AppDelegate,
    // SceneDelegate, and the DN* FFI symbols the Dart kernel resolves.
    // (No -u pins needed: these symbols are defined in the linked object,
    // so they are kept. The delegate classes themselves are only referenced
    // by name at runtime and need no link-time reference at all.)
    dnObject,
    // Third-party native dependencies (FlexLayout/Yoga objects).
    ...nativeObjects,
    // Apple's clang driver links the platform compiler-rt implicitly;
    // ld64.lld does not. It provides ___isPlatformVersionAtLeast among
    // other runtime helpers.
    if (compilerRt != null) compilerRt,
    // Swift backward-compatibility archives (Xcode links them via the
    // toolchain's own search path; ld64.lld needs the explicit -L/-l).
    // They provide the __swift_FORCE_LOAD_$ compatibility shims the
    // Swift objects reference for our deployment target.
    if (swiftIphoneosLibDir != null) ...[
      '-L',
      swiftIphoneosLibDir,
      '-lswiftCompatibility50',
      '-lswiftCompatibility51',
      '-lswiftCompatibility56',
      '-lswiftCompatibilityConcurrency',
      '-lswiftCompatibilityDynamicReplacements',
    ],
    // Swift standard libraries the statically-linked runtime needs. They
    // live outside the linker's default search paths, hence the explicit
    // -L; the -l set mirrors what swiftc passes when linking Swift code.
    '-L',
    p.join(iosSdk, 'usr', 'lib', 'swift'),
    '-lswiftCore',
    '-lswiftFoundation',
    '-lswiftObjectiveC',
    '-lswiftDispatch',
    '-lswiftUIKit',
    '-lswiftCoreGraphics',
    '-lswiftQuartzCore',
    '-lswiftCoreImage',
    '-lswiftMetal',
    '-lswiftAVFoundation',
    '-lswiftCoreMedia',
    '-lswiftPhotos',
    '-lswiftSwiftOnoneSupport',
    '-F',
    flutterSlice,
    '-F',
    p.join(iosSdk, 'System', 'Library', 'Frameworks'),
    '-F',
    subframeworks,
    '-framework',
    'Flutter',
    '-framework',
    'UIKit',
    '-framework',
    'Foundation',
    '-lobjc',
    '-lc',
    // Yoga/FlexLayout are C++ (the podspec declares s.libraries = 'c++').
    '-lc++',
    '-rpath',
    '@executable_path/Frameworks',
  ];

  /// Prefer the generic `iPhoneOS.sdk` symlink; fall back to the versioned SDK.
  static String _resolveIPhoneOsSDK(DarwinSdk sdk) {
    final generic = p.join(
      sdk.bundle,
      'Developer',
      'Platforms',
      'iPhoneOS.platform',
      'Developer',
      'SDKs',
      'iPhoneOS.sdk',
    );
    if (Directory(generic).existsSync()) return generic;
    return sdk.iPhoneOSSdk();
  }

  /// Returns the `ios-arm64` slice directory inside [xcframework].
  static String _deviceSlice(String xcframework, String framework) {
    final slice = p.join(xcframework, 'ios-arm64');
    if (!Directory(p.join(slice, framework)).existsSync()) {
      throw FlutterBuildError(
        'DnRunnerShim: device slice not found at $slice/$framework',
      );
    }
    return slice;
  }

  /// Version number from an SDK dir name: `iPhoneOS17.5.sdk` → `17.5`.
  static String? _sdkVersion(String sdkPath) {
    final name = p.basenameWithoutExtension(sdkPath);
    if (!name.startsWith('iPhoneOS')) return null;
    final version = name.substring('iPhoneOS'.length);
    return version.isEmpty ? null : version;
  }

  /// `libclang_rt.ios.a` under
  /// `.../XcodeDefault.xctoolchain/usr/lib/clang/<version>/lib/darwin/` in a
  /// Darwin SDK artifact bundle, or null when that layout isn't there.
  /// Apple's clang driver links the platform compiler-rt implicitly;
  /// ld64.lld does not — without it the link fails with "undefined symbol:
  /// ___isPlatformVersionAtLeast". Duplicated from
  /// swift_runner_builder.dart's identical helper rather than shared, to
  /// keep each runner builder file self-contained.
  @visibleForTesting
  static String? compilerRtIos(String darwinSdkBundle) {
    final clang = Directory(
      p.join(
        darwinSdkBundle,
        'Developer',
        'Toolchains',
        'XcodeDefault.xctoolchain',
        'usr',
        'lib',
        'clang',
      ),
    );
    if (!clang.existsSync()) return null;
    final versions = clang.listSync().whereType<Directory>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final entry in versions) {
      final candidate = p.join(entry.path, 'lib', 'darwin', 'libclang_rt.ios.a');
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Toolchain Swift compatibility archives for device (`iphoneos/`) in a
  /// Darwin SDK artifact bundle, or null when that layout isn't there.
  /// Holds the `libswiftCompatibility*.a` archives Xcode links implicitly.
  static String? _swiftIphoneosLibDir(String darwinSdkBundle) {
    final dir = p.join(
      darwinSdkBundle,
      'Developer',
      'Toolchains',
      'XcodeDefault.xctoolchain',
      'usr',
      'lib',
      'swift',
      'iphoneos',
    );
    return Directory(dir).existsSync() ? dir : null;
  }

  /// Minimal ObjC `main` that boots the DartNative runtime: the application
  /// delegate class is resolved by name at launch ([appDelegateClassName]),
  /// so no native headers are needed here.
  ///
  /// It also carries a `UIStoryboard` fallback for the launch screen:
  /// `DNNavigationController` installs a splash overlay from the
  /// `LaunchScreen` storyboard, but xcross cannot compile storyboards
  /// (`ibtool` is macOS-only), so the bundle has none. Without the
  /// fallback the lookup throws and the app dies on launch; with it the
  /// splash installer gets an empty storyboard (nil initial view
  /// controller) and skips its overlay instead of crashing. Only the
  /// `LaunchScreen` name is rescued — every other missing storyboard
  /// still throws.
  @visibleForTesting
  static String runnerObjcSource({required bool verbose}) => '''
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface UIStoryboard (XCrossDNLaunchScreen)
+ (UIStoryboard *)xcross_storyboardWithName:(NSString *)name bundle:(NSBundle *)storyboardBundleOrNil;
@end

@implementation UIStoryboard (XCrossDNLaunchScreen)
+ (void)load {
  Method original = class_getClassMethod(self, @selector(storyboardWithName:bundle:));
  Method fallback = class_getClassMethod(self, @selector(xcross_storyboardWithName:bundle:));
  if (original != NULL && fallback != NULL) {
    method_exchangeImplementations(original, fallback);
  }
}
+ (UIStoryboard *)xcross_storyboardWithName:(NSString *)name bundle:(NSBundle *)storyboardBundleOrNil {
  // After the exchange above, this call invokes the ORIGINAL implementation.
  @try {
    return [self xcross_storyboardWithName:name bundle:storyboardBundleOrNil];
  } @catch (NSException *exception) {
    if ([name isEqualToString:@"LaunchScreen"]) {
      return [[UIStoryboard alloc] init];
    }
    @throw;
  }
}
@end

int main(int argc, char * argv[]) {
  @autoreleasepool {
    ${verbose ? 'NSLog(@"[xcross] DN Runner launch started");' : ''}
    return UIApplicationMain(argc, argv, nil, @"$appDelegateClassName");
  }
}
''';
}
