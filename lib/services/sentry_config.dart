// lib/services/sentry_config.dart

/// Sentry の DSN (取り込みエンドポイント)。
///
/// Web / デスクトップのエラー収集にのみ使用する (モバイルは Firebase
/// Crashlytics のまま)。init は main.dart で web/desktop 限定。
///
/// DSN は「公開可能な取り込みキー」であり、クライアントに埋め込んで問題ない
/// (push_relay_config.dart と同じ扱い)。秘匿が必要なのは auth token であって
/// DSN ではない。
///
/// Sentry の Project Settings → Client Keys (DSN)。EU (de) リージョン。
/// 空文字にすると main.dart 側で Sentry init をスキップする
/// (エラー収集は無効、起動はする)。
const String sentryDsn =
    'https://40a271ba04f11f1c607ead823b0c58a2@o4511499613372416.ingest.de.sentry.io/4511499621630032';

/// Sentry の送信可否ランタイムフラグ。設定「クラッシュレポートを送信」と連動し、
/// main.dart の `beforeSend` がこの値を見て送信/破棄を切り替える (live にオプト
/// アウト可能)。起動時に crashReportingEnabled で初期化、設定 UI から更新する。
///
/// main.dart と app_settings_page.dart の双方から参照するため、import 循環を
/// 避けてここ (依存ゼロの config ファイル) に置く。
bool sentryReportingEnabled = true;
