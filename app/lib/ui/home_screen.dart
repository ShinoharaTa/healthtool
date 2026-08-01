import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../auth/auth_service.dart';
import '../data/firestore_repository.dart';
import '../models/generated/generated.dart' as m;
import '../sync/sync_engine.dart';
import 'permission_flow.dart';
import 'probe_screen.dart';
import 'trend_chart.dart';

/// 同期の起点と、直近の推移の簡易表示。
/// じっくり見るのは Web ダッシュボードの役目なので、ここは同期の状況が分かれば十分。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.user, required this.auth});

  final User user;
  final AuthService auth;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final FirestoreRepository _repo;
  SyncEngine? _sync;

  @override
  void initState() {
    super.initState();
    _repo = FirestoreRepository(uid: widget.user.uid);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sync != null) return;
    final scope = AppScope.of(context);
    _sync = SyncEngine(health: scope.health, firestore: _repo, time: scope.time)
      ..restore();
    _repo.ensureUserDocument(
      timeZone: scope.time.timeZoneName,
      displayName: widget.user.displayName,
    );
  }

  @override
  void dispose() {
    _sync?.dispose();
    super.dispose();
  }

  Future<void> _runSync() async {
    final scope = AppScope.of(context);
    final ok = await ensureHealthPermissions(context, scope.health);
    if (!ok) return;
    final result = await _sync!.syncNow();
    if (!mounted || result == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${result.from}〜${result.to} の ${result.days} 日分を同期しました')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sync = _sync;
    return Scaffold(
      appBar: AppBar(
        title: const Text('healthtool'),
        actions: [
          IconButton(
            tooltip: '取得できるデータを調べる',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ProbeScreen(health: AppScope.of(context).health),
              ),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              switch (value) {
                case 'signOut':
                  await widget.auth.signOut();
                case 'resetBackfill':
                  await _sync?.resetBackfill();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('次回の同期で過去90日分を読み直します')),
                    );
                  }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'resetBackfill', child: Text('全期間を再取得する')),
              PopupMenuItem(value: 'signOut', child: Text('サインアウト')),
            ],
          ),
        ],
      ),
      body: sync == null
          ? const Center(child: CircularProgressIndicator())
          : ListenableBuilder(
              listenable: sync,
              builder: (context, _) => _body(context, sync),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: sync?.status is SyncRunning ? null : _runSync,
        icon: const Icon(Icons.sync),
        label: const Text('今すぐ同期'),
      ),
    );
  }

  Widget _body(BuildContext context, SyncEngine sync) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _statusCard(context, sync.status),
        const SizedBox(height: 16),
        StreamBuilder<List<m.DailySummary>>(
          stream: _repo.watchDailies(limit: 30),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _message(context, '読み込みに失敗しました: ${snapshot.error}');
            }
            final days = snapshot.data;
            if (days == null) {
              return const Center(child: Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              ));
            }
            if (days.isEmpty) {
              return _message(context, 'まだデータがありません。「今すぐ同期」を実行してください。');
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('直近 ${days.length} 日',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                TrendChart(
                  title: '歩数',
                  unit: '歩',
                  values: [
                    for (final d in days)
                      (d.date, d.activity?.steps?.toDouble()),
                  ],
                ),
                const SizedBox(height: 16),
                TrendChart(
                  title: '睡眠時間',
                  unit: '時間',
                  values: [
                    for (final d in days)
                      (d.date, d.sleep?.totalMin == null ? null : d.sleep!.totalMin! / 60),
                  ],
                ),
                const SizedBox(height: 16),
                TrendChart(
                  title: '安静時心拍',
                  unit: 'bpm',
                  values: [
                    for (final d in days) (d.date, d.hr?.restingBpm),
                  ],
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _statusCard(BuildContext context, SyncStatus status) {
    final theme = Theme.of(context);
    return switch (status) {
      SyncRunning(:final message, :final progress) => Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: progress),
              ],
            ),
          ),
        ),
      SyncFailed(:final message, :final detail) => Card(
          color: theme.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message, style: theme.textTheme.titleSmall),
                if (detail != null) ...[
                  const SizedBox(height: 8),
                  Text('$detail', style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ),
      SyncIdle(:final lastSyncedAt, :final lastResult) => Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  lastSyncedAt == null
                      ? 'まだ同期していません'
                      : '最終同期: ${_formatTime(lastSyncedAt)}',
                  style: theme.textTheme.titleSmall,
                ),
                if (lastResult != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${lastResult.pointsFetched} 件のサンプルから '
                    '${lastResult.days} 日分を作成',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
    };
  }

  Widget _message(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(child: Text(text, textAlign: TextAlign.center)),
      );

  static String _formatTime(DateTime t) {
    final l = t.toLocal();
    return '${l.month}/${l.day} '
        '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }
}
