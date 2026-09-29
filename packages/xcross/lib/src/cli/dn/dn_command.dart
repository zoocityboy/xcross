import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/cli/shared/device_selection.dart';
import 'package:xcross/src/cli/shared/ipa_packager.dart';
import 'package:xcross/src/device/core_device_launch_profile.dart';
import 'package:xcross/src/device/device_run_operation.dart';
import 'package:xcross/src/dn/dn_app_resolver.dart';
import 'package:xcross/src/dn/dn_build_options.dart';
import 'package:xcross/src/dn/dn_hot_reload_setup.dart';
import 'package:xcross/src/dn/dn_pack_operation.dart';
import 'package:xcross/src/flutter/flutter.dart';

/// `xcross dn build` — build a DartNative iOS `.app` without Xcode.
///
/// Mirrors `xcross flutter build`: the Dart bundle comes from
/// `dn build bundle` (runs on Linux), the Runner binary is compiled with the
/// xcross Darwin cross-toolchain, and the `.app` is assembled into
/// `build/xcross-ios/`. Debug/JIT only; signing happens at `run` time.
final class DnBuildCommand extends Command<void> {
  @override
  String get name => 'build';

  @override
  String get description => 'Build a DartNative iOS .app without Xcode.';

  DnBuildCommand() {
    argParser
      ..addOption('target', abbr: 't', defaultsTo: 'lib/main.dart')
      ..addMultiOption('dart-define', abbr: 'D')
      ..addMultiOption('dart-define-from-file')
      ..addFlag('pub', defaultsTo: true)
      ..addOption('build-name')
      ..addOption('build-number')
      ..addOption('flavor')
      ..addOption('bundle-id', help: 'Override CFBundleIdentifier.')
      ..addFlag('ipa', help: 'Package the .app into an .ipa.', negatable: false)
      ..addFlag('verbose', abbr: 'v', help: 'Verbose output.', negatable: false);
  }

  @override
  Future<void> run() async {
    if (argResults!['verbose'] as bool) Log.setVerbose();
    final options = await DnBuildOptions.resolve(
      target: argResults!['target'] as String,
      dartDefine: argResults!['dart-define'] as List<String>,
      dartDefineFromFile:
          argResults!['dart-define-from-file'] as List<String>,
      pub: argResults!['pub'] as bool,
      buildName: argResults!['build-name'] as String?,
      buildNumber: argResults!['build-number'] as String?,
      flavor: argResults!['flavor'] as String?,
    );
    final pack = await DnPackOperation.pack(
      options: options,
      bundleIdOverride: argResults!['bundle-id'] as String?,
    );
    final finalPath = (argResults!['ipa'] as bool)
        ? await IpaPackager.package(pack.appPath)
        : pack.outputPath;
    Log.logDone('Wrote $finalPath');
  }
}

/// `xcross dn run` — build, install, and run a DartNative app on iOS 17+.
///
/// Mirrors `xcross flutter run`: always builds a debug (JIT) app via
/// [DnPackOperation], then installs/launches it through the shared
/// [DeviceRunOperation] pipeline. Pass `--app-path` to skip the build and
/// deploy a prebuilt `.app` (e.g. built with `dn` on macOS).
final class DnRunCommand extends Command<void> {
  @override
  String get name => 'run';

  @override
  String get description =>
      'Build, install, and run a DartNative iOS app on a device.';

  DnRunCommand() {
    argParser
      ..addOption('target', abbr: 't', defaultsTo: 'lib/main.dart')
      ..addMultiOption('dart-define', abbr: 'D')
      ..addMultiOption('dart-define-from-file')
      ..addFlag('pub', defaultsTo: true)
      ..addOption('build-name')
      ..addOption('build-number')
      ..addOption('flavor')
      ..addOption('app-path', help: 'Deploy a prebuilt .app, skipping the build.')
      ..addOption('bundle-id', help: 'Override CFBundleIdentifier.')
      ..addOption('device-id', abbr: 'd', help: 'Target device id or name.')
      ..addOption('udid', abbr: 'u', help: 'Target device UDID.')
      ..addFlag('usb', help: 'Search USB devices only.', negatable: false)
      ..addFlag('wifi', help: 'Search Wi-Fi devices only.', negatable: false)
      ..addOption(
        'device-connection',
        defaultsTo: 'both',
        allowed: ['attached', 'wireless', 'both'],
        help: 'Discovery: attached (USB), wireless (Wi-Fi), or both.',
      )
      ..addMultiOption('app-argument', abbr: 'a', help: 'Pass arguments to the app main().')
      ..addFlag('hot',
          help: 'Run with support for hot reloading (debug mode only, like `dn run --hot`).',
          defaultsTo: true)
      ..addFlag('verbose', abbr: 'v', help: 'Verbose output.', negatable: false);
  }

