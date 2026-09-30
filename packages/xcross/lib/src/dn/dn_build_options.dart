import 'package:xcross/src/flutter/models/flutter/dart_defines.dart';

/// Options shared by `xcross dn build` and `xcross dn run`, mirroring the
/// semantics of `xcross flutter build`/`run` (debug/JIT only).
final class DnBuildOptions {
  const DnBuildOptions({
    this.target = 'lib/main.dart',
    this.dartDefines = const [],
    this.pub = true,
    this.buildName,
    this.buildNumber,
    this.flavor,
  });

  /// Build options from raw CLI arguments, merging `--dart-define-from-file`
  /// entries (lower precedence) with explicit `--dart-define` entries, then
  /// appending the derived `FLUTTER_APP_FLAVOR` define unless explicitly set.
  /// Derived here (not only in the packer) so hot reload compiles see the
  /// identical constants as the bundled kernel.
  static Future<DnBuildOptions> resolve({
    required String target,
    required List<String> dartDefine,
    required List<String> dartDefineFromFile,
    required bool pub,
    String? buildName,
    String? buildNumber,
    String? flavor,
  }) async => DnBuildOptions(
    target: target,
    dartDefines: DartDefines.withFlavorDefine(
      await DartDefines.mergeDartDefines(dartDefineFromFile, dartDefine),
      flavor,
    ),
    pub: pub,
    buildName: buildName,
    buildNumber: buildNumber,
    flavor: flavor,
  );

  /// `-t/--target` entrypoint.
  final String target;

  /// Merged `--dart-define` + `--dart-define-from-file` values as `KEY=VALUE`
  /// strings (file entries first, explicit `--dart-define` overriding them),
  /// plus the derived `FLUTTER_APP_FLAVOR` define when `--flavor` is set
  /// (unless explicitly defined).
  final List<String> dartDefines;

  /// `--[no-]pub` — whether `dn build bundle` runs `dn pub get` itself.
  final bool pub;

  /// `--build-name` → `CFBundleShortVersionString` (defaults from pbxproj).
  final String? buildName;

  /// `--build-number` → `CFBundleVersion` (defaults from pbxproj).
  final String? buildNumber;

  /// `--flavor` — forwarded as a `FLUTTER_APP_FLAVOR` dart-define, readable
  /// at runtime via `String.fromEnvironment`, mirroring the Flutter path.
  final String? flavor;
}
