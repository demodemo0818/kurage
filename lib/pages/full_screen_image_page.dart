// lib/pages/full_screen_image_page.dart

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import '../l10n/l10n.dart';
import '../providers/settings_provider.dart';
import '../services/image_download_stub.dart'
    if (dart.library.js_interop) '../services/image_download_web.dart'
    as image_download;
import '../services/image_save_io.dart';
import '../utils/platform.dart';
import '../widgets/network_image_x.dart';
import '../models/media_attachment.dart';
import '../utils/breakpoints.dart';
import '../widgets/post_tile.dart' show showAltTextDialog;
import '../widgets/video_player_widget.dart';

/// メディアの全画面ビューアを開く統一エントリ。
///
/// ワイド幅 (Deck / デスクトップ) では `showDialog` で「画像のアスペクト比に
/// 合わせた中央モーダル窓 + 暗幕」として開き、暗幕タップ / Esc / 閉じるボタンで
/// 閉じる。ナロー (モバイル) では従来どおりフルスクリーンの [FullScreenGalleryPage]
/// を `Navigator.push` する。
///
/// `showDialog` は既定で root navigator を使うため、Deck ポップアップ内 (nested
/// Navigator) から開いても暗幕が画面全体を覆い最前面に出る。
void showMediaGallery(
  BuildContext context, {
  required List<String> imageUrls,
  List<MediaAttachment>? mediaAttachments,
  int initialIndex = 0,
}) {
  if (isWideLayout(context)) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.85),
      barrierDismissible: true, // 暗幕 (窓の外) タップで閉じる
      builder: (_) => FullScreenGalleryPage(
        imageUrls: imageUrls,
        mediaAttachments: mediaAttachments,
        initialIndex: initialIndex,
        windowed: true,
      ),
    );
  } else {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullScreenGalleryPage(
          imageUrls: imageUrls,
          mediaAttachments: mediaAttachments,
          initialIndex: initialIndex,
        ),
      ),
    );
  }
}

class FullScreenGalleryPage extends ConsumerStatefulWidget {
  final List<String> imageUrls;
  final List<MediaAttachment>? mediaAttachments;
  final int initialIndex;

  /// Deck (ワイド) で「アスペクト比に合わせた中央モーダル窓」として表示するか。
  /// `false` (既定) のときは従来どおりフルスクリーン Scaffold で表示する。
  /// 通常は [showMediaGallery] が幅に応じて出し分ける。
  final bool windowed;

  const FullScreenGalleryPage({
    super.key,
    required this.imageUrls,
    this.mediaAttachments,
    this.initialIndex = 0,
    this.windowed = false,
  });

  @override
  ConsumerState<FullScreenGalleryPage> createState() =>
      _FullScreenGalleryPageState();
}

