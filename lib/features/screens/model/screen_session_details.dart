// Remote screens (4.0): numbers about a running session, for the
// Session details card and sheet. Plain data: the controller samples it once
// a second while the details are shown, and whatever draws it reads nothing
// else.

/// One second of a session: the bytes that came and went and the frames
/// drawn in it. [at] counts from when the details were opened.
class ScreenSessionSample {
  const ScreenSessionSample({required this.at, required this.bytesIn, required this.bytesOut, required this.frames});

  final Duration at;
  final int bytesIn;
  final int bytesOut;
  final int frames;

  @override
  bool operator ==(Object other) =>
      other is ScreenSessionSample &&
      other.at == at &&
      other.bytesIn == bytesIn &&
      other.bytesOut == bytesOut &&
      other.frames == frames;

  @override
  int get hashCode => Object.hash(at, bytesIn, bytesOut, frames);

  @override
  String toString() => 'ScreenSessionSample(${at.inSeconds}s: $bytesIn in, $bytesOut out, $frames frames)';
}

class ScreenSessionDetails {
  const ScreenSessionDetails({
    this.last = const [],
    this.drawnWith = '',
    this.roundTripMs,
    this.width = 0,
    this.height = 0,
    this.protocol = '',
  });

  /// Before the first second.
  static const none = ScreenSessionDetails();

  /// The most samples kept: the last minute.
  static const keep = 60;

  /// The last seconds, oldest first, [keep] at most.
  final List<ScreenSessionSample> last;

  /// What the picture is drawn with, as a name (not translated): "H.264
  /// (AVC444)", "RemoteFX Progressive", "Planar" and so on. Empty where it is
  /// not known (before the first report, and for VNC, whose engine does not
  /// say which encoding its server uses).
  final String drawnWith;

  /// The time a round trip to the remote computer takes, in milliseconds;
  /// null where it is not measured (a screen reached without an SSH
  /// connection to the computer it is on), before the first answer, and
  /// where the last question had no answer in time.
  final int? roundTripMs;

  /// The whole remote desktop's size, every display.
  final int width;
  final int height;

  /// "RDP" or "VNC"; empty before the session is connected.
  final String protocol;

  /// What an RDP session's picture is drawn with, from the engine's graphics
  /// report (its INFO event's `graphics`): the graphics pipeline's codec that
  /// decoded the most pixels, else the kind of fast-path update that carried
  /// the most bytes. Empty where the report names nothing of either.
  static String drawnWithFrom(Object? report) {
    if (report is! Map) return '';
    String most(Object? counts, String field, String? Function(String key) name) {
      if (counts is! Map) return '';
      var best = '';
      var bestOf = 0;
      for (final e in counts.entries) {
        final value = e.value;
        final key = e.key;
        if (key is! String || value is! Map) continue;
        final n = value[field];
        final named = name(key);
        if (n is int && n > bestOf && named != null) {
          best = named;
          bestOf = n;
        }
      }
      return best;
    }

    final codec = most(report['gfx_codecs'], 'pixels', (k) => switch (k) {
          'avc444' => 'H.264 (AVC444)',
          'avc420' => 'H.264 (AVC420)',
          'progressive' => 'RemoteFX Progressive',
          'cavideo' => 'RemoteFX',
          'planar' => 'Planar',
          'clearcodec' => 'ClearCodec',
          'uncompressed' => 'Uncompressed',
          // (Alpha planes go with another codec's picture: not what draws it.)
          _ => null,
        });
    if (codec.isNotEmpty) return codec;
    return most(report['fastpath'], 'bytes', (k) {
      if (k == 'surface/remotefx') return 'RemoteFX';
      if (k.startsWith('bitmap/')) return 'Bitmap';
      return null;
    });
  }

  @override
  String toString() =>
      'ScreenSessionDetails($protocol ${width}x$height, ${drawnWith.isEmpty ? 'unknown' : drawnWith}, ${last.length} samples)';
}
