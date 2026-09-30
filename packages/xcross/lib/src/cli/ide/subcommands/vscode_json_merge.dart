import 'dart:convert';

const String xcrossLaunchName = 'xcross: iOS device';
const String dapPathSetting = 'dart.customFlutterDapPath';
const String dapPathValue = '.vscode/xcross_dap.dart';
const String promptErrorsSetting = 'dart.promptToRunIfErrors';

/// Shim file names (under `.vscode/`). The Flutter-adapter shim serves
/// `dart.customFlutterDapPath`; the Dart-adapter shim serves
/// `dart.customDartDapPath` for DartNative projects (see above).
const String xcrossDapFile = 'xcross_dap.dart';
const String dartDapFile = 'xcross_dart_dap.dart';

/// Marks a launch config as xcross-owned. Carried in the config's `env` (a
/// schema-valid Dart launch field) so editors don't flag an unknown key.
const String xcrossEnvKey = 'XCROSS';
const String xcrossEnvValue = 'true';

/// `dart.customDartDapPath` shim for DartNative projects. Dart-Code classifies
/// DN workspaces as Dart-only (their pubspecs never reference `flutter`, so
/// `debuggerType: flutter` entries are rejected outright), therefore DN
/// launches go through the Dart adapter slot instead of the Flutter one.
const String dartDapPathSetting = 'dart.customDartDapPath';
const String dartDapPathValue = '.vscode/xcross_dart_dap.dart';

/// JSONC parse/merge helpers for VS Code launch.json / settings.json.
abstract final class VscodeJsonMerge {
  /// Strip JSONC sugar VS Code allows: `//` / `/* */` comments and trailing
  /// commas before `}` / `]`. Strings are left untouched.
  static String stripJsonc(String source) {
    final out = StringBuffer();
    var i = 0;
    while (i < source.length) {
      final c = source[i];
      if (c == '"') {
        i = _copyStringLiteral(source, i, out);
        continue;
      }
      if (_skipComment(source, i) case final afterComment?) {
        i = afterComment;
        continue;
      }
      if (c == ',') {
        final afterComma = _skipTrivia(source, i + 1);
        if (afterComma < source.length &&
            (source[afterComma] == '}' || source[afterComma] == ']')) {
          i = afterComma;
          continue;
        }
      }
      out.write(c);
      i++;
    }
    return out.toString();
  }

  /// Copy the string literal opening at [start] verbatim, escapes included,
  /// so that `//`, `/*` and `,` inside it survive. Returns the index just
  /// past the closing quote, or the end of input for an unterminated string.
  static int _copyStringLiteral(String source, int start, StringBuffer out) {
    out.write(source[start]);
    var i = start + 1;
    while (i < source.length) {
      final c = source[i];
      out.write(c);
      if (c == r'\' && i + 1 < source.length) {
        out.write(source[i + 1]);
        i += 2;
        continue;
      }
      i++;
      if (c == '"') return i;
    }
    return i;
  }

  /// Index just past the comment starting at [start], or null when [start]
  /// does not open one. A `//` comment stops *at* its newline so the line
  /// structure of the document is preserved.
  static int? _skipComment(String source, int start) {
    if (start + 1 >= source.length || source[start] != '/') return null;
    var i = start + 2;
    switch (source[start + 1]) {
      case '/':
        while (i < source.length && source[i] != '\n') {
          i++;
        }
        return i;
      case '*':
        while (i + 1 < source.length &&
            !(source[i] == '*' && source[i + 1] == '/')) {
          i++;
        }
        return i + 2 <= source.length ? i + 2 : source.length;
      default:
        return null;
    }
  }

  static bool _isSpace(String c) =>
      c == ' ' || c == '\t' || c == '\n' || c == '\r';

  /// Skip whitespace and comments; returns the index of the next real token.
  static int _skipTrivia(String source, int start) {
    var i = start;
    while (i < source.length) {
      if (_isSpace(source[i])) {
        i++;
        continue;
      }
      if (_skipComment(source, i) case final afterComment?) {
        i = afterComment;
        continue;
      }
      break;
    }
    return i;
  }

  /// Parse JSON or JSONC. Throws [FormatException] on failure.
  static Object? parseJsonc(String source) => jsonDecode(stripJsonc(source));

  static bool jsonDeepEqual(Object? a, Object? b) => switch ((a, b)) {
    _ when identical(a, b) => true,
    (final Map<Object?, Object?> x, final Map<Object?, Object?> y) =>
      x.length == y.length &&
          x.keys.every((k) => y.containsKey(k) && jsonDeepEqual(x[k], y[k])),
    (final List<Object?> x, final List<Object?> y) =>
      x.length == y.length &&
          x.indexed.every((e) => jsonDeepEqual(e.$2, y[e.$1])),
    _ => a == b,
  };

