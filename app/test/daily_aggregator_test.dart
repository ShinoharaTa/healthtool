import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:healthtool/core/app_time.dart';
import 'package:healthtool/models/generated/generated.dart' as m;
import 'package:healthtool/sync/daily_aggregator.dart';

/// テスト用の HealthDataPoint を組み立てる。
///
/// 時刻は JST で指定する。実機から返るのは UTC の DateTime だが、
/// 日境界の扱いを検証したいので入力側は人間が読める JST で書く。
HealthDataPoint point(
  HealthDataType type, {
  required String from,
  String? to,
  num value = 0,
  String uuid = 'uuid',
  String source = 'com.mi.health',
}) {
  final start = DateTime.parse('$from+09:00');
  final end = to == null ? start : DateTime.parse('$to+09:00');
  return HealthDataPoint(
    uuid: uuid,
    value: NumericHealthValue(numericValue: value),
    type: type,
    unit: HealthDataUnit.COUNT,
    dateFrom: start,
    dateTo: end,
    sourcePlatform: HealthPlatformType.googleHealthConnect,
    sourceDeviceId: 'device',
    sourceId: source,
    sourceName: 'Mi Fitness',
  );
}

void main() {
  final time = AppTime.init('Asia/Tokyo');
  final fixedNow = DateTime.utc(2026, 8, 1, 12);
  final aggregator = DailyAggregator(time: time, nowOverride: fixedNow);

  List<DayBundle> run(List<HealthDataPoint> points, List<String> days) =>
      aggregator.aggregate(points: points, days: days);

  group('日境界の切り出し', () {
    test('データが1件も無い日は出力しない', () {
      final out = run([], ['2026-07-30', '2026-07-31']);
      expect(out, isEmpty);
    });

    test('深夜をまたぐ歩数レコードは期間の中点が属する日に入る', () {
      // 23:50-00:10 の記録。中点は 00:00 なので翌日側。
      final out = run(
        [point(HealthDataType.STEPS, from: '2026-07-30T23:50:00', to: '2026-07-31T00:10:00', value: 100)],
        ['2026-07-30', '2026-07-31'],
      );
      expect(out.map((b) => b.date), ['2026-07-31']);
      expect(out.single.summary.activity?.steps, 100);
    });

    test('要求していない日のデータは捨てる', () {
      final out = run(
        [
          point(HealthDataType.STEPS, from: '2026-07-25T10:00:00', to: '2026-07-25T10:10:00', value: 500),
          point(HealthDataType.STEPS, from: '2026-07-31T10:00:00', to: '2026-07-31T10:10:00', value: 300),
        ],
        ['2026-07-31'],
      );
      expect(out.map((b) => b.date), ['2026-07-31']);
      expect(out.single.summary.activity?.steps, 300);
    });
  });

  group('心拍', () {
    test('5分ビンに畳み、平均・最小・最大・装着時間を出す', () {
      final points = [
        // 10:00-10:04 の 3 サンプル → 同じビンにまとまる
        point(HealthDataType.HEART_RATE, from: '2026-07-31T10:00:00', value: 60),
        point(HealthDataType.HEART_RATE, from: '2026-07-31T10:02:00', value: 70),
        point(HealthDataType.HEART_RATE, from: '2026-07-31T10:04:00', value: 80),
        // 別のビン
        point(HealthDataType.HEART_RATE, from: '2026-07-31T11:00:00', value: 100),
      ];
      final b = run(points, ['2026-07-31']).single;

      expect(b.hrBins.length, 2, reason: '10:00台の3点は1ビンに畳まれる');
      expect(b.hrBins.first.bpm, closeTo(70, 0.01));
      expect(b.summary.hr?.avgBpm, closeTo(77.5, 0.01));
      expect(b.summary.hr?.minBpm, 60);
      expect(b.summary.hr?.maxBpm, 100);
      expect(b.summary.hr?.sampleCount, 4);
      // ビン2つ × 5分
      expect(b.summary.coverage.hrCoveredMin, 10);
      expect(b.summary.coverage.wornHours, closeTo(0.17, 0.01));
    });

    test('安静時心拍はその日の平均を採る', () {
      final b = run([
        point(HealthDataType.RESTING_HEART_RATE, from: '2026-07-31T04:00:00', value: 54),
        point(HealthDataType.RESTING_HEART_RATE, from: '2026-07-31T05:00:00', value: 58),
      ], ['2026-07-31']).single;
      expect(b.summary.hr?.restingBpm, 56);
    });
  });

  group('睡眠', () {
    /// 前夜 23:00 就寝、翌 07:00 起床のセッションとステージ。
    List<HealthDataPoint> nightOf31() => [
          point(HealthDataType.SLEEP_SESSION,
              from: '2026-07-30T23:00:00', to: '2026-07-31T07:00:00', uuid: 'sess-1'),
          point(HealthDataType.SLEEP_DEEP,
              from: '2026-07-30T23:30:00', to: '2026-07-31T01:00:00', uuid: 'd1'),
          point(HealthDataType.SLEEP_REM,
              from: '2026-07-31T01:00:00', to: '2026-07-31T02:00:00', uuid: 'r1'),
          point(HealthDataType.SLEEP_LIGHT,
              from: '2026-07-31T02:00:00', to: '2026-07-31T06:30:00', uuid: 'l1'),
          point(HealthDataType.SLEEP_AWAKE,
              from: '2026-07-31T06:30:00', to: '2026-07-31T07:00:00', uuid: 'a1'),
        ];

    test('起床日に割り当てられる（就寝日ではない）', () {
      final out = run(nightOf31(), ['2026-07-30', '2026-07-31']);
      expect(out.map((b) => b.date), ['2026-07-31']);
    });

    test('ステージ別の分数と睡眠効率を計算する', () {
      final sleep = run(nightOf31(), ['2026-07-31']).single.summary.sleep!;

      expect(sleep.deepMin, 90);
      expect(sleep.remMin, 60);
      expect(sleep.lightMin, 270);
      expect(sleep.awakeMin, 30);
      // 覚醒は睡眠時間に含めない
      expect(sleep.totalMin, 420);
      expect(sleep.inBedMin, 480);
      expect(sleep.efficiencyPct, closeTo(87.5, 0.01));
      expect(sleep.sessionIds, ['sess-1']);
    });

    test('mid-sleep は就寝と起床の中点になる', () {
      final sleep = run(nightOf31(), ['2026-07-31']).single.summary.sleep!;
      // 23:00 と 07:00 の中点 = 03:00 JST = 18:00 UTC 前日
      expect(sleep.midSleepAt!.toUtc(), DateTime.utc(2026, 7, 30, 18));
    });

    test('セッションレコードが無くてもステージから睡眠区間を復元する', () {
      final stagesOnly = nightOf31().where((p) => p.type != HealthDataType.SLEEP_SESSION).toList();
      final b = run(stagesOnly, ['2026-07-31']).single;

      expect(b.sleepSessions.length, 1);
      expect(b.sleepSessions.single.startAt.toUtc(), DateTime.utc(2026, 7, 30, 14, 30));
      expect(b.sleepSessions.single.endAt.toUtc(), DateTime.utc(2026, 7, 30, 22));
      expect(b.summary.sleep?.deepMin, 90);
    });

    test('60分以上空いたステージは別の睡眠として分ける（昼寝）', () {
      final points = [
        point(HealthDataType.SLEEP_LIGHT,
            from: '2026-07-31T01:00:00', to: '2026-07-31T05:00:00', uuid: 'night'),
        point(HealthDataType.SLEEP_LIGHT,
            from: '2026-07-31T14:00:00', to: '2026-07-31T15:00:00', uuid: 'nap'),
      ];
      final b = run(points, ['2026-07-31']).single;
      expect(b.sleepSessions.length, 2);
      expect(b.summary.sleep?.lightMin, 300);
    });

    test('ステージを出さないデバイスでも unknown 区間として睡眠時間が残る', () {
      final b = run([
        point(HealthDataType.SLEEP_SESSION,
            from: '2026-07-30T23:00:00', to: '2026-07-31T06:00:00', uuid: 's'),
      ], ['2026-07-31']).single;

      expect(b.summary.sleep?.unknownMin, 420);
      expect(b.summary.sleep?.totalMin, 420);
      expect(b.summary.sleep?.deepMin, 0);
    });
  });

  group('欠損の扱い', () {
    test('取得できなかった指標グループは null になる（空オブジェクトを書かない）', () {
      final b = run([
        point(HealthDataType.STEPS, from: '2026-07-31T10:00:00', to: '2026-07-31T10:10:00', value: 1000),
      ], ['2026-07-31']).single;

      expect(b.summary.activity?.steps, 1000);
      expect(b.summary.hr, isNull, reason: '心拍が無い日は hr ごと null');
      expect(b.summary.spo2, isNull);
      expect(b.summary.sleep, isNull);
      expect(b.summary.workouts, isNull);
      expect(b.summary.coverage.hasSleep, isFalse);
      expect(b.summary.coverage.hasSteps, isTrue);
      expect(b.summary.coverage.hrCoveredMin, 0);
    });

    test('SpO2 が比率で返る端末でも百分率に揃える', () {
      final b = run([
        point(HealthDataType.BLOOD_OXYGEN, from: '2026-07-31T03:00:00', value: 0.97),
        point(HealthDataType.BLOOD_OXYGEN, from: '2026-07-31T04:00:00', value: 0.95),
      ], ['2026-07-31']).single;

      expect(b.summary.spo2?.avgPct, closeTo(96, 0.01));
      expect(b.summary.spo2?.minPct, closeTo(95, 0.01));
    });

    test('心拍変動は Android では RMSSD のみ埋まり SDNN は null のまま', () {
      final b = run([
        point(HealthDataType.HEART_RATE_VARIABILITY_RMSSD, from: '2026-07-31T03:00:00', value: 42),
      ], ['2026-07-31']).single;

      expect(b.summary.hrv?.rmssdMs, 42);
      expect(b.summary.hrv?.sdnnMs, isNull);
    });
  });

  group('ワークアウト', () {
    test('種別ごとに回数と分数を集計する', () {
      final walk = HealthDataPoint(
        uuid: 'w1',
        value: WorkoutHealthValue(
          workoutActivityType: HealthWorkoutActivityType.WALKING,
          totalEnergyBurned: 120,
          totalDistance: 3000,
          totalSteps: 4000,
        ),
        type: HealthDataType.WORKOUT,
        unit: HealthDataUnit.NO_UNIT,
        dateFrom: DateTime.parse('2026-07-31T18:00:00+09:00'),
        dateTo: DateTime.parse('2026-07-31T18:45:00+09:00'),
        sourcePlatform: HealthPlatformType.googleHealthConnect,
        sourceDeviceId: 'device',
        sourceId: 'com.mi.health',
        sourceName: 'Mi Fitness',
      );

      final b = run([walk], ['2026-07-31']).single;

      expect(b.workouts.single.type, 'WALKING');
      expect(b.workouts.single.durationMin, 45);
      expect(b.workouts.single.kcal, 120);
      expect(b.summary.workouts?.count, 1);
      expect(b.summary.workouts?.totalMin, 45);
      expect(b.summary.workouts?.byType?['WALKING']?.count, 1);
      expect(b.summary.activity?.exerciseMin, 45);
    });
  });

  group('メタ情報', () {
    test('tz とデータ提供元を記録する', () {
      final b = run([
        point(HealthDataType.STEPS,
            from: '2026-07-31T10:00:00', to: '2026-07-31T10:10:00', value: 10, source: 'com.mi.health'),
      ], ['2026-07-31']).single;

      expect(b.summary.tz, 'Asia/Tokyo');
      expect(b.summary.sources, ['com.mi.health']);
      expect(b.summary.schemaVersion, 1);
      expect(b.summary.updatedAt, fixedNow);
    });

    test('JSON に落として復元できる', () {
      final b = run(nightOfSimple(), ['2026-07-31']).single;
      final json = b.summary.toJson();
      final restored = m.DailySummary.fromJson(json);

      expect(restored.date, '2026-07-31');
      expect(restored.sleep?.totalMin, b.summary.sleep?.totalMin);
      expect(json['updatedAt'], isA<String>(), reason: 'Firestore には ISO 8601 文字列で入れる');
    });
  });
}

List<HealthDataPoint> nightOfSimple() => [
      point(HealthDataType.SLEEP_SESSION,
          from: '2026-07-30T23:00:00', to: '2026-07-31T07:00:00', uuid: 's'),
    ];
