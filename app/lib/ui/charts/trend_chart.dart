import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'chart_palette.dart';

/// 1 指標の推移を出す折れ線。
///
/// 欠測日は線を切って表示する。0 として描くと「その日は歩かなかった」と
/// 「バンドを着けていなかった」の区別がつかなくなり、判断を誤らせる。
class TrendChart extends StatelessWidget {
  const TrendChart({
    super.key,
    required this.title,
    required this.unit,
    required this.values,
    this.digits = 0,
  });

  final String title;
  final String unit;

  /// (日付キー, 値)。値が null の日は欠測として扱う。
  final List<(String, double?)> values;
  final int digits;

  @override
  Widget build(BuildContext context) {
    final palette = ChartPalette.of(context);
    final theme = Theme.of(context);
    final present = values.where((v) => v.$2 != null).toList();
    final missing = values.length - present.length;

    if (present.isEmpty) {
      return ChartCard(
        title: title,
        child: SizedBox(
          height: 80,
          child: Center(
            child: Text('データなし', style: theme.textTheme.bodySmall),
          ),
        ),
      );
    }

    final nums = present.map((v) => v.$2!).toList();
    final minY = nums.reduce((a, b) => a < b ? a : b);
    final maxY = nums.reduce((a, b) => a > b ? a : b);
    // 値が一定でも線が潰れないように余白を確保する。
    final pad = (maxY - minY) == 0 ? (maxY.abs() * 0.1 + 1) : (maxY - minY) * 0.15;

    return ChartCard(
      title: title,
      // 系列が 1 本なので凡例は置かない。見出しがその系列の名前になっている。
      trailing: '${_fmt(present.last.$2!)}$unit',
      footnote: missing > 0 ? '欠測 $missing 日' : null,
      child: SizedBox(
        height: 110,
        child: LineChart(
          LineChartData(
            minY: minY - pad,
            maxY: maxY + pad,
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            titlesData: const FlTitlesData(show: false),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipItems: (touched) => [
                  for (final t in touched)
                    LineTooltipItem(
                      '${values[t.x.toInt()].$1}\n${_fmt(t.y)}$unit',
                      theme.textTheme.bodySmall ?? const TextStyle(),
                    ),
                ],
              ),
            ),
            lineBarsData: [
              LineChartBarData(
                spots: [
                  for (var i = 0; i < values.length; i++)
                    if (values[i].$2 case final v?)
                      FlSpot(i.toDouble(), v)
                    else
                      FlSpot.nullSpot,
                ],
                isCurved: false,
                barWidth: 2,
                color: palette.slot(0),
                dotData: FlDotData(show: present.length <= 14),
                belowBarData: BarAreaData(
                  show: true,
                  color: palette.slot(0).withValues(alpha: 0.12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(double v) => v.toStringAsFixed(digits);
}
