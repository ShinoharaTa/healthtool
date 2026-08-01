import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/app_time.dart';
import 'chart_palette.dart';
import 'day_slots.dart';

/// 就寝と起床の時刻を日ごとに打つ。
///
/// 縦軸は 0 時起点ではなく **18 時起点**。
/// 0 時起点だと 23:50 就寝と 00:10 就寝が軸の上端と下端に離れて描かれ、
/// 20 分しか違わないものが正反対に見える。18 時を原点にすれば
/// 就寝は軸の下部、起床は上部にまとまり、ばらつきがそのまま縦の散らばりになる。
class BedtimeScatterChart extends StatelessWidget {
  const BedtimeScatterChart({super.key, required this.days, required this.time});

  /// 欠測日を null で埋めた並び。
  final List<DaySlot> days;
  final AppTime time;

  /// 軸の原点となる時刻（分）。18:00。
  static const _originMinutes = 18 * 60;

  @override
  Widget build(BuildContext context) {
    final palette = ChartPalette.of(context);
    final theme = Theme.of(context);

    final points = <_Night>[];
    for (var i = 0; i < days.length; i++) {
      final sleep = days[i].summary?.sleep;
      if (sleep?.startAt == null || sleep?.endAt == null) continue;
      points.add(_Night(
        x: i.toDouble(),
        date: days[i].date,
        bedMinutes: time.minutesOfDay(sleep!.startAt!),
        wakeMinutes: time.minutesOfDay(sleep.endAt!),
      ));
    }

    if (points.isEmpty) {
      return const ChartCard(
        title: '就寝と起床の時刻',
        child: SizedBox(
          height: 80,
          child: Center(child: Text('睡眠データがありません')),
        ),
      );
    }

    final bedSpread = _spreadMinutes(points.map((p) => p.bedAxis));
    final wakeSpread = _spreadMinutes(points.map((p) => p.wakeAxis));

    final radius = points.length > 90 ? 3.0 : (points.length > 40 ? 4.0 : 5.0);

    // 軸は 24 時間分ではなく、実際に点がある範囲に詰める。
    // 就寝と起床はせいぜい 21:00〜10:00 に収まるので、
    // 24 時間を等分すると縦の半分が空白になり、肝心のばらつきが潰れて見える。
    final axisValues = [
      ...points.map((p) => p.bedAxis),
      ...points.map((p) => p.wakeAxis),
    ];
    const padMinutes = 45.0;
    final rawMin = (axisValues.reduce(math.min) - padMinutes).clamp(0.0, 1440.0);
    final rawMax = (axisValues.reduce(math.max) + padMinutes).clamp(0.0, 1440.0);
    // 目盛りは 2 時間刻み。範囲が狭いときは 1 時間刻みに落とす。
    final tickInterval = (rawMax - rawMin) > 480 ? 120.0 : 60.0;
    // 上下端を目盛りの倍数に丸める。半端な位置で切ると、
    // 端に描かれるラベルが直近の目盛りと重なって読めなくなる。
    final minY = (rawMin / tickInterval).floor() * tickInterval;
    final maxY = (rawMax / tickInterval).ceil() * tickInterval;

    return ChartCard(
      title: '就寝と起床の時刻',
      legend: ChartLegend(entries: [
        ('就寝', palette.slot(0), _clock(_meanAxis(points.map((p) => p.bedAxis)))),
        ('起床', palette.slot(1), _clock(_meanAxis(points.map((p) => p.wakeAxis)))),
      ]),
      footnote: 'ばらつき（標準偏差）: 就寝 ${bedSpread.round()}分 · 起床 ${wakeSpread.round()}分'
          '${days.length - points.length > 0 ? ' · 欠測 ${days.length - points.length}日' : ''}',
      child: SizedBox(
        height: 180,
        child: ScatterChart(
          ScatterChartData(
            minX: -1,
            maxX: days.length.toDouble(),
            minY: minY,
            maxY: maxY,
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              horizontalInterval: tickInterval,
              getDrawingHorizontalLine: (_) =>
                  FlLine(color: palette.gridline, strokeWidth: 1),
            ),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              rightTitles: const AxisTitles(),
              topTitles: const AxisTitles(),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 20,
                  // 両端の日付だけ出す。全部出すと読めないし、
                  // 何も出さないとどこからどこまでか分からなくなる。
                  interval: (days.length - 1).clamp(1, 9999).toDouble(),
                  getTitlesWidget: (value, _) {
                    final i = value.round();
                    if (i < 0 || i >= days.length) return const SizedBox.shrink();
                    return Text(
                      days[i].date.substring(5),
                      style: theme.textTheme.bodySmall?.copyWith(color: palette.muted),
                    );
                  },
                ),
              ),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 40,
                  interval: tickInterval,
                  getTitlesWidget: (value, _) => Text(
                    _clock(value),
                    style: theme.textTheme.bodySmall?.copyWith(color: palette.muted),
                  ),
                ),
              ),
            ),
            scatterTouchData: ScatterTouchData(
              touchTooltipData: ScatterTouchTooltipData(
                getTooltipItems: (spot) {
                  final night = points.firstWhere(
                    (p) => p.x == spot.x,
                    orElse: () => points.first,
                  );
                  return ScatterTooltipItem(
                    '${night.date}\n就寝 ${_clock(night.bedAxis)} → 起床 ${_clock(night.wakeAxis)}',
                    textStyle: theme.textTheme.bodySmall ?? const TextStyle(),
                  );
                },
              ),
            ),
            scatterSpots: [
              for (final p in points)
                ScatterSpot(
                  p.x,
                  p.bedAxis,
                  dotPainter: FlDotCirclePainter(
                    radius: radius,
                    color: palette.slot(0),
                    // 点が重なったときに境目が分かるよう背景色の輪を付ける。
                    strokeColor: theme.cardColor,
                    strokeWidth: 1,
                  ),
                ),
              for (final p in points)
                ScatterSpot(
                  p.x,
                  p.wakeAxis,
                  dotPainter: FlDotCirclePainter(
                    radius: radius,
                    color: palette.slot(1),
                    strokeColor: theme.cardColor,
                    strokeWidth: 1,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 18時起点の軸の値を、時計表示に戻す。
  static String _clock(double axisMinutes) {
    final actual = ((axisMinutes.round() + _originMinutes) % 1440 + 1440) % 1440;
    final h = actual ~/ 60;
    final m = actual % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  static double _meanAxis(Iterable<double> values) {
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a + b) / values.length;
  }

  /// 18時起点に直したあとは、その範囲で線形の標準偏差を取ってよい。
  /// 就寝も起床もこの原点なら折り返さないため。
  static double _spreadMinutes(Iterable<double> values) {
    final xs = values.toList();
    if (xs.length < 2) return 0;
    final mean = xs.reduce((a, b) => a + b) / xs.length;
    final variance =
        xs.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) / (xs.length - 1);
    return variance <= 0 ? 0 : math.sqrt(variance);
  }
}

class _Night {
  _Night({
    required this.x,
    required this.date,
    required this.bedMinutes,
    required this.wakeMinutes,
  });

  final double x;
  final String date;

  /// 0時起点の実時刻（分）。
  final int bedMinutes;
  final int wakeMinutes;

  /// 18時を原点に付け替えた軸上の位置。
  double get bedAxis => _toAxis(bedMinutes);
  double get wakeAxis => _toAxis(wakeMinutes);

  static double _toAxis(int minutes) =>
      (((minutes - BedtimeScatterChart._originMinutes) % 1440) + 1440) % 1440;
}
