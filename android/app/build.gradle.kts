plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "net.xpossystems.dejavoo_restaurant"
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
        applicationId = "net.xpossystems.dejavoo_restaurant"
        // The invoke-dvpay-lite SDK / Dejavoo P-series terminals need 24+.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Dejavoo terminals only run APKs signed with the shared kozen keystore
    // (copied in from repos/dejavoo/app/ before a terminal build). When the
    // file is absent — CI, plain `flutter build` on a dev box — fall back to
    // the debug keys so non-terminal builds still work.
    val kozenKeystore = file("kozen.jks")
    if (kozenKeystore.exists()) {
        signingConfigs {
            create("kozen") {
                storeFile = kozenKeystore
                storePassword = "kozen"
                keyAlias = "xc-buildsrv"
                keyPassword = "kozen"
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (kozenKeystore.exists()) {
                signingConfigs.getByName("kozen")
            } else {
                // Signing with the debug keys so `flutter run --release` works.
                signingConfigs.getByName("debug")
            }
        }
        debug {
            if (kozenKeystore.exists()) {
                signingConfig = signingConfigs.getByName("kozen")
            }
        }
    }
}

dependencies {
    // Dejavoo DvPayLite intent SDK — resolved from the credentialed S3 maven
    // repo declared in ../build.gradle.kts (skipped when no creds are
    // present, so `flutter analyze`/`flutter test` never need it).
    implementation("com.denovo:invoke-dvpay-lite:1.2.1.3")
}

flutter {
    source = "../.."
}
