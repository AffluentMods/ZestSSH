class EscapeEmitter {
  const EscapeEmitter();

  String primaryDeviceAttributes() {
    return '\x1b[?1;2c';
  }

  String secondaryDeviceAttributes() {
    const model = 0;
    const version = 0;
    return '\x1b[>$model;$version;0c';
  }

  String tertiaryDeviceAttributes() {
    return '\x1bP!|00000000\x1b\\';
  }

  String operatingStatus() {
    return '\x1b[0n';
  }

  /// Where the cursor is: [row] and [column] counted from 1, as a program
  /// names them when it puts the cursor somewhere. [extended] is the answer
  /// to the DEC form of the question.
  String cursorPosition(int row, int column, {bool extended = false}) {
    return '\x1b[${extended ? '?' : ''}$row;${column}R';
  }

  String bracketedPaste(String text) {
    // SECURITY: strip any embedded paste-END marker before wrapping.
    //
    // Bracketed paste tells the remote shell "everything between these two
    // markers is pasted data, do not execute it". If the payload itself
    // contains `ESC [ 201 ~`, it closes the bracket early and everything
    // after it arrives as if the user had TYPED it, so content copied from
    // a web page or produced by a hostile server can run commands on the
    // host with a single paste. Removing the marker is what every hardened
    // terminal does; there is no legitimate reason for it to appear inside
    // pasted text. Removed until none is left: removed once, its own pieces
    // made another (ESC[20, the marker, 1~). (A paste reaches here with no
    // ESC at all: Terminal.pasteable.)
    var sanitized = text;
    while (sanitized.contains('\x1b[201~')) {
      sanitized = sanitized.replaceAll('\x1b[201~', '');
    }
    return '\x1b[200~$sanitized\x1b[201~';
  }

  String size(int rows, int cols) {
    return '\x1b[8;$rows;${cols}t';
  }
}
