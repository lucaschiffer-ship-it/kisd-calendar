/// The app's visual style, picked in Settings › Appearance › Style.
///
/// Independent of light/dark (`ThemeService.currentColor`): every style has
/// both. [classic] is the original look; the two minimal styles share colours,
/// shapes and accent rules and differ only in type. Stored by [name].
enum AppStyle {
  classic,

  /// Monochrome, hairlines, Inter everywhere. Work in progress.
  minimal,

  /// [minimal] with IBM Plex Mono everywhere. Work in progress.
  mono,
}

/// The base colours of the minimal styles (ignored by [AppStyle.classic]).
/// Stored by [name].
enum AppPalette { grey, paper, pure }
