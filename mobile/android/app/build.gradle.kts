import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Flutter hands --dart-define values to Gradle as comma-separated base64 "KEY=value".
val dartDefines: Map<String, String> =
    (project.findProperty("dart-defines") as String? ?: "")
        .split(",")
        .filter { it.isNotEmpty() }
        .associate {
            val pair = String(Base64.getDecoder().decode(it), Charsets.UTF_8).split("=", limit = 2)
            pair[0] to pair.getOrElse(1) { "" }
        }
val apiBaseUrl: String = dartDefines["API_BASE_URL"] ?: ""
// No define => the dev default (http://...) is used, which needs cleartext.
val allowCleartext: Boolean = apiBaseUrl.isEmpty() || apiBaseUrl.startsWith("http://")

android {
    namespace = "ph.edu.cok.ite_attendance"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "ph.edu.cok.ite_attendance"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // mobile_scanner 7.x (CameraX) requires minSdk 23.
        minSdk = maxOf(23, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        debug {
            // Dev servers are plain HTTP on the LAN.
            manifestPlaceholders["usesCleartextTraffic"] = "true"
        }
        // Flutter's plugin already defines "profile"; give it the dev default too.
        getByName("profile") {
            manifestPlaceholders["usesCleartextTraffic"] = "true"
        }
        release {
            // Cleartext HTTP is allowed in a release build only when the backend
            // URL baked in via --dart-define=API_BASE_URL is itself http:// (a
            // plain-HTTP demo server). An https:// URL => cleartext is blocked.
            manifestPlaceholders["usesCleartextTraffic"] = allowCleartext.toString()
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
