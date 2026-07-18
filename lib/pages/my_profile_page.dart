// lib/pages/my_profile_page.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import '../models/auth_account.dart';
import '../widgets/user_avatar.dart';
import 'profile_page.dart';

/// マイプロフィールページ（アカウント選択機能付き）
class MyProfilePage extends ConsumerWidget {
  /// Deck (ワイド) のポップアップで開かれた時に渡される戻る (←) コールバック。
  /// null (ナロー/通常) のときは AppBar に戻る矢印を出さない。
  final VoidCallback? onDeckBack;

  const MyProfilePage({super.key, this.onDeckBack});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);

    // アカウントがない場合
    if (authState.accounts.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          leading:
              onDeckBack == null ? null : BackButton(onPressed: onDeckBack),
          title: const Text('マイプロフィール'),
        ),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.person_off, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text(
                'ログインしたアカウントがありません',
                style: TextStyle(fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }
    
    // アカウントが1つの場合は直接プロフィールページを表示
    if (authState.accounts.length == 1) {
      return ProfilePage(
        user: authState.accounts.first,
        onDeckBack: onDeckBack,
      );
    }

    // 複数アカウントがある場合はアカウント選択ページを表示
    return _AccountSelectionPage(
      accounts: authState.accounts,
      onDeckBack: onDeckBack,
    );
  }
}

/// アカウント選択ページ
class _AccountSelectionPage extends StatelessWidget {
  final List<AuthAccount> accounts;
  final VoidCallback? onDeckBack;

  const _AccountSelectionPage({required this.accounts, this.onDeckBack});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading:
            onDeckBack == null ? null : BackButton(onPressed: onDeckBack),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('マイプロフィール'),
            Text(
              '表示するアカウントを選択してください',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
            ),
          ],
        ),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: accounts.length,
        itemBuilder: (context, index) {
          final account = accounts[index];
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            // ListTile.leading は高さを 56px に制限する (Material 仕様) ため、
            // 60px (radius 30) のアバターを置くと Web の ClipOval が縦に潰れて
            // 横長の楕円になる。プロフィールヘッダと同じく Row で組んで、アバターの
            // 高さが制限されないようにする。
            child: InkWell(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ProfilePage(user: account),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Stack(
                      children: [
                        UserAvatar(
                          url: account.avatarUrl,
                          radius: 30,
                        ),
                        if (account.accountColor != null)
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 18,
                              height: 18,
                              decoration: BoxDecoration(
                                color: account.accountColor,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            account.displayName.isNotEmpty
                                ? account.displayName
                                : account.username,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '@${account.username}',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            Uri.parse(account.instanceUrl).host,
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.arrow_forward_ios, color: Colors.grey),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
