import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/dn/dn_project.dart';
import 'package:xcross/src/shared/cli/ide/subcommands/vscode_json_merge.dart';
import 'package:xcross/src/shared/cli/ide/xcross_executable.dart';
import 'package:xcross/src/shared/errors/errors.dart';

/// `xcross ide vscode` — write / upsert `.vscode/` so Run & Debug / Restart /
/// Hot Reload drive `xcross flutter run` (or `xcross dn run` in a DartNative
/// project — the DAP picks the subcommand from the project's pubspec).
///
/// DartNative projects additionally get a Dart-adapter shim: Dart-Code
/// classifies DN workspaces as Dart-only (their pubspecs never reference
/// `flutter`), so a `"debuggerType": "flutter"` entry is rejected outright
/// and DN launches must go through the Dart adapter slot instead.
@internal
final class VscodeCommand extends Command<void> {
  VscodeCommand(this.launcher);

  final XcrossIdeLauncher launcher;
  @override
  String get name => 'vscode';

  @override
  String get description =>
      'Set up .vscode/ so F5, Restart and Hot Reload run on an iOS device.';

  @override
  Future<void> run() async {
    final paths = launcher.host.paths.context;
    final projectRoot = paths.current;
    final dartNative = DnProject.isDartNativeProject(projectRoot);
    final dir = launcher.host.fileSystem.directory(
      paths.join(projectRoot, '.vscode'),
    );
    await dir.create(recursive: true);

    await _writeShim(dir, xcrossDapFile, _shim);
    if (dartNative) await _writeShim(dir, dartDapFile, _dartShim);
    await upsertJsonFile(
      paths.join(dir.path, 'launch.json'),
      (existing) => VscodeJsonMerge.mergeLaunchDoc(
        existing,
        generatedEnvironment: launcher.generatedEnvironment,
        flutterDebugger: !dartNative,
      ),
      log: launcher.log,
      files: launcher.host.fileSystem,
    );
    await upsertJsonFile(
      paths.join(dir.path, 'settings.json'),
      (existing) => VscodeJsonMerge.mergeSettingsDoc(
        existing,
        dartDapPath: dartNative ? dartDapPathValue : null,
      ),
      log: launcher.log,
      files: launcher.host.fileSystem,
    );

    launcher.log.logInfo(
      'Next',
      launcher.log.dim(
        'open the project in VS Code and press F5, '
        "then 'Hot Reload' / 'Restart' in the debug toolbar",
      ),
    );
  }

  /// A shim is always ours, so it is overwritten rather than merged.
  Future<void> _writeShim(Directory dir, String fileName, String template) async {
    final exe = launcher.resolve(subcommand: 'vscode', brokenFeature: 'F5');
    final shim = launcher.host.fileSystem.file(
      launcher.host.paths.context.join(dir.path, fileName),
    );
    // The shim embeds the path as a non-raw Dart string literal, so `$` needs
    // escaping on top of what jsonEncode does.
    await shim.writeAsString(
      template
          .replaceAll('<XCROSS>', jsonEncode(exe).replaceAll(r'$', r'\$'))
          .replaceAll(
            '<ENVIRONMENT>',
            jsonEncode(launcher.generatedEnvironment).replaceAll(r'$', r'\$'),
          )
          .replaceAll(
            '<INHERIT_PARENT>',
            '${launcher.inheritParentEnvironment}',
          ),
    );
    launcher.log.logDone(
      'Wrote ${launcher.host.paths.context.relative(shim.path)}',
    );
  }

  /// Read-merge-write a JSON/JSONC file. Skips the write when already current.
  static Future<void> upsertJsonFile(
    String path,
    Map<String, Object?> Function(Map<String, Object?>? existing) merge, {
    required Log log,
    required HostFileSystemInterface files,
  }) async {
    final file = files.file(path);
    final existing = file.existsSync()
        ? _decodeJsonObject(await file.readAsString(), path)
        : null;

    final merged = merge(existing);
    if (existing != null && VscodeJsonMerge.jsonDeepEqual(existing, merged)) {
      log.logDone('Unchanged $path');
      return;
    }

    await file.writeAsString(VscodeJsonMerge.encodePrettyJson(merged));
    log.logDone(existing == null ? 'Wrote $path' : 'Updated $path');
  }

