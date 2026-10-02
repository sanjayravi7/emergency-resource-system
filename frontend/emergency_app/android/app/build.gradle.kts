plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.android.libraries.mapsplatform.secrets-gradle-plugin")
}

// Firebase (Google sign-in + FCM) needs google-services.json, which is NOT
// committed: it carries project identifiers and is installed per deployment.
// Applying the plugin only when the file is present keeps plain builds (and CI)
// working while making the release APK pick the real configuration up.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

secrets {
    defaultPropertiesFileName = "local.defaults.properties"
    propertiesFileName = "secrets.properties"
}

// A release build is signed only with the production keystore supplied through
// the local build environment. Debug signing is never silently accepted for a
// release APK because Google Sign-In fingerprints depend on this certificate.
val releaseKeystorePath = System.getenv("ERAS_ANDROID_KEYSTORE_PATH")
val releaseKeystoreAlias = System.getenv("ERAS_ANDROID_KEY_ALIAS")
val releaseKeystorePassword = System.getenv("ERAS_ANDROID_STORE_PASSWORD")
val releaseKeyPassword = System.getenv("ERAS_ANDROID_KEY_PASSWORD")
val releaseSigningConfigured =
    !releaseKeystorePath.isNullOrBlank() &&
        !releaseKeystoreAlias.isNullOrBlank() &&
        !releaseKeystorePassword.isNullOrBlank() &&
        !releaseKeyPassword.isNullOrBlank() &&
        file(releaseKeystorePath).isFile
val releaseTaskRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
if (releaseTaskRequested && !releaseSigningConfigured) {
    throw GradleException(
        "A production-signed release requires ERAS_ANDROID_KEYSTORE_PATH, " +
            "ERAS_ANDROID_KEY_ALIAS, ERAS_ANDROID_STORE_PASSWORD and ERAS_ANDROID_KEY_PASSWORD."
    )
}

android {
    namespace = "io.github.sanjayravi7.eras"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "30.0.16248370"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.sanjayravi7.eras"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigningConfigured) {
            create("release") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeystoreAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (releaseSigningConfigured) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
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
