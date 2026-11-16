// Remote screens (4.0): the remote's displays as the app knows them,
// and the one a view shows. Plain data: the controller makes it from what
// the engine tells, and a picker, a bar or a strip is drawn from it.
/// One of the remote's displays (4.0): its number from 0 (it is shown
/// to people as "Display 1" and so on), its place and size in the remote
/// picture's pixels, and whether it is the remote's primary one.
class ScreenDisplay {
  const ScreenDisplay({
    required this.index,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.primary = false,
  });

  final int index;
  final int x;
  final int y;
  final int width;
  final int height;
  final bool primary;

  @override
  bool operator ==(Object other) =>
      other is ScreenDisplay &&
      other.index == index &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height &&
      other.primary == primary;

  @override
  int get hashCode => Object.hash(index, x, y, width, height, primary);

  @override
  String toString() => 'ScreenDisplay(${index + 1}: ${width}x$height at $x,$y${primary ? ' primary' : ''})';
}

/// The remote's displays and the one a view shows, for whatever draws a
/// display picker, a bar or a strip. It changes by itself, apart from the
/// menu's state: a display comes or goes while connected, and the one shown
/// changes by a key or by three fingers.
class ScreenDisplays {
  const ScreenDisplays({this.list = const [], this.shown});

  /// No display known (before a session is connected).
  static const none = ScreenDisplays();

  /// The most displays a session asks for (the engine's own ceiling).
  static const most = 4;

  final List<ScreenDisplay> list;

  /// The number of the display the view shows, or null: all of them, the
  /// whole remote desktop.
  final int? shown;

  /// More than one: only then is there anything to pick, and only then are
  /// the bars, the strip and the menu's Displays group drawn.
  bool get several => list.length > 1;

  /// The display shown, or null for all of them.
  ScreenDisplay? get shownDisplay => shown == null || shown! < 0 || shown! >= list.length ? null : list[shown!];

  @override
  bool operator ==(Object other) {
    if (other is! ScreenDisplays || other.shown != shown || other.list.length != list.length) return false;
    for (var i = 0; i < list.length; i++) {
      if (other.list[i] != list[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(shown, Object.hashAll(list));

  @override
  String toString() => 'ScreenDisplays(${list.length}, shown: ${shown == null ? 'all' : shown! + 1})';
}
