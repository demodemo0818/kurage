pluginManagement {
    val flutterSdkPath = run {
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
    // Flutter 3.47.5 のテンプレートと同じ組み合わせ (Gradle 9.3.1 / AGP 9.1.0 / Kotlin 2.4.0)。
    // Flutter の Gradle プラグインは AGP < 9.0.1 / Kotlin < 2.3.20 / Gradle < 9.1 だと
    // 「まもなくサポート終了」の警告を出す。
    // Kotlin プラグインはアプリ側では apply しない (AGP 9 の組み込み Kotlin 移行)。
    // builtInKotlin=false の間は Flutter の Gradle プラグインが各サブプロジェクトに自動適用する。
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
    id("com.google.gms.google-services") version "4.5.0" apply false
    id("com.google.firebase.crashlytics") version "3.0.8" apply false
}

include(":app")
