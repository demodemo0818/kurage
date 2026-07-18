// lib/models/status_context.dart

import '../models/status.dart'; // 既存の Status モデルを参照

/// Mastodon の /api/v1/statuses/:id/context が返す JSON は以下の形式:
/// {
///   "ancestors": [ ... ],     // 先祖投稿リスト (`List<Status>`)
///   "descendants": [ ... ]    // 子孫投稿リスト (`List<Status>`)
/// }
class StatusContext {
  final List<Status> ancestors;
  final List<Status> descendants;

  StatusContext({
    required this.ancestors,
    required this.descendants,
  });

  factory StatusContext.fromJson(Map<String, dynamic> json) {
    final ancestorsJson = json['ancestors'] as List<dynamic>;
    final descendantsJson = json['descendants'] as List<dynamic>;

    return StatusContext(
      ancestors: ancestorsJson
          .map((j) => Status.fromJson(j as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt)), // 古い順にソート
      descendants: descendantsJson
          .map((j) => Status.fromJson(j as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt)), // 古い順にソート
    );
  }
}
