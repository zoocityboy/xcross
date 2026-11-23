import 'package:args/command_runner.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:dart_mobile_device/shared/network/device_sockets.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/composition/dn/dn_app_resolver.dart';
import 'package:xcross/src/composition/dn/dn_context.dart';
import 'package:xcross/src/composition/dn/dn_hot_reload_setup.dart';
import 'package:xcross/src/composition/dn/dn_pack_operation.dart';
import 'package:xcross/src/shared/cli/device_selection.dart';
import 'package:xcross/src/shared/cli/shared/ipa_packager.dart';
import 'package:xcross/src/shared/flutter/flutter_build_options_resolver.dart';
import 'package:xcross/src/shared/flutter/models/flutter/dart_defines.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/shared/flutter/models/hot_reload_config.dart';
import 'package:xcross/src/shared/flutter/project/dart_defines_reader.dart';
import 'package:xcross/src/shared/models/pack_result.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';
import 'package:xcross/src/target/iphone/device/core_device_launch_profile.dart';
import 'package:xcross/src/target/iphone/device/device_run_operation.dart';

/// `xcross dn build` — build a DartNative iOS `.app` without Xcode.
///
/// Mirrors `xcross flutter build`: the Dart bundle comes from
/// `dn build bundle` (runs on Linux), the Runner binary is compiled with the
/// xcross Darwin cross-toolchain, and the `.app` is assembled into
/// `build/xcross-ios/`. Debug/JIT only; signing happens at `run` time.
@internal
final class DnBuildCommand<T extends PlatformHostInterface>
    extends Command<void> {
  DnBuildCommand(this.runtime) {
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
      ..addFlag(
        'verbose',
        abbr: 'v',
        help: 'Verbose output.',
        negatable: false,
      );
  }

  final XcrossRuntime<T> runtime;

  @override
  String get name => 'build';

  @override
  String get description => 'Build a DartNative iOS .app without Xcode.';

  @override
  Future<void> run() async {
    if (argResults!.flag('verbose')) runtime.log.setVerbose();
    final options =
        await FlutterBuildOptionsResolver(
          DartDefinesReader(
            runtime.host.fileSystem,
            runtime.host.paths.context,
          ),
        ).resolve(
          target: argResults!.option('target')!,
          dartDefine: argResults!.multiOption('dart-define'),
          dartDefineFromFile: argResults!.multiOption('dart-define-from-file'),
          pub: argResults!.flag('pub'),
          buildName: argResults!.option('build-name'),
          buildNumber: argResults!.option('build-number'),
          flavor: argResults!.option('flavor'),
        );
    final pack = await DnPackOperation.pack(
      context: _context(),
      options: options,
      bundleIdOverride: argResults!.option('bundle-id'),
    );
    final finalPath = argResults!.flag('ipa')
        ? await IpaPackager(host: runtime.host).package(pack.appPath)
        : pack.outputPath;
    runtime.log.logDone('Wrote $finalPath');
  }

  DnContext<T> _context() => DnContext(
    runner: runtime.runner,
    projectRoot: runtime.host.paths.context.current,
    sdkRepository: runtime.sdkRepository,
    toolchainResolver: runtime.darwinToolchain,
    downloader: runtime.downloader,
    sdkInstall: runtime.sdkInstall,
  );
}

