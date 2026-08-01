import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'chart_palette.dart';

/// 重ねる 1 系列の定義。
class OverlaySeries {
  const OverlaySeries({
    required this.label,
    required this.unit,
    required this.values,
    this.digits = 0,
  });

  final String label;
  final String unit;

  /// 日付順の値。欠測日は null。
  final List<double?> values;

  /// 実値を表示するときの小数桁。
  final int digits;
}

/// 2 つの指標を 1 枚に重ねる。
///
/// **二軸グラフにはしない。** 左右で別々の目盛りを持たせると、
/// 縦位置の重なりや交差が目盛りの取り方次第でどうにでも作れてしまい、
/// 実際には無い関係が見えてしまう。
///
/// 代わりに各系列を「その期間の自分の中央値に対する %」に指数化して、
/// 単一の軸に載せる。100% の線が各指標の平常値で、そこからの離れ方を
/// 同じものさしで比べられる。実際の値はツールチップと凡例に出す。
class IndexedOverlayChart extends StatelessWidget {
  const IndexedOverlayChart({
    super.key,
    required this.title,
    required this.dates,
    required this.primary,
    required this.secondary,
  });

  final String title;

  /// 横軸のラベル（yyyy-MM-dd）。
  final List<String> dates;
  final OverlaySeries primary;
  final OverlaySeries secondary;

  @override
  Widget build(BuildContext context) {
    final palette = ChartPalette.of(context);
    final theme = Theme.of(context);

    final base1 = _median(primary.values);
    final base2 = _median(secondary.values);

    if (base1 == null || base2 == null) {
      return ChartCard(
        title: title,
        child: SizedBox(
          height: 80,
          child: Center(
            child: Text(
              '${base1 == null ? primary.label : secondary.label}のデータが足りません',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ),
      );
    }

    final idx1 = _index(primary.values, base1);
    final idx2 = _index(secondary.values, base2);

    final all = [...idx1, ...idx2].whereType<double>().toList();
    final lo = all.reduce((a, b) => a < b ? a : b);
    final hi = all.reduce((a, b) => a > b ? a : b);
    // 100% の基準線が必ず入るようにしたうえで、上下端を目盛りの倍数に丸める。
    // 半端な位置で切ると、端のラベルが直近の目盛りと重なって読めなくなる。
    const tick = 25.0;
    final minY = (((lo < 100 ? lo : 100.0) - 5) / tick).floor() * tick;
    final maxY = (((hi > 100 ? hi : 100.0) + 5) / tick).ceil() * tick;

    return ChartCard(
      title: title,
      legend: ChartLegend(entries: [
        (primary.label, palette.slot(0), '中央値 ${_fmt(base1, primary)}'),
        (secondary.label, palette.slot(1), '中央値 ${_fmt(base2, secondary)}'),
      ]),
      footnote: '各指標を自身の中央値に対する % で表示。100% がその指標の平常値。',
      child: SizedBox(
        height: 160,
        child: LineChart(
          LineChartData(
            minY: minY,
            maxY: maxY,
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              horizontalInterval: tick,
              getDrawingHorizontalLine: (value) => FlLine(
                // 100% だけ濃くして基準線に見せる。
                color: value == 100 ? palette.axis : palette.gridline,
                strokeWidth: value == 100 ? 1.5 : 1,
              ),
            ),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              rightTitles: const AxisTitles(),
              topTitles: const AxisTitles(),
              bottomTitles: const AxisTitles(),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 40,
                  interval: 25,
                  getTitlesWidget: (value, _) => Text(
                    '${value.round()}%',
                    style: theme.textTheme.bodySmall?.copyWith(color: palette.muted),
                  ),
                ),
              ),
            ),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipItems: (touched) => [
                  for (final t in touched)
                    LineTooltipItem(
                      _tooltip(t.x.toInt(), t.barIndex),
                      theme.textTheme.bodySmall ?? const TextStyle(),
                    ),
                ],
              ),
            ),
            lineBarsData: [
              _bar(idx1, palette.slot(0)),
              _bar(idx2, palette.slot(1)),
            ],
          ),
        ),
      ),
    );
  }

  String _tooltip(int i, int barIndex) {
    final series = barIndex == 0 ? primary : secondary;
    final raw = i < series.values.length ? series.values[i] : null;
    final date = i < dates.length ? dates[i] : '';
    if (raw == null) return date;
    // 実際の値を出す。% だけだと「で、何分寝たのか」が分からない。
    return '$date\n${series.label} ${_fmt(raw, series)}';
  }

  static LineChartBarData _bar(List<double?> values, Color color) => LineChartBarData(
        spots: [
          for (var i = 0; i < values.length; i++)
            if (values[i] case final v?) FlSpot(i.toDouble(), v) else FlSpot.nullSpot,
        ],
        isCurved: false,
        barWidth: 2,
        color: color,
        dotData: const FlDotData(show: false),
      );

  static String _fmt(double value, OverlaySeries s) =>
      '${value.toStringAsFixed(s.digits)}${s.unit}';

  /// 中央値を基準にする。平均だと 1 日の外れ値に引きずられ、
  /// 平常値のつもりの線が平常でなくなる。
  static double? _median(List<double?> values) {
    final xs = values.whereType<double>().toList()..sort();
    if (xs.isEmpty) return null;
    final mid = xs.length ~/ 2;
    final m = xs.length.isEven ? (xs[mid - 1] + xs[mid]) / 2 : xs[mid];
    return m == 0 ? null : m;
  }

  static List<double?> _index(List<double?> values, double base) =>
      [for (final v in values) v == null ? null : (v / base) * 100];
}
