package jp.demo2.kurage

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * 他アプリの「共有」から受け取った text/plain を、MainActivity が Flutter 側へ
 * 引き渡すまで保持しておくプロセス内バッファ。
 *
 * ShareActivity と MainActivity は同一プロセスなので static なバッファで確実に
 * 渡せる。consume() は 1 回取り出すと同時にクリアするので、二重で投稿画面が
 * 開くことはない。
 */
object ShareIntake {
  private var pendingSharedText: String? = null

  /// ACTION_SEND + text/plain なら EXTRA_TEXT (および EXTRA_SUBJECT) を
  /// バッファに格納する。
  fun capture(intent: Intent?) {
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

  /// 保持しているテキストを取り出す (取り出すと同時にクリア)。
  fun consume(): String? {
    val text = pendingSharedText
    pendingSharedText = null
    return text
  }
}

/**
 * ACTION_SEND (text/plain) 専用の中継 Activity。
 *
 * なぜ MainActivity で直接受けないか:
 *   ACTION_SEND の intent-filter を MainActivity に直付けすると、共有起動時の
 *   SEND Intent が「メインタスクの Intent」として Android 側に保存される。
 *   投稿を終えて Activity / プロセスが破棄されたあと、タスク復元やランチャー
 *   からの再起動で onCreate に**その古い SEND Intent が再配達**され、投稿済みの
 *   内容が入った投稿画面がまた開いてしまう (setIntent や extra の削除では直せ
 *   ない。保存されているのは system_server 側の Intent なので、アプリ内で
 *   書き換えても復元時には元のものが来る)。
 *
 *   そこで SEND は taskAffinity="" / noHistory / excludeFromRecents を付けた
 *   この Activity で受け、テキストだけ ShareIntake に移して即 finish する。
 *   メインタスクの Intent は常に MAIN/LAUNCHER のままになり、再配達が起きない。
 *
 * Flutter 側は MainActivity 起動後の post-frame と、resumed のたびに
 * `consumePendingSharedText` を叩くので (lib/main.dart)、コールド / ウォームの
 * どちらの経路でも拾える。
 */
class ShareActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    ShareIntake.capture(intent)
    startActivity(
      Intent(this, MainActivity::class.java).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
      }
    )
    finish()
  }
}
