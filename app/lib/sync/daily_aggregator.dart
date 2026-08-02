import 'package:health/health.dart';

import '../core/app_time.dart';
import '../models/generated/generated.dart' as m;

/// 心拍を間引くビンの幅（分）。
/// 1日 288 点になり、Firestore の 1MB 制限に対して十分小さい。
const kHrBinMinutes = 5;

/// 5分ビンに畳んだ心拍。日内グラフ用。
class HrBin {
  const HrBin({required this.at, required this.bpm});

  /// ビンの開始時刻。
  final DateTime at;

  /// ビン内の平均心拍。
  final double bpm;

  Map<String, dynamic> toJson() => {
    't': at.toIso8601String(),
    'bpm': double.parse(bpm.toStringAsFixed(1)),
  };
}

/// 1日分の集約結果一式。
class DayBundle {
  const DayBundle({
    required this.date,
    required this.summary,
    required this.sleepSessions,
    required this.workouts,
    required this.hrBins,
  });

  final String date;
  final m.DailySummary summary;
  final List<m.SleepSession> sleepSessions;
  final List<m.Workout> workouts;
  final List<HrBin> hrBins;
}

/// Health Connect の生サンプルを日次集約に畳む。
///
/// Firebase にも Flutter のウィジェットにも依存しない純粋なロジックにしてある。
/// ここが同期処理で唯一「間違え方が静かな」部分なので、単体テストで固める前提。
class DailyAggregator {
  DailyAggregator({required this.time, this.nowOverride});

  final AppTime time;

  /// updatedAt に使う時刻。テストで固定するために差し替えられるようにしてある。
  final DateTime? nowOverride;

  DateTime get _now => nowOverride ?? DateTime.now().toUtc();

  /// [points] を暦日ごとに集約する。
  ///
  /// [days] に挙げた日だけを出力する。データが 1 件も無い日は結果に含めない
  /// （空の daily ドキュメントを書くと「計測ゼロ」と「未同期」が区別できなくなるため）。
  List<DayBundle> aggregate({
    required List<HealthDataPoint> points,
    required List<String> days,
  }) {
    final wanted = days.toSet();

    // 種別ごとに分けてから日ごとに配る。睡眠だけは起床日基準で配るので別扱い。
    final byDay = <String, List<HealthDataPoint>>{};
    final sleepPoints = <HealthDataPoint>[];

    for (final p in points) {
      if (_isSleepType(p.type)) {
        sleepPoints.add(p);
        continue;
      }
      // 期間の中点が属する日に配る。深夜をまたぐレコードを
      // 開始時刻で配ると、就寝直前の記録が前日に寄ってしまう。
      final day = time.dayKey(_midpoint(p));
      if (!wanted.contains(day)) continue;
      (byDay[day] ??= []).add(p);
    }

    final sessionsByDay = _buildSleepSessions(sleepPoints, wanted);

    // 睡眠しか無い日も出力対象にする。
    final activeDays = <String>{...byDay.keys, ...sessionsByDay.keys};

    final bundles = <DayBundle>[];
    for (final day in activeDays.toList()..sort()) {
      bundles.add(
        _buildDay(
          date: day,
          points: byDay[day] ?? const [],
          sessions: sessionsByDay[day] ?? const [],
        ),
      );
    }
    return bundles;
  }

  // ---------------------------------------------------------------- 1日分

