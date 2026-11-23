import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:dds/dap.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/dap/dap_router.dart';

/// Stubs the pre-launch DAP handshake, then replays the raw frames into the
/// chosen adapter (xcross or Flutter's own `debug-adapter`) and drops its
/// duplicate responses for already-acked seqs.
@internal
final class DapRouter {
  DapRouter(
    this._input,
    this._output,
    this._startXcross, {
    required this.runner,
    required this.errors,
    this.flutterRoot,
    this.environmentRoot,
    this.flutterTool,
    this.declarative = false,
    this.testAdapter = false,
    this.dartShimmed = false,
    List<String> flutterAdapterArguments = const [],
  }) : flutterAdapterArguments = List.unmodifiable(flutterAdapterArguments);

  final ProcessRunner runner;
  final IOSink errors;
  final String? flutterRoot;
  final String? environmentRoot;
  final String? flutterTool;
  final bool declarative;
  final bool testAdapter;

  /// Whether this session arrived through the `.vscode/xcross_dart_dap.dart`
  /// shim (DartNative workspace, Dart adapter slot). Injected from the
  /// composition root instead of reading the environment here.
  final bool dartShimmed;
  final List<String> flutterAdapterArguments;

  String? resolveFlutterExecutable({String? projectRoot}) {
    var flutterRoot =
        this.flutterRoot ??
        environmentRoot ??
        (declarative
            ? null
            : runner.environmentValue(
                runner.effectiveEnvironment,
                'FLUTTER_ROOT',
              ));
    if (flutterRoot == null) {
      final fvm = runner.host.paths.context.join(
        projectRoot ?? runner.host.paths.context.current,
        '.fvm',
        'flutter_sdk',
      );
      if (runner.host.fileSystem.directory(fvm).existsSync() ||
          runner.host.fileSystem.link(fvm).existsSync()) {
        flutterRoot = runner.host.fileSystem
            .link(fvm)
            .resolveSymbolicLinksSync();
      }
    }
    return flutterRoot == null
        ? flutterTool
        : runner.host.paths.context.join(
            flutterRoot,
            'bin',
            runner.host.paths.executableName('flutter', extension: '.bat'),
          );
  }

  final Stream<List<int>> _input;
  final StreamSink<List<int>> _output;
  final void Function(ByteStreamServerChannel channel) _startXcross;

  final _parser = DapFrameParser();
  final _replay = <Uint8List>[];
  final _answered = <int>{};
  var _outSeq = 1;
  var _forwarding = false;
  final _rest = StreamController<List<int>>();
  final _done = Completer<void>();

  static const _initializeCapabilities = <String, Object?>{
    'supportsConfigurationDoneRequest': true,
    'supportsRestartRequest': true,
    'supportsTerminateRequest': true,
    'supportsConditionalBreakpoints': true,
    'supportsDelayedStackTraceLoading': true,
    'supportsEvaluateForHovers': true,
    'supportsLogPoints': true,
    'exceptionBreakpointFilters': [
      {'filter': 'All', 'label': 'All Exceptions', 'default': false},
      {'filter': 'Unhandled', 'label': 'Uncaught Exceptions', 'default': true},
    ],
  };

  Future<void> run() {
    _input.listen(
      _onChunk,
      onError: _fail,
      onDone: () {
        _closeRest();
        if (!_forwarding) _finish();
      },
    );
    return _done.future;
  }

  void _finish() {
    if (!_done.isCompleted) _done.complete();
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (!_done.isCompleted) _done.completeError(error, stackTrace);
  }

  void _closeRest() {
    if (!_rest.isClosed) unawaited(_rest.close());
  }

  void _onChunk(List<int> chunk) {
    if (_forwarding) {
      _rest.add(chunk);
      return;
    }
    for (final frame in _parser.push(chunk)) {
      _replay.add(frame.raw);
      if (_handleRequest(frame.json)) return;
    }
  }

  bool _handleRequest(Map<String, Object?> msg) {
    if (msg['type'] != 'request') return false;
    final command = msg['command'] as String?;
    final seq = msg['seq'] as int?;
    if (command == null || seq == null) return false;

    switch (command) {
      case 'launch' || 'attach':
        _beginHandoff(msg);
        return true;
      case 'disconnect' || 'terminate':
        _answered.add(seq);
        _sendResponse(command, seq);
        _finish();
        return true;
      default:
        _answered.add(seq);
        _ack(command, seq, msg);
        return false;
    }
  }

  void _beginHandoff(Map<String, Object?> launchRequest) {
    _forwarding = true;
    final buffered = _parser.takeBuffered();
    if (buffered.isNotEmpty) _rest.add(buffered);
    unawaited(_handoff(launchRequest).then((_) => _finish()).catchError(_fail));
  }

  Future<void> _handoff(Map<String, Object?> launchRequest) async {
    final useXcross = !testAdapter && _wantsXcross(launchRequest['arguments']);

    final filtered = DapResponseFilter(_output, _answered);
    final inbound = StreamController<List<int>>();

    if (useXcross) {
      _startXcrossAdapter(inbound.stream, filtered);
    } else if (!await _startFallbackAdapter(
      inbound.stream,
      filtered,
      launchRequest['arguments'],
    )) {
      return;
    }

    for (final frame in _replay) {
      inbound.add(frame);
    }
    await _rest.stream.pipe(inbound);
  }

  /// A session is ours when its launch args carry `env: {XCROSS: true}`
  /// (the legacy top-level `xcross: true` flag still works).
  static bool _wantsXcross(Object? args) {
    if (args is! Map<Object?, Object?>) return false;
    if (args['xcross'] == true) return true;
    if (args['env'] case final Map<Object?, Object?> env) {
      return '${env['XCROSS']}'.toLowerCase() == 'true';
    }
    return false;
  }

