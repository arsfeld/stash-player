/// What a Stash library scan generates for the files it finds, and whether
/// it re-scans files it already knows. Mirrors Stash's `ScanMetadataInput`
/// minus `paths` and `filter`, which this client never sets.
class ScanOptions {
  const ScanOptions({
    this.generateCovers = false,
    this.generatePreviews = false,
    this.generateImagePreviews = false,
    this.generateSprites = false,
    this.generatePhashes = false,
    this.generateThumbnails = false,
    this.generateClipPreviews = false,
    this.rescan = false,
  });

  /// Reads the known flags out of a saved options object. A missing or
  /// non-bool flag is off, and any other key is ignored, so whatever else
  /// the web UI stored alongside never reaches the mutation.
  factory ScanOptions.fromJson(Map<String, Object?> json) {
    bool flag(String key) => json[key] == true;
    return ScanOptions(
      generateCovers: flag('scanGenerateCovers'),
      generatePreviews: flag('scanGeneratePreviews'),
      generateImagePreviews: flag('scanGenerateImagePreviews'),
      generateSprites: flag('scanGenerateSprites'),
      generatePhashes: flag('scanGeneratePhashes'),
      generateThumbnails: flag('scanGenerateThumbnails'),
      generateClipPreviews: flag('scanGenerateClipPreviews'),
      rescan: flag('rescan'),
    );
  }

  /// What the web UI scans with when nothing is saved: covers only
  /// (Stash v0.29.1, `LibraryTasks.tsx`'s `getDefaultScanOptions`).
  static const builtIn = ScanOptions(generateCovers: true);

  final bool generateCovers;
  final bool generatePreviews;
  final bool generateImagePreviews;
  final bool generateSprites;
  final bool generatePhashes;
  final bool generateThumbnails;
  final bool generateClipPreviews;
  final bool rescan;

  /// The `ScanMetadataInput` variables for `metadataScan`.
  Map<String, Object?> toInput() => {
    'scanGenerateCovers': generateCovers,
    'scanGeneratePreviews': generatePreviews,
    'scanGenerateImagePreviews': generateImagePreviews,
    'scanGenerateSprites': generateSprites,
    'scanGeneratePhashes': generatePhashes,
    'scanGenerateThumbnails': generateThumbnails,
    'scanGenerateClipPreviews': generateClipPreviews,
    'rescan': rescan,
  };

  @override
  bool operator ==(Object other) =>
      other is ScanOptions &&
      other.generateCovers == generateCovers &&
      other.generatePreviews == generatePreviews &&
      other.generateImagePreviews == generateImagePreviews &&
      other.generateSprites == generateSprites &&
      other.generatePhashes == generatePhashes &&
      other.generateThumbnails == generateThumbnails &&
      other.generateClipPreviews == generateClipPreviews &&
      other.rescan == rescan;

  @override
  int get hashCode => Object.hash(
    generateCovers,
    generatePreviews,
    generateImagePreviews,
    generateSprites,
    generatePhashes,
    generateThumbnails,
    generateClipPreviews,
    rescan,
  );

  @override
  String toString() => 'ScanOptions(${toInput()})';
}

/// The options the Stash web UI's Tasks page would scan with, picked the
/// way it picks them: the options it last saved in its UI config
/// ([uiTaskDefaultsScan], `configuration.ui.taskDefaults.scan`), else the
/// older server-side defaults ([serverDefaultsScan],
/// `configuration.defaults.scan`), else [ScanOptions.builtIn]. Either
/// argument is raw decoded JSON; anything but an object counts as unset.
ScanOptions resolveScanOptions({
  Object? uiTaskDefaultsScan,
  Object? serverDefaultsScan,
}) {
  for (final source in [uiTaskDefaultsScan, serverDefaultsScan]) {
    if (source is Map) {
      return ScanOptions.fromJson(source.cast<String, Object?>());
    }
  }
  return ScanOptions.builtIn;
}
