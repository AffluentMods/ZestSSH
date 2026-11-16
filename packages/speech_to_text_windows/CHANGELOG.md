# speech_to_text_windows releases

## 1.0.1+zest.1 (vendored in ZestSSH, not published)

speech_to_text_windows 1.0.1 from pub.dev, BSD-3-Clause (see LICENSE), changed by Affluent Labs LLC:

* A recognised phrase reaches Dart as a map of its words and whether it is final, and the Dart side
  writes the result's JSON with dart:convert. 1.0.1 pasted the words into a JSON string by hand
  without escaping them, so a phrase with a quote mark or a backslash in it was not valid JSON and
  speech_to_text dropped it.
* Every call into Dart (results and status) is posted to the platform thread through a message-only
  window. 1.0.1 called the channel from its recognition thread on Flutter versions without a task
  runner on the plugin registrar (3.50 has none), which the engine warns about.
* Nothing is printed to stdout any more. 1.0.1 printed every call, status and recognised phrase.
* The recognition thread is joined when listening stops, instead of left running detached with a
  pointer to the plugin, and the plugin's destructor no longer locks its mutex twice (it called
  Stop with the lock held, and Stop locks it again).

## 1.0.1

### New
* First implementation of Windows for speech_to_text

### Fixes
* Uses the proper threading for communication
* Fixes missing implementation
