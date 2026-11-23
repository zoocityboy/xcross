import 'package:meta/meta.dart';

/// The two `Info.plist` transforms the DartNative bundle needs that the
/// Flutter bundle assembler no longer exposes as statics (it moved to
/// host-aware collaborators in v2.1).
@internal
abstract final class DnInfoPlist {
  /// Insert a raw plist [fragment] before the closing `</dict>` of the root
  /// dict. Used for multi-key fragments (`CFBundleIcons`) that
  /// `PlistMutations.setPlistString` cannot express.
  static String insertFragment(String plistXml, String fragment) =>
      _insertBeforeEnd(plistXml, fragment);

  /// Point the programmatic launch screen at [imageName]
  /// (`UILaunchScreen.UIImageName`, iOS 14+).
  ///
  /// Replaces the empty `<dict/>` that the storyboard policy emits when no
  /// compiled `LaunchScreen.storyboardc` exists; inserts a populated dict
  /// when `UILaunchScreen` is absent; leaves a non-empty dict alone.
  static String setUILaunchScreen(String plistXml, String imageName) {
    final empty = RegExp(r'<key>UILaunchScreen</key>\s*<dict\s*/>');
    const populated =
        '<key>UILaunchScreen</key>'
        '<dict><key>UIImageName</key><string>{IMAGE}</string></dict>';
    if (empty.hasMatch(plistXml)) {
      return plistXml.replaceFirst(
        empty,
        populated.replaceAll('{IMAGE}', imageName),
      );
    }
    if (plistXml.contains('<key>UILaunchScreen</key>')) return plistXml;
    return _insertBeforeEnd(
      plistXml,
      populated.replaceAll('{IMAGE}', imageName),
    );
  }

  static String _insertBeforeEnd(String xml, String fragment) {
    const sentinel = '</dict>\n</plist>';
    final idx = xml.lastIndexOf(sentinel);
    if (idx >= 0) {
      return xml.substring(0, idx) + fragment + xml.substring(idx);
    }
    const dictEnd = '</dict>';
    final dictIdx = xml.lastIndexOf(dictEnd);
    if (dictIdx >= 0) {
      return xml.substring(0, dictIdx) + fragment + xml.substring(dictIdx);
    }
    return xml + fragment;
  }
}
