// lib/models/live_mode.dart

import 'dart:convert';

/// 実況モード設定
class LiveModeSettings {
  /// 実況モードが有効かどうか
  final bool isEnabled;
  
  /// 自動挿入するハッシュタグリスト
  final List<String> hashtags;
  
  /// ハッシュタグを挿入する位置（true: 末尾、false: 先頭）
  final bool insertAtEnd;

  const LiveModeSettings({
    this.isEnabled = false,
    this.hashtags = const [],
    this.insertAtEnd = true,
  });

  /// コピーコンストラクタ
  LiveModeSettings copyWith({
    bool? isEnabled,
    List<String>? hashtags,
    bool? insertAtEnd,
  }) {
    return LiveModeSettings(
      isEnabled: isEnabled ?? this.isEnabled,
      hashtags: hashtags ?? this.hashtags,
      insertAtEnd: insertAtEnd ?? this.insertAtEnd,
    );
  }

  /// JSONからデシリアライズ
  factory LiveModeSettings.fromJson(Map<String, dynamic> json) {
    return LiveModeSettings(
      isEnabled: json['isEnabled'] as bool? ?? false,
      hashtags: (json['hashtags'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList() ?? [],
      insertAtEnd: json['insertAtEnd'] as bool? ?? true,
    );
  }

  /// JSONにシリアライズ
  Map<String, dynamic> toJson() {
    return {
      'isEnabled': isEnabled,
      'hashtags': hashtags,
      'insertAtEnd': insertAtEnd,
    };
  }

  /// SharedPreferences用の文字列に変換
  String toJsonString() {
    return jsonEncode(toJson());
  }

  /// SharedPreferences用の文字列から復元
  factory LiveModeSettings.fromJsonString(String jsonString) {
    try {
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      return LiveModeSettings.fromJson(json);
    } catch (e) {
      return const LiveModeSettings();
    }
  }

  /// ハッシュタグを整形して取得（#を自動付与）
  List<String> get formattedHashtags {
    return hashtags.map((tag) {
      final cleanTag = tag.trim().replaceAll(RegExp(r'^#+'), '');
      return cleanTag.isNotEmpty ? '#$cleanTag' : '';
    }).where((tag) => tag.isNotEmpty).toList();
  }

  /// ハッシュタグ文字列を生成
  String get hashtagString {
    final formatted = formattedHashtags;
    return formatted.isEmpty ? '' : ' ${formatted.join(' ')}';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LiveModeSettings &&
        other.isEnabled == isEnabled &&
        _listEquals(other.hashtags, hashtags) &&
        other.insertAtEnd == insertAtEnd;
  }

  @override
  int get hashCode {
    return isEnabled.hashCode ^
        hashtags.fold(0, (prev, element) => prev ^ element.hashCode) ^
        insertAtEnd.hashCode;
  }

  bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}