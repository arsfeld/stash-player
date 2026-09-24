import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/platform_dialect.dart';

/// Every glyph the app draws, named by meaning, each with its GNOME
/// (Adwaita dialect), Lucide (macOS dialect) source, and SF Symbol name
/// (for surfaces AppKit draws itself, like the native toolbar).
///
/// Assets live under `assets/icons/`; `tool/fetch_icons.py` fetches them.
/// Adding a value here means adding its names to that script too, and
/// `app_icons_test.dart` fails until the files exist.
enum AppIcon {
  back('go-previous', 'arrow-left', sf: 'chevron.left'),
  dropdown('pan-down', 'chevron-down', sf: 'chevron.down'),
  sortAscending('view-sort-ascending', 'arrow-up-narrow-wide', sf: 'arrow.up'),
  sortDescending(
    'view-sort-descending',
    'arrow-down-wide-narrow',
    sf: 'arrow.down',
  ),
  organizedAny('checkbox', 'circle-dashed', sf: 'circle.dashed'),
  organizedYes('circle-check', 'circle-check-big', sf: 'checkmark.circle'),
  organizedNo('cross', 'circle-x', sf: 'xmark.circle'),
  eye('eye-open', 'eye', sf: 'eye'),
  eyeOff('eye-crossed', 'eye-off', sf: 'eye.slash'),
  shuffle('media-playlist-shuffle', 'shuffle', sf: 'shuffle'),
  scan('folder-plus', 'folder-plus', sf: 'folder.badge.plus'),
  tasks('list', 'list-checks', sf: 'list.bullet.rectangle'),
  mainMenu('open-menu', 'menu', sf: 'line.3.horizontal'),
  filters('sliders', 'sliders-horizontal', sf: 'slider.horizontal.3'),
  clock('clock', 'clock', sf: 'clock'),
  warning('dialog-warning', 'triangle-alert', sf: 'exclamationmark.triangle'),
  done('circle-check', 'circle-check-big', sf: 'checkmark.circle'),
  quality('video-encode', 'monitor-play', sf: 'tv'),
  info('info-outline', 'info', sf: 'info.circle'),
  volumeMuted('speaker-cross', 'volume-x', sf: 'speaker.slash'),
  volumeHigh('speaker-max', 'volume-2', sf: 'speaker.wave.3'),
  skipPrevious('media-skip-backward', 'skip-back', sf: 'backward.end'),
  skipNext('media-skip-forward', 'skip-forward', sf: 'forward.end'),
  // Lucide has no "seek 10 seconds" glyph; its rotate arrows carry a
  // drawn "10" instead.
  seekBack10(
    'arrow-left-10',
    'rotate-ccw',
    sf: 'gobackward.10',
    lucideBadge: '10',
  ),
  seekForward10(
    'arrow-right-10',
    'rotate-cw',
    sf: 'goforward.10',
    lucideBadge: '10',
  ),
  play('media-playback-start', 'play', sf: 'play'),
  pause('media-playback-pause', 'pause', sf: 'pause'),
  playFilled(
    'media-playback-start-filled',
    'circle-play',
    sf: 'play.circle.fill',
  ),
  oCounter('raindrop', 'droplet', sf: 'drop'),
  reset('edit-clear', 'delete', sf: 'arrow.counterclockwise'),
  close('cross', 'x', sf: 'xmark'),
  video('video', 'film', sf: 'film'),
  emptyLibrary('clapper', 'clapperboard', sf: 'film.stack'),
  error('round-exclamation', 'circle-alert', sf: 'exclamationmark.circle'),
  star('star-filled', 'star', sf: 'star'),
  search('loupe', 'search', sf: 'magnifyingglass');

  const AppIcon(this.gnome, this.lucide, {required String sf, this.lucideBadge})
    : sfSymbol = sf;

  /// File name (without `.svg`) under `assets/icons/gnome/`.
  final String gnome;

  /// File name (without `.svg`) under `assets/icons/lucide/`.
  final String lucide;

  /// SF Symbol name, for surfaces AppKit draws itself (the native toolbar).
  /// Lucide stays the drawn macOS glyph.
  final String sfSymbol;

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
