allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// 全サブプロジェクト (= 各 Flutter プラグイン) の Java コンパイル警告を抑制。
// firebase_messaging 14.x など、まだ Java 8 ターゲットのプラグインが
// 「ソース値8は廃止されていて...」やノート (推奨されない API 使用 等) を
// 大量に出すのを黙らせる。プラグイン側でないと根本対処できないので、
// プラグイン側の警告/ノートのみ完全に黙らせる。アプリ自体の Java 警告は
// app/build.gradle.kts 側で個別制御している。
subprojects {
    tasks.withType<JavaCompile>().configureEach {
        options.compilerArgs.addAll(listOf(
            "-Xlint:none",   // 全 lint 抑制 (警告 + 関連ノート)
            "-nowarn",
        ))
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
