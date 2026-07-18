import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Firebase / FCM 用
    id("com.google.gms.google-services")
    // Firebase Crashlytics 用 (Dart 例外 + ネイティブクラッシュをレポート)
    id("com.google.firebase.crashlytics")
}

// android/key.properties に release 用 keystore の情報を書いておくと、
// release ビルドが本番鍵で署名される。ファイルが無いと debug 鍵に
// フォールバックする (= ローカル開発で `flutter run --release` が動く)。
// key.properties / keystore 自体はリポジトリ外。詳細は RELEASING.md。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}
val hasReleaseKeystore = keystorePropertiesFile.exists()

android {
    namespace = "jp.demo2.kurage"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        // Core library desugaringを有効にする
        isCoreLibraryDesugaringEnabled = true
    }

    tasks.withType<JavaCompile> {
        options.compilerArgs.addAll(listOf("-Xlint:-options", "-Xlint:-deprecation"))
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "jp.demo2.kurage"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // release / profile はこのデフォルト値を使う。debug は下の buildTypes
        // ブロックで applicationIdSuffix と一緒に上書きする。
        manifestPlaceholders["appAuthRedirectScheme"] = "jp.demo2.kurage"
        manifestPlaceholders["appLabel"] = "Kurage"
    }

    signingConfigs {
        create("release") {
            if (hasReleaseKeystore) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        debug {
            // 配布版 (release) と共存させるため、debug ビルドだけ
            // applicationId を `.debug` 接尾辞付きにする (= 別アプリ扱い)。
            // OAuth リダイレクトスキームも別にしないと、ブラウザの
            // コールバックで「アプリで開く」ダイアログが出てしまうので
            // 同じく `.debug` を付ける。
            // 連動して Dart 側 (auth_service_mobile.dart) は `kDebugMode`
            // で `jp.demo2.kurage.debug://callback` を使うように分岐済み。
            applicationIdSuffix = ".debug"
            manifestPlaceholders["appAuthRedirectScheme"] =
                "jp.demo2.kurage.debug"
            manifestPlaceholders["appLabel"] = "Kurage Dev"
        }
        release {
            // android/key.properties があれば本番鍵で署名。なければ debug 鍵に
            // フォールバックして `flutter run --release` がローカルで動くようにする。
            // 配布する APK は必ず key.properties が解決できる環境でビルドすること。
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
    // Core library desugaringに必要
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}
