# speech_to_text_windows

The Windows implementation of the speech_to_text plugin.

This is speech_to_text_windows 1.0.1 from pub.dev (BSD-3-Clause, see LICENSE), vendored in ZestSSH
with fixes: phrases with a quote mark are no longer dropped, calls into Dart are made on the platform
thread, and nothing is printed to stdout. CHANGELOG.md lists the changes. The app's pubspec.yaml
points speech_to_text at this copy through dependency_overrides.

## Usage

See [speech_to_text](https://github.com/csdcorp/speech_to_text/blob/main/speech_to_text/README.md)