  static String encodePrettyJson(Object? value) =>
      '${const JsonEncoder.withIndent('  ').convert(value)}\n';

  /// Canonical launch.json fields for the xcross entry (except `args`).
  ///
  /// [flutterDebugger] selects the `debuggerType` Dart-Code must use. Flutter
  /// projects keep `"flutter"`; DartNative projects must omit the field so
  /// Dart-Code auto-selects the Dart debugger — an explicit `"flutter"` is
  /// rejected in DN-only workspaces ("Unable to launch Flutter project in a
  /// Dart-only workspace") because no pubspec there references `flutter`.
  static Map<String, Object?> xcrossLaunchFields({
    bool flutterDebugger = true,
  }) => {
    'name': xcrossLaunchName,
    'type': 'dart',
    'request': 'launch',
    if (flutterDebugger) 'debuggerType': 'flutter',
    'program': 'lib/main.dart',
    'cwd': r'${workspaceFolder}',
  };

  /// The xcross marker merged onto the entry's own `env` entries.
  static Map<String, Object?> _withMarker(
    Object? env,
    Map<String, String> generatedEnvironment,
  ) => {
    if (env case final Map<Object?, Object?> existing)
      for (final e in existing.entries) '${e.key}': e.value,
    ...generatedEnvironment,
    xcrossEnvKey: xcrossEnvValue,
  };

  /// Overwrite the xcross-managed fields on an existing launch entry while
  /// keeping the user's own keys, their original order, their `env` and their
  /// `args` (device flags they typed there must survive a re-run).
  /// The legacy top-level `xcross` flag is migrated into `env`.
  /// With [flutterDebugger] false (DartNative projects) a stale
  /// `debuggerType: flutter` is removed so Dart-Code stops rejecting the
  /// entry in DN-only workspaces.
  static Map<String, Object?> _withCanonicalFields(
    Map<Object?, Object?> entry,
    Map<String, String> generatedEnvironment, {
    bool flutterDebugger = true,
  }) {
    final merged = <String, Object?>{
      for (final e in entry.entries) '${e.key}': e.value,
    };
    if (!flutterDebugger) {
      // A stale explicit `flutter` type would keep Dart-Code rejecting the
      // entry in DN-only workspaces; auto-detect (Dart) is what we merge.
      merged.remove('debuggerType');
    }
    final args = merged.containsKey('args') ? merged['args'] : <Object?>[];
    final env = _withMarker(merged['env'], generatedEnvironment);
    return merged
      ..remove('xcross')
      ..addAll(xcrossLaunchFields(flutterDebugger: flutterDebugger))
      ..['env'] = env
      ..['args'] = args;
  }

  static bool _isXcrossConfig(Object? config) =>
      config is Map &&
      (config['name'] == xcrossLaunchName ||
          config['xcross'] == true ||
          (config['env'] is Map &&
              (config['env']! as Map)[xcrossEnvKey] == xcrossEnvValue));

  /// Upsert the xcross launch configuration into a launch.json document.
  /// With [flutterDebugger] false (DartNative projects) the entry carries no
  /// `debuggerType` so Dart-Code uses its Dart debugger instead of rejecting
  /// an explicit `"flutter"` in a workspace without Flutter projects.
  static Map<String, Object?> mergeLaunchDoc(
    Map<String, Object?>? existing, {
    Map<String, String> generatedEnvironment = const {},
    bool flutterDebugger = true,
  }) {
    final doc = <String, Object?>{...?existing};
    doc.putIfAbsent('version', () => '0.2.0');

    final configs = <Object?>[...?doc['configurations'] as List<Object?>?];
    final index = configs.indexWhere(_isXcrossConfig);
    if (index < 0) {
      configs.add({
        ...xcrossLaunchFields(flutterDebugger: flutterDebugger),
        'env': _withMarker(null, generatedEnvironment),
        'args': <Object?>[],
      });
    } else {
      configs[index] = _withCanonicalFields(
        configs[index]! as Map,
        generatedEnvironment,
        flutterDebugger: flutterDebugger,
      );
    }

    doc['configurations'] = configs;
    return doc;
  }

  /// Upsert xcross DAP settings onto a settings.json document.
  /// [dartDapPath] adds the Dart-adapter shim for DartNative projects (their
  /// launches go through the Dart adapter slot); Flutter projects only need
  /// the Flutter-adapter shim.
  static Map<String, Object?> mergeSettingsDoc(
    Map<String, Object?>? existing, {
    String? dartDapPath,
  }) {
    final doc = <String, Object?>{...?existing};
    doc[dapPathSetting] = dapPathValue;
    doc[promptErrorsSetting] = false;
    if (dartDapPath != null) doc[dartDapPathSetting] = dartDapPath;
    return doc;
  }
}
