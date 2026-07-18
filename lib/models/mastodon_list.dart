// lib/models/mastodon_list.dart

import 'json_utils.dart';

class MastodonList {
  final String id;
  final String title;
  final String repliesPolicy;

  MastodonList({
    required this.id,
    required this.title,
    required this.repliesPolicy,
  });

  factory MastodonList.fromJson(Map<String, dynamic> json) {
    return MastodonList(
      id: asIdString(json['id']),
      title: json['title'] as String? ?? '',
      repliesPolicy: json['replies_policy'] as String? ?? 'list',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'replies_policy': repliesPolicy,
  };
}