import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/icons/app_icons.dart';

/// Finds an [AppIconView] showing [icon]; the replacement for
/// `find.byIcon` now that the app draws no Material icons.
Finder findAppIcon(AppIcon icon) => find.byWidgetPredicate(
  (widget) => widget is AppIconView && widget.icon == icon,
);

/// The replacement for `find.widgetWithIcon`.
Finder findWidgetWithAppIcon(Type type, AppIcon icon) =>
    find.ancestor(of: findAppIcon(icon), matching: find.byType(type));
