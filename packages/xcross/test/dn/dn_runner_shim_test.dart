import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/dn/dn_runner_shim.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';

void main() {
  const deploymentTarget = IosDeploymentTarget('15.0');

  group('DnRunnerShim.runnerObjcSource', () {
    test('boots the runtime delegate by its ObjC runtime name', () {
      final source = DnRunnerShim.runnerObjcSource(verbose: false);
      // Swift exposes the class to ObjC under its mangled name; the
      // friendly name only exists at compile time (see SWIFT_CLASS in
      // dartnative_ios-Swift.h).
      expect(source, contains('@"${DnRunnerShim.appDelegateClassName}"'));
      expect(source, contains('UIApplicationMain'));
      expect(source, isNot(contains('FlutterViewController')));
    });

    test('rescues only the missing LaunchScreen storyboard', () {
      final source = DnRunnerShim.runnerObjcSource(verbose: false);
      expect(source, contains('xcross_storyboardWithName'));
      expect(source, contains('method_exchangeImplementations'));
      expect(source, contains('isEqualToString:@"LaunchScreen"'));
    });
  });

  group('DnRunnerShim.linkArguments', () {
    test('links the dartnative_ios object and keeps delegate classes', () {
      final args = DnRunnerShim.linkArguments(
        objectPath: '/tmp/Runner.o',
        outputPath: '/tmp/Runner',
        iosSdk: '/sdk',
        flutterSlice: '/xc',
        subframeworks: '/sub',
        sdkVersion: '26.5',
        deploymentTarget: deploymentTarget,
        dnObject: '/dn/dartnative_ios',
      );
      // Static native runtime linked by path (it is a Mach-O object,
      // not a dynamic framework).
      expect(args, contains('/dn/dartnative_ios'));
      expect(args, contains('-framework'));
      expect(args, contains('Flutter'));
      expect(args, isNot(contains('dartnative_ios.framework')));
      // No -u pins: the runtime symbols are defined in the linked
      // object, and the delegate classes resolve by name at runtime.
      expect(args, isNot(contains('-u')));
      // Swift runtime for the statically-linked Swift object.
      expect(args, contains('-lswiftCore'));
      expect(args, contains('-lswiftUIKit'));
      expect(
        args.sublist(0, args.indexOf('-lswiftCore')),
        contains(p.join('/sdk', 'usr', 'lib', 'swift')),
      );
    });
  });

  group('DnRunnerShim native objects', () {
    test('links third-party native dependency objects', () {
      final args = DnRunnerShim.linkArguments(
        objectPath: '/tmp/Runner.o',
        outputPath: '/tmp/Runner',
        iosSdk: '/sdk',
        flutterSlice: '/xc',
        subframeworks: '/sub',
        sdkVersion: '26.5',
        deploymentTarget: deploymentTarget,
        dnObject: '/dn/dartnative_ios',
        nativeObjects: const ['/deps/a.o', '/deps/b.o'],
      );
      expect(
        args,
        containsAllInOrder(['/dn/dartnative_ios', '/deps/a.o', '/deps/b.o']),
      );
    });
    test('links compiler-rt when provided', () {
      final args = DnRunnerShim.linkArguments(
        objectPath: '/tmp/Runner.o',
        outputPath: '/tmp/Runner',
        iosSdk: '/sdk',
        flutterSlice: '/xc',
        subframeworks: '/sub',
        sdkVersion: '26.5',
        deploymentTarget: deploymentTarget,
        dnObject: '/dn/dartnative_ios',
        compilerRt: '/sdk/libclang_rt.ios.a',
        swiftIphoneosLibDir: '/toolchain/swift/iphoneos',
      );
      expect(args, contains('/sdk/libclang_rt.ios.a'));
      expect(
        args,
        containsAllInOrder([
          '/toolchain/swift/iphoneos',
          '-lswiftCompatibility50',
        ]),
      );
      expect(args, contains('-lc++'));
    });
    test('compilerRtIos finds the archive in a Darwin SDK bundle', () {
      final dir = Directory.systemTemp.createTempSync('dn-rt');
      try {
        final rt = File(
          p.join(
            dir.path,
            'Developer',
            'Toolchains',
            'XcodeDefault.xctoolchain',
            'usr',
            'lib',
            'clang',
            '17',
            'lib',
            'darwin',
            'libclang_rt.ios.a',
          ),
        )..createSync(recursive: true);
        expect(DnRunnerShim.compilerRtIos(dir.path), rt.path);
        expect(
          DnRunnerShim.compilerRtIos(p.join(dir.path, 'missing')),
          isNull,
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('DnRunnerShim.compileArguments', () {
    test('targets the deployment triple', () {
      final args = DnRunnerShim.compileArguments(
        sourcePath: '/tmp/Runner.m',
        objectPath: '/tmp/Runner.o',
        iosSdk: '/sdk',
        subframeworks: '/sub',
        flutterSlice: '/xc',
        deploymentTarget: deploymentTarget,
      );
      expect(args, contains('arm64-apple-ios15.0'));
      expect(args, contains('-fobjc-arc'));
    });
  });
}
