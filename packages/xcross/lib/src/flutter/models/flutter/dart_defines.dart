import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/errors.dart';

/// Merging of dart-define sources into `KEY=VALUE` strings.
abstract final class DartDefines {
  /// Key part of a `KEY=value` (or bare `KEY`) define string.
  static String keyOf(String define) {
    final eq = define.indexOf('=');
    return eq < 0 ? define : define.substring(0, eq);
  }

  /// Append [fallback] defines for keys [base] doesn't already define.
  ///
  /// Tool-injected constants (`FLUTTER_*`, license keys) merge this way: an
  /// explicitly passed key wins (dn's own precedence), the rest is appended
  /// in order. frontend_server resolves duplicate keys last-wins, so
  /// appending unfiltered would invert the precedence.
  static List<String> mergeFallback({
    required List<String> base,
    required List<String> fallback,
  }) {
    final baseKeys = {for (final d in base) keyOf(d)};
    return [
      ...base,
      for (final d in fallback)
        if (!baseKeys.contains(keyOf(d))) d,
    ];
  }

  /// Append `-DFLUTTER_APP_FLAVOR=<flavor>` unless [flavor] is null or the
  /// [defines] already set the key explicitly (explicit wins).
  ///
  /// Applied in `*BuildOptions.resolve` so the bundle compile and hot reload
  /// compiles see identical constants; packers keep their own guard for
  /// directly-constructed options.
  static List<String> withFlavorDefine(
    List<String> defines,
    String? flavor,
  ) {
    if (flavor == null ||
        defines.any((d) => d.startsWith('FLUTTER_APP_FLAVOR='))) {
      return defines;
    }
    return [...defines, 'FLUTTER_APP_FLAVOR=$flavor'];
  }
  /// Merge dart-define sources into ordered `KEY=VALUE` strings.
  ///
  /// ORDER MATTERS: file entries come first and explicit `--dart-define`
  /// entries last, so the explicit ones win when frontend_server resolves
  /// duplicate keys (last-wins). De-duplicating or sorting this list would
  /// invert which value the app sees.
  static Future<List<String>> mergeDartDefines(
    List<String> fromFiles,
    List<String> explicit,
  ) async => [
    for (final path in fromFiles) ...await _readDefineFile(path),
    ...explicit,
  ];

  /// Parse a `--dart-define-from-file` source (`.json` object or `.env`-style
  /// `KEY=VALUE` lines) into `KEY=VALUE` strings.
  static Future<List<String>> _readDefineFile(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw FlutterBuildError('--dart-define-from-file: file not found: $path');
    }
    final content = await file.readAsString();
    final isJson =
        p.extension(path) == '.json' || content.trimLeft().startsWith('{');
    return isJson ? _parseJson(path, content) : _parseEnv(content);
  }

  static List<String> _parseJson(String path, String content) {
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw FlutterBuildError(
        '--dart-define-from-file: $path is not a JSON object',
      );
    }
    // Dart's default toString keeps JSON true/1/1.5 as bare tokens;
    // jsonEncode here would quote strings and change every emitted define.
    return [for (final e in decoded.entries) '${e.key}=${e.value}'];
  }

  /// `.env` style: `KEY=VALUE` lines, ignoring blanks and `#` comments. The
  /// whole line is kept verbatim (never re-joined around `=`) so values
  /// containing `=` — base64, URLs, JWTs — survive byte-exact.
  static List<String> _parseEnv(String content) => [
    for (final raw in const LineSplitter().convert(content))
      if (raw.trim() case final line
          when line.isNotEmpty && !line.startsWith('#') && line.contains('='))
        line,
  ];
}
