import 'package:flutter/material.dart';

/// Aspect ratio used for every scene thumbnail in the UI — this
/// placeholder and the library grid's cards both render at 16:9, and
/// share this constant rather than each hardcoding `16 / 9` separately.
const double sceneThumbnailAspectRatio = 16 / 9;

/// Fixed-aspect-ratio placeholder shown wherever a scene thumbnail
/// couldn't be shown: no `screenshot` path, a failed fetch, or a failed
/// decode. `ThumbnailRepository.load` resolves to `null` in exactly those
/// cases rather than throwing, and this widget is the uniform fallback
/// for all of them so none ever surfaces as an exception in the grid.
class ScenePlaceholder extends StatelessWidget {
  const ScenePlaceholder({super.key});

  /// The semantic label announced for this placeholder, also usable by
  /// tests/finders that need to locate it without relying on widget type.
  static const String semanticLabel = 'Thumbnail unavailable';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: sceneThumbnailAspectRatio,
      child: Semantics(
        label: semanticLabel,
        image: true,
        child: Material(
          color: colorScheme.surfaceContainerHighest,
          child: Center(
            child: Icon(
              Icons.movie_outlined,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
