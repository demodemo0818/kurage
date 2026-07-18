class Draft {
  final String id;
  final String title;
  final String content;
  final DateTime createdAt;

  /// CW (警告文)。未設定の下書きでは null。
  final String? spoilerText;

  /// 投票の選択肢テキスト。投票なしの下書きでは null。
  final List<String>? pollOptions;

  /// 投票が複数選択可か。投票なしでは null。
  final bool? pollMultiple;

  /// 投票期限 (相対秒数。例: 86400 = 1 日)。投票なしでは null。
  final int? pollDuration;

  Draft({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
    this.spoilerText,
    this.pollOptions,
    this.pollMultiple,
    this.pollDuration,
  });

  /// 投票を含む下書きか。
  bool get hasPoll => pollOptions != null && pollOptions!.isNotEmpty;

  // CW / 投票は途中から追加したフィールド。旧データにはキーが無いので、
  // toJson では値があるときだけ書き出し、fromJson では null フォールバックで
  // 後方互換を保つ (既存の下書きはそのまま読める)。
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
        if (spoilerText != null && spoilerText!.isNotEmpty)
          'spoilerText': spoilerText,
        if (pollOptions != null) 'pollOptions': pollOptions,
        if (pollMultiple != null) 'pollMultiple': pollMultiple,
        if (pollDuration != null) 'pollDuration': pollDuration,
      };

  factory Draft.fromJson(Map<String, dynamic> m) => Draft(
        id: m['id'] as String,
        title: m['title'] as String,
        content: m['content'] as String,
        createdAt: DateTime.parse(m['createdAt'] as String),
        spoilerText: m['spoilerText'] as String?,
        pollOptions:
            (m['pollOptions'] as List?)?.map((e) => e.toString()).toList(),
        pollMultiple: m['pollMultiple'] as bool?,
        pollDuration: m['pollDuration'] as int?,
      );
}
