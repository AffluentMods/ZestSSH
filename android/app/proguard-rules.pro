# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.view.** { *; }

# Firebase
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }

# dartssh2 / BouncyCastle (pointycastle uses JNI on some platforms)
-dontwarn org.bouncycastle.**
-keep class org.bouncycastle.** { *; }

# RevenueCat
-keep class com.revenuecat.purchases.** { *; }

# Google Sign-In
-keep class com.google.android.gms.auth.** { *; }

# Play Core (Flutter deferred components: not used but referenced)
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.SplitInstallException
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManager
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManagerFactory
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest$Builder
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest
-dontwarn com.google.android.play.core.splitinstall.SplitInstallSessionState
-dontwarn com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
-dontwarn com.google.android.play.core.tasks.OnFailureListener
-dontwarn com.google.android.play.core.tasks.OnSuccessListener
-dontwarn com.google.android.play.core.tasks.Task

# CameraX + mobile_scanner (QR / barcode scanner, mobile_scanner 7.x).
# WITHOUT these, R8 strips androidx.camera.camera2.Camera2Config$Companion, and
# GeneratedPluginRegistrant throws NoSuchFieldError while registering the scanner
# plugin at startup, which crashes the whole app before the first frame. It is
# release-only (debug builds do not run R8), so analyze/tests never catch it.
# Keep CameraX, the plugin, and the ML Kit barcode backend intact.
-keep class androidx.camera.** { *; }
-keep interface androidx.camera.** { *; }
-dontwarn androidx.camera.**
-keep class dev.steenbakker.mobile_scanner.** { *; }
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-dontwarn com.google.mlkit.**

# Credential Manager (passkeys, 3.3): it finds Google Play services' provider
# by reflection, which R8 would strip in a release build, leaving Android 9 to
# 13 with no provider (the rule Android's Credential Manager guide gives).
-if class androidx.credentials.CredentialManager
-keep class androidx.credentials.playservices.** {
  *;
}

# WorkManager (background task scheduling)
-keep class androidx.work.** { *; }
-keep class com.affluentlabs.zestssh.scheduler.** { *; }

# Keep annotations
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod
