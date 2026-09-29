import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:xcross/src/flutter/flutter.dart';

final class CoreDeviceLaunchProfile {
  const CoreDeviceLaunchProfile.native({this.arguments = const []})
    : hotReload = null,
      _flutterRuntime = false;

  const CoreDeviceLaunchProfile.flutter({
    required this.hotReload,
    this.arguments = const [],
  }) : _flutterRuntime = true;

  /// DartNative debug (JIT) launch with hot reload.
  ///
  /// The DN engine is a Flutter-engine fork and accepts the same VM Service
  /// flags, so this passes the identical runtime arguments as [flutter].
  /// Kept as a separate constructor so call sites read as DN rather than
  /// Flutter, and so future DN-only flags have a home.
  const CoreDeviceLaunchProfile.dn({
    required this.hotReload,
    this.arguments = const [],
  }) : _flutterRuntime = true;

  final List<String> arguments;
  final HotReloadConfig? hotReload;
  final bool _flutterRuntime;

  List<String> argumentsForLaunch({
    required bool isDap,
    bool ipv6VmService = false,
  }) => [
    if (_flutterRuntime && hotReload != null) ...[
      '--vm-service-host=${ipv6VmService ? '::0' : '0.0.0.0'}',
      '--vm-service-port=${TunnelConstants.vmServicePort}',
      '--disable-service-auth-codes',
      if (isDap) '--start-paused',
    ],
    if (_flutterRuntime) ...['--enable-checked-mode', '--verify-entry-points'],
    ...arguments,
  ];
}