  /// Sessions the `.vscode/xcross_dart_dap.dart` shim delivered arrived
  /// through the Dart adapter slot (DartNative workspace); their fallback is
  /// the Dart SDK's adapter. Everything else keeps the Flutter fallback.
  Future<bool> _startFallbackAdapter(
    Stream<List<int>> inbound,
    DapResponseFilter outbound,
    Object? launchArgs,
  ) => dartShimmed
      ? _startDartAdapter(inbound, outbound, launchArgs)
      : _startFlutterAdapter(inbound, outbound);

  /// Resolve the `dart` executable owning the session's own SDK
  /// (`dartSdkPath` in the DAP launch request — the SDK Dart-Code itself
  /// selected), or null when it is missing or has no `bin/dart`.
  static String? resolveDartExecutable(
    Object? launchArgs, {
    required PlatformHostInterface host,
  }) {
    if (launchArgs is Map<Object?, Object?>) {
      final sdkPath = launchArgs['dartSdkPath'];
      if (sdkPath is String && sdkPath.isNotEmpty) {
        final candidate = host.paths.context.join(
          sdkPath,
          'bin',
          host.paths.executableName('dart'),
        );
        if (host.fileSystem.file(candidate).existsSync()) return candidate;
      }
    }
    return null;
  }

  void _startXcrossAdapter(
    Stream<List<int>> inbound,
    DapResponseFilter outbound,
  ) {
    final channel = ByteStreamServerChannel(inbound, outbound, null);
    _startXcross(channel);
    unawaited(channel.closed.then((_) => _closeRest()));
  }

  Future<bool> _startFlutterAdapter(
    Stream<List<int>> inbound,
    DapResponseFilter outbound,
  ) async {
    final flutter = resolveFlutterExecutable();
    if (flutter == null) {
      errors.writeln(
        'xcross dap: launch config is missing "env": {"XCROSS": "true"} '
        'and no Flutter SDK is configured — cannot fall back to the Flutter '
        'DAP.\nConfigure roots.flutterSdk, environment FLUTTER_ROOT, or '
        'tools.flutter.',
      );
      await outbound.close();
      return false;
    }
    final child = await runner.start(flutter, [
      'debug-adapter',
      if (testAdapter) '--test',
      ...flutterAdapterArguments,
    ]);
    _pipeAdapterChild(child, inbound, outbound);
    return true;
  }

  /// Fallback for sessions the `.vscode/xcross_dart_dap.dart` shim delivered:
  /// this DAP arrived through the Dart adapter slot (DartNative workspace),
  /// so unmarked sessions go to the Dart SDK's own adapter instead of
  /// Flutter's. The SDK is the one Dart-Code itself selected
  /// (`dartSdkPath` in the launch request), keeping plain `dart run` /
  /// CodeLens sessions bit-for-bit identical to life without xcross.
  Future<bool> _startDartAdapter(
    Stream<List<int>> inbound,
    DapResponseFilter outbound,
    Object? launchArgs,
  ) async {
    final dart = resolveDartExecutable(launchArgs, host: runner.host);
    if (dart == null) {
      errors.writeln(
        'xcross dap: launch config is missing "env": {"XCROSS": "true"} '
        'and no Dart SDK path arrived with the launch request — cannot fall '
        'back to the Dart DAP.',
      );
      await outbound.close();
      return false;
    }
    final child = await runner.start(dart, const ['debug_adapter']);
    _pipeAdapterChild(child, inbound, outbound);
    return true;
  }

  void _pipeAdapterChild(
    Process child,
    Stream<List<int>> inbound,
    DapResponseFilter outbound,
  ) {
    child.stderr.listen(errors.add, onError: (_) {});
    inbound.listen(
      child.stdin.add,
      onError: (_) {},
      onDone: child.stdin.close,
      cancelOnError: false,
    );
    child.stdout.listen(outbound.add, onError: (_) {}, onDone: outbound.close);
    unawaited(child.exitCode.then((_) => _closeRest()));
  }

  void _ack(String command, int requestSeq, Map<String, Object?> request) {
    switch (command) {
      case 'initialize':
        _sendResponse(command, requestSeq, body: _initializeCapabilities);
        _sendEvent('initialized', const <String, Object?>{});
      case 'setBreakpoints':
        _sendResponse(
          command,
          requestSeq,
          body: {'breakpoints': _unverifiedBreakpoints(request)},
        );
      default:
        _sendResponse(command, requestSeq);
    }
  }

  static List<Map<String, Object?>> _unverifiedBreakpoints(
    Map<String, Object?> request,
  ) {
    final args = request['arguments'];
    final breakpoints = args is Map<Object?, Object?>
        ? args['breakpoints']
        : null;
    if (breakpoints is! List) return const [];
    return breakpoints
        .whereType<Map<Object?, Object?>>()
        .map((b) => {'verified': false, 'line': b['line']})
        .toList();
  }

  void _sendResponse(String command, int requestSeq, {Object? body}) {
    _output.add(
      DapFrame.encode({
        'seq': _outSeq++,
        'type': 'response',
        'request_seq': requestSeq,
        'success': true,
        'command': command,
        'body': ?body,
      }),
    );
  }

  void _sendEvent(String event, Object? body) {
    _output.add(
      DapFrame.encode({
        'seq': _outSeq++,
        'type': 'event',
        'event': event,
        'body': ?body,
      }),
    );
  }
}
