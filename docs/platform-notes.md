# プラットフォーム固有の注意 (詳細)

[CLAUDE.md](../CLAUDE.md) から切り出した詳細ドキュメント。Android のビルド設定・debug/release 共存、Windows のツールチェーンセットアップ、配布などの詳細を扱う。

## Android

- `compileSdk` / `targetSdk` / `minSdk` は Flutter SDK 既定を継承（`flutter.compileSdkVersion` 等）
- `appAuthRedirectScheme = "jp.demo2.kurage"`（[build.gradle.kts](../android/app/build.gradle.kts)。`buildTypes.debug` だけ `applicationIdSuffix = ".debug"` で `jp.demo2.kurage.debug` に、OAuth scheme も `jp.demo2.kurage.debug` に、ラベルは `Kurage Dev` に上書き。release / profile はデフォルト値を継承）
- **debug / release 共存運用**: `flutter run` (debug) は `jp.demo2.kurage.debug` 別アプリとしてインストールされるので、`flutter build apk --release` で作った release 版と端末上で共存する (ホーム画面にアイコン 2 つ、ストレージ・OAuth トークン・カラム設定すべて独立)。Dart 側は [auth_service_mobile.dart](../lib/services/auth_service_mobile.dart) が `kDebugMode` 定数で redirect URI を分岐 (`kDebugMode == true` → `jp.demo2.kurage.debug://callback`、false → `jp.demo2.kurage://callback`)。これは Android 側の `manifestPlaceholders` と 1:1 で対応していて、profile / release は false 側に揃う
- **FCM の debug ビルド注意**: [google-services.json](../android/app/google-services.json) に `jp.demo2.kurage.debug` 用のクライアントエントリをダミー追加してビルドを通している (= Firebase Console 未登録)。**debug ビルドでは FCM トークン取得が実行時に失敗** してプッシュ通知が動かない。debug でもプッシュを動かしたい場合は Firebase Console で debug 用 Android アプリを正式登録して google-services.json を再ダウンロード
- `JavaCompile` で `-Xlint:-options,-Xlint:-deprecation` を抑制（古い API 利用時の警告除去）
- 通知用に `POST_NOTIFICATIONS` 権限を `AndroidManifest.xml` で宣言済み (Android 13+ ランタイム要求は `PushNotificationService.initialize()` 内で実行)
- `MainActivity.kt` は **`FlutterFragmentActivity` 継承** (アプリロックの `local_auth` が要求)。`USE_BIOMETRIC` 権限あり。
- **アダプティブアイコン** ([mipmap-anydpi-v26/ic_launcher.xml](../android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml)): 背景色 `#0A0620` ([colors.xml](../android/app/src/main/res/values/colors.xml)) + 前景画像。`pubspec.yaml` の `flutter_icons` で `adaptive_icon_foreground` には **元画像と異なる別ファイル** [assets/icon/kurage_icon_foreground.png](../assets/icon/kurage_icon_foreground.png) を指定 (元の `kurage_icon.png` をそのまま使うと安全ゾーンを超えてマスクで端が切られる)。foreground は元画像を 70% に縮小し同色の余白を足したもの。元画像を差し替えたら foreground 用画像も再生成が必要。

## Web

- `web/auth/callback.html` をアセットに含む。OAuth 完了時に親ウィンドウへ `postMessage`。

## Windows (デスクトップ)

`flutter run -d windows` / `flutter build windows` には以下のツールチェーン整備が必要。Android/Web だけ触ってきた環境で初めて通すと複数の壁に順にぶつかるので、新しい PC でセットアップする時は下記を先に揃える。

- **Visual Studio 2022 + 「C++ によるデスクトップ開発」ワークロード必須**。VS2019 BuildTools 同梱の CMake 3.20 では `firebase_cpp_sdk_windows` が CMake 3.22+ を要求して configure 失敗する。Flutter は検出した VS に同梱された cmake を使う (flutter_tools `visual_studio.dart` の `cmakePath`) ため、PATH に新しい cmake を入れても効かず **VS 自体を 2022 に上げる**必要がある。winget: `winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"`。
- **ATL コンポーネント (`Microsoft.VisualStudio.Component.VC.ATL`) も必須**。無いと `flutter_secure_storage_windows` (アプリロックの PIN 保管) が `atlstr.h` not found (C1083) で失敗する。既存 VS への追加は **winget では不可** (既インストール→アップグレード判定でスキップ)。VS Installer を直接叩く: `"C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe" modify --productId Microsoft.VisualStudio.Product.BuildTools --channelId VisualStudio.17.Release --add Microsoft.VisualStudio.Component.VC.ATL` → GUI が開くので「変更」+ UAC。注意: `--passive`/`--quiet` は最初から管理者起動でないと exit 5007 で即終了する (自己昇格しない)。`--installPath "C:\Program Files (x86)\..."` は PowerShell の `Start-Process` がスペースを自動クオートせず途中で切れるので、**productId/channelId 指定**が安全。
- **NuGet にパッケージソースが必要**。`%APPDATA%\NuGet\NuGet.Config` の `<packageSources>` が空だと `audioplayers_windows` の `nuget install Microsoft.Windows.ImplementationLibrary` が "Argument cannot be null or empty / primarySources" で失敗する。`<add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />` を追加して解決。
- VS のジェネレータを変えた後 (例: VS2019→2022) は `build\windows` を一度削除する。古い `CMakeCache.txt` が「generator does not match」エラーを出すため。
- 生成 exe は **`build\windows\x64\runner\Debug\mastodon_app.exe`** (`kurage.exe` ではない。Windows runner の `BINARY_NAME` が旧名 `mastodon_app` のまま [windows/CMakeLists.txt](../windows/CMakeLists.txt))。リンク時の `LNK4099 PDB が見つかりません` 大量警告は Firebase 静的ライブラリのシンボル欠落で**無害**。
- 実行時は [main.dart](../lib/main.dart) が `firebaseSupported = kIsWeb || android` で Windows の Firebase 初期化を skip するので起動する。**Windows ではプッシュ通知 (FCM) / Crashlytics / Analytics は無効** (Firebase は Android/Web のみ対象の設計)。
- **動画再生**: 公式 `video_player` は Windows 未対応のため、[video_player_win](https://pub.dev/packages/video_player_win) (Windows 標準 Media Foundation ベースの federated 実装) を pubspec に追加して対応している。依存に入れるだけで `VideoPlayerController` がそのまま動く。なお mp4 未変換の GIF gifv (Misskey 等) はどのプラットフォームでも動画プレイヤーで再生できないため画像デコーダ経路で再生 ([full_screen_image_page.dart](../lib/pages/full_screen_image_page.dart) `_buildPage`)。Linux は video_player 実装が無く動画再生不可のまま (gifv のみ `remote_url` の元 GIF に画像フォールバック)。
- **配布**: テスター向けは `tool\package_windows.ps1` で release ビルド + VC++ ランタイム同梱の zip (`dist\kurage-vX.Y.Z[-pre]-windows.zip`) を生成する (ポータブル/未署名)。exe 名・ウィンドウタイトル・アイコンは Kurage ブランド化済み ([windows/CMakeLists.txt](../windows/CMakeLists.txt) `BINARY_NAME=kurage`、[windows/runner/Runner.rc](../windows/runner/Runner.rc)、`app_icon.ico` は [tool/gen_windows_icon.dart](../tool/gen_windows_icon.dart) で生成)。詳細は [RELEASING.md](../RELEASING.md)「Windows 配布」。