  DayBundle _buildDay({
    required String date,
    required List<HealthDataPoint> points,
    required List<m.SleepSession> sessions,
  }) {
    final byType = <HealthDataType, List<HealthDataPoint>>{};
    for (final p in points) {
      (byType[p.type] ??= []).add(p);
    }

    final hrPoints = byType[HealthDataType.HEART_RATE] ?? const [];
    final hrBins = _binHeartRate(hrPoints);
    final hrValues = hrPoints.map(_num).whereType<double>().toList();

    final steps = _sumInt(byType[HealthDataType.STEPS]);
    final workouts = _buildWorkouts(
      date,
      byType[HealthDataType.WORKOUT] ?? const [],
    );

    final activity = _nullIfEmpty(
      m.Activity(
        steps: steps,
        distanceM: _sum(byType[HealthDataType.DISTANCE_DELTA]),
        activeKcal: _sum(byType[HealthDataType.ACTIVE_ENERGY_BURNED]),
        totalKcal: _sum(byType[HealthDataType.TOTAL_CALORIES_BURNED]),
        floors: _sum(byType[HealthDataType.FLIGHTS_CLIMBED]),
        exerciseMin: workouts.isEmpty
            ? null
            : workouts.fold<double>(0, (a, w) => a + w.durationMin),
      ),
      (a) => [
        a.steps,
        a.distanceM,
        a.activeKcal,
        a.totalKcal,
        a.floors,
        a.exerciseMin,
      ],
    );

    final hr = _nullIfEmpty(
      m.Hr(
        restingBpm: _avg(byType[HealthDataType.RESTING_HEART_RATE]),
        avgBpm: _mean(hrValues),
        minBpm: hrValues.isEmpty
            ? null
            : hrValues.reduce((a, b) => a < b ? a : b),
        maxBpm: hrValues.isEmpty
            ? null
            : hrValues.reduce((a, b) => a > b ? a : b),
        sampleCount: hrValues.isEmpty ? null : hrValues.length,
      ),
      (h) => [h.restingBpm, h.avgBpm, h.minBpm, h.maxBpm],
    );

    final rmssd = byType[HealthDataType.HEART_RATE_VARIABILITY_RMSSD];
    final hrv = _nullIfEmpty(
      m.Hrv(
        // Android の Health Connect は SDNN を扱わない。iOS 対応時に埋まる。
        sdnnMs: null,
        rmssdMs: _avg(rmssd),
        sampleCount: rmssd?.length,
      ),
      (h) => [h.sdnnMs, h.rmssdMs],
    );

    final spo2Values = (byType[HealthDataType.BLOOD_OXYGEN] ?? const [])
        .map(_num)
        .whereType<double>()
        .map(_normalizeSpo2)
        .toList();
    final spo2 = _nullIfEmpty(
      m.Spo2(
        avgPct: _mean(spo2Values),
        minPct: spo2Values.isEmpty
            ? null
            : spo2Values.reduce((a, b) => a < b ? a : b),
        sampleCount: spo2Values.isEmpty ? null : spo2Values.length,
      ),
      (s) => [s.avgPct, s.minPct],
    );

    final sleep = sessions.isEmpty ? null : _summarizeSleep(sessions);

    final body = _nullIfEmpty(
      m.Body(
        weightKg: _last(byType[HealthDataType.WEIGHT]),
        bodyFatPct: _last(byType[HealthDataType.BODY_FAT_PERCENTAGE]),
        bmi: _last(byType[HealthDataType.BODY_MASS_INDEX]),
      ),
      (b) => [b.weightKg, b.bodyFatPct, b.bmi],
    );

    final vitals = _nullIfEmpty(
      m.Vitals(
        bodyTempC: _avg(byType[HealthDataType.BODY_TEMPERATURE]),
        bloodPressureSys: _avg(byType[HealthDataType.BLOOD_PRESSURE_SYSTOLIC]),
        bloodPressureDia: _avg(byType[HealthDataType.BLOOD_PRESSURE_DIASTOLIC]),
      ),
      (v) => [v.bodyTempC, v.bloodPressureSys, v.bloodPressureDia],
    );

    final respiratory = _nullIfEmpty(
      m.Respiratory(avgRpm: _avg(byType[HealthDataType.RESPIRATORY_RATE])),
      (r) => [r.avgRpm],
    );

    // WATER はリットル単位で返るので mL に直す。
    final waterL = _sum(byType[HealthDataType.WATER]);
    final nutrition = waterL == null
        ? null
        : m.Nutrition(waterMl: waterL * 1000);

    // 心拍ビンの数から装着時間を推定する。心拍は装着中しか記録されないため、
    // 「その日どれだけ真面目に着けていたか」の代理指標になる。
    final hrCoveredMin = (hrBins.length * kHrBinMinutes).toDouble();

    final sources = <String>{
      for (final p in points) p.sourceId,
      for (final s in sessions) s.source,
    }.where((s) => s.isNotEmpty).toList()..sort();

    return DayBundle(
      date: date,
      summary: m.DailySummary(
        schemaVersion: 1,
        date: date,
        tz: time.timeZoneName,
        activity: activity,
        hr: hr,
        hrv: hrv,
        spo2: spo2,
        respiratory: respiratory,
        sleep: sleep,
        workouts: _summarizeWorkouts(workouts),
        body: body,
        vitals: vitals,
        nutrition: nutrition,
        sources: sources,
        coverage: m.Coverage(
          hrCoveredMin: hrCoveredMin,
          wornHours: double.parse(
            (hrCoveredMin / 60).clamp(0, 24).toStringAsFixed(2),
          ),
          hasSleep: sessions.isNotEmpty,
          hasSteps: steps != null && steps > 0,
        ),
        updatedAt: _now,
      ),
      sleepSessions: sessions,
      workouts: workouts,
      hrBins: hrBins,
    );
  }

