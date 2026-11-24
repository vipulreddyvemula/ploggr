plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val fieldKeystore = providers.environmentVariable("PLOGGR_FIELD_KEYSTORE")

android {
    namespace = "com.example.ploggr"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        manifestPlaceholders["appAuthRedirectScheme"] = "com.example.ploggr.auth"
        applicationId = "com.example.ploggr"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["appLabel"] = "ploggr"
    }

    signingConfigs {
        if (fieldKeystore.isPresent) {
            create("field") {
                storeFile = file(fieldKeystore.get())
                storePassword = providers.environmentVariable("PLOGGR_FIELD_STORE_PASSWORD").get()
                keyAlias = "ploggr-field"
                keyPassword = storePassword
            }
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

// Keep the regular local APK path and give the CI build its own package and identity.
if (fieldKeystore.isPresent) {
    android.defaultConfig.applicationId = "com.example.ploggr.field"
    android.defaultConfig.manifestPlaceholders["appLabel"] = "ploggr Field"
    android.buildTypes.getByName("release").signingConfig = android.signingConfigs.getByName("field")
    android.sourceSets.getByName("release") {
        manifest.srcFile("src/field/AndroidManifest.xml")
        res.srcDir("src/field/res")
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
