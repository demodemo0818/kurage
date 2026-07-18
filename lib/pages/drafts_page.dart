import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/draft.dart';

class DraftsPage extends StatefulWidget {
  /// Deck (ワイド) のポップアップで開かれた時に渡される戻る (←) コールバック。
  /// null (ナロー/通常 push) のときは AppBar に通常の戻る矢印を出す。
  final VoidCallback? onDeckBack;

  /// 下書きが選択された時に下書き全体を受け取るコールバック。Deck のポップアップ
  /// は Future を返さないため、選択結果は `Navigator.pop` の戻り値ではなくこれで
  /// 呼び出し元 (投稿欄) に渡す。本文だけでなく CW / 投票も復元できるよう、
  /// content だけでなく Draft をそのまま渡す。指定時は本ページが自身を閉じる。
  final void Function(Draft draft)? onSelected;

  const DraftsPage({super.key, this.onDeckBack, this.onSelected});

  @override
  State<DraftsPage> createState() => _DraftsPageState();
}

class _DraftsPageState extends State<DraftsPage> {
  List<Draft> _drafts = [];

  @override
  void initState() {
    super.initState();
    _loadDrafts();
  }

  Future<void> _loadDrafts() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('post_drafts');
    if (jsonStr != null) {
      final list = (jsonDecode(jsonStr) as List).cast<Map<String, dynamic>>();
      setState(() {
        _drafts = list.map((m) => Draft.fromJson(m)).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      });
    }
  }

  Future<void> _saveAll() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(_drafts.map((d) => d.toJson()).toList());
    await prefs.setString('post_drafts', jsonStr);
  }

  Future<void> _deleteDraft(String id) async {
    setState(() => _drafts.removeWhere((d) => d.id == id));
    await _saveAll();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('下書き一覧'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onDeckBack ?? () => Navigator.pop(context),
        ),
      ),
      body: _drafts.isEmpty
          ? const Center(child: Text('下書きはありません'))
          : ListView.separated(
              itemCount: _drafts.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final d = _drafts[i];
                return ListTile(
                  title: Text(d.title),
                  subtitle: Text(
                    DateFormat('yyyy/MM/dd HH:mm').format(d.createdAt.toLocal()),
                    style: const TextStyle(fontSize: 12),
                  ),
                  onTap: () {
                    if (widget.onSelected != null) {
                      // Deck ポップアップ / 投稿欄から開かれた: 下書きをコール
                      // バックで渡してから自身を閉じる。
                      widget.onSelected!(d);
                      (widget.onDeckBack ?? () => Navigator.pop(context))();
                    } else {
                      // 後方互換 (pop の戻り値で受け取る経路)。
                      Navigator.pop(context, d);
                    }
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () => _deleteDraft(d.id),
                  ),
                );
              },
            ),
    );
  }
}