  // ------------------------------------------------------------------ 睡眠

  /// Health Connect のステージ型 → スキーマ上のステージ値。
  /// SLEEP_ASLEEP と SLEEP_UNKNOWN は「寝てはいるが段階不明」なので unknown にまとめる。
  static const _sleepStageNames = <HealthDataType, m.StageEnum>{
    HealthDataType.SLEEP_DEEP: m.StageEnum.DEEP,
    HealthDataType.SLEEP_LIGHT: m.StageEnum.LIGHT,
    HealthDataType.SLEEP_REM: m.StageEnum.REM,
    HealthDataType.SLEEP_AWAKE: m.StageEnum.AWAKE,
    HealthDataType.SLEEP_AWAKE_IN_BED: m.StageEnum.AWAKE,
    HealthDataType.SLEEP_OUT_OF_BED: m.StageEnum.OUT_OF_BED,
    HealthDataType.SLEEP_ASLEEP: m.StageEnum.UNKNOWN,
    HealthDataType.SLEEP_UNKNOWN: m.StageEnum.UNKNOWN,
  };

  static bool _isSleepType(HealthDataType t) =>
      t == HealthDataType.SLEEP_SESSION || _sleepStageNames.containsKey(t);

  /// 睡眠セッションを組み立てて、起床日ごとに配る。
  ///
  /// Health Connect はセッションとステージを別レコードで返し、両者を結ぶ ID が無い。
  /// そのため時間区間の重なりでステージをセッションに割り当てる。
  /// セッションレコード自体が無いデバイス向けに、ステージだけから
  /// セッションを組み立てるフォールバックも持つ。
  Map<String, List<m.SleepSession>> _buildSleepSessions(
    List<HealthDataPoint> points,
    Set<String> wanted,
  ) {
    final sessionPoints =
        points.where((p) => p.type == HealthDataType.SLEEP_SESSION).toList()
          ..sort((a, b) => a.dateFrom.compareTo(b.dateFrom));
    final stagePoints =
        points.where((p) => p.type != HealthDataType.SLEEP_SESSION).toList()
          ..sort((a, b) => a.dateFrom.compareTo(b.dateFrom));

    final intervals = sessionPoints.isNotEmpty
        ? sessionPoints
              .map(
                (p) => (
                  id: p.uuid,
                  from: p.dateFrom,
                  to: p.dateTo,
                  source: p.sourceId,
                ),
              )
              .toList()
        : _clusterStages(stagePoints);

    final byDay = <String, List<m.SleepSession>>{};

    for (final iv in intervals) {
      // 起床時刻の属する日に割り当てる。前夜に寝た分をその日の睡眠として扱う。
      final day = time.dayKey(iv.to);
      if (!wanted.contains(day)) continue;

      final stages = <m.StageElement>[];
      for (final s in stagePoints) {
        final mid = _midpoint(s);
        if (mid.isBefore(iv.from) || !mid.isBefore(iv.to)) continue;
        stages.add(
          m.StageElement(
            stage: _sleepStageNames[s.type] ?? m.StageEnum.UNKNOWN,
            startAt: s.dateFrom,
            endAt: s.dateTo,
          ),
        );
      }
      stages.sort((a, b) => a.startAt.compareTo(b.startAt));

      // ステージが 1 件も無いデバイス向けに、セッション全体を 1 区間として置く。
      if (stages.isEmpty) {
        stages.add(
          m.StageElement(
            stage: m.StageEnum.UNKNOWN,
            startAt: iv.from,
            endAt: iv.to,
          ),
        );
      }

      (byDay[day] ??= []).add(
        m.SleepSession(
          schemaVersion: 1,
          id: iv.id,
          date: day,
          tz: time.timeZoneName,
          startAt: iv.from,
          endAt: iv.to,
          inBedMin: iv.to.difference(iv.from).inSeconds / 60,
          stages: stages,
          source: iv.source,
          updatedAt: _now,
        ),
      );
    }

    for (final list in byDay.values) {
      list.sort((a, b) => a.startAt.compareTo(b.startAt));
    }
    return byDay;
  }

