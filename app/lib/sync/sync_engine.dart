import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_time.dart';
import '../data/firestore_repository.dart';
import '../health/health_repository.dart';
import '../health/health_types.dart';
import 'daily_aggregator.dart';

/// 同期の進行状況。UI にそのまま出せる粒度にしてある。
sealed class SyncStatus {
  const SyncStatus();
}

class SyncIdle extends SyncStatus {
  const SyncIdle({this.lastSyncedAt, this.lastResult});
  final DateTime? lastSyncedAt;
  final SyncResult? lastResult;
}

class SyncRunning extends SyncStatus {
  const SyncRunning({required this.message, this.progress});
  final String message;

  /// 0.0-1.0。不定の場合は null。
  final double? progress;
}

class SyncFailed extends SyncStatus {
  const SyncFailed(this.message, {this.detail});
  final String message;
  final Object? detail;
}

/// 1 回の同期の結果。
class SyncResult {
  const SyncResult({
    required this.days,
    required this.documentsWritten,
    required this.pointsFetched,
    required this.from,
    required this.to,
  });

  final int days;
  final int documentsWritten;
  final int pointsFetched;
  final String from;
  final String to;
}

/// Health Connect から読んで集約し、Firestore に書くまでの一連の流れ。
///
/// 差分同期に Health Connect の変更トークンは使っていない。
/// トークンは 30 日で失効するうえ、Mi Fitness はバンドとの同期時に
/// 数日前のデータを後から書き足すことがあり、トークン方式だと取りこぼす。
/// 「直近 N 日を毎回読み直して上書き」のほうが、書き込みが冪等な本設計では堅い。
class SyncEngine extends ChangeNotifier {
  SyncEngine({
    required this.health,
    required this.firestore,
    required this.time,
  });

  final HealthRepository health;
  final FirestoreRepository firestore;
  final AppTime time;

  /// 手動同期で読み直す日数。
  static const foregroundWindowDays = 7;

  /// 定期同期で読み直す日数。
  static const backgroundWindowDays = 3;

  /// 初回バックフィルの日数。READ_HEALTH_DATA_HISTORY が無い場合は
  /// Health Connect 側が 30 日で頭打ちにするので、要求しても害はない。
  static const backfillDays = 90;

  static const _prefsLastSync = 'sync.lastSyncedAtMs';
  static const _prefsBackfilled = 'sync.backfillCompleted';

  SyncStatus _status = const SyncIdle();
  SyncStatus get status => _status;

  void _setStatus(SyncStatus s) {
    _status = s;
    notifyListeners();
  }

  /// 起動時に前回の同期時刻を読み込む。
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_prefsLastSync);
    _setStatus(SyncIdle(
      lastSyncedAt: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms),
    ));
  }

  /// 初回バックフィルが済んでいなければ [backfillDays] 日分、
  /// 済んでいれば直近 [foregroundWindowDays] 日分を同期する。
  Future<SyncResult?> syncNow({bool background = false}) async {
    if (_status is SyncRunning) return null;

    final prefs = await SharedPreferences.getInstance();
    final backfilled = prefs.getBool(_prefsBackfilled) ?? false;
    final windowDays = backfilled
        ? (background ? backgroundWindowDays : foregroundWindowDays)
        : backfillDays;

    try {
      _setStatus(SyncRunning(
        message: backfilled ? '直近 $windowDays 日分を取得中' : '過去 $windowDays 日分を初回取得中',
      ));

      final days = time.lastDays(windowDays);
      final start = time.startOfDay(days.first);
      // 終端は最終日の翌日 00:00。当日の途中までのデータも拾える。
      final end = time.endOfDay(days.last);

      final points = await health.fetch(
        types: health.requestedTypes,
        start: start,
        end: end,
      );

      _setStatus(SyncRunning(message: '${points.length} 件を集計中', progress: 0.5));

      final bundles = DailyAggregator(time: time).aggregate(points: points, days: days);

      if (bundles.isEmpty) {
        // データが 1 件も無いのは、権限が実は下りていないか、
        // Mi Fitness が Health Connect に書いていないかのどちらか。
        // 空振りを成功と report すると原因追及ができなくなるので失敗として扱う。
        _setStatus(const SyncFailed(
          'Health Connect からデータを取得できませんでした',
          detail: 'Mi Fitness の Health Connect 連携が有効か、権限画面で読み取りが許可されているか確認してください。',
        ));
        return null;
      }

      _setStatus(SyncRunning(message: '${bundles.length} 日分を保存中', progress: 0.8));

      final written = await firestore.writeBundles(bundles);
      await firestore.updateSyncState(
        grantedTypes: HealthTypeCatalog.androidTypes.map((t) => t.name).toList(),
        fullBackfill: !backfilled,
      );

      final now = DateTime.now();
      await prefs.setInt(_prefsLastSync, now.millisecondsSinceEpoch);
      await prefs.setBool(_prefsBackfilled, true);

      final result = SyncResult(
        days: bundles.length,
        documentsWritten: written,
        pointsFetched: points.length,
        from: bundles.first.date,
        to: bundles.last.date,
      );
      _setStatus(SyncIdle(lastSyncedAt: now, lastResult: result));
      return result;
    } catch (e, st) {
      debugPrint('同期に失敗: $e\n$st');
      _setStatus(SyncFailed('同期に失敗しました', detail: e));
      return null;
    }
  }

  /// バックフィル済みフラグを消して、次回の同期で全期間を読み直させる。
  /// 集約ロジックを変更したときに使う。
  Future<void> resetBackfill() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsBackfilled);
    _setStatus(const SyncIdle());
  }
}
