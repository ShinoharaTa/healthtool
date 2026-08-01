import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../auth/auth_service.dart';
import '../data/firestore_repository.dart';
import '../models/generated/generated.dart' as m;
import '../sync/sync_engine.dart';
import 'charts/bedtime_scatter_chart.dart';
import 'charts/chart_palette.dart';
import 'charts/day_slots.dart';
import 'charts/indexed_overlay_chart.dart';
import 'charts/sleep_stage_chart.dart';
import 'charts/trend_chart.dart';
import 'permission_flow.dart';
import 'probe_screen.dart';

/// 表示期間。
enum Period {
  month('30日', 30),
  quarter('90日', 90),
  year('1年', 365);

  const Period(this.label, this.days);
  final String label;
  final int days;
}

/// 同期の起点と、推移の閲覧。
///
/// 日々の数字を眺めるだけなら Mi Fitness で足りる。この画面が引き受けるのは、
/// Mi Fitness では見づらい「長期の推移」「指標をまたいだ比較」「就寝リズムのばらつき」。
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
  Period _period = Period.month;

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
      // FAB の下にグラフが隠れないよう余白を取る。
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
      children: [
        _statusCard(context, sync.status),
        const SizedBox(height: 12),
        _PeriodSelector(
          value: _period,
          onChanged: (p) => setState(() => _period = p),
        ),
        const SizedBox(height: 12),
        StreamBuilder<List<m.DailySummary>>(
          // 期間を変えたらストリームを張り直す。
          key: ValueKey(_period),
          stream: _repo.watchDailies(limit: _period.days),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _message(context, '読み込みに失敗しました: ${snapshot.error}');
            }
            final days = snapshot.data;
            if (days == null) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (days.isEmpty) {
              return _message(context, 'まだデータがありません。「今すぐ同期」を実行してください。');
            }
            return _charts(context, days);
          },
        ),
      ],
    );
  }

  Widget _charts(BuildContext context, List<m.DailySummary> days) {
    final time = AppScope.of(context).time;

    // Firestore は計測が無かった日のドキュメントを持たない。
    // 日付の抜けを埋めてからグラフに渡さないと、欠測期間が詰められて
    // 切れ目のない線として描かれてしまう。
    final slots = denseSlots(days, time);
    final missing = slots.length - days.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            '${slots.first.date} 〜 ${slots.last.date}'
            '（${days.length}日分${missing > 0 ? ' · 欠測 $missing日' : ''}）',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),

        SleepStageChart(days: slots),
        const SizedBox(height: 12),

        BedtimeScatterChart(days: slots, time: time),
        const SizedBox(height: 12),

        // 二軸にせず、それぞれの中央値を 100% として重ねる。
        IndexedOverlayChart(
          title: '睡眠時間と安静時心拍',
          dates: [for (final s in slots) s.date],
          primary: OverlaySeries(
            label: '睡眠時間',
            unit: '分',
            values: [for (final s in slots) s.summary?.sleep?.totalMin],
          ),
          secondary: OverlaySeries(
            label: '安静時心拍',
            unit: 'bpm',
            values: [for (final s in slots) s.summary?.hr?.restingBpm],
            digits: 1,
          ),
        ),
        const SizedBox(height: 12),

        TrendChart(
          title: '歩数',
          unit: '歩',
          values: [
            for (final s in slots) (s.date, s.summary?.activity?.steps?.toDouble()),
          ],
        ),
        const SizedBox(height: 12),

        TrendChart(
          title: '安静時心拍',
          unit: 'bpm',
          digits: 1,
          values: [for (final s in slots) (s.date, s.summary?.hr?.restingBpm)],
        ),
        const SizedBox(height: 12),

        TrendChart(
          title: '推定装着時間',
          unit: '時間',
          digits: 1,
          values: [for (final s in slots) (s.date, s.summary?.coverage.wornHours)],
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
                    '${lastResult.pointsFetched} 件のサンプルから ${lastResult.days} 日分を作成',
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

/// 期間の切り替え。グラフより上に 1 行で置く。
class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({required this.value, required this.onChanged});

  final Period value;
  final ValueChanged<Period> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = ChartPalette.of(context);
    return SegmentedButton<Period>(
      segments: [
        for (final p in Period.values)
          ButtonSegment(value: p, label: Text(p.label)),
      ],
      selected: {value},
      showSelectedIcon: false,
      onSelectionChanged: (s) => onChanged(s.first),
      style: SegmentedButton.styleFrom(
        side: BorderSide(color: palette.axis),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
