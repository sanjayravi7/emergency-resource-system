// Remove conflicting ANDROID_PREFS_ROOT if ANDROID_USER_HOME is present to fix AGP AndroidLocationsException
try {
    val peClass = Class.forName("java.lang.ProcessEnvironment")
    val envField = peClass.getDeclaredField("theEnvironment").apply { isAccessible = true }
    (envField.get(null) as? MutableMap<String, String>)?.remove("ANDROID_PREFS_ROOT")
    val ciEnvField = peClass.getDeclaredField("theCaseInsensitiveEnvironment").apply { isAccessible = true }
    (ciEnvField.get(null) as? MutableMap<String, String>)?.remove("ANDROID_PREFS_ROOT")
} catch (_: Exception) {}

pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
    id("com.google.android.libraries.mapsplatform.secrets-gradle-plugin") version "2.0.1" apply false
}

include(":app")