  /// Decode a JSON/JSONC object, or null when the file is blank. Refuses to
  /// guess at malformed input — silently overwriting a user's config would
  /// lose their launch configurations.
  static Map<String, Object?>? _decodeJsonObject(String raw, String path) {
    if (raw.trim().isEmpty) return null;

    final Object? decoded;
    try {
      decoded = VscodeJsonMerge.parseJsonc(raw);
    } on FormatException catch (e) {
      throw XcrossError(
        '$path is not valid JSON/JSONC (${e.message}) — '
        'fix it, then re-run `xcross ide vscode`',
      );
    }
    if (decoded is! Map) {
      throw XcrossError(
        '$path must be a JSON object — '
        'fix it, then re-run `xcross ide vscode`',
      );
    }
    return {for (final e in decoded.entries) '${e.key}': e.value};
  }
}

/// Dart-Code spawns this as `dart <this file> debug_adapter`, so it must stay a
/// source file (the Dart VM cannot run xcross's AOT snapshot) and must write
/// NOTHING to stdout — that pipe carries DAP frames.
const String _shim = r'''
// GENERATED by `xcross ide vscode`. Do not edit — re-run the command instead.
import 'dart:io';

Future<void> main(List<String> args) async {
  try {
    final dap = await Process.start(
      <XCROSS>,
      [
        'flutter', 'dap',
        if (args.contains('--test')) '--test',
        if (args.contains('--test')) '--',
        if (args.contains('--test'))
          ...args.where((a) => a != 'debug_adapter' && a != '--test'),
      ],
      mode: ProcessStartMode.inheritStdio,
      environment: <ENVIRONMENT>,
      includeParentEnvironment: <INHERIT_PARENT>,
    );
    exit(await dap.exitCode);
  } on ProcessException catch (e) {
    stderr.writeln('xcross_dap: could not start xcross: ${e.message}\n'
        'Reinstall xcross, then re-run `xcross ide vscode`.');
    exit(2);
  }
}
''';

/// Dart-adapter twin of [_shim] for DartNative projects (see
/// `dart.customDartDapPath`). Dart-Code routes every Dart-debug session in a
/// DN workspace through it — ours (marked `XCROSS` in the DAP launch request,
/// handled inside `xcross flutter dap`) as well as plain `dart run` /
/// `dart test` / CodeLens sessions, which must behave exactly as without
/// xcross and therefore never reach the device.
const String _dartShim = r'''
// GENERATED by `xcross ide vscode`. Do not edit — re-run the command instead.
import 'dart:io';

Future<void> main(List<String> args) async {
  // `dart test` sessions never drive the device: hand them straight to the
  // Dart SDK's own test debug adapter running from this same Dart.
  if (args.contains('--test')) {
    try {
      final dart = await Process.start(
        Platform.resolvedExecutable,
        args,
        mode: ProcessStartMode.inheritStdio,
      );
      exit(await dart.exitCode);
    } on ProcessException catch (e) {
      stderr.writeln('xcross_dart_dap: could not start Dart: ${e.message}');
      exit(2);
    }
  }

  try {
    final dap = await Process.start(
      <XCROSS>,
      ['flutter', 'dap'],
      mode: ProcessStartMode.inheritStdio,
      environment: {
        ...<ENVIRONMENT>,
        'XCROSS_DART_SHIM': 'true',
      },
      includeParentEnvironment: <INHERIT_PARENT>,
    );
    exit(await dap.exitCode);
  } on ProcessException catch (e) {
    stderr.writeln('xcross_dart_dap: could not start xcross: ${e.message}\n'
        'Reinstall xcross, then re-run `xcross ide vscode`.');
    exit(2);
  }
}
''';
