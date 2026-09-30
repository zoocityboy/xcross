enum PackOutputKind { app, framework }

final class PackResult {
  const PackResult({
    required this.outputPath,
    required this.bundleId,
    this.kind = PackOutputKind.app,
    this.projectRoot,
    this.injectedDefines = const [],
  });

  final String outputPath;
  final String bundleId;
  final PackOutputKind kind;

  /// Source root the bundle was built from, when the builder knows it.
  ///
  /// `compose run --watch` needs it to watch the right tree: the CLI's own
  /// working directory is not necessarily the project root (the packer walks
  /// up to find `settings.gradle.kts`), and watching the wrong directory
  /// silently reports "no source changes" forever.
  final String? projectRoot;

  /// Defines the builder's own toolchain injected on top of the caller's
  /// `--dart-define`s (`dn` license key, `FLUTTER_*` constants).
  ///
  /// Compiles outside the builder (hot reload / restart) must mirror them,
  /// or the reloaded program differs from the bundled one — e.g. a restarted
  /// DN isolate boots without `DN_LICENSE_KEY` and shows the license screen.
  final List<String> injectedDefines;

  String get appPath {
    if (kind != PackOutputKind.app) {
      throw StateError('PackResult is a framework, not an app');
    }
    return outputPath;
  }
}
