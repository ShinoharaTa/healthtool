import 'dart:math';

import 'package:flutter/material.dart';

import '../core/app_time.dart';
import '../models/generated/generated.dart' as m;
import 'charts/bedtime_scatter_chart.dart';
import 'charts/day_slots.dart';
import 'charts/indexed_overlay_chart.dart';
import 'charts/sleep_stage_chart.dart';
import 'charts/trend_chart.dart';
import 'home_screen.dart' show Period;

/// 合成データでグラフの見た目を確認する画面。
///
/// 実データが入る前にレイアウトと配色を検証できるようにしてある。
/// 長期表示で棒が潰れないか、欠測日が線の切れとして出ているか、
/// ダークモードで色が沈まないかは、描いて見ないと分からない。
class ChartPreviewScreen extends StatefulWidget {
  const ChartPreviewScreen({super.key, required this.time});

  final AppTime time;

  @override
  State<ChartPreviewScreen> createState() => _ChartPreviewScreenState();
}

class _ChartPreviewScreenState extends State<ChartPreviewScreen> {
  Period _period = Period.month;
  late final List<m.DailySummary> _all = _synthesize(widget.time, 365);

  @override
  Widget build(BuildContext context) {
    // 合成データも実データと同じく欠測日を含む。日付軸を張り直してから渡す。
    final all = denseSlots(_all, widget.time);
    final days = all
        .skip((all.length - _period.days).clamp(0, all.length))
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('グラフのプレビュー（合成データ）')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'これは動作確認用の架空のデータです。実際の記録ではありません。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<Period>(
            segments: [
              for (final p in Period.values)
                ButtonSegment(value: p, label: Text(p.label)),
            ],
            selected: {_period},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _period = s.first),
          ),
          const SizedBox(height: 12),
          SleepStageChart(days: days),
          const SizedBox(height: 12),
          BedtimeScatterChart(days: days, time: widget.time),
          const SizedBox(height: 12),
          IndexedOverlayChart(
            title: '睡眠時間と安静時心拍',
            dates: [for (final d in days) d.date],
            primary: OverlaySeries(
              label: '睡眠時間',
              unit: '分',
              values: [for (final d in days) d.summary?.sleep?.totalMin],
            ),
            secondary: OverlaySeries(
              label: '安静時心拍',
              unit: 'bpm',
              values: [for (final d in days) d.summary?.hr?.restingBpm],
              digits: 1,
            ),
          ),
          const SizedBox(height: 12),
          TrendChart(
            title: '歩数',
            unit: '歩',
            values: [
              for (final d in days)
                (d.date, d.summary?.activity?.steps?.toDouble()),
            ],
          ),
          const SizedBox(height: 12),
          TrendChart(
            title: '推定装着時間',
            unit: '時間',
            digits: 1,
            values: [
              for (final d in days) (d.date, d.summary?.coverage.wornHours),
            ],
          ),
        ],
      ),
    );
  }
}

/// もっともらしい 1 年分を作る。
///
/// 乱数の種を固定してあるので、実行のたびに同じ絵が出る。
/// 見た目の変化がコードの変更によるものだと分かるようにするため。
List<m.DailySummary> _synthesize(AppTime time, int days) {
  final rnd = Random(42);
  final out = <m.DailySummary>[];
  final dates = time.lastDays(days);

  for (var i = 0; i < dates.length; i++) {
    final date = dates[i];
    final start = time.startOfDay(date);
    final isWeekend = start.weekday >= 6;

    // 1 割ほどは同期漏れや未装着で欠測させる。欠測の見え方を確認したい。
    if (rnd.nextDouble() < 0.08) continue;

    // 就寝は 23:00〜25:00、休日は 1 時間ほど遅い。
    final bedBase = 23 * 60 + (isWeekend ? 60 : 0) + rnd.nextInt(90) - 20;
    final sleepMin = 330 + rnd.nextInt(150) + (isWeekend ? 30 : 0);
    final bedAt = start.subtract(Duration(minutes: 1440 - bedBase));
    final wakeAt = bedAt.add(
      Duration(minutes: sleepMin + 20 + rnd.nextInt(40)),
    );

    final deep = 55 + rnd.nextInt(50);
    final rem = 60 + rnd.nextInt(55);
    final awake = 10 + rnd.nextInt(35);
    final light = (sleepMin - deep - rem).clamp(60, 400);
    final inBed = (sleepMin + awake).toDouble();

    // 睡眠が短い日は安静時心拍が上がる、という関係を薄く入れておく。
    final resting = 62 - (sleepMin - 400) * 0.012 + rnd.nextDouble() * 3;
    final steps = (isWeekend ? 3500 : 7500) + rnd.nextInt(6000);
    final worn = rnd.nextDouble() < 0.1
        ? 6 + rnd.nextDouble() * 5
        : 19 + rnd.nextDouble() * 4;

    out.add(
      m.DailySummary(
        schemaVersion: 1,
        date: date,
        tz: time.timeZoneName,
        activity: m.Activity(
          steps: steps,
          activeKcal: steps * 0.04,
          distanceM: steps * 0.7,
        ),
        hr: m.Hr(
          restingBpm: double.parse(resting.toStringAsFixed(1)),
          avgBpm: resting + 14 + rnd.nextInt(8).toDouble(),
          minBpm: resting - 6,
          maxBpm: 110 + rnd.nextInt(40).toDouble(),
          sampleCount: 280,
        ),
        sleep: m.Sleep(
          sessionIds: ['synthetic-$date'],
          startAt: bedAt,
          endAt: wakeAt,
          midSleepAt: bedAt.add(Duration(minutes: (sleepMin + awake) ~/ 2)),
          inBedMin: inBed,
          totalMin: sleepMin.toDouble(),
          deepMin: deep.toDouble(),
          lightMin: light.toDouble(),
          remMin: rem.toDouble(),
          awakeMin: awake.toDouble(),
          unknownMin: 0,
          efficiencyPct: double.parse(
            (sleepMin / inBed * 100).toStringAsFixed(1),
          ),
        ),
        sources: const ['com.mi.health'],
        coverage: m.Coverage(
          hrCoveredMin: worn * 60,
          wornHours: double.parse(worn.toStringAsFixed(1)),
          hasSleep: true,
          hasSteps: true,
        ),
        updatedAt: DateTime.now(),
      ),
    );
  }

  return out;
}