/// `xcross dn run` — build, install, and run a DartNative app on iOS 17+.
///
/// Mirrors `xcross flutter run`: always builds a debug (JIT) app via
/// [DnPackOperation], then installs/launches it through the shared
/// [DeviceRunOperation] pipeline. Pass `--app-path` to skip the build and
/// deploy a prebuilt `.app` (e.g. built with `dn` on macOS).
@internal
final class DnRunCommand<T extends PlatformHostInterface>
    extends Command<void> {
  DnRunCommand(this.runtime, this.pymd, {required this.sockets}) {
    argParser
      ..addOption('target', abbr: 't', defaultsTo: 'lib/main.dart')
      ..addMultiOption('dart-define', abbr: 'D')
      ..addMultiOption('dart-define-from-file')
      ..addFlag('pub', defaultsTo: true)
      ..addOption('build-name')
      ..addOption('build-number')
      ..addOption('flavor')
      ..addOption(
        'app-path',
        help: 'Deploy a prebuilt .app, skipping the build.',
      )
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
      ..addMultiOption(
        'app-argument',
        abbr: 'a',
        help: 'Pass arguments to the app main().',
      )
      ..addFlag(
        'hot',
        help:
            'Run with support for hot reloading (debug mode only, like '
            '`dn run --hot`).',
        defaultsTo: true,
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        help: 'Verbose output.',
        negatable: false,
      );
  }

  final XcrossRuntime<T> runtime;
  final Pymd pymd;
  final DeviceSockets sockets;

  @override
  String get name => 'run';

  @override
  String get description =>
      'Build, install, and run a DartNative iOS app on a device.';

  @override
  Future<void> run() async {
    if (argResults!.flag('verbose')) runtime.log.setVerbose();
    final context = DnContext(
      runner: runtime.runner,
      projectRoot: runtime.host.paths.context.current,
      sdkRepository: runtime.sdkRepository,
      toolchainResolver: runtime.darwinToolchain,
      downloader: runtime.downloader,
      sdkInstall: runtime.sdkInstall,
    );
    final connection = DeviceConnection.values.firstWhere(
      (v) => v.name == argResults!.option('device-connection'),
    );
    final mode = deviceSearchMode(
      usb: argResults!.flag('usb'),
      wifi: argResults!.flag('wifi'),
      deviceConnection: connection,
    );
    final PackResult pack;
    final String appPath = argResults!.option('app-path') ?? '';
    if (appPath.isNotEmpty) {
      pack = DnAppResolver.resolve(
        projectRoot: context.projectRoot,
        appPath: appPath,
        bundleIdOverride: argResults!.option('bundle-id'),
      );
    } else {
      pack = await DnPackOperation.pack(
        context: context,
        options: await _buildOptions(),
        bundleIdOverride: argResults!.option('bundle-id'),
      );
    }
    runtime.log.logInfo(
      'App',
      '${pack.bundleId} ${runtime.log.dim('dartnative, attached via CoreDevice')}',
    );
    final operation = await DeviceRunOperation.resolve(
      pymd,
      sockets: sockets,
      httpClients: runtime.signingHttpClients,
      connector: runtime.vmConnector,
      vmOutput: runtime.vmOutput,
      hostServices: runtime.appleHostServices,
      createNativeLibraryLoader: runtime.createNativeLibraryLoader,
      prompt: runtime.commandPrompt,
    );
    // Full parity with `dn run --hot` (on by default): a persistent DN
    // frontend_server recompiles changed sources to an incremental dill and
    // the shared HotReloadController pushes it over DevFS, giving the same
    // r/R workflow as Flutter. When the DN SDK pieces are missing (or
    // --no-hot), fall back to the streaming native profile.
    HotReloadConfig? hotReload;
    if (argResults!.flag('hot')) {
      // A fresh build already carries dn's injected defines (license key,
      // FLUTTER_*); without one there is no pack to take them from, so the
      // plain CLI defines are used.
      final dartDefines = pack.dartDefines.isNotEmpty
          ? pack.dartDefines
          : DartDefines.withFlavorDefine(
              (await _buildOptions()).dartDefines,
              argResults!.option('flavor'),
            );
      hotReload = await DnHotReloadSetup.buildHotReloadConfig(
        context: context,
        target: argResults!.option('target')!,
        dartDefines: dartDefines,
        verbose: argResults!.flag('verbose'),
      );
    }
    final profile = hotReload == null
        ? CoreDeviceLaunchProfile.native(
            arguments: argResults!.multiOption('app-argument'),
          )
        : CoreDeviceLaunchProfile.flutter(
            buildMode: FlutterBuildMode.debug,
            hotReload: hotReload,
            arguments: argResults!.multiOption('app-argument'),
          );
    await operation.run(
      pack: pack,
      selector: argResults!.option('udid') ?? argResults!.option('device-id'),
      mode: mode,
      launchProfile: profile,
    );
  }

  Future<FlutterBuildOptions> _buildOptions() =>
      FlutterBuildOptionsResolver(
        DartDefinesReader(runtime.host.fileSystem, runtime.host.paths.context),
      ).resolve(
        target: argResults!.option('target')!,
        dartDefine: argResults!.multiOption('dart-define'),
        dartDefineFromFile: argResults!.multiOption('dart-define-from-file'),
        pub: argResults!.flag('pub'),
        buildName: argResults!.option('build-name'),
        buildNumber: argResults!.option('build-number'),
        flavor: argResults!.option('flavor'),
      );
}

/// `xcross dn` — parent command grouping DartNative `build`, `run` and
/// `doctor`.
@internal
final class DnCommand<T extends PlatformHostInterface> extends Command<void> {
  DnCommand(
    XcrossRuntime<T> runtime,
    Pymd pymd,
    DeviceSockets sockets, {
    Command<void>? doctorCommand,
  }) {
    addSubcommand(DnBuildCommand(runtime));
    addSubcommand(DnRunCommand(runtime, pymd, sockets: sockets));
    if (doctorCommand != null) addSubcommand(doctorCommand);
  }

  @override
  String get name => 'dn';

  @override
  String get description =>
      'Build and run DartNative iOS apps without Xcode '
      '(dn CLI + xcross deploy).';
}
