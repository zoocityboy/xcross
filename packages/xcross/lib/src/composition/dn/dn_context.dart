import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_build_platform.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/cli/basic/sdk_install.dart';
import 'package:xcross/src/shared/errors/errors.dart';

/// Everything the DartNative (dn) build pipeline needs from the xcross
/// runtime: process execution, logging, the selected Darwin SDK and its
/// cross-toolchain, plus the shared download/SDK-install services.
///
/// Passed explicitly (instead of the globals the pre-v2.1 pipeline used) so
/// the dn modules share one configured host, runner and log with the rest of
/// the CLI.
@internal
final class DnContext<T extends PlatformHostInterface> {
  const DnContext({
    required this.runner,
    required this.projectRoot,
    required this.sdkRepository,
    required this.toolchainResolver,
    required this.downloader,
    required this.sdkInstall,
  });

  final ProcessRunner<T> runner;
  final String projectRoot;
  final DarwinSdkRepository<T> sdkRepository;
  final DarwinToolchainResolver<T> toolchainResolver;
  final Downloader downloader;
  final SdkInstall<T> sdkInstall;

  T get host => runner.host;
  Log get log => runner.log;
  p.Context get paths => host.paths.context;

  /// The installed Darwin SDK, or [XcrossError] with install guidance.
  DarwinSdk requireSdk() {
    final sdk = sdkRepository.current();
    if (sdk == null) {
      throw XcrossError(
        'DnPackOperation: Darwin SDK not found. '
        'Install with `xcross sdk install <Xcode.xip|Xcode.app>`.',
      );
    }
    return sdk;
  }

  /// Absolute path of the iPhoneOS SDK inside the installed SDK bundle.
  String requireIosSdk() =>
      sdkRepository.iosSdk(requireSdk(), target: const IPhoneBuildPlatform());
}
