// lib/widgets/video_player_widget.dart

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';

import '../l10n/l10n.dart';
import 'network_image_x.dart';

class VideoPlayerWidget extends StatefulWidget {
  final String videoUrl;
  final double? width;
  final double? height;
  final bool autoPlay;
  final bool showControls;
  final bool muted;

  /// 再生終端で先頭に戻ってループ再生するか。
  /// Mastodon の gifv (GIF を mp4 化したもの) はループ再生されるべきなので true で渡す。
  final bool looping;

  /// 音声ファイルとして再生する。映像が無いので、映像の代わりにカバー画像
  /// ([audioCoverUrl]、無ければ音符アイコン) を出し、コントロールを出したままにする。
  final bool isAudio;

  /// 音声のカバー画像 (アルバムアート等) の URL。[isAudio] のときだけ使う。
  final String? audioCoverUrl;

  const VideoPlayerWidget({
    super.key,
    required this.videoUrl,
    this.width,
    this.height,
    this.autoPlay = false,
    this.showControls = true,
    this.muted = true,
    this.looping = false,
    this.isAudio = false,
    this.audioCoverUrl,
  });

  @override
  State<VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> {
  VideoPlayerController? _videoPlayerController;
  ChewieController? _chewieController;
  bool _isInitialized = false;
  bool _hasError = false;
  String? _errorMessage;

  /// 再生が終端に達したか。[_replay] まで維持され、true の間は Chewie を外す。
  /// `isCompleted` とは独立 (終端から離すために seek するので連動させられない)。
  bool _finished = false;

  /// 終端から離す seek が進行中か (多重発行の抑止)。
  bool _seekAwayPending = false;

  /// 終端の連鎖回避 ([_onValueChanged] 参照) が必要なプラットフォームか。
  ///
  /// video_player_win 固有の問題なので Windows のみ。他プラットフォームは
  /// Chewie の標準挙動 (最終フレームのまま + Chewie のリプレイボタン) を保つ。
  /// `dart:io` の `Platform` は Web で throw するため使わない
  /// ([utils/platform.dart](../utils/platform.dart) と同方針)。
  static final bool _needsEndOfPlaybackWorkaround =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// 終端到達を検知し、終端表示に切り替えたうえで再生位置を終端から離す。
  ///
  /// **終端に留まらせてはいけない。** `video_player` は終端イベントを受けるたびに
  /// `pause()` → `seekTo(duration)` を呼ぶが ([video_player.dart] の
  /// `VideoEventType.completed`)、この「終端への seek」が Media Foundation の
  /// `MESessionEnded` を再発火させるため、Windows (video_player_win) では
  /// イベントが延々と往復し、テクスチャが描き直され続けて映像がチカチカする
  /// (GitHub Issue #4。実測で終端到達後 3600 回以上の value 更新を確認)。
  ///
  /// Chewie を外すだけでは止まらない (点滅の実体はネイティブ側の再描画であり、
  /// Dart 側の widget 構成とは無関係) ため、**先頭へ seek して連鎖を断つ**。
  /// `video_player` の `seekTo(duration)` と綱引きになるので、終端へ戻された
  /// ことを検知したら何度でも逃がす。`video_player` 側は `completed` イベントを
  /// 受けたときしか seek しないため、この綱引きは必ず収束する。
  void _onValueChanged() {
    if (!mounted) return;
    if (!_needsEndOfPlaybackWorkaround) return;
    // ループ再生 (gifv) は終端に留まらないので対象外。
    if (widget.looping) return;
    final value = _videoPlayerController?.value;
    if (value == null || !value.isInitialized) return;

    if (!_finished && value.isCompleted) {
      setState(() => _finished = true);
    }
    if (!_finished) return;

    // 終端 (に戻された) 状態なら先頭へ逃がす。
    final atEnd = value.duration > Duration.zero &&
        value.position >= value.duration;
    if (atEnd && !_seekAwayPending) {
      _seekAwayPending = true;
      // video_player 側の pause() → seekTo(duration) が着弾したあとに実行したい
      // ので 1 フレームでは足らず、短い遅延を置く。
      Future.delayed(const Duration(milliseconds: 120), () async {
        _seekAwayPending = false;
        if (!mounted || !_finished) return;
        final controller = _videoPlayerController;
        if (controller == null) return;
        await controller.pause();
        await controller.seekTo(Duration.zero);
      });
    }
  }

  /// 終端表示のリプレイボタン。先頭に戻して再生し直す。
  Future<void> _replay() async {
    final controller = _videoPlayerController;
    if (controller == null) return;
    setState(() => _finished = false);
    await controller.seekTo(Duration.zero);
    await controller.play();
  }

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    try {
      _videoPlayerController = VideoPlayerController.networkUrl(
        Uri.parse(widget.videoUrl),
      );

      await _videoPlayerController!.initialize();

      _videoPlayerController!.addListener(_onValueChanged);

      if (mounted) {
        _chewieController = ChewieController(
          videoPlayerController: _videoPlayerController!,
          autoPlay: widget.autoPlay,
          looping: widget.looping,
          showControls: widget.showControls,
          // 音声は映像サイズが 0 なので正方形 (カバー画像の枠) にする。
          aspectRatio: widget.isAudio
              ? 1.0
              : _videoPlayerController!.value.aspectRatio,
          overlay: widget.isAudio ? _buildAudioCover() : null,
          // 音声は見るものが無いので、コントロールを自動で隠さない。
          hideControlsTimer: widget.isAudio
              ? const Duration(days: 1)
              : ChewieController.defaultHideControlsTimer,
          errorBuilder: (context, errorMessage) {
            return Container(
              color: Colors.black,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.error,
                      color: Colors.white,
                      size: 40,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      context.l10n.videoLoadFailed,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            );
          },
        );

        if (widget.muted) {
          _videoPlayerController!.setVolume(0.0);
        }

        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  void dispose() {
    _videoPlayerController?.removeListener(_onValueChanged);
    _chewieController?.dispose();
    _videoPlayerController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return Container(
        width: widget.width,
        height: widget.height,
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error,
                color: Colors.white,
                size: 40,
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.videoLoadFailed,
                style: const TextStyle(color: Colors.white),
              ),
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      );
    }

    if (!_isInitialized || _chewieController == null) {
      return Container(
        width: widget.width,
        height: widget.height,
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(
            color: Colors.white,
          ),
        ),
      );
    }

    // 終端では Chewie を使わず、最終フレーム + リプレイボタンの静的表示に切り替える。
    // Chewie を挟むと video_player_win が終端で撃ち続ける buffering イベントで
    // ローディング表示とリプレイボタンが交互に描かれて点滅する (Issue #4)。
    // 詳細は [_onValueChanged] のコメント参照。
    Widget player = _finished
        ? _buildFinishedView()
        : Chewie(controller: _chewieController!);

    if (widget.width != null || widget.height != null) {
      player = SizedBox(
        width: widget.width,
        height: widget.height,
        child: player,
      );
    }

    return player;
  }