class _FullScreenGalleryPageState extends ConsumerState<FullScreenGalleryPage>
    with SingleTickerProviderStateMixin {
  late final PageController _pageController;
  late int _currentIndex;
  bool _saving = false;
  static const _mediaScannerChannel =
      MethodChannel('kurage/media_scanner');

  /// 画面内トースト。窓モードのビューアは `showDialog` の黒幕モーダルで
  /// ScaffoldMessenger を持たないため、保存完了/失敗の `SnackBar` を出しても
  /// 黒幕の裏に隠れてしまう。代わりにビューアの Stack 内へ重ねる自前トーストで
  /// 通知する (フルスクリーンモードでも同じ導線に統一)。
  String? _toastMessage;
  Timer? _toastTimer;

  double _dragOffset = 0.0;
  late AnimationController _animController;
  late Animation<double> _anim;
  bool _isImageZoomed = false; // 現在の画像がズームされているかどうか

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex)
      ..addListener(() {
        final newIndex = _pageController.page?.round() ?? _currentIndex;
        if (newIndex != _currentIndex) {
          setState(() {
            _currentIndex = newIndex;
            // ページが変わると新しい画像は等倍から始まる (画面外の tile は破棄
            // ・再生成される) ので拡大フラグをリセット。これがないと拡大中に
            // キーボードでページ送りした際に窓が全画面のまま戻らない。
            _isImageZoomed = false;
          });
        }
      });

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..addListener(() {
        setState(() {
          _dragOffset = _anim.value;
        });
      });
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _animController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  /// ビューア内に重ねる自前トーストを表示する (4 秒で自動消去)。
  void _showToast(String message) {
    if (!mounted) return;
    setState(() => _toastMessage = message);
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _toastMessage = null);
    });
  }

  Future<void> _saveCurrentImage() async {
    if (_saving) return;
    setState(() => _saving = true);

    try {
      final url = widget.imageUrls[_currentIndex];

      if (kIsWeb) {
        // Web: CanvasKit 描画では右クリック「画像を保存」が使えない
        // (画像は <canvas> のピクセルであって <img> 要素ではない) ため、
        // アプリ側で Blob + <a download> ダウンロードを提供する。
        await _saveOnWeb(url);
        return; // _saving の解除は finally に任せる
      }

      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode != 200) throw Exception(l10n.downloadFailed);

      final fileName = 'mastodon_${DateTime.now().millisecondsSinceEpoch}.jpg';

      if (isDesktop()) {
        // デスクトップ: 設定の既定フォルダ or 毎回確認ダイアログで保存先を決める。
        final settings = ref.read(settingsProvider);
        final savedPath = await saveImageToDesktop(
          resp.bodyBytes,
          suggestedName: fileName,
          preferredDir: settings.imageSaveDirectory,
          askLocation: settings.confirmImageSaveLocation,
        );
        if (savedPath == null) return; // 保存ダイアログをキャンセル
        _showToast(l10n.savedTo(savedPath));
      } else {
        // モバイル: Android = Pictures + media scanner、iOS 等 = サンドボックス。
        final saveDir = Platform.isAndroid
            ? Directory('/storage/emulated/0/Pictures')
            : await getApplicationDocumentsDirectory();
        if (!await saveDir.exists()) {
          await saveDir.create(recursive: true);
        }

        final filePath = '${saveDir.path}/$fileName';
        final file = File(filePath);
        await file.writeAsBytes(resp.bodyBytes);

        if (Platform.isAndroid) {
          await _mediaScannerChannel
              .invokeMethod('scanFile', {'path': file.path});
        }

        _showToast(l10n.savedTo(filePath));
      }
    } catch (e) {
      _showToast(l10n.saveFailed('$e'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Web の保存処理。bytes を fetch できれば Blob + `<a download>` で
  /// ダウンロード、CORS 未対応 CDN 等で fetch が失敗したら新しいタブで開いて
  /// ブラウザの保存メニューに委ねる (タブ側は素の `<img>` なので右クリック/
  /// 長押しで保存できる)。
  Future<void> _saveOnWeb(String url) async {
    try {
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final mime = resp.headers['content-type'] ?? 'image/jpeg';
      final fileName =
          'mastodon_${DateTime.now().millisecondsSinceEpoch}.${_extFromMime(mime)}';
      await image_download.downloadBytes(
        resp.bodyBytes,
        fileName: fileName,
        mimeType: mime,
      );
      _showToast(l10n.downloadedAs(fileName));
    } catch (_) {
      image_download.openInNewTab(url);
      _showToast(l10n.imageOpenedInNewTab);
    }
  }

  /// Content-Type の MIME からファイル拡張子を導出する (Web の保存ファイル名用)。
  String _extFromMime(String mime) {
    final sub = mime.split('/').last.split(';').first.trim().toLowerCase();
    if (sub.isEmpty) return 'jpg';
    return switch (sub) {
      'jpeg' => 'jpg',
      'svg+xml' => 'svg',
      _ => sub,
    };
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragOffset += details.delta.dy;
    });
  }

  void _onDragEnd(DragEndDetails details) {
    const threshold = 200.0;
    const velocityThreshold = 500.0;

    if (_dragOffset > threshold || details.primaryVelocity! > velocityThreshold) {
      Navigator.pop(context);
    } else {
      // アニメーションで元の位置に戻す
      _anim = Tween<double>(begin: _dragOffset, end: 0.0).animate(_animController);
      _animController.forward(from: 0.0);
    }
  }

  /// 指定 index へアニメ付きでページ送りする。範囲外 / 同一は no-op (ラップなし)。
  /// キーボード (← →) と左右チェブロンの両方から呼ぶ。
  void _goToPage(int target) {
    if (target < 0 || target >= widget.imageUrls.length) return;
    if (target == _currentIndex) return;
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
  }

  /// 1 ページ分のメディア (画像 or 動画) を組む。フルスクリーン / 窓 で共有。
  /// [fit] は画像のフィット、[allowDragDismiss] は縦スワイプで閉じる導線の有無。
  Widget _buildPage(
    int i, {
    required BoxFit fit,
    required bool allowDragDismiss,
    bool expandOnZoom = false,
  }) {
    final attachment = widget.mediaAttachments != null && i < widget.mediaAttachments!.length
        ? widget.mediaAttachments![i]
        : null;
    final isVideo = attachment?.isVideo ?? false;
    final isGif = attachment?.isGif ?? false;

    if (isVideo) {
      final video = Center(
        child: VideoPlayerWidget(
          videoUrl: widget.imageUrls[i],
          autoPlay: true,
          // gifv は GIF と同じ感覚で扱いたいのでループ再生 + 無音、コントロールも
          // 要らない。通常の video はユーザーが制御したいので従来どおり。
          showControls: !isGif,
          muted: isGif,
          looping: isGif,
        ),
      );
      if (allowDragDismiss) {
        return GestureDetector(
          onVerticalDragUpdate: _onDragUpdate,
          onVerticalDragEnd: _onDragEnd,
          child: video,
        );
      }
      return video;
    }

    return _ZoomableImage(
      imageUrl: widget.imageUrls[i],
      fit: fit,
      expandOnZoom: expandOnZoom,
      onVerticalDragUpdate: allowDragDismiss ? _onDragUpdate : null,
      onVerticalDragEnd: allowDragDismiss ? _onDragEnd : null,
      onZoomChanged: (isZoomed) {
        setState(() {
          _isImageZoomed = isZoomed;
        });
      },
    );
  }

  String _altTextFor(int index) {
    if (widget.mediaAttachments == null ||
        index >= widget.mediaAttachments!.length) {
      return '';
    }
    return widget.mediaAttachments![index].description?.trim() ?? '';
  }

  /// ビューア下部に重ねる自前トースト (保存完了/失敗)。`_toastMessage` が null の
  /// ときは hit-test を素通りさせる SizedBox.shrink を返す。タップは透過。
  Widget _buildToastOverlay() {
    final message = _toastMessage;
    if (message == null) return const SizedBox.shrink();
    return Positioned(
      left: 16,
      right: 16,
      bottom: 24,
      child: IgnorePointer(
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 520),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                message,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return widget.windowed ? _buildWindowed(context) : _buildFullscreen(context);
  }

  // ---------------------------------------------------------------------------
  // フルスクリーン (ナロー / モバイル) — 従来どおり
  // ---------------------------------------------------------------------------
  Widget _buildFullscreen(BuildContext context) {
    // 背景の不透明度: ドラッグ量が大きいほど透明に
    final normalized = (_dragOffset.abs() / 300).clamp(0.0, 1.0);
    final backgroundOpacity = 1.0 - normalized;

    // Web / デスクトップで窓が狭い (600px 未満) ときもこのフルスクリーン
    // 経路に入るが、Flutter のデフォルト dragDevices に mouse が含まれず
    // スワイプ (マウスドラッグ) でページ送りできない。マウス前提の環境では
    // windowed と同じチェブロン + キーボード操作を提供する。
    // Android / iOS 実機は false で従来 UI のまま。
    final showDesktopNav = kIsWeb || isDesktop();

    final scaffold = Scaffold(
      backgroundColor: Colors.black.withValues(alpha: backgroundOpacity),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          '${_currentIndex + 1}/${widget.imageUrls.length}',
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: Colors.black.withValues(alpha: backgroundOpacity),
        elevation: 0,
        actions: [
          IconButton(
            icon: _saving
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2),
                  )
                : const Icon(Icons.save_alt, color: Colors.white),
            onPressed: _saveCurrentImage,
          ),
        ],
      ),
      body: Stack(
        children: [
          Transform.translate(
            offset: Offset(0, _dragOffset),
            child: ScrollConfiguration(
              behavior: _GalleryScrollBehavior(),
              child: PageView.builder(
                controller: _pageController,
                physics: _isImageZoomed
                    ? const NeverScrollableScrollPhysics()
                    : null,
                itemCount: widget.imageUrls.length,
                itemBuilder: (_, i) =>
                    _buildPage(i, fit: BoxFit.contain, allowDragDismiss: true),
              ),
            ),
          ),
          _AltTextOverlay(
            description: _altTextFor(_currentIndex),
            // ドラッグで下に流れている時はオーバーレイも一緒に追従させて、
            // 「画像だけ動いてバーが画面下に固定で残る」違和感をなくす。
            translateY: _dragOffset,
            opacity: backgroundOpacity,
          ),
          if (showDesktopNav &&
              widget.imageUrls.length > 1 &&
              !_isImageZoomed) ...[
            _edgeButton(left: true, enabled: _currentIndex > 0),
            _edgeButton(
              left: false,
              enabled: _currentIndex < widget.imageUrls.length - 1,
            ),
          ],
          _buildToastOverlay(),
        ],
      ),
    );

    // キーボード (←→ / Esc) はマウス前提の環境のみ。windowed の _onKey を
    // そのまま共用する (Esc → Navigator.pop はフルスクリーン route でも正しい)。
    if (!showDesktopNav) return scaffold;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: scaffold,
    );
  }

  // ---------------------------------------------------------------------------
  // 窓 (Deck / デスクトップ) — アスペクト比に合わせた中央モーダル窓
  // ---------------------------------------------------------------------------
  Widget _buildWindowed(BuildContext context) {
    final media = MediaQuery.of(context).size;
    final aspect = (widget.mediaAttachments != null &&
            _currentIndex < widget.mediaAttachments!.length)
        ? widget.mediaAttachments![_currentIndex].aspectRatio
        : (16 / 9);
    // 拡大中は窓を画面いっぱいに広げ、ズーム操作に最大の領域を与える (特に縦長
    // 画像は通常時の窓が横に狭く、その中でズームしても窮屈なため)。等倍に戻すと
    // アスペクト比に合わせた窓へアニメで戻る。
    final panel = _isImageZoomed ? media : _panelSize(media, aspect);
    final hasMultiple = widget.imageUrls.length > 1;

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          width: panel.width,
          height: panel.height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.black,
            // 全画面 (拡大中) は角丸を消してフルスクリーン感を出す。
            borderRadius: BorderRadius.circular(_isImageZoomed ? 0 : 12),
            boxShadow: const [
              BoxShadow(color: Colors.black54, blurRadius: 24),
            ],
          ),
          child: Stack(
            children: [
              ScrollConfiguration(
                behavior: _GalleryScrollBehavior(),
                child: PageView.builder(
                  controller: _pageController,
                  physics: _isImageZoomed
                      ? const NeverScrollableScrollPhysics()
                      : null,
                  itemCount: widget.imageUrls.length,
                  itemBuilder: (_, i) => _buildPage(
                    i,
                    fit: BoxFit.scaleDown,
                    allowDragDismiss: false,
                    expandOnZoom: true,
                  ),
                ),
              ),
              _AltTextOverlay(
                description: _altTextFor(_currentIndex),
                translateY: 0,
                opacity: 1,
              ),
              _buildWindowTopBar(context),
              if (hasMultiple && !_isImageZoomed) ...[
                _edgeButton(left: true, enabled: _currentIndex > 0),
                _edgeButton(
                  left: false,
                  enabled: _currentIndex < widget.imageUrls.length - 1,
                ),
              ],
              _buildToastOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  /// 画像のアスペクト比を保ったまま、利用可能領域 (Deck) の 92% に収まる最大の
  /// 矩形サイズを返す。
  Size _panelSize(Size avail, double aspect) {
    final maxW = avail.width * 0.92;
    final maxH = avail.height * 0.92;
    double w = maxW;
    double h = w / aspect;
    if (h > maxH) {
      h = maxH;
      w = h * aspect;
    }
    return Size(w, h);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored; // 押下のみ (リピート無視)
    // 入力欄にフォーカスがあるときは奪わない (本画面には無いが安全策)。
    if (FocusManager.instance.primaryFocus?.context?.widget is EditableText) {
      return KeyEventResult.ignored;
    }
    final kb = HardwareKeyboard.instance;
    if (kb.isControlPressed || kb.isMetaPressed || kb.isAltPressed) {
      return KeyEventResult.ignored; // 修飾付きは OS / ブラウザに委譲
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.pop(context);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _goToPage(_currentIndex - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _goToPage(_currentIndex + 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored; // Space 等は Chewie コントロールへ
  }

  /// 窓の左右中央に重ねる前後送りチェブロン。端では淡色 + 無効。
  Widget _edgeButton({required bool left, required bool enabled}) {
    return Positioned(
      left: left ? 8 : null,
      right: left ? null : 8,
      top: 0,
      bottom: 0,
      child: Center(
        child: Opacity(
          opacity: enabled ? 1.0 : 0.25,
          child: Material(
            color: Colors.black.withValues(alpha: 0.45),
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: IconButton(
              icon: Icon(
                left ? Icons.chevron_left : Icons.chevron_right,
                color: Colors.white,
              ),
              onPressed: enabled
                  ? () => _goToPage(left ? _currentIndex - 1 : _currentIndex + 1)
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  /// 窓上端に重ねる細い半透明バー (戻る / カウンタ / 保存)。既存 AppBar と同じ導線。
  Widget _buildWindowTopBar(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.5),
              Colors.transparent,
            ],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              tooltip: context.l10n.close,
              onPressed: () => Navigator.pop(context),
            ),
            Expanded(
              child: Text(
                '${_currentIndex + 1}/${widget.imageUrls.length}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
            IconButton(
              icon: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2),
                    )
                  : const Icon(Icons.save_alt, color: Colors.white),
              tooltip: context.l10n.save,
              onPressed: _saveCurrentImage,
            ),
          ],
        ),
      ),
    );
  }
}

/// フルスクリーンビューア下部に重ねる ALT 文表示バー。description が
/// 空のときは描画自体をスキップする (null 返しではなく SizedBox.shrink で
/// Stack の hit-test を素通りさせる)。タップで [showAltTextDialog] を開いて
/// 全文をスクロール可能なダイアログで読める。
class _AltTextOverlay extends StatelessWidget {
  final String description;
  final double translateY;
  final double opacity;

  const _AltTextOverlay({
    required this.description,
    required this.translateY,
    required this.opacity,
  });

  @override
  Widget build(BuildContext context) {
    if (description.isEmpty) return const SizedBox.shrink();

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Transform.translate(
        offset: Offset(0, translateY),
        child: SafeArea(
          top: false,
          child: Opacity(
            opacity: opacity,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => showAltTextDialog(context, description),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  color: Colors.black.withValues(alpha: 0.55),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 1),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: const Text(
                          'ALT',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          description,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ZoomableImage extends StatefulWidget {
  final String imageUrl;
  final BoxFit fit;

  /// 窓モード (Deck) で、ズーム時にホスト側が窓を全画面へ広げるか。`true` のとき
  /// は (a) ダブルタップズームをタップ位置ではなくビューポート中央基準にし、
  /// (b) 窓のリサイズでビューポートサイズが変わるたびに現在スケールのまま中央へ
  /// 再アンカーする。これがないと「小さい窓の座標で計算したズーム変換」が全画面
  /// リサイズ後にズレて画像が右に寄る。`false` (モバイル全画面) は従来どおり
  /// タップ位置基準のアニメズーム。
  final bool expandOnZoom;
  final Function(DragUpdateDetails)? onVerticalDragUpdate;
  final Function(DragEndDetails)? onVerticalDragEnd;
  final Function(bool) onZoomChanged;

  const _ZoomableImage({
    required this.imageUrl,
    required this.fit,
    this.expandOnZoom = false,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
    required this.onZoomChanged,
  });

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage>
    with TickerProviderStateMixin {
  final TransformationController _transformationController = TransformationController();
  bool _isZoomed = false;
  late AnimationController _animationController;
  Offset? _lastTapPosition;

  /// 直近のビューポートサイズ (窓モードの中央再アンカー用)。
  Size? _viewportSize;

  /// ピンチ等のジェスチャ進行中か (進行中は中央再アンカーを抑止して操作と競合
  /// させない)。
  bool _interacting = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    // 変換行列の変更を監視
    _transformationController.addListener(_onTransformationChanged);
  }

  @override
  void dispose() {
    _transformationController.removeListener(_onTransformationChanged);
    _transformationController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  void _onTransformationChanged() {
    // 変換行列の変更時にズーム状態を更新
    final scale = _transformationController.value.getMaxScaleOnAxis();
    final newIsZoomed = scale > 1.01; // 少し余裕を持たせる
    if (_isZoomed != newIsZoomed) {
      setState(() {
        _isZoomed = newIsZoomed;
      });
      // 親にズーム状態の変更を通知
      widget.onZoomChanged(newIsZoomed);
    }
  }

  void _onInteractionUpdate(ScaleUpdateDetails details) {
    // この関数は残しておくが、主要な判定は _onTransformationChanged で行う
  }

  void _onDoubleTap() {
    if (widget.expandOnZoom) {
      // 窓モード: 中央基準で即時にズーム切替。窓が全画面へリサイズしてもズレ
      // ないよう、タップ位置ではなくビューポート中央を基準にする。実際の拡大の
      // 動きはホスト側の窓リサイズ (AnimatedContainer) が担う。
      if (_isZoomed) {
        _transformationController.value = Matrix4.identity();
      } else {
        _setCenteredScale(2.0);
      }
      return;
    }
    // モバイル全画面: 従来どおりタップ位置を中心にアニメズーム
    if (_isZoomed) {
      _animateToScale(Matrix4.identity());
    } else if (_lastTapPosition != null) {
      final scale = 2.0;
      final focalPoint = _lastTapPosition!;
      final matrix = Matrix4.identity()
        ..translateByDouble(focalPoint.dx, focalPoint.dy, 0.0, 1.0)
        ..scaleByDouble(scale, scale, scale, 1.0)
        ..translateByDouble(-focalPoint.dx, -focalPoint.dy, 0.0, 1.0);
      _animateToScale(matrix);
    } else {
      // フォールバック: 中央をズーム
      _animateToScale(Matrix4.identity()..scaleByDouble(2.0, 2.0, 2.0, 1.0));
    }
  }

  /// 現在のビューポート中央を基準に指定スケールへ設定する (窓モード用)。
  void _setCenteredScale(double scale) {
    final size = _viewportSize;
    if (size == null) {
      _transformationController.value = Matrix4.identity()
        ..scaleByDouble(scale, scale, scale, 1.0);
      return;
    }
    final cx = size.width / 2;
    final cy = size.height / 2;
    _transformationController.value = Matrix4.identity()
      ..translateByDouble(cx, cy, 0.0, 1.0)
      ..scaleByDouble(scale, scale, scale, 1.0)
      ..translateByDouble(-cx, -cy, 0.0, 1.0);
  }

  /// 現在のスケールを保ったまま、中央へ再アンカーする (窓のリサイズ追従用)。
  void _recenterAtCurrentScale() {
    final scale = _transformationController.value.getMaxScaleOnAxis();
    if (scale <= 1.01) return;
    _setCenteredScale(scale);
  }

  void _animateToScale(Matrix4 targetMatrix) {
    final animation = Matrix4Tween(
      begin: _transformationController.value,
      end: targetMatrix,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));

    animation.addListener(() {
      _transformationController.value = animation.value;
    });

    _animationController.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        // 窓モードでズーム中にビューポートサイズが変わったら (= ホストが窓を
        // 全画面へリサイズ中)、現在スケールのまま中央へ再アンカーしてズレを防ぐ。
        // ジェスチャ進行中は操作と競合するので抑止。
        if (_viewportSize != size) {
          _viewportSize = size;
          if (widget.expandOnZoom && _isZoomed && !_interacting) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _recenterAtCurrentScale();
            });
          }
        }
        return GestureDetector(
          // ダブルタップでズームイン/アウト
          onDoubleTapDown: (details) {
            _lastTapPosition = details.localPosition;
          },
          onDoubleTap: _onDoubleTap,
          // ズームされていない場合のみ縦スワイプで閉じる処理を有効にする
          onVerticalDragUpdate: _isZoomed ? null : widget.onVerticalDragUpdate,
          onVerticalDragEnd: _isZoomed ? null : widget.onVerticalDragEnd,
          child: InteractiveViewer(
            transformationController: _transformationController,
            minScale: 1.0,
            maxScale: 5.0,
            onInteractionStart: (_) => _interacting = true,
            onInteractionUpdate: _onInteractionUpdate,
            onInteractionEnd: (_) => _interacting = false,
            // 境界を有効にしてスムーズなパン操作を実現
            boundaryMargin: const EdgeInsets.all(20.0),
            // パンが有効になる最小スケール
            panEnabled: true,
            // スケールが有効になる最小スケール
            scaleEnabled: true,
            child: Center(
              child: KurageNetworkImage(
                imageUrl: widget.imageUrl,
                fit: widget.fit,
                placeholder: (_, _) => const Center(
                  child: CircularProgressIndicator(color: Colors.white)
                ),
                errorWidget: (_, _, _) => const Icon(
                  Icons.broken_image,
                  size: 80,
                  color: Colors.white
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// ギャラリーの PageView 専用 ScrollBehavior。Flutter デフォルトの
/// dragDevices には mouse が含まれず、Web / デスクトップの狭幅 (フルスクリーン
/// モード) でマウスドラッグによるページ送りができないため、全デバイスを許可
/// する。グローバル (MaterialApp.scrollBehavior) に広げるとタイムライン等の
/// 挙動が変わるため、このビューアに閉じる。
class _GalleryScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}
