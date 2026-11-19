import java.util.Base64
import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // No Kotlin Gradle plugin named here (Flutter 3.50 warned on every build that the app applied
    // it). While android.builtInKotlin is false (gradle.properties: plugins still apply it
    // themselves), Flutter's Gradle plugin applies it to the app, so the app's Kotlin compiles as
    // before, with the JVM target of the kotlin block below; once built-in Kotlin is on, AGP
    // compiles it and nothing here changes.
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

// Firebase / Google Services, where the build has a google-services.json: the release's (never in
// the repository), or a builder's own. A public clone has none, and builds and runs without
// Firebase: no sign-in on the device, which a community build has no service for anyway (found in a
// review before 4.0: the plugin was applied always, and a clone did not build at all). The release
// must never be built without it: a build made as ZestSSH, the release (--dart-define=ZEST_OFFICIAL=true),
// stops here where the file is missing.
val dartDefines: List<String> = ((project.findProperty("dart-defines") as String?) ?: "")
    .split(",")
    .filter { it.isNotEmpty() }
    .map { String(Base64.getDecoder().decode(it)) }
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
} else if (dartDefines.any { it.trim() == "ZEST_OFFICIAL=true" }) {
    throw GradleException(
        "ZEST_OFFICIAL=true needs android/app/google-services.json: the release signs people in with Firebase."
    )
}

// Load key.properties for release signing
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.affluentlabs.zestssh"
    compileSdk = flutter.compileSdkVersion

    // A release build runs no lint of its own: lint of AGP 9.3.1 crashes on a plugin's Java
    // (google_sign_in_android: NoSuchMethodError in its Javadoc parser, which lint itself calls
    // a bug in lint), and that stopped the build. Lint stays a step of its own (gradlew lint).
    lint {
        checkReleaseBuilds = false
    }
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.affluentlabs.zestssh"
        // Android 8.0 (Oreo): required for modern Keystore + secure storage
        // hardware-backed keys, hardware AES, and FLAG_SECURE on all OEMs.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // The Flutter integration tests on a device or Firebase Test Lab
        // (src/androidTest, tool/test_lab/README.md): androidx's runner, as
        // the integration_test package documents.
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    // 16 KB page size alignment (required for Android 15+)
    packaging {
        jniLibs {
            useLegacyPackaging = false
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        release {
            // Signed with the upload key (key.properties). Without it a
            // release build fails at signing, as it should: it was signed
            // with the debug key, quietly (found 16 October 2026 in a
            // security review). A local release build without the
            // key asks for the debug key by name: -PdebugSignedRelease.
            signingConfig = if (!keystorePropertiesFile.exists() && project.hasProperty("debugSignedRelease")) {
                signingConfigs.getByName("debug")
            } else {
                signingConfigs.getByName("release")
            }
            // Shrink & optimize for release
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // WorkManager: background task scheduling for SSH automation
    implementation("androidx.work:work-runtime-ktx:2.9.0")
    // Coroutines (required by CoroutineWorker)
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")

    // Passkeys (3.3, passkeys/PasskeyChannel.kt): Credential Manager, and
    // Google Play services' provider of it for Android 9 to 13 (from Android
    // 14 the system has its own).
    implementation("androidx.credentials:credentials:1.6.0")
    implementation("androidx.credentials:credentials-play-services-auth:1.6.0")

    // ── QR scanner native deps (mobile_scanner 7.4.0) ── two constraints:
    //  1. 16 KB page-size alignment: Google Play rejects AABs whose native
    //     libs aren't 16 KB-aligned. MLKit aligned libbarhopper_v3.so in 17.3.0
    //     and CameraX aligned libimage_processing_util_jni.so in 1.4.x+.
    //  2. VERSION MATCH: mobile_scanner 7.4.0 is compiled against CameraX 1.6.1,
    //     whose androidx.camera.camera2.Camera2Config is a Kotlin class with a
    //     Companion. Forcing an older CameraX (this used to pin 1.4.2, from when
    //     the plugin was 5.2.3) makes the scanner's plugin registration throw
    //     NoSuchFieldError(Camera2Config$Companion) at startup and CRASH THE APP
    //     AT LAUNCH. So keep CameraX at exactly what mobile_scanner needs (1.6.1)
    //     which is also 16 KB-aligned, satisfying both. MLKit 17.3.0 already
    //     matches the plugin. Bump these in lockstep whenever mobile_scanner is
    //     upgraded. resolutionStrategy.force below pins them against transitives.
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
    implementation("androidx.camera:camera-core:1.6.1")
    implementation("androidx.camera:camera-camera2:1.6.1")
    implementation("androidx.camera:camera-lifecycle:1.6.1")
    implementation("androidx.camera:camera-view:1.6.1")

    // The Flutter integration tests' instrumentation (src/androidTest,
    // MainActivityTest): what the integration_test package's README asks the
    // app to declare, at its versions: the plugin puts the same libraries in
    // the debug app (1.2+ and 3.2+, resolved to 1.2.0 and 3.2.0), and the
    // test APK must match the app's (Gradle's consistent resolution refuses
    // newer ones here).
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.2.0")
    androidTestImplementation("androidx.test:rules:1.2.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.2.0")
}

configurations.all {
    resolutionStrategy {
        force(
            "com.google.mlkit:barcode-scanning:17.3.0",
            "androidx.camera:camera-core:1.6.1",
            "androidx.camera:camera-camera2:1.6.1",
            "androidx.camera:camera-lifecycle:1.6.1",
            "androidx.camera:camera-view:1.6.1",
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
