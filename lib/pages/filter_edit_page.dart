// lib/pages/filter_edit_page.dart
//
// フィルタの新規作成 / 編集フォーム。
// - タイトル
// - 適用先コンテキスト (multi-select)
// - 失効: 無期限 / 30 分 / 1 時間 / 6 時間 / 12 時間 / 1 日 / 1 週間
// - フィルタアクション (warn / hide)
// - キーワード (text + whole_word toggle, 追加/削除)
//
// 保存に成功すると pop で MastodonFilter を返す (一覧側で list 更新に使う)。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/auth_account.dart';
import '../models/filter.dart';
import '../services/mastodon_api.dart';
import '../utils/snackbar_helpers.dart';

class FilterEditPage extends StatefulWidget {
  final AuthAccount auth;
  /// 編集時は既存の MastodonFilter を渡す。null なら新規作成モード。
  final MastodonFilter? existing;

  const FilterEditPage({super.key, required this.auth, this.existing});

  @override
  State<FilterEditPage> createState() => _FilterEditPageState();
}

class _FilterEditPageState extends State<FilterEditPage> {
  final _titleController = TextEditingController();
  final Set<String> _selectedContexts = {};
  String _filterAction = 'warn';

  /// 失効までの秒数。null は「無期限」。
  /// 編集時で既存フィルタが期限指定持ちのときは「変更しない」を選べるよう
  /// _expirationChanged フラグで保存時に送信を制御する。
  int? _expiresIn;
  bool _expirationChanged = false;

  /// 現在のキーワード一覧 (編集中の素朴な編集モデル)。
  /// - 新規追加分: id == null
  /// - 既存変更分: id 付き、destroy=false
  /// - 削除予定: id 付き、destroy=true
  final List<_KeywordRow> _rows = [];

  bool _saving = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _titleController.text = e.title;
      _selectedContexts.addAll(e.context);
      _filterAction = e.filterAction;
      for (final k in e.keywords) {
        _rows.add(_KeywordRow(
          id: k.id,
          keyword: k.keyword,
          wholeWord: k.wholeWord,
        ));
      }
    } else {
      // 新規はデフォルトでホームと公開を ON
      _selectedContexts.addAll(['home', 'public']);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    for (final r in _rows) {
      r.controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      showErrorSnackBar(context, 'タイトルを入力してください');
      return;
    }
    if (_selectedContexts.isEmpty) {
      showErrorSnackBar(context, '適用先を1つ以上選択してください');
      return;
    }

    setState(() => _saving = true);
    try {
      MastodonFilter result;
      if (_isEditing) {
        result = await updateFilter(
          instanceUrl: widget.auth.instanceUrl,
          accessToken: widget.auth.accessToken,
          filterId: widget.existing!.id,
          title: title,
          context: _selectedContexts.toList(),
          filterAction: _filterAction,
          expiresIn: _expirationChanged ? _expiresIn : null,
          keywordOps: _rows
              .where((r) =>
                  // 新規/変更/削除のいずれか。空行は無視。
                  r.id != null || r.keyword.isNotEmpty)
              .map((r) => (
                    id: r.id,
                    keyword: r.keyword,
                    wholeWord: r.wholeWord,
                    destroy: r.destroy,
                  ))
              .toList(),
        );
      } else {
        result = await createFilter(
          instanceUrl: widget.auth.instanceUrl,
          accessToken: widget.auth.accessToken,
          title: title,
          context: _selectedContexts.toList(),
          filterAction: _filterAction,
          expiresIn: _expiresIn,
          keywords: _rows
              .where((r) => !r.destroy && r.keyword.isNotEmpty)
              .map((r) => (keyword: r.keyword, wholeWord: r.wholeWord))
              .toList(),
        );
      }
      if (!mounted) return;
      Navigator.pop(context, result);
    } on FiltersNotSupportedException catch (_) {
      if (!mounted) return;
      showErrorSnackBar(context, 'このサーバはフィルタ機能に未対応です');
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, '保存に失敗しました: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _addKeywordRow() {
    setState(() {
      _rows.add(_KeywordRow(id: null, keyword: '', wholeWord: false));
    });
  }

  void _removeRow(int index) {
    setState(() {
      final r = _rows[index];
      if (r.id == null) {
        _rows.removeAt(index);
      } else {
        // 既存キーワードは destroy フラグを立てて保存時に送る
        r.destroy = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'フィルタを編集' : 'フィルタを作成'),
        actions: [
          // 色を明示しないことで AppBar の foregroundColor (ライトでは黒,
          // ダークでは白) を継承する。元の `onPrimary` 指定はダーク AppBar 上で
          // 暗い文字色になり見えづらかったため撤去。`onPressed: null` のとき
          // TextButton が自動で disabled 表現にしてくれる。
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中…' : '保存'),
          ),
        ],
      ),
      body: ListView(
        // 下端は Android のシステムナビゲーションバー (3 ボタン / ジェスチャ
        // バー) と被らないよう viewPadding.bottom 分だけ余白を追加する。
        // edge-to-edge 表示時に最後のキーワード行や削除ボタンがバー裏に
        // 隠れてタップしづらくなるのを防ぐ。
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          // タイトル
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: 'タイトル',
              border: OutlineInputBorder(),
            ),
            inputFormatters: [LengthLimitingTextInputFormatter(200)],
          ),
          const SizedBox(height: 24),

          // 適用先 context
          Text(
            '適用先',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'このフィルタを効かせる画面を選択 (複数可)',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          ...kFilterContextLabels.entries.map((entry) {
            return CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(entry.value),
              value: _selectedContexts.contains(entry.key),
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    _selectedContexts.add(entry.key);
                  } else {
                    _selectedContexts.remove(entry.key);
                  }
                });
              },
            );
          }),

          const SizedBox(height: 16),

          // フィルタアクション
          Text(
            'マッチしたときの挙動',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: _filterAction,
            onChanged: (v) {
              if (v != null) setState(() => _filterAction = v);
            },
            child: Column(
              children: [
                for (final entry in kFilterActionLabels.entries)
                  RadioListTile<String>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry.value),
                    value: entry.key,
                  ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // 失効
          Text(
            '失効',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          _buildExpirationPicker(),

          const SizedBox(height: 24),

          // キーワード
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'キーワード',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              TextButton.icon(
                onPressed: _addKeywordRow,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('追加'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '完全一致 ON: 単語の境界でのみマッチ (例: 「猫」は「猫田」にマッチしない)',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          ..._rows.asMap().entries.where((e) => !e.value.destroy).map((e) {
            final i = e.key;
            final r = e.value;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        hintText: 'キーワード',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      controller: r.controller,
                      onChanged: (v) => r.keyword = v,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    children: [
                      const Text('完全一致', style: TextStyle(fontSize: 11)),
                      Switch(
                        value: r.wholeWord,
                        onChanged: (v) =>
                            setState(() => r.wholeWord = v),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    color: Colors.red,
                    onPressed: () => _removeRow(i),
                  ),
                ],
              ),
            );
          }),
          if (_rows.where((r) => !r.destroy).isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'キーワードがありません。「追加」から登録してください。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  static const Map<int?, String> _expirationLabels = {
    null: '無期限',
    30 * 60: '30 分',
    60 * 60: '1 時間',
    6 * 60 * 60: '6 時間',
    12 * 60 * 60: '12 時間',
    24 * 60 * 60: '1 日',
    7 * 24 * 60 * 60: '1 週間',
  };

  Widget _buildExpirationPicker() {
    // _isEditing で _expirationChanged == false のときは、現在の期限を表示するだけ。
    String currentLabel;
    if (_isEditing && !_expirationChanged) {
      final exp = widget.existing!.expiresAt;
      if (exp == null) {
        currentLabel = '無期限';
      } else if (exp.isBefore(DateTime.now())) {
        currentLabel = '期限切れ';
      } else {
        currentLabel = exp.toLocal().toString();
      }
    } else {
      currentLabel = _expirationLabels[_expiresIn] ?? '無期限';
    }

    return Row(
      children: [
        Expanded(child: Text(currentLabel)),
        TextButton(
          onPressed: () async {
            final picked = await showDialog<({bool ok, int? value})>(
              context: context,
              builder: (ctx) {
                int? selection = _expiresIn;
                return StatefulBuilder(builder: (ctx, setSt) {
                  return AlertDialog(
                    title: const Text('失効までの期間'),
                    content: SizedBox(
                      width: double.maxFinite,
                      // 「無期限」の value が null のため T = int? を使う。
                      // RadioGroup の onChanged に来る null は「無期限を選択」
                      // と同義なのでそのまま代入してよい (旧実装と同じ挙動)。
                      child: RadioGroup<int?>(
                        groupValue: selection,
                        onChanged: (v) => setSt(() => selection = v),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final entry in _expirationLabels.entries)
                              RadioListTile<int?>(
                                dense: true,
                                title: Text(entry.value),
                                value: entry.key,
                              ),
                          ],
                        ),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('キャンセル'),
                      ),
                      ElevatedButton(
                        onPressed: () =>
                            Navigator.pop(ctx, (ok: true, value: selection)),
                        child: const Text('決定'),
                      ),
                    ],
                  );
                });
              },
            );
            if (!mounted) return;
            if (picked == null) return; // キャンセル
            setState(() {
              _expiresIn = picked.value;
              _expirationChanged = true;
            });
          },
          child: const Text('変更'),
        ),
      ],
    );
  }
}

/// フォーム編集中のキーワード行。`destroy` は削除ボタン押下時に true へ
/// 切り替わり、保存時に `_destroy=true` で送られる。
///
/// `controller` は行ごとに 1 個保持。setState で行リスト全体が再 build される
/// 際に controller を毎回新規作成すると、編集中のカーソル位置がリセット
/// される / IME 候補が消えるので、行と一緒に持つ。`_FilterEditPageState.dispose`
/// でまとめて dispose する。
class _KeywordRow {
  String? id;
  String keyword;
  bool wholeWord;
  bool destroy = false;
  final TextEditingController controller;

  _KeywordRow({
    this.id,
    required this.keyword,
    required this.wholeWord,
  }) : controller = TextEditingController(text: keyword);
}
