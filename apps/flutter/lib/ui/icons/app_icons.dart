import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/platform_dialect.dart';

/// Every glyph the app draws, named by meaning, each with its GNOME
/// (Adwaita dialect) and Lucide (macOS dialect) source.
///
/// Assets live under `assets/icons/`; `tool/fetch_icons.py` fetches them.
/// Adding a value here means adding its names to that script too, and
/// `app_icons_test.dart` fails until the files exist.
enum AppIcon {
  back('go-previous', 'arrow-left'),
  dropdown('pan-down', 'chevron-down'),
  sortAscending('view-sort-ascending', 'arrow-up-narrow-wide'),
  sortDescending('view-sort-descending', 'arrow-down-wide-narrow'),
  organizedAny('checkbox', 'circle-dashed'),
  organizedYes('circle-check', 'circle-check-big'),
  organizedNo('cross', 'circle-x'),
  eye('eye-open', 'eye'),
  eyeOff('eye-crossed', 'eye-off'),
  shuffle('media-playlist-shuffle', 'shuffle'),
  scan('folder-plus', 'folder-plus'),
  tasks('list', 'list-checks'),
  mainMenu('open-menu', 'menu'),
  filters('sliders', 'sliders-horizontal'),
  clock('clock', 'clock'),
  warning('dialog-warning', 'triangle-alert'),
  done('circle-check', 'circle-check-big'),
  quality('video-encode', 'monitor-play'),
  info('info-outline', 'info'),
  volumeMuted('speaker-cross', 'volume-x'),
  volumeHigh('speaker-max', 'volume-2'),
  skipPrevious('media-skip-backward', 'skip-back'),
  skipNext('media-skip-forward', 'skip-forward'),
  // Lucide has no "seek 10 seconds" glyph; its rotate arrows carry a
  // drawn "10" instead.
  seekBack10('arrow-left-10', 'rotate-ccw', lucideBadge: '10'),
  seekForward10('arrow-right-10', 'rotate-cw', lucideBadge: '10'),
  play('media-playback-start', 'play'),
  pause('media-playback-pause', 'pause'),
  playFilled('media-playback-start-filled', 'circle-play'),
  oCounter('raindrop', 'droplet'),
  reset('edit-clear', 'delete'),
  close('cross', 'x'),
  video('video', 'film'),
  emptyLibrary('clapper', 'clapperboard'),
  error('round-exclamation', 'circle-alert'),
  star('star-filled', 'star'),
  search('loupe', 'search');

  const AppIcon(this.gnome, this.lucide, {this.lucideBadge});

  /// File name (without `.svg`) under `assets/icons/gnome/`.
  final String gnome;

  /// File name (without `.svg`) under `assets/icons/lucide/`.
  final String lucide;

  /// Text drawn inside the Lucide glyph, for meanings Lucide lacks.
  final String? lucideBadge;

  String assetFor(PlatformDialect dialect) => switch (dialect) {
    PlatformDialect.adwaita => 'assets/icons/gnome/$gnome.svg',
    PlatformDialect.macos => 'assets/icons/lucide/$lucide.svg',
  };
}

/// Draws an [AppIcon] in the ambient dialect. Sized and coloured like
/// [Icon]: explicit values win, otherwise the ambient [IconTheme] (so an
/// [IconButton]'s resolved foreground applies), otherwise 16px.
class AppIconView extends StatelessWidget {
  const AppIconView(
    this.icon, {
    this.size,
    this.color,
    this.semanticLabel,
    super.key,
  });

  final AppIcon icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  /// The colour an [AppIconView] with [explicit] would paint in [context].
  static Color colorOf(BuildContext context, Color? explicit) =>
      explicit ?? IconTheme.of(context).color ?? const Color(0xFF000000);

  @override
  Widget build(BuildContext context) {
    final dialect = PlatformDialect.of(context);
    final extent = size ?? IconTheme.of(context).size ?? 16;
    final paint = colorOf(context, color);
    Widget glyph = SvgPicture.asset(
      icon.assetFor(dialect),
      width: extent,
      height: extent,
      colorFilter: ColorFilter.mode(paint, BlendMode.srcIn),
      excludeFromSemantics: true,
    );
    final badge = icon.lucideBadge;
    if (dialect == PlatformDialect.macos && badge != null) {
      glyph = Stack(
        alignment: Alignment.center,
        children: [
          glyph,
          Text(
            badge,
            style: TextStyle(
              color: paint,
              fontSize: extent * 0.34,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
        ],
      );
    }
    glyph = SizedBox.square(dimension: extent, child: glyph);
    return semanticLabel == null
        ? glyph
        : Semantics(label: semanticLabel, child: glyph);
  }
}