  /// セッションレコードが無い場合に、ステージの並びから睡眠区間を復元する。
  /// 60分以上の空きがあれば別の睡眠とみなす。
  List<({String id, DateTime from, DateTime to, String source})> _clusterStages(
    List<HealthDataPoint> stages,
  ) {
    if (stages.isEmpty) return const [];
    const gapThreshold = Duration(minutes: 60);
    final out = <({String id, DateTime from, DateTime to, String source})>[];

    var from = stages.first.dateFrom;
    var to = stages.first.dateTo;
    var id = stages.first.uuid;
    var source = stages.first.sourceId;

    for (final s in stages.skip(1)) {
      if (s.dateFrom.difference(to) > gapThreshold) {
        out.add((id: id, from: from, to: to, source: source));
        from = s.dateFrom;
        id = s.uuid;
        source = s.sourceId;
      }
      if (s.dateTo.isAfter(to)) to = s.dateTo;
    }
    out.add((id: id, from: from, to: to, source: source));
    return out;
  }

  m.Sleep _summarizeSleep(List<m.SleepSession> sessions) {
    final stageMinutes = <m.StageEnum, double>{};
    for (final s in sessions) {
      for (final st in s.stages) {
        final minutes = st.endAt.difference(st.startAt).inSeconds / 60;
        stageMinutes[st.stage] = (stageMinutes[st.stage] ?? 0) + minutes;
      }
    }

    final start = sessions
        .map((s) => s.startAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final end = sessions
        .map((s) => s.endAt)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    final inBed = sessions.fold<double>(0, (a, s) => a + (s.inBedMin ?? 0));

    final deep = stageMinutes[m.StageEnum.DEEP] ?? 0;
    final light = stageMinutes[m.StageEnum.LIGHT] ?? 0;
    final rem = stageMinutes[m.StageEnum.REM] ?? 0;
    final awake = stageMinutes[m.StageEnum.AWAKE] ?? 0;
    final unknown = stageMinutes[m.StageEnum.UNKNOWN] ?? 0;
    // 覚醒と離床は睡眠時間に含めない。
    final asleep = deep + light + rem + unknown;

    return m.Sleep(
      sessionIds: sessions.map((s) => s.id).toList(),
      startAt: start,
      endAt: end,
      // 就寝と起床の中点。日ごとのばらつきが睡眠の規則性を表す。
      midSleepAt: start.add(
        Duration(milliseconds: end.difference(start).inMilliseconds ~/ 2),
      ),
      inBedMin: _round(inBed),
      totalMin: _round(asleep),
      deepMin: _round(deep),
      lightMin: _round(light),
      remMin: _round(rem),
      awakeMin: _round(awake),
      unknownMin: _round(unknown),
      efficiencyPct: inBed > 0 ? _round((asleep / inBed) * 100) : null,
    );
  }

  // -------------------------------------------------------------- ワークアウト

  List<m.Workout> _buildWorkouts(String date, List<HealthDataPoint> points) {
    final out = <m.Workout>[];
    for (final p in points) {
      final v = p.value;
      if (v is! WorkoutHealthValue) continue;
      out.add(
        m.Workout(
          schemaVersion: 1,
          id: p.uuid,
          date: date,
          tz: time.timeZoneName,
          type: v.workoutActivityType.name,
          title: null,
          startAt: p.dateFrom,
          endAt: p.dateTo,
          durationMin:
              _round(p.dateTo.difference(p.dateFrom).inSeconds / 60) ?? 0,
          kcal: v.totalEnergyBurned?.toDouble(),
          distanceM: v.totalDistance?.toDouble(),
          steps: v.totalSteps,
          avgHrBpm: null,
          maxHrBpm: null,
          source: p.sourceId,
          updatedAt: _now,
        ),
      );
    }
    out.sort((a, b) => a.startAt.compareTo(b.startAt));
    return out;
  }

  m.Workouts? _summarizeWorkouts(List<m.Workout> workouts) {
    if (workouts.isEmpty) return null;
    final byType = <String, m.ByType>{};
    for (final w in workouts) {
      final prev = byType[w.type];
      byType[w.type] = m.ByType(
        count: (prev?.count ?? 0) + 1,
        minutes: (prev?.minutes ?? 0) + w.durationMin,
      );
    }
    final kcal = workouts.map((w) => w.kcal).whereType<double>();
    return m.Workouts(
      count: workouts.length,
      totalMin: _round(workouts.fold<double>(0, (a, w) => a + w.durationMin)),
      totalKcal: kcal.isEmpty
          ? null
          : _round(kcal.fold<double>(0, (a, b) => a + b)),
      byType: byType,
    );
  }

  // ---------------------------------------------------------------- 心拍ビン

  List<HrBin> _binHeartRate(List<HealthDataPoint> points) {
    if (points.isEmpty) return const [];
    const binMs = kHrBinMinutes * 60 * 1000;
    final sums = <int, double>{};
    final counts = <int, int>{};

    for (final p in points) {
      final v = _num(p);
      if (v == null) continue;
      final bin = _midpoint(p).millisecondsSinceEpoch ~/ binMs;
      sums[bin] = (sums[bin] ?? 0) + v;
      counts[bin] = (counts[bin] ?? 0) + 1;
    }

    final bins = sums.keys.toList()..sort();
    return [
      for (final b in bins)
        HrBin(
          at: DateTime.fromMillisecondsSinceEpoch(b * binMs, isUtc: true),
          bpm: sums[b]! / counts[b]!,
        ),
    ];
  }

  // ------------------------------------------------------------------ 補助

  static DateTime _midpoint(HealthDataPoint p) {
    final span = p.dateTo.difference(p.dateFrom);
    if (span.inMilliseconds <= 0) return p.dateFrom;
    return p.dateFrom.add(Duration(milliseconds: span.inMilliseconds ~/ 2));
  }

  static double? _num(HealthDataPoint p) {
    final v = p.value;
    return v is NumericHealthValue ? v.numericValue.toDouble() : null;
  }

  /// SpO2 は端末によって 0.0-1.0 の比率で返ることがあるので百分率に揃える。
  static double _normalizeSpo2(double v) => v <= 1.0 ? v * 100 : v;

  static double? _sum(List<HealthDataPoint>? points) {
    if (points == null || points.isEmpty) return null;
    final values = points.map(_num).whereType<double>();
    if (values.isEmpty) return null;
    return _round(values.fold<double>(0, (a, b) => a + b));
  }

  static int? _sumInt(List<HealthDataPoint>? points) {
    final s = _sum(points);
    return s?.round();
  }

  static double? _avg(List<HealthDataPoint>? points) {
    if (points == null || points.isEmpty) return null;
    return _mean(points.map(_num).whereType<double>().toList());
  }

  /// その日の最後に記録された値。体重のように「最新値」が意味を持つ指標に使う。
  static double? _last(List<HealthDataPoint>? points) {
    if (points == null || points.isEmpty) return null;
    final sorted = [...points]
      ..sort((a, b) => a.dateFrom.compareTo(b.dateFrom));
    return _round(_num(sorted.last));
  }

  static double? _mean(List<double> values) {
    if (values.isEmpty) return null;
    return _round(values.reduce((a, b) => a + b) / values.length);
  }

  static double? _round(double? v) =>
      v == null ? null : double.parse(v.toStringAsFixed(2));

  /// すべてのフィールドが null なら、そのグループ自体を null にする。
  /// 「全部 null のオブジェクト」を書くと、欠損なのか計測ゼロなのかが読み手に伝わらない。
  static T? _nullIfEmpty<T>(T value, List<Object?> Function(T) fields) =>
      fields(value).any((f) => f != null) ? value : null;
}
