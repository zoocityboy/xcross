import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Detects DartNative projects from their `pubspec.yaml`.
///
/// Shared contract: the composition layer owns `dn` executable resolution;
/// every layer that needs to branch on "is this a DartNative workspace" uses
/// this host-injected detector.
@internal
final class DnProjectDetector {
  const DnProjectDetector(this.fileSystem, this.paths);

  final HostFileSystemInterface fileSystem;
  final p.Context paths;

  /// Whether [projectRoot] looks like a DartNative project.
  ///
  /// Reads `dependencies:` straight from `pubspec.yaml` rather than the
  /// resolved package list: `dn` resolves DartNative packages from its own
  /// SDK, so a lock file written by plain `pub`/`flutter pub get` never
  /// contains them (and `dn pub get` writes `dn_plugins.lock` instead).
  bool isDartNativeProject(String projectRoot) {
    try {
      final file = fileSystem.file(paths.join(projectRoot, 'pubspec.yaml'));
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
}
