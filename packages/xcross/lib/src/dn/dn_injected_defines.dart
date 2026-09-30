import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;

/// Defines `dn build bundle` injects into every kernel compile on top of the
/// caller's `--dart-define`s: the license from `dn config --license-key` /
/// `--license-token` (`DN_LICENSE_KEY`, `DART_NATIVE_LICENSE_TOKEN`,
/// `DN_TRIAL_ENDED`) plus the informational `FLUTTER_*` constants. A key
/// passed explicitly on the build command wins over the configured value
/// (dn's own precedence rule).
///
/// xcross's persistent `frontend_server` (hot reload / restart) is a separate
/// compile that would otherwise miss them: the bundled app boots with the key
/// while a restarted isolate boots without it and shows the DartNative
/// license screen instead of the app.
///
/// `dn config --list` masks secret values, but the verbose bundle build
/// prints the effective frontend_server command line in plaintext, so
/// [extractFromBuildLog] scrapes the injected set there. Values are secrets:
/// never log them (key names only), matching dn's own masking.
abstract final class DnInjectedDefines {
  /// Whether [key] (the part before `=`) is mirrored from dn's injection.
  static bool isMirrored(String key) =>
      key == 'DN_LICENSE_KEY' ||
      key == 'DART_NATIVE_LICENSE_TOKEN' ||
      key == 'DN_TRIAL_ENDED' ||
      key.startsWith('FLUTTER_');

  /// Key part of a `KEY=value` (or bare `KEY`) define string.
  static String keyOf(String define) {
    final eq = define.indexOf('=');
    return eq < 0 ? define : define.substring(0, eq);
  }

  // Flag boundary: ` -X` or ` --xxx` (dn's line mixes both after -D values).
  static final _flagStart = RegExp(' -(?:-?[A-Za-z])');
  // No `^` anchor: used with [RegExp.matchAsPrefix] at a cursor, where `^`
  // would only match index 0.
  static final _keyPattern = RegExp('[A-Za-z_][A-Za-z0-9_.]*');

  /// Scrape dn-injected `-D` flags from `dn build bundle -v` output.
  ///
  /// Only `frontend_server` invocation lines are considered. A flag value
  /// runs until the next ` -<letter>` (start of another flag) or end of
  /// line, so values containing spaces (e.g. `FLUTTER_DART_VERSION=3.12.0
  /// (build ...)`) survive. Returns `KEY=value` strings in first-seen order.
  static List<String> extractFromBuildLog(String log) {
    final found = <String>[];
    final seen = <String>{};
    for (final line in log.split('\n')) {
      if (!line.contains('frontend_server')) continue;
      var i = 0;
      while (true) {
        i = line.indexOf(' -D', i);
        if (i < 0) break;
        i += 3; // past ' -D'
        final keyMatch = _keyPattern.matchAsPrefix(line, i);
        if (keyMatch == null) continue;
        final key = keyMatch.group(0)!;
        i = keyMatch.end;
        String define;
        if (i < line.length && line[i] == '=') {
          i++;
          final end = _flagStart.firstMatch(line.substring(i));
          final rawEnd = end == null ? line.length : i + end.start;
          define = '$key=${line.substring(i, rawEnd).trimRight()}';
          i = rawEnd;
        } else {
          define = key;
        }
        if (isMirrored(key) && seen.add(key)) found.add(define);
      }
    }
    return found;
  }

  /// Merge dn-injected defines under explicit user defines: an explicitly
  /// passed key wins (dn's own rule), the rest is appended in scrape order.
  static List<String> merge({
    required List<String> user,
    required List<String> injected,
  }) {
    final userKeys = {for (final d in user) keyOf(d)};
    return [
      ...user,
      for (final d in injected)
        if (!userKeys.contains(keyOf(d))) d,
    ];
  }

  /// On-disk cache so an incremental `dn build bundle` (which skips the
  /// kernel compile and prints no frontend_server line) still restores the
  /// injected set. Lives directly under `build/` — the per-step directories
  /// below it (`xcross-dn-debug`, `xcross-dn-assets`) are wiped and rebuilt
  /// during packing. A clean (`dn clean`) removes it, but then the next
  /// build fully recompiles and rescrapes, so it self-heals.
  static String cachePath(String projectRoot) =>
      p.join(projectRoot, 'build', '.dn-injected-defines.json');

  static List<String> readCache(String projectRoot) {
    try {
      final file = File(cachePath(projectRoot));
      if (!file.existsSync()) return const [];
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List) return const [];
      return decoded.whereType<String>().toList();
    } on Object catch (e) {
      Log.logTrace('dn injected-defines cache unreadable: $e');
      return const [];
    }
  }

  static Future<void> writeCache(
    String projectRoot,
    List<String> defines,
  ) async {
    try {
      final file = File(cachePath(projectRoot));
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(defines));
    } on Object catch (e) {
      Log.logTrace('dn injected-defines cache unwritable: $e');
    }
  }
}
