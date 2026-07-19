// lib/widgets/link_preview.dart

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../models/preview_card.dart';
import '../providers/settings_provider.dart';
import 'network_image_x.dart';

/// OGP プレビューカード。`Status.card` を Mastodon サーバから受け取って
/// 描画する。クライアント側で OGP 取得しないので、初期描画から最終形まで
/// 高さ変化が起きずタイムラインがガクつかない。
///
/// `layout` で表示スタイルを切替:
/// - `OgpLayout.standard`: 16:9 ヘッダー画像 + 題名 + 説明 + ドメイン (従来)
/// - `OgpLayout.compact`: 左に小サムネ + 右に題名 + ドメインの横並び 1〜2 行
class LinkPreview extends StatelessWidget {
  final PreviewCard card;
  final OgpLayout layout;
  const LinkPreview({
    super.key,
    required this.card,
    this.layout = OgpLayout.standard,
  });

  @override
  Widget build(BuildContext context) {
    if (card.title.isEmpty && card.description.isEmpty && !card.hasImage) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: GestureDetector(
        onTap: () => _open(card.url),
        child: Card(
          clipBehavior: Clip.antiAlias,
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          child: layout == OgpLayout.compact
              ? _buildCompact(context)
              : _buildStandard(context),
        ),
      ),
    );
  }

  // ===== standard (従来) =====

  Widget _buildStandard(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (card.hasImage)
          AspectRatio(
            aspectRatio: 16 / 9,
            child: KurageNetworkImage(
              imageUrl: card.image!,
              fit: BoxFit.cover,
              memCacheWidth: 400,
              fadeInDuration: const Duration(milliseconds: 150),
              fadeOutDuration: const Duration(milliseconds: 100),
              placeholder: (_, _) => Container(
                color: Colors.grey.shade200,
              ),
              errorWidget: (_, _, _) => Container(
                color: Colors.grey.shade200,
                child: Center(
                  child: Icon(
                    Icons.broken_image,
                    size: 40,
                    color: Colors.grey.shade400,
                  ),
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (card.missingAttribution) ...[
                const _AttributionWarning(),
                const SizedBox(height: 6),
              ],
              if (card.title.isNotEmpty)
                Text(
                  card.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              if (card.description.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  card.description,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.grey.shade600,
                      ),
                ),
              ],
              const SizedBox(height: 6),
              _DomainRow(url: card.url),
            ],
          ),
        ),
      ],
    );
  }

  // ===== compact (横並びサムネ) =====

  /// 左サムネのサイズ。タイトル + ドメイン 2 行 と合わせて 1 枚分の高さに
  /// 揃える。`IntrinsicHeight` で右側のテキスト列の高さを取ってそれに合わせる
  /// 方法もあるが、`AspectRatio` を使うとサムネが正方形になり高さがバラつく
  /// ので、固定高 + 1:1 サムネで安定させる。
  static const double _compactThumbSize = 72;

  Widget _buildCompact(BuildContext context) {
    return SizedBox(
      height: _compactThumbSize,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (card.hasImage)
            // SizedBox で width / height を明示し、画像は BoxFit.cover で
            // 正方形に center-crop する。
            //
            // **重要**: `memCacheWidth` と `memCacheHeight` を **両方** 指定
            // しないこと。Flutter の `ResizeImage` はデフォルト
            // `ResizeImagePolicy.exact` で、両方指定すると **アスペクト比を
            // 無視して指定通りのサイズに歪めて** decode する。その後に
            // `BoxFit.cover` をかけても元の比率には戻らないため、元画像が
            // 横長/縦長/正方形で歪み方がバラつく ("潰れたり伸びたり" 現象)。
            // 片方だけ指定すればもう片方はアスペクト比を保って算出される。
            // ここでは長辺 (= width) だけ抑える方針。
            SizedBox(
              width: _compactThumbSize,
              height: _compactThumbSize,
              child: KurageNetworkImage(
                imageUrl: card.image!,
                fit: BoxFit.cover,
                memCacheWidth: 216, // 72px * 3 DPR
                fadeInDuration: const Duration(milliseconds: 150),
                fadeOutDuration: const Duration(milliseconds: 100),
                placeholder: (_, _) => Container(
                  color: Colors.grey.shade200,
                ),
                errorWidget: (_, _, _) => Container(
                  color: Colors.grey.shade200,
                  child: Icon(
                    Icons.broken_image,
                    size: 24,
                    color: Colors.grey.shade400,
                  ),
                ),
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (card.missingAttribution) ...[
                    const _AttributionWarning(dense: true),
                    const SizedBox(height: 2),
                  ],
                  if (card.title.isNotEmpty)
                    Text(
                      card.title,
                      // 警告バッジを出すときは 72px 枠に収めるため 1 行に詰める。
                      maxLines: card.missingAttribution ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                          ),
                    ),
                  const SizedBox(height: 4),
                  _DomainRow(url: card.url, dense: true),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _open(String link) async {
    try {
      final uri = Uri.parse(link);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Failed to launch URL: $e');
    }
  }
}

/// ドメイン (URL のホスト部) を 🔗 アイコンと並べて表示する小要素。
/// standard / compact 両方で使う。
class _DomainRow extends StatelessWidget {
  final String url;
  final bool dense;
  const _DomainRow({required this.url, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final domain = _extractDomain(url);
    return Row(
      children: [
        Icon(
          Icons.link,
          size: dense ? 12 : 14,
          color: Colors.grey.shade500,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            domain,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey.shade500,
                  fontSize: dense ? 11 : null,
                ),
          ),
        ),
      ],
    );
  }

  static String _extractDomain(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }
}

/// `PreviewCard.missingAttribution == true` のとき出す帰属警告バッジ。
///
/// Mastodon 4.6 の `missing_attribution` は「カードに表示される投稿者
/// (著者) を、リンク先サイトが `attribution_domains` で承認していない」=
/// 帰属が裏取りできていない (なりすまし/誤帰属の可能性) を示す。誇張を避け、
/// 「帰属未確認」という事実ベースの表現に留め、詳細は tooltip で補う。
class _AttributionWarning extends StatelessWidget {
  final bool dense;
  const _AttributionWarning({this.dense = false});

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFFB26A00); // amber 系 (ライト/ダーク両対応の落ち着いた橙)
    return Tooltip(
      message: context.l10n.linkAttributionUnverifiedTooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: dense ? 12 : 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              context.l10n.linkAttributionUnverified,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: color,
                    fontSize: dense ? 11 : 12,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
