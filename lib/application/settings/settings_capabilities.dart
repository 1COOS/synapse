enum ModelCapability { chat, vision, embedding }

final class ApplicationMetadata {
  const ApplicationMetadata({
    required this.version,
    required this.buildNumber,
    required this.platformMode,
  });

  final String version;
  final String buildNumber;
  final String platformMode;
}
