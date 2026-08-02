import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'chart_palette.dart';
import 'day_slots.dart';

/// 睡眠の内訳を日ごとに積み上げる。
///
/// 覚醒時間は積まない。この棒の高さは「眠っていた時間」で、
/// 覚醒を混ぜると合計が睡眠時間と一致しなくなり読み違えのもとになる。
/// 中途覚醒は下の注記に平均値として出す。
class SleepStageChart extends StatelessWidget {
  const SleepStageChart({super.key, required this.days});

  /// 欠測日を null で埋めた並び。denseSlots() を通したものを渡す。
  final List<DaySlot> days;

  /// 棒が細くなりすぎる長期表示では週平均にまとめる。
  static const _weeklyThreshold = 120;

  @override
  Widget build(BuildContext context) {
    final palette = ChartPalette.of(context);
    final theme = Theme.of(context);

    final buckets = days.length > _weeklyThreshold
        ? _weekly(days)
        : _daily(days);
    final withSleep = buckets.where((b) => b.total > 0).toList();

    if (withSleep.isEmpty) {
      return const ChartCard(
        title: '睡眠の内訳',
        child: _Empty(message: '睡眠データがありません'),
      );
    }

    // 実際に記録されているステージだけを積む。
    // デバイスがステージを出さない場合は「ステージ不明」1 本になる。
    final components = <_Component>[
      if (withSleep.any((b) => b.deep > 0))
        _Component('深い', (b) => b.deep, palette.slot(0)),
      if (withSleep.any((b) => b.light > 0))
        _Component('浅い', (b) => b.light, palette.slot(1)),
      if (withSleep.any((b) => b.rem > 0))
        _Component('レム', (b) => b.rem, palette.slot(2)),
      if (withSleep.any((b) => b.unknown > 0))
        _Component('ステージ不明', (b) => b.unknown, palette.slot(3)),
    ];

    final avgTotal = _mean(withSleep.map((b) => b.total));
    final avgAwake = _mean(withSleep.map((b) => b.awake));

    return ChartCard(
      title: buckets.length == days.length ? '睡眠の内訳' : '睡眠の内訳（週平均）',
      trailing: '平均 ${_hm(avgTotal)}',
      legend: ChartLegend(
        entries: [
          for (final c in components)
            (
              c.label,
              c.color,
              // ライトモードではアクアと黄が背景に対して 3:1 に届かない。
              // 色だけで見分けさせないよう、平均値を必ず併記する。
              _hm(_mean(withSleep.map(c.pick))),
            ),
        ],
      ),
      footnote: [
        if (avgAwake > 0) '中途覚醒 平均 ${_hm(avgAwake)}',
        if (buckets.length - withSleep.length > 0)
          '欠測 ${buckets.length - withSleep.length}${buckets.length == days.length ? '日' : '週'}',
      ].join(' · '),
      child: SizedBox(
        height: 160,
        child: BarChart(
          BarChartData(
            alignment: BarChartAlignment.spaceBetween,
            maxY: _niceCeil(buckets.map((b) => b.total).fold<double>(0, _max)),
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              // 1 時間ごとの補助線。目盛りは控えめにして棒を主役にする。
              horizontalInterval: 60,
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
                  // 棒グラフの bottomTitles は interval を指定しても
                  // グループごとに呼ばれるので、ここで間引く。
                  // 全部描くと日付が重なって読めない。
                  getTitlesWidget: (value, _) {
                    final i = value.round();
                    if (i != 0 && i != buckets.length - 1) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        buckets[i].label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.muted,
                        ),
                      ),
                    );
                  },
                ),
              ),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 34,
                  interval: 120,
                  getTitlesWidget: (value, _) => Text(
                    '${(value / 60).round()}h',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette.muted,
                    ),
                  ),
                ),
              ),
            ),
            barTouchData: BarTouchData(
              touchTooltipData: BarTouchTooltipData(
                getTooltipItem: (group, _, _, _) {
                  final b = buckets[group.x];
                  final lines = components
                      .where((c) => c.pick(b) > 0)
                      .map((c) => '${c.label} ${_hm(c.pick(b))}')
                      .join('\n');
                  return BarTooltipItem(
                    '${b.label}\n合計 ${_hm(b.total)}\n$lines',
                    theme.textTheme.bodySmall ?? const TextStyle(),
                  );
                },
              ),
            ),
            barGroups: [
              for (var i = 0; i < buckets.length; i++)
                BarChartGroupData(
                  x: i,
                  barRods: [
                    BarChartRodData(
                      toY: buckets[i].total,
                      width: _barWidth(buckets.length),
                      // データの先端だけ丸める。積み上げの途中は角のまま。
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(4),
                      ),
                      color: palette.gridline,
                      rodStackItems: _stack(
                        buckets[i],
                        components,
                        theme.cardColor,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 積み上げの各区間。境目に背景色の細い線を入れて、隣り合う色が溶けないようにする。
  static List<BarChartRodStackItem> _stack(
    _Bucket b,
    List<_Component> components,
    Color surface,
  ) {
    final items = <BarChartRodStackItem>[];
    var from = 0.0;
    for (final c in components) {
      final v = c.pick(b);
      if (v <= 0) continue;
      items.add(
        BarChartRodStackItem(
          from,
          from + v,
          c.color,
          borderSide: BorderSide(color: surface, width: 1),
        ),
      );
      from += v;
    }
    return items;
  }

  static double _barWidth(int count) {
    if (count <= 14) return 14;
    if (count <= 40) return 7;
    if (count <= 60) return 5;
    return 3;
  }

  static List<_Bucket> _daily(List<DaySlot> days) => [
    for (final d in days)
      _Bucket(
        label: d.date.substring(5),
        deep: d.summary?.sleep?.deepMin ?? 0,
        light: d.summary?.sleep?.lightMin ?? 0,
        rem: d.summary?.sleep?.remMin ?? 0,
        unknown: d.summary?.sleep?.unknownMin ?? 0,
        awake: d.summary?.sleep?.awakeMin ?? 0,
      ),
  ];

  /// 7 日ずつの平均。長期表示で棒が潰れるのを避ける。
  static List<_Bucket> _weekly(List<DaySlot> days) {
    final out = <_Bucket>[];
    for (var i = 0; i < days.length; i += 7) {
      final chunk = days.skip(i).take(7).toList();
      // 睡眠が記録された日だけで平均する。欠測日を 0 として混ぜると
      // 「その週はあまり眠っていない」ように見えてしまう。
      final slept = chunk
          .where((d) => (d.summary?.sleep?.totalMin ?? 0) > 0)
          .toList();
      if (slept.isEmpty) {
        out.add(_Bucket(label: chunk.first.date.substring(5)));
        continue;
      }
      out.add(
        _Bucket(
          label: '${chunk.first.date.substring(5)}〜',
          deep: _mean(slept.map((d) => d.summary?.sleep?.deepMin ?? 0)),
          light: _mean(slept.map((d) => d.summary?.sleep?.lightMin ?? 0)),
          rem: _mean(slept.map((d) => d.summary?.sleep?.remMin ?? 0)),
          unknown: _mean(slept.map((d) => d.summary?.sleep?.unknownMin ?? 0)),
          awake: _mean(slept.map((d) => d.summary?.sleep?.awakeMin ?? 0)),
        ),
      );
    }
    return out;
  }

  static double _max(double a, double b) => a > b ? a : b;

  static double _mean(Iterable<double> values) {
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a + b) / values.length;
  }

  /// 上端を 2 時間刻みの切りのいい値にする。
  static double _niceCeil(double v) =>
      v <= 0 ? 480 : ((v / 120).ceil() * 120).toDouble();

  static String _hm(double minutes) {
    final total = minutes.round();
    final h = total ~/ 60;
    final m = total % 60;
    return h > 0 ? '$h時間${m > 0 ? '$m分' : ''}' : '$m分';
  }
}

class _Component {
  const _Component(this.label, this.pick, this.color);
  final String label;
  final double Function(_Bucket) pick;
  final Color color;
}

class _Bucket {
  const _Bucket({
    required this.label,
    this.deep = 0,
    this.light = 0,
    this.rem = 0,
    this.unknown = 0,
    this.awake = 0,
  });

  final String label;
  final double deep;
  final double light;
  final double rem;
  final double unknown;
  final double awake;

  double get total => deep + light + rem + unknown;
}

class _Empty extends StatelessWidget {
  const _Empty({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 80,
    child: Center(
      child: Text(message, style: Theme.of(context).textTheme.bodySmall),
    ),
  );
}
