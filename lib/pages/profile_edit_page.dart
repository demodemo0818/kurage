// lib/pages/profile_edit_page.dart

import 'dart:io' show File;

import 'package:flutter/foundation.dart' show kIsWeb, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../models/auth_account.dart';
import '../models/account.dart';
import '../models/profile.dart';
import '../services/mastodon_api.dart';
import '../providers/auth_provider.dart';
import '../utils/html_parser.dart';
import '../utils/avatar_utils.dart';
import '../utils/snackbar_helpers.dart';

/// プロフィール編集ページ
class ProfileEditPage extends ConsumerStatefulWidget {
  final AuthAccount user;
  final Account profile;
  
  const ProfileEditPage({
    super.key,
    required this.user,
    required this.profile,
  });

  @override
  ConsumerState<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends ConsumerState<ProfileEditPage> {
  late TextEditingController _displayNameController;
  late TextEditingController _noteController;
  final List<Map<String, TextEditingController>> _fieldControllers = [];
  
  bool _isLocked = false;
  bool _isBot = false;
  bool _isSaving = false;

  // ===== 文字数/フィールド数上限 (InstanceConfig 連動、4.6+) =====
  // 取得前は従来のハードコード値を既定にし、取得後 setState で差し替える。
  InstanceConfig? _config;
  int get _maxDisplayName => _config?.maxDisplayNameLength ?? 30;
  int get _maxNote => _config?.maxNoteLength ?? 500;
  int get _maxFields => _config?.maxProfileFields ?? 4;
  int get _fieldNameLimit => _config?.profileFieldNameLimit ?? 255;
  int get _fieldValueLimit => _config?.profileFieldValueLimit ?? 255;

  // ===== 4.6 詳細設定 (GET/PATCH /api/v1/profile) =====
  // 既存フォームとは独立にバックグラウンド取得する。未対応サーバ (404) は
  // セクションごと非表示。
  Profile? _profile; // 取得できた初期値 (差分判定の基準にも使う)
  bool _profileLoading = true;
  bool _profileUnsupported = false;

  late final TextEditingController _avatarDescController =
      TextEditingController();
  late final TextEditingController _headerDescController =
      TextEditingController();
  late final TextEditingController _attribDomainController =
      TextEditingController();

  bool _showMedia = false;
  bool _showMediaReplies = false;
  bool _showFeatured = false;
  bool _hideCollections = false;
  bool _discoverable = false;
  bool _indexable = false;
  List<String> _attributionDomains = [];

  // dart:io File ではなく XFile (cross_file) を使うのは、Web で `File(path)` /
  // `FileImage` が動かないため。`mastodon_api.dart::updateProfile` も XFile を
  // 受け取るシグネチャに揃えてある。
  XFile? _newAvatarFile;
  XFile? _newHeaderFile;

  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _displayNameController = TextEditingController(text: widget.profile.displayName);
    // HTMLタグを除去してプレーンテキストに変換
    _noteController = TextEditingController(text: parseHtmlToPlainText(widget.profile.note));

    _isLocked = widget.profile.locked;
    _isBot = widget.profile.bot;

    // プロフィール補足フィールドの初期化（HTMLタグを除去）
    for (var field in widget.profile.fields) {
      _fieldControllers.add({
        'name': TextEditingController(text: parseHtmlToPlainText(field.name)),
        'value': TextEditingController(text: parseHtmlToPlainText(field.value)),
      });
    }

    // 空のフィールドを (既定 4 つまで) 追加。InstanceConfig 取得後に
    // _maxFields に合わせて追加し直す。
    _ensureFieldSlots(4);

    // 上限と 4.6 詳細設定をバックグラウンドで読み込む。
    _loadInstanceConfig();
    _loadProfileMeta();
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _noteController.dispose();
    _avatarDescController.dispose();
    _headerDescController.dispose();
    _attribDomainController.dispose();
    for (var controllers in _fieldControllers) {
      controllers['name']?.dispose();
      controllers['value']?.dispose();
    }
    super.dispose();
  }

  /// 空のフィールド入力欄を [count] 個まで確保する。
  void _ensureFieldSlots(int count) {
    while (_fieldControllers.length < count) {
      _fieldControllers.add({
        'name': TextEditingController(),
        'value': TextEditingController(),
      });
    }
  }

  /// インスタンスの文字数/フィールド数上限を取得して反映する。失敗しても
  /// 既定のハードコード値で動くので握りつぶす。
  Future<void> _loadInstanceConfig() async {
    try {
      final config = await fetchInstanceConfig(
        instanceUrl: widget.user.instanceUrl,
        accessToken: widget.user.accessToken,
      );
      if (!mounted) return;
      setState(() {
        _config = config;
        _ensureFieldSlots(config.maxProfileFields);
      });
    } catch (_) {
      // 既定値のまま続行。
    }
  }

