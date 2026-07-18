// lib/pages/collection_form_page.dart
//
// Mastodon 4.6+ の Collection の作成 / 編集フォーム。
//  - existing == null: createCollection (新規作成)
//  - existing != null: updateCollection (メタ編集)
// 保存に成功すると結果の Collection を Navigator.pop で返す。メンバーの追加は
// このフォームでは扱わず、プロフィールや投稿メニューの「コレクションに追加」で
// 行う (addCollectionItem)。

import 'package:flutter/material.dart';

import '../models/auth_account.dart';
import '../models/collection.dart';
import '../services/mastodon_api.dart';
import '../utils/snackbar_helpers.dart';

/// 作成/編集フォームを開いて、保存された [Collection] を返す。キャンセル時は null。
Future<Collection?> openCollectionForm(
  BuildContext context, {
  required AuthAccount user,
  Collection? existing,
}) {
  return Navigator.push<Collection>(
    context,
    MaterialPageRoute(
      builder: (_) => CollectionFormPage(user: user, existing: existing),
    ),
  );
}

class CollectionFormPage extends StatefulWidget {
  const CollectionFormPage({
    super.key,
    required this.user,
    this.existing,
  });

  final AuthAccount user;
  final Collection? existing;

  @override
  State<CollectionFormPage> createState() => _CollectionFormPageState();
}

class _CollectionFormPageState extends State<CollectionFormPage> {
  // 仕様上の上限 (name 40 文字 / description 100 文字)。
  static const int _nameMax = 40;
  static const int _descriptionMax = 100;

  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _languageController;
  late final TextEditingController _tagController;

  bool _sensitive = false;
  bool _discoverable = true;
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameController = TextEditingController(text: e?.name ?? '');
    _descriptionController = TextEditingController(text: e?.description ?? '');
    _languageController = TextEditingController(text: e?.language ?? '');
    _tagController = TextEditingController(text: e?.tag?.name ?? '');
    _sensitive = e?.sensitive ?? false;
    _discoverable = e?.discoverable ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _languageController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      showErrorSnackBar(context, '名前を入力してください');
      return;
    }
    setState(() => _saving = true);

    // 空文字は「指定なし」として null で送る。
    final description = _descriptionController.text.trim();
    final language = _languageController.text.trim();
    final tagName = _tagController.text.trim();

    try {
      final Collection result;
      if (_isEdit) {
        result = await updateCollection(
          instanceUrl: widget.user.instanceUrl,
          accessToken: widget.user.accessToken,
          collectionId: widget.existing!.id,
          name: name,
          description: description.isEmpty ? '' : description,
          language: language.isEmpty ? null : language,
          tagName: tagName.isEmpty ? '' : tagName,
          sensitive: _sensitive,
          discoverable: _discoverable,
        );
      } else {
        result = await createCollection(
          instanceUrl: widget.user.instanceUrl,
          accessToken: widget.user.accessToken,
          name: name,
          description: description.isEmpty ? null : description,
          language: language.isEmpty ? null : language,
          tagName: tagName.isEmpty ? null : tagName,
          sensitive: _sensitive,
          discoverable: _discoverable,
        );
      }
      if (!mounted) return;
      Navigator.pop(context, result);
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, '保存できませんでした: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'コレクションを編集' : 'コレクションを作成'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    '保存',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '名前',
                border: OutlineInputBorder(),
              ),
              maxLength: _nameMax,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: '説明 (任意)',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              maxLines: 3,
              maxLength: _descriptionMax,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _tagController,
              decoration: const InputDecoration(
                labelText: '関連ハッシュタグ (任意、# は不要)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _languageController,
              decoration: const InputDecoration(
                labelText: '言語コード (任意、例: ja)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text('閲覧注意 (sensitive)'),
              value: _sensitive,
              onChanged: (v) => setState(() => _sensitive = v),
            ),
            SwitchListTile(
              title: const Text('見つけやすくする (discoverable)'),
              subtitle: const Text('ディレクトリや提案に表示されることを許可'),
              value: _discoverable,
              onChanged: (v) => setState(() => _discoverable = v),
            ),
          ],
        ),
      ),
    );
  }
}
