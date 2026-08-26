package jp.demo2.kurage

import android.media.MediaScannerConnection
import android.os.Build
import android.content.Intent
import android.net.Uri
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

  // 共有テキストの受け渡し用。実際に ACTION_SEND を受けるのは ShareActivity で、
  // ここはそれが ShareIntake に貯めたものを Flutter 側へ渡すだけ。
  private val SHARE_INTAKE_CHANNEL = "jp.demo2.kurage/share_intake"

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
    // チャンネル。ShareActivity が ShareIntake に貯めたテキストを 1 回だけ返し、
    // 同時にクリアされる (二重起動防止)。
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_INTAKE_CHANNEL)
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "consumePendingSharedText" -> {
            result.success(ShareIntake.consume())
          }
          else -> result.notImplemented()
        }
      }
  }
}
