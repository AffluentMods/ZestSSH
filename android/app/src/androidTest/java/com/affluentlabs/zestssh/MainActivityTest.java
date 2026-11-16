package com.affluentlabs.zestssh;

import android.app.Instrumentation;
import android.content.Intent;
import android.os.ParcelFileDescriptor;
import android.util.Log;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.rule.ActivityTestRule;
import dev.flutter.plugins.integration_test.FlutterTestRunner;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import org.junit.Rule;
import org.junit.runner.RunWith;

// The Android instrumentation entry for the app's Flutter integration tests
// (integration_test/*.dart), as the integration_test package documents: the
// test APK built by `./gradlew app:assembleAndroidTest` starts MainActivity,
// FlutterTestRunner waits for the Dart test file the app APK was built with
// (`./gradlew app:assembleDebug -Ptarget=integration_test/<file>.dart`) and
// reports each of its tests as a JUnit test. Used by Firebase Test Lab
// (tool/test_lab/README.md) and by `./gradlew app:connectedAndroidTest`.
// Debug builds only: a release build carries no test APK.
@RunWith(FlutterTestRunner.class)
public class MainActivityTest {
  private static final String TAG = "MainActivityTest";

  // FlutterTestRunner calls launchActivity on this rule, and the rule's own
  // way asks the system to start the activity from the app's process, which
  // is in the background then. Xiaomi's HyperOS refuses that (Test Lab,
  // Xiaomi 14, 12 November 2026, logcat: "MIUILOG- Permission Denied
  // Activity", "Abort background activity starts"): the app never opened,
  // the rule gave up after 45 seconds and the run waited for results until
  // Test Lab ended it. So the activity is started through the device's shell,
  // as adb or a tap on the icon starts it, which no maker's rules stop; the
  // rule's own way stays as the fallback where the shell cannot be used.
  @Rule
  public ActivityTestRule<MainActivity> rule =
      new ActivityTestRule<MainActivity>(MainActivity.class, true, false) {
        @Override
        public MainActivity launchActivity(Intent startIntent) {
          Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
          String component =
              instrumentation.getTargetContext().getPackageName() + "/" + MainActivity.class.getName();
          try {
            String said = shell(instrumentation, "am start -W -n " + component);
            Log.i(TAG, "am start: " + said.trim().replace('\n', ' '));
            if (!said.contains("Error")) {
              return null;
            }
          } catch (IOException | RuntimeException e) {
            Log.w(TAG, "am start through the shell failed, starting as the rule does: " + e);
          }
          return super.launchActivity(startIntent);
        }
      };

  // What a shell command prints, read to its end (the command has finished).
  private static String shell(Instrumentation instrumentation, String command) throws IOException {
    ParcelFileDescriptor out = instrumentation.getUiAutomation().executeShellCommand(command);
    try (InputStream in = new ParcelFileDescriptor.AutoCloseInputStream(out)) {
      ByteArrayOutputStream text = new ByteArrayOutputStream();
      byte[] buffer = new byte[1024];
      int n;
      while ((n = in.read(buffer)) != -1) {
        text.write(buffer, 0, n);
      }
      return text.toString("UTF-8");
    }
  }
}
