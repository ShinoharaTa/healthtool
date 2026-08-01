import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/generated/generated.dart' as m;
import '../sync/daily_aggregator.dart';

/// Firestore への読み書き。パス構成は packages/schema/src/index.ts の `paths` と対応する。
///
/// 書き込みはすべてドキュメント ID を決め打ちにして冪等にしてある。
/// 同じ期間を何度同期しても増殖せず、後から Health Connect 側のデータが
/// 修正された場合は上書きで追従する。
class FirestoreRepository {
  FirestoreRepository({required this.uid, FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final String uid;
  final FirebaseFirestore _db;

  /// Firestore のバッチ上限は 500 操作。余裕をみて分割する。
  static const _batchLimit = 400;

  DocumentReference<Map<String, dynamic>> get _userDoc => _db.doc('users/$uid');
  CollectionReference<Map<String, dynamic>> get _dailyCol => _userDoc.collection('daily');

  /// 初回サインイン時にユーザードキュメントを用意する。既存の設定は壊さない。
  Future<void> ensureUserDocument({
    required String timeZone,
    String? displayName,
  }) async {
    await _userDoc.set({
      'profile': {
        'displayName': ?displayName,
        'timezone': timeZone,
      },
      'settings': {
        'locale': 'ja',
        'weeklyReport': true,
      },
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// 同期の進捗を記録する。次回どこから読み直すかの判断に使う。
  Future<void> updateSyncState({
    required List<String> grantedTypes,
    bool fullBackfill = false,
  }) async {
    await _userDoc.set({
      'syncState': {
        'lastSyncedAt': FieldValue.serverTimestamp(),
        if (fullBackfill) 'lastFullBackfillAt': FieldValue.serverTimestamp(),
        'grantedTypes': grantedTypes,
      },
    }, SetOptions(merge: true));
  }

  Future<Map<String, dynamic>?> readSyncState() async {
    final snap = await _userDoc.get();
    return snap.data()?['syncState'] as Map<String, dynamic>?;
  }

  /// 集約結果をまとめて書き込む。
  ///
  /// daily は日付が ID なので上書きで冪等。睡眠とワークアウトは Health Connect の
  /// レコード ID をそのまま使うため、再同期で重複しない。
  /// 戻り値は書き込んだドキュメント数。
  Future<int> writeBundles(List<DayBundle> bundles) async {
    final ops = <void Function(WriteBatch)>[];

    for (final bundle in bundles) {
      final dailyRef = _dailyCol.doc(bundle.date);
      ops.add((b) => b.set(dailyRef, bundle.summary.toJson()));

      if (bundle.hrBins.isNotEmpty) {
        // 5分ビンは 1 日 1 ドキュメントにまとめる。1 サンプル 1 ドキュメントにすると
        // 読み取り課金が 2 桁増えるうえ、グラフ描画で毎回 288 回読むことになる。
        ops.add((b) => b.set(dailyRef.collection('intraday').doc('hr'), {
              'date': bundle.date,
              'binMinutes': kHrBinMinutes,
              'samples': bundle.hrBins.map((e) => e.toJson()).toList(),
              'updatedAt': bundle.summary.updatedAt.toIso8601String(),
            }));
      }

      for (final s in bundle.sleepSessions) {
        ops.add((b) => b.set(_userDoc.collection('sleepSessions').doc(s.id), s.toJson()));
      }
      for (final w in bundle.workouts) {
        ops.add((b) => b.set(_userDoc.collection('workouts').doc(w.id), w.toJson()));
      }
    }

    for (var i = 0; i < ops.length; i += _batchLimit) {
      final batch = _db.batch();
      for (final op in ops.skip(i).take(_batchLimit)) {
        op(batch);
      }
      await batch.commit();
    }
    return ops.length;
  }

  /// 期間内の日次サマリーを新しい順に読む。ダッシュボードと簡易グラフ用。
  Stream<List<m.DailySummary>> watchDailies({int limit = 30}) {
    return _dailyCol
        .orderBy(FieldPath.documentId, descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => m.DailySummary.fromJson(d.data()))
            .toList()
            .reversed
            .toList());
  }

  /// すでに同期済みの日付。差分同期の判定に使う。
  Future<Set<String>> syncedDates({required String from, required String to}) async {
    final snap = await _dailyCol
        .orderBy(FieldPath.documentId)
        .startAt([from])
        .endAt([to])
        .get();
    return snap.docs.map((d) => d.id).toSet();
  }
}
