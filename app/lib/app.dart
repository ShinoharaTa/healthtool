import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'auth/auth_service.dart';
import 'core/app_time.dart';
import 'health/health_repository.dart';
import 'ui/home_screen.dart';
import 'ui/probe_screen.dart';
import 'ui/sign_in_screen.dart';

/// 依存をまとめて下に配る。DI ライブラリを使うほどの規模ではないので
/// InheritedWidget 1 枚で済ませる。
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.time,
    required this.health,
    required this.auth,
    required this.firebaseReady,
    required super.child,
  });

  final AppTime time;
  final HealthRepository health;
  final AuthService? auth;
  final bool firebaseReady;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope が見つかりません');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope old) => false;
}

class HealthToolApp extends StatefulWidget {
  const HealthToolApp({
    super.key,
    required this.time,
    required this.firebaseReady,
    this.firebaseError,
  });

  final AppTime time;
  final bool firebaseReady;
  final Object? firebaseError;

  @override
  State<HealthToolApp> createState() => _HealthToolAppState();
}

class _HealthToolAppState extends State<HealthToolApp> {
  late final HealthRepository _health = HealthRepository();
  late final AuthService? _auth = widget.firebaseReady ? AuthService() : null;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      time: widget.time,
      health: _health,
      auth: _auth,
      firebaseReady: widget.firebaseReady,
      child: MaterialApp(
        title: 'healthtool',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B6EA5)),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF3B6EA5),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: widget.firebaseReady
            ? _AuthGate(auth: _auth!)
            : _LocalOnlyHome(error: widget.firebaseError),
      ),
    );
  }
}

/// サインイン状態で画面を出し分ける。
class _AuthGate extends StatelessWidget {
  const _AuthGate({required this.auth});

  final AuthService auth;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: auth.authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final user = snapshot.data;
        if (user == null) return SignInScreen(auth: auth);
        return HomeScreen(user: user, auth: auth);
      },
    );
  }
}

/// Firebase 未設定時の画面。Health Connect の調査だけはここからできる。
class _LocalOnlyHome extends StatelessWidget {
  const _LocalOnlyHome({this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('healthtool (ローカルモード)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Firebase が未設定です',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'サインインと Firestore への保存は使えません。\n'
                    'Health Connect から何が取得できるかの確認だけ行えます。\n\n'
                    'docs/setup-firebase.md の手順で flutterfire configure を実行してください。',
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text('$error', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.search),
            label: const Text('取得できるデータを調べる'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ProbeScreen(health: scope.health),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
