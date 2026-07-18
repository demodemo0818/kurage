package jp.demo2.kurage

import android.media.MediaScannerConnection
import android.os.Build
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.File

// local_auth プラグインは FragmentActivity 系を要求するので、
// 標準の FlutterActivity ではなく FlutterFragmentActivity を継承する。
class MainActivity: FlutterFragmentActivity() {
  private val MEDIA_CHANNEL = "kurage/media_scanner"
  private val SHARE_CHANNEL = "jp.demo2.kurage/share"

  // 他アプリの「共有」メニューから受け取った text/plain を Flutter 側が
  // 取りに来るまで保持しておくバッファ。consumePendingSharedText で取り出すと
  // 同時にクリアされる。
  private var pendingSharedText: String? = null
  private val SHARE_INTAKE_CHANNEL = "jp.demo2.kurage/share_intake"

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    // コールドスタート時の Intent を捕捉
    captureSharedText(intent)
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    // launchMode=singleTop なので、すでに動いている Activity に新しい Intent が
    // 来た場合はここで受ける。setIntent しておかないと getIntent() で古いものが
    // 返るので、念のため更新。
    setIntent(intent)
    captureSharedText(intent)
  }

  /// ACTION_SEND + text/plain なら EXTRA_TEXT (および EXTRA_SUBJECT) を
  /// pendingSharedText に格納する。
  private fun captureSharedText(intent: Intent?) {
    if (intent == null) return
    if (intent.action != Intent.ACTION_SEND) return
    if (intent.type != "text/plain") return
    val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
    val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
    // ブラウザ等は EXTRA_SUBJECT にページタイトル + EXTRA_TEXT に URL を載せる。
    // 両方ある場合は「タイトル\nURL」の形で連結して投稿欄に流し込みやすくする。
    pendingSharedText = if (!subject.isNullOrBlank() && subject != text) {
      "$subject\n$text"
    } else {
      text
    }
  }

  override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)

    // Media scanner channel
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_CHANNEL).setMethodCallHandler { call, result ->
      if (call.method == "scanFile") {
        val path = call.argument<String>("path")
        if (path != null) {
          MediaScannerConnection.scanFile(
            this,
            arrayOf(path),
            null,
            null
          )
          result.success(true)
        } else {
          result.error("INVALID_PATH", "path is null", null)
        }
      } else {
        result.notImplemented()
      }
    }

    // Share channel for translation apps
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL).setMethodCallHandler { call, result ->
      when (call.method) {
        "shareText" -> {
          val text = call.argument<String>("text")
          val subject = call.argument<String>("subject")
          // チューザのタイトル。呼び出し側が用途 (翻訳 / URL 共有 等) に
          // 合わせて指定できるよう引数化。指定がなければ汎用の文言を使う。
          val title = call.argument<String>("title") ?: "共有"

          if (text != null) {
            val shareIntent = Intent().apply {
              action = Intent.ACTION_SEND
              type = "text/plain"
              putExtra(Intent.EXTRA_TEXT, text)
              if (subject != null) {
                putExtra(Intent.EXTRA_SUBJECT, subject)
              }
            }

            val chooserIntent = Intent.createChooser(shareIntent, title)
            if (shareIntent.resolveActivity(packageManager) != null) {
              startActivity(chooserIntent)
              result.success(true)
            } else {
              result.error("NO_APPS", "共有可能なアプリが見つかりません", null)
            }
          } else {
            result.error("INVALID_TEXT", "text is null", null)
          }
        }

        // ACTION_PROCESS_TEXT を使った翻訳呼び出し。
        // Google 翻訳 / Microsoft Translator / DeepL 等の翻訳アプリは、
        // テキスト選択メニューの「翻訳」と同じ経路で呼ばれた時にフローティング
        // ポップアップで開く設計になっている。targetPackage を指定すれば
        // チューザを出さずに対象アプリへ直行できる。
        "processText" -> {
          val text = call.argument<String>("text")
          val targetPackage = call.argument<String>("targetPackage")
          if (text == null) {
            result.error("INVALID_TEXT", "text is null", null)
            return@setMethodCallHandler
          }
          val intent = Intent("android.intent.action.PROCESS_TEXT").apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_PROCESS_TEXT, text)
            putExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, true)
            // FlutterActivity から外部アプリのフローティング Activity を
            // 起動するので NEW_TASK が必要
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
          }
          if (targetPackage != null) {
            intent.setPackage(targetPackage)
          }
          if (intent.resolveActivity(packageManager) != null) {
            try {
              startActivity(intent)
              result.success(true)
            } catch (e: Exception) {
              result.error("LAUNCH_FAILED", e.message, null)
            }
          } else {
            result.error("NO_APP", "対応する翻訳アプリが見つかりません", null)
          }
        }

        else -> result.notImplemented()
      }
    }

    // 他アプリの「共有」から受け取ったテキストを Flutter 側が取り出すための
    // チャンネル。consumePendingSharedText を 1 回呼ぶと、保持していたテキストが
    // 戻り値として返り、同時にクリアされる (二重起動防止)。
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_INTAKE_CHANNEL)
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "consumePendingSharedText" -> {
            val text = pendingSharedText
            pendingSharedText = null
            result.success(text)
          }
          else -> result.notImplemented()
        }
      }
  }
}
