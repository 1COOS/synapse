import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../application/settings/settings_capabilities.dart';

Future<ApplicationMetadata> loadPackageApplicationMetadata() async {
  final info = await PackageInfo.fromPlatform();
  return ApplicationMetadata(
    version: info.version,
    buildNumber: info.buildNumber,
    platformMode: kIsWeb
        ? 'Web/H5 预览'
        : switch (defaultTargetPlatform) {
            TargetPlatform.macOS => 'macOS 桌面',
            TargetPlatform.windows => 'Windows 工程预览',
            TargetPlatform.linux => 'Linux 工程预览',
            TargetPlatform.iOS => 'iOS 工程预览',
            TargetPlatform.android => 'Android 工程预览',
            TargetPlatform.fuchsia => 'Fuchsia 工程预览',
          },
  );
}