  /// 再生終了後の表示。最終フレームをそのまま見せ、中央にリプレイボタンを置く。
  Widget _buildFinishedView() {
    final controller = _videoPlayerController!;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.isAudio)
            _buildAudioCover()
          else
            Center(
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black54,
              shape: BoxShape.circle,
            ),
            child: SizedBox(width: 56, height: 56),
          ),
          IconButton(
            iconSize: 32,
            icon: const Icon(Icons.replay, color: Colors.white),
            onPressed: _replay,
          ),
        ],
      ),
    );
  }

  /// 音声の「映像」代わりに出すカバー。カバー画像が無い / 読めない時は音符アイコン。
  /// Chewie は overlay を Stack の直下に置くので、枠いっぱいに広げて返す。
  Widget _buildAudioCover() {
    const fallback = ColoredBox(
      color: Colors.black,
      child: Center(
        child: Icon(Icons.audiotrack, color: Colors.white54, size: 96),
      ),
    );
    final coverUrl = widget.audioCoverUrl;
    return SizedBox.expand(
      child: coverUrl == null
          ? fallback
          : KurageNetworkImage(
              imageUrl: coverUrl,
              fit: BoxFit.contain,
              placeholder: (_, _) => fallback,
              errorWidget: (_, _, _) => fallback,
            ),
    );
  }
}