  /// 4.6 の `GET /api/v1/profile` を取得し、詳細設定セクションの初期値にする。
  Future<void> _loadProfileMeta() async {
    try {
      final profile = await fetchProfile(
        instanceUrl: widget.user.instanceUrl,
        accessToken: widget.user.accessToken,
      );
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _profileLoading = false;
        _avatarDescController.text = profile.avatarDescription ?? '';
        _headerDescController.text = profile.headerDescription ?? '';
        _showMedia = profile.showMedia;
        _showMediaReplies = profile.showMediaReplies;
        _showFeatured = profile.showFeatured;
        _hideCollections = profile.hideCollections ?? false;
        _discoverable = profile.discoverable ?? false;
        _indexable = profile.indexable;
        _attributionDomains = List<String>.from(profile.attributionDomains);
      });
    } on ProfileApiNotSupportedException {
      if (!mounted) return;
      setState(() {
        _profileUnsupported = true;
        _profileLoading = false;
      });
    } catch (_) {
      // 取得失敗 (一時的なネットワーク等): セクションは出さず黙って畳む。
      if (!mounted) return;
      setState(() {
        _profileLoading = false;
        _profileUnsupported = true;
      });
    }
  }

  Future<void> _pickImage(bool isAvatar) async {
    final XFile? image = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: isAvatar ? 400 : 1500,
      maxHeight: isAvatar ? 400 : 500,
    );
    
    if (image != null) {
      setState(() {
        if (isAvatar) {
          _newAvatarFile = image;
        } else {
          _newHeaderFile = image;
        }
      });
    }
  }

  /// 4.6 メタ情報を初期値からの差分だけ `updateProfileMeta` で保存する。
  /// 戻り値: 続行してよいか (true = 成功 / 送る変更なし / 未対応サーバ、
  /// false = 保存失敗したので呼び出し側は pop しない)。
  Future<bool> _saveProfileMeta() async {
    final p = _profile;
    if (p == null) return true; // 未取得 (未対応サーバ含む) → 何もしない。

    final avatarDesc = _avatarDescController.text;
    final headerDesc = _headerDescController.text;
    final changedAvatarDesc = avatarDesc != (p.avatarDescription ?? '');
    final changedHeaderDesc = headerDesc != (p.headerDescription ?? '');
    final changedShowMedia = _showMedia != p.showMedia;
    final changedShowMediaReplies = _showMediaReplies != p.showMediaReplies;
    final changedShowFeatured = _showFeatured != p.showFeatured;
    final changedHideCollections =
        _hideCollections != (p.hideCollections ?? false);
    final changedDiscoverable = _discoverable != (p.discoverable ?? false);
    final changedIndexable = _indexable != p.indexable;
    final changedDomains =
        !listEquals(_attributionDomains, p.attributionDomains);

    final anyChanged = changedAvatarDesc ||
        changedHeaderDesc ||
        changedShowMedia ||
        changedShowMediaReplies ||
        changedShowFeatured ||
        changedHideCollections ||
        changedDiscoverable ||
        changedIndexable ||
        changedDomains;
    if (!anyChanged) return true;

    try {
      // null = 据え置き。変更があったフィールドだけ送る。
      await updateProfileMeta(
        instanceUrl: widget.user.instanceUrl,
        accessToken: widget.user.accessToken,
        avatarDescription: changedAvatarDesc ? avatarDesc : null,
        headerDescription: changedHeaderDesc ? headerDesc : null,
        showMedia: changedShowMedia ? _showMedia : null,
        showMediaReplies: changedShowMediaReplies ? _showMediaReplies : null,
        showFeatured: changedShowFeatured ? _showFeatured : null,
        hideCollections: changedHideCollections ? _hideCollections : null,
        discoverable: changedDiscoverable ? _discoverable : null,
        indexable: changedIndexable ? _indexable : null,
        attributionDomains: changedDomains ? _attributionDomains : null,
      );
      return true;
    } on ProfileApiNotSupportedException {
      // 未対応サーバ: メタは送れないだけ。本体は保存済みなので続行する。
      return true;
    } catch (e) {
      // 422 (バリデーション) 等。本文をそのまま見せて再試行できるようにする。
      if (mounted) {
        showErrorSnackBar(context, '詳細設定の保存に失敗しました: $e');
      }
      return false;
    }
  }

  Future<void> _saveProfile() async {
    setState(() {
      _isSaving = true;
    });

    try {
      // プロフィール補足フィールドの準備
      final fields = <Map<String, String>>[];
      for (var controllers in _fieldControllers) {
        final name = controllers['name']?.text ?? '';
        final value = controllers['value']?.text ?? '';
        if (name.isNotEmpty || value.isNotEmpty) {
          fields.add({'name': name, 'value': value});
        }
      }

      // APIコールでプロフィールを更新
      final updatedAccount = await updateProfile(
        instanceUrl: widget.user.instanceUrl,
        accessToken: widget.user.accessToken,
        displayName: _displayNameController.text,
        note: _noteController.text,
        locked: _isLocked,
        bot: _isBot,
        fields: fields,
        avatarFile: _newAvatarFile,
        headerFile: _newHeaderFile,
      );

      // 4.6 メタ情報 (代替テキスト / タブ表示 / 帰属ドメイン) を差分だけ保存。
      // 画像本体や表示名/note は上の updateProfile が担う棲み分け。
      if (!await _saveProfileMeta()) {
        // メタ保存だけ失敗 (本体は保存済み)。pop せず再試行できるようにする。
        return;
      }

      // AuthProviderのアカウント情報も更新
      await ref.read(authProvider.notifier).updateAccountInfo(
        widget.user.id,
        displayName: updatedAccount.displayName,
        avatarUrl: updatedAccount.avatarUrl,
      );

      // アバターが変更された場合、キャッシュをクリア
      if (_newAvatarFile != null) {
        await AvatarUtils.clearImageCache(widget.profile.avatarUrl);
        await AvatarUtils.clearImageCache(updatedAccount.avatarUrl);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('プロフィールを更新しました')),
        );
        Navigator.pop(context, true); // 更新成功を返す
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(context, 'プロフィールの更新に失敗しました: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('プロフィール編集'),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _saveProfile,
            child: _isSaving 
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            // ヘッダー画像
            _buildHeaderSection(),
            const SizedBox(height: 16),
            
            // アバター画像
            _buildAvatarSection(),
            const SizedBox(height: 24),
            
            // 表示名
            TextField(
              controller: _displayNameController,
              decoration: const InputDecoration(
                labelText: '表示名',
                border: OutlineInputBorder(),
              ),
              maxLength: _maxDisplayName,
            ),
            const SizedBox(height: 16),
            
            // 自己紹介
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(
                labelText: '自己紹介',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              maxLines: 5,
              maxLength: _maxNote,
            ),
            const SizedBox(height: 24),
            
            // プロフィール補足
            const Text(
              'プロフィール補足',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '最大$_maxFieldsつまで設定できます',
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            
            // フィールド入力
            ..._buildFieldInputs(),
            
            const SizedBox(height: 24),
            
            // アカウント設定
            const Text(
              'アカウント設定',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            
            SwitchListTile(
              title: const Text('非公開アカウント'),
              subtitle: const Text('フォローリクエストを承認制にする'),
              value: _isLocked,
              onChanged: (value) {
                setState(() {
                  _isLocked = value;
                });
              },
            ),
            
            SwitchListTile(
              title: const Text('Botアカウント'),
              subtitle: const Text('このアカウントが自動化されていることを示す'),
              value: _isBot,
              onChanged: (value) {
                setState(() {
                  _isBot = value;
                });
              },
            ),

            // 4.6 詳細設定 (代替テキスト / タブ表示 / 帰属ドメイン)
            ..._buildMetaSection(),

            // Androidのナビゲーションバー分の余白を追加
            SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
          ],
        ),
        ),
      ),
    );
  }

  Widget _buildHeaderSection() {
    return GestureDetector(
      onTap: () => _pickImage(false),
      child: Container(
        height: 150,
        decoration: BoxDecoration(
          color: Colors.grey[300],
          image: _newHeaderFile != null
              ? DecorationImage(
                  // Web では XFile.path が blob: URL なので NetworkImage が
                  // 解決できる。モバイル/デスクトップは従来通り FileImage。
                  image: kIsWeb
                      ? NetworkImage(_newHeaderFile!.path)
                      : FileImage(File(_newHeaderFile!.path)) as ImageProvider,
                  fit: BoxFit.cover,
                )
              : widget.profile.headerUrl.isNotEmpty
                  ? DecorationImage(
                      image: NetworkImage(widget.profile.headerUrl),
                      fit: BoxFit.cover,
                    )
                  : null,
        ),
        child: Stack(
          children: [
            Container(
              color: Colors.black26,
              child: const Center(
                child: Icon(
                  Icons.camera_alt,
                  color: Colors.white,
                  size: 40,
                ),
              ),
            ),
            const Positioned(
              bottom: 8,
              right: 8,
              child: Text(
                'タップして変更',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  backgroundColor: Colors.black54,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatarSection() {
    return Center(
      child: GestureDetector(
        onTap: () => _pickImage(true),
        child: Stack(
          children: [
            CircleAvatar(
              radius: 60,
              backgroundImage: _newAvatarFile != null
                  ? (kIsWeb
                      ? NetworkImage(_newAvatarFile!.path)
                      : FileImage(File(_newAvatarFile!.path)) as ImageProvider)
                  : NetworkImage(widget.profile.avatarUrl) as ImageProvider,
            ),
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Colors.blue,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.camera_alt,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 4.6 詳細設定セクション (GET/PATCH /api/v1/profile)。読み込み中はスリムな
  /// インジケータ、未対応サーバ (404) や取得失敗のときは何も出さない。
  List<Widget> _buildMetaSection() {
    if (_profileUnsupported) return const [];
    if (_profileLoading) {
      return const [
        SizedBox(height: 24),
        Center(
          child: Padding(
            padding: EdgeInsets.all(8),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ];
    }

    return [
      const SizedBox(height: 24),
      const Divider(),
      const SizedBox(height: 8),
      const Text(
        '詳細設定 (Mastodon 4.6)',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 16),

      // 画像の代替テキスト
      TextField(
        controller: _avatarDescController,
        decoration: const InputDecoration(
          labelText: 'アバターの代替テキスト',
          helperText: '視覚障碍のある人向けの画像説明',
          border: OutlineInputBorder(),
        ),
        maxLines: 2,
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _headerDescController,
        decoration: const InputDecoration(
          labelText: 'ヘッダーの代替テキスト',
          helperText: '視覚障碍のある人向けの画像説明',
          border: OutlineInputBorder(),
        ),
        maxLines: 2,
      ),
      const SizedBox(height: 16),

      // タブ表示など
      SwitchListTile(
        title: const Text('メディアタブを表示'),
        value: _showMedia,
        onChanged: (v) => setState(() => _showMedia = v),
      ),
      SwitchListTile(
        title: const Text('メディアタブに返信を含める'),
        value: _showMediaReplies,
        onChanged: (v) => setState(() => _showMediaReplies = v),
      ),
      SwitchListTile(
        title: const Text('ピックアップ（注目の投稿）タブを表示'),
        value: _showFeatured,
        onChanged: (v) => setState(() => _showFeatured = v),
      ),
      SwitchListTile(
        title: const Text('フォロー / フォロワーを隠す'),
        value: _hideCollections,
        onChanged: (v) => setState(() => _hideCollections = v),
      ),
      SwitchListTile(
        title: const Text('ディレクトリで見つけやすくする'),
        subtitle: const Text('プロフィールディレクトリや提案に表示されることを許可'),
        value: _discoverable,
        onChanged: (v) => setState(() => _discoverable = v),
      ),
      SwitchListTile(
        title: const Text('検索エンジンのインデックスを許可'),
        value: _indexable,
        onChanged: (v) => setState(() => _indexable = v),
      ),
      const SizedBox(height: 16),

      // 帰属ドメイン (attribution_domains)
      const Text(
        '帰属を許可するドメイン',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      const Text(
        'これらのドメインの記事で、あなたが著者として帰属表示されることを許可します。',
        style: TextStyle(color: Colors.grey, fontSize: 12),
      ),
      const SizedBox(height: 8),
      if (_attributionDomains.isNotEmpty)
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final domain in _attributionDomains)
              Chip(
                label: Text(domain),
                onDeleted: () =>
                    setState(() => _attributionDomains.remove(domain)),
              ),
          ],
        ),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _attribDomainController,
              decoration: const InputDecoration(
                labelText: 'ドメインを追加 (例: example.com)',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _addAttributionDomain(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            icon: const Icon(Icons.add),
            tooltip: '追加',
            onPressed: _addAttributionDomain,
          ),
        ],
      ),
    ];
  }

  void _addAttributionDomain() {
    final raw = _attribDomainController.text.trim().toLowerCase();
    // 入力に http(s):// や末尾スラッシュが付いてもホスト部だけ拾う。
    var domain = raw;
    final parsed = Uri.tryParse(raw.contains('://') ? raw : 'https://$raw');
    if (parsed != null && parsed.host.isNotEmpty) {
      domain = parsed.host;
    }
    if (domain.isEmpty || _attributionDomains.contains(domain)) {
      _attribDomainController.clear();
      return;
    }
    setState(() {
      _attributionDomains.add(domain);
      _attribDomainController.clear();
    });
  }

  List<Widget> _buildFieldInputs() {
    final widgets = <Widget>[];
    
    for (int i = 0; i < _fieldControllers.length; i++) {
      widgets.add(
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                TextField(
                  controller: _fieldControllers[i]['name'],
                  decoration: InputDecoration(
                    labelText: 'ラベル ${i + 1}',
                    border: const OutlineInputBorder(),
                  ),
                  maxLength: _fieldNameLimit,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _fieldControllers[i]['value'],
                  decoration: InputDecoration(
                    labelText: '内容 ${i + 1}',
                    border: const OutlineInputBorder(),
                  ),
                  maxLength: _fieldValueLimit,
                ),
              ],
            ),
          ),
        ),
      );
      widgets.add(const SizedBox(height: 8));
    }
    
    return widgets;
  }
}