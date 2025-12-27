import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.ieee_organizer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

        val keystoreProperties = Properties()
        val keystorePropertiesFile = rootProject.file("key.properties")
        val hasReleaseKeystore = keystorePropertiesFile.exists()
        if (hasReleaseKeystore) {
            keystoreProperties.load(keystorePropertiesFile.inputStream())
        }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.ieee_organizer"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

        signingConfigs {
            if (hasReleaseKeystore) {
                create("release") {
                    val storeFilePath = keystoreProperties["storeFile"] as String?
                    if (storeFilePath != null) {
                        storeFile = file(storeFilePath)
                    }
                    keyAlias = keystoreProperties["keyAlias"] as String?
                    keyPassword = keystoreProperties["keyPassword"] as String?
                    storePassword = keystoreProperties["storePassword"] as String?
                    enableV3Signing = true
                    enableV4Signing = true
                }
            }
        }

    buildTypes {
        release {
                        signingConfig = if (hasReleaseKeystore) {
                            signingConfigs.getByName("release")
                        } else {
                            signingConfigs.getByName("debug")
                        }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
