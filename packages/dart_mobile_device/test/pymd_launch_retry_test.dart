import 'dart:io';

import 'package:dart_mobile_device/src/errors.dart';
import 'package:dart_mobile_device/src/pymd/pymd.dart';
import 'package:test/test.dart';

void main() {
  group('Pymd.isTransientLaunchError', () {
    test('transient DVT race is retryable', () {
      expect(
        Pymd.isTransientLaunchError(
          TunnelError('pymobiledevice3 failed: Failed to launch process: -402653103'),
        ),
        isTrue,
      );
    });

    test('missing pid line is retryable', () {
      expect(
        Pymd.isTransientLaunchError(
          TunnelError('expected "Process launched with pid <N>" in stdout, got: '),
        ),
        isTrue,
      );
    });

    test('tunnel hiccups are retryable', () {
      expect(
        Pymd.isTransientLaunchError(TunnelError('Connection reset by peer')),
        isTrue,
      );
      expect(
        Pymd.isTransientLaunchError(TunnelError('timed out after 45s')),
        isTrue,
      );
    });

    test('background launch rejection is permanent', () {
      expect(
        Pymd.isTransientLaunchError(
          TunnelError('Background launch requested but app is not in foreground'),
        ),
        isFalse,
      );
    });

    test('missing DDI and unknown device are permanent', () {
      expect(
        Pymd.isTransientLaunchError(
          TunnelError('Developer Disk Image not mounted, run xcross tunnel'),
        ),
        isFalse,
      );
      expect(
        Pymd.isTransientLaunchError(TunnelError('Could not find device foo')),
        isFalse,
      );
      expect(
        Pymd.isTransientLaunchError(TunnelError('App is not installed: bar')),
        isFalse,
      );
    });
  });
}
