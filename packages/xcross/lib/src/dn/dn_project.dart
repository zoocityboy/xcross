import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Groups DartNative project detection and `dn` executable resolution.
///
/// A DartNative project is a Dart package whose `pubspec.yaml` depends on
/// `dartnative` (directly or via the lock file). The `dn` CLI wraps the
/// `flutter` tool against the Zero engine and lives in `~/zero/bin` after
/// the documented install.
abstract final class DnProject {
  /// Whether [projectRoot] looks like a DartNative project.
  ///
  /// Reads `dependencies:` straight from `pubspec.yaml` rather than the
  /// resolved package list: `dn` resolves DartNative packages from its own
  /// SDK, so a lock file written by plain `pub`/`flutter pub get` never
  /// contains them (and `dn pub get` writes `dn_plugins.lock` instead).
  static bool isDartNativeProject(String projectRoot) {
    try {
      final file = File(p.join(projectRoot, 'pubspec.yaml'));
      if (!file.existsSync()) return false;
      final doc = loadYaml(file.readAsStringSync());
      if (doc is! YamlMap) return false;
      final deps = doc['dependencies'];
      if (deps is! YamlMap) return false;
      return deps.keys.whereType<String>().any(
        (name) =>
            name == 'dartnative' ||
            name == 'dartnative_ios' ||
            name == 'dartnative_android',
      );
    } on Object {
      return false;
    }
  }

  /// Resolve the `dn` executable to invoke.
  ///
  /// Precedence: explicit `--dn-executable`, `DN_EXECUTABLE` env,
  /// `dn` on `PATH`, `~/zero/bin/dn` from the documented install.
  /// Returns null when nothing is found.
  static String? resolveDnExecutable({String? explicit}) {
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final env = Platform.environment['DN_EXECUTABLE'];
    if (env != null && env.isNotEmpty) return env;
    final onPath = _which('dn');
    if (onPath != null) return onPath;
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      final candidate = p.join(home, 'zero', 'bin', Platform.isWindows ? 'dn.bat' : 'dn');
      if (File(candidate).existsSync()) return candidate;
      final plain = p.join(home, 'zero', 'bin', 'dn');
      if (File(plain).existsSync()) return plain;
    }
    return null;
  }

  static String? _which(String name) {
    final path = Platform.environment['PATH'] ?? '';
    final entries = path.split(Platform.isWindows ? ';' : ':');
    final candidates = Platform.isWindows ? ['$name.exe', '$name.bat', name] : [name];
    for (final dir in entries) {
      for (final candidate in candidates) {
        final full = p.join(dir, candidate);
        if (File(full).existsSync()) return full;
      }
    }
    return null;
  }
}
