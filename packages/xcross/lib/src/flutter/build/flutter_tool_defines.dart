import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// The `-D` constants the official `flutter` tool bakes into every kernel
/// compile: SDK identity (`FLUTTER_VERSION`, `FLUTTER_CHANNEL`,
/// `FLUTTER_GIT_URL`, `FLUTTER_FRAMEWORK_REVISION`, `FLUTTER_ENGINE_REVISION`,
/// `FLUTTER_DART_VERSION`) and the app version (`FLUTTER_BUILD_NAME`,
/// `FLUTTER_BUILD_NUMBER`).
///
/// xcross compiles kernels itself (bundle + hot reload), so it must mirror
/// both sets — otherwise a restarted isolate reads different
/// `String.fromEnvironment` constants than the bundled app did. The DN
/// equivalents arrive via [DnInjectedDefines]; this file covers stock
/// Flutter only.
abstract final class FlutterToolDefines {
  /// `KEY=VALUE` SDK identity defines for [flutterRoot].
  ///
  /// Resolved once per process per root via `flutter --version --machine`
  /// (tens of milliseconds); failures yield an empty list so a build never
  /// breaks over informational constants.
  static Future<List<String>> sdkDefines({required String flutterRoot}) =>
      _sdkCache.putIfAbsent(flutterRoot, () => _readSdkDefines(flutterRoot));

  static final _sdkCache = <String, Future<List<String>>>{};

  static Future<List<String>> _readSdkDefines(String flutterRoot) async {
    try {
      final flutter = p.join(
        flutterRoot,
        'bin',
        Platform.isWindows ? 'flutter.bat' : 'flutter',
      );
      if (!File(flutter).existsSync()) return const [];
      final result = await ProcessRunner.run(flutter, [
        '--version',
        '--machine',
      ]);
      if (result.exitCode != 0) return const [];
      return sdkDefinesFromJson(
        jsonDecode(result.stdout) as Map<String, Object?>,
      );
    } on Object catch (e) {
      Log.logTrace('flutter tool defines unavailable: $e');
      return const [];
    }
  }

  /// Map `flutter --version --machine` JSON to `KEY=VALUE` defines.
  ///
  /// Revisions are truncated to 10 chars, matching what the tool itself
  /// passes to frontend_server.
  static List<String> sdkDefinesFromJson(Map<String, Object?> json) {
    String str(String key) => '${json[key] ?? ''}';
    String rev(String key) {
      final full = str(key);
      return full.length <= 10 ? full : full.substring(0, 10);
    }

    return [
      'FLUTTER_VERSION=${str('frameworkVersion')}',
      'FLUTTER_CHANNEL=${str('channel')}',
      'FLUTTER_GIT_URL=${str('repositoryUrl')}',
      'FLUTTER_FRAMEWORK_REVISION=${rev('frameworkRevision')}',
      'FLUTTER_ENGINE_REVISION=${rev('engineRevision')}',
      'FLUTTER_DART_VERSION=${str('dartSdkVersion')}',
    ];
  }

  /// `FLUTTER_BUILD_NAME` / `FLUTTER_BUILD_NUMBER` defines.
  ///
  /// Explicit `--build-name` / `--build-number` win; the rest defaults to the
  /// pubspec `version:` (`1.0.0+1` → name `1.0.0`, number `1`), then to
  /// `1.0.0` / `1` — the same ladder the flutter tool climbs.
  static List<String> buildDefines({
    required String projectRoot,
    String? buildName,
    String? buildNumber,
  }) {
    final (pubName, pubBuild) = parsePubspecVersion(_readVersion(projectRoot));
    return [
      'FLUTTER_BUILD_NAME=${buildName ?? pubName ?? '1.0.0'}',
      'FLUTTER_BUILD_NUMBER=${buildNumber ?? pubBuild ?? '1'}',
    ];
  }

  /// Split a pubspec `version:` (`1.0.0+1`) into (name, build); either side
  /// may be null when absent or blank.
  static (String?, String?) parsePubspecVersion(String? version) {
    if (version == null || version.trim().isEmpty) return (null, null);
    final plus = version.indexOf('+');
    if (plus < 0) {
      final name = version.trim();
      return (name.isEmpty ? null : name, null);
    }
    final name = version.substring(0, plus).trim();
    final build = version.substring(plus + 1).trim();
    return (
      name.isEmpty ? null : name,
      build.isEmpty ? null : build,
    );
  }

  static String? _readVersion(String projectRoot) {
    try {
      final doc =
          loadYaml(File(p.join(projectRoot, 'pubspec.yaml')).readAsStringSync());
      if (doc is! YamlMap) return null;
      final version = doc['version'];
      return version is String ? version : null;
    } on Object catch (e) {
      Log.logTrace('pubspec version unreadable: $e');
      return null;
    }
  }
}