  @override
  Future<void> run() async {
    if (argResults!['verbose'] as bool) Log.setVerbose();
    final connection = DeviceConnection.values.firstWhere(
      (v) => v.name == (argResults!['device-connection'] as String),
    );
    final mode = deviceSearchMode(
      usb: argResults!['usb'] as bool,
      wifi: argResults!['wifi'] as bool,
      deviceConnection: connection,
    );
    final PackResult pack;
    final appPath = argResults!['app-path'] as String?;
    if (appPath != null && appPath.isNotEmpty) {
      pack = DnAppResolver.resolve(
        projectRoot: Directory.current.path,
        appPath: appPath,
        bundleIdOverride: argResults!['bundle-id'] as String?,
      );
    } else {
      final options = await DnBuildOptions.resolve(
        target: argResults!['target'] as String,
        dartDefine: argResults!['dart-define'] as List<String>,
        dartDefineFromFile:
            argResults!['dart-define-from-file'] as List<String>,
        pub: argResults!['pub'] as bool,
        buildName: argResults!['build-name'] as String?,
        buildNumber: argResults!['build-number'] as String?,
        flavor: argResults!['flavor'] as String?,
      );
      pack = await DnPackOperation.pack(
        options: options,
        bundleIdOverride: argResults!['bundle-id'] as String?,
      );
    }
    Log.logInfo('App', '${pack.bundleId} ${Log.dim('dartnative, attached via CoreDevice')}');
    final operation = await DeviceRunOperation.resolve();
    // Full parity with `dn run --hot` (on by default): a persistent DN
    // frontend_server recompiles changed sources to an incremental dill and
    // the shared HotReloadController pushes it over DevFS, giving the same
    // r/R workflow as Flutter. When the DN SDK pieces are missing (or
    // --no-hot), fall back to the streaming native profile.
    HotReloadConfig? hotReload;
    if (argResults!['hot'] as bool) {
      final defines = await DnBuildOptions.resolve(
        target: argResults!['target'] as String,
        dartDefine: argResults!['dart-define'] as List<String>,
        dartDefineFromFile:
            argResults!['dart-define-from-file'] as List<String>,
        pub: argResults!['pub'] as bool,
        buildName: argResults!['build-name'] as String?,
        buildNumber: argResults!['build-number'] as String?,
        flavor: argResults!['flavor'] as String?,
      );
      hotReload = await DnHotReloadSetup.buildHotReloadConfig(
        target: argResults!['target'] as String,
        dartDefines: defines.dartDefines,
        verbose: argResults!['verbose'] as bool,
      );
    }
    final profile = hotReload == null
        ? CoreDeviceLaunchProfile.native(
            arguments: argResults!['app-argument'] as List<String>,
          )
        : CoreDeviceLaunchProfile.dn(
            hotReload: hotReload,
            arguments: argResults!['app-argument'] as List<String>,
          );
    await operation.run(
      pack: pack,
      selector:
          (argResults!['udid'] as String?) ?? (argResults!['device-id'] as String?),
      mode: mode,
      launchProfile: profile,
    );
  }
}

/// `xcross dn` — parent command grouping DartNative `build` and `run`.
final class DnCommand extends Command<void> {
  DnCommand() {
    addSubcommand(DnBuildCommand());
    addSubcommand(DnRunCommand());
  }

  @override
  String get name => 'dn';

  @override
  String get description =>
      'Build and run DartNative iOS apps without Xcode (dn CLI + xcross deploy).';
}
