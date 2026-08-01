import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// 直近の推移を出す小さな折れ線。
///
/// 欠損日は線を切って表示する。0 として描くと「その日は歩かなかった」と
/// 「バンドを着けていなかった」の区別がつかなくなり、判断を誤らせる。
class TrendChart extends StatelessWidget {
  const TrendChart({
    super.key,
    required this.title,
    required this.unit,
    required this.values,
  });

  final String title;
  final String unit;

  /// (日付キー, 値)。値が null の日は欠損として扱う。
  final List<(String, double?)> values;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final present = values.where((v) => v.$2 != null).toList();

    if (present.isEmpty) {
      return _frame(
        context,
        child: SizedBox(
          height: 80,
          child: Center(
            child: Text('データなし', style: theme.textTheme.bodySmall),
          ),
        ),
        latest: null,
      );
    }

    final spots = <FlSpot>[
      for (var i = 0; i < values.length; i++)
        if (values[i].$2 case final v?) FlSpot(i.toDouble(), v) else FlSpot.nullSpot,
    ];

    final nums = present.map((v) => v.$2!).toList();
    final minY = nums.reduce((a, b) => a < b ? a : b);
    final maxY = nums.reduce((a, b) => a > b ? a : b);
    // 値が一定でも線が潰れないように余白を確保する。
    final pad = (maxY - minY) == 0 ? (maxY.abs() * 0.1 + 1) : (maxY - minY) * 0.15;

    return _frame(
      context,
      latest: present.last.$2,
      child: SizedBox(
        height: 120,
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
                      '${values[t.x.toInt()].$1}\n'
                      '${_format(t.y)} $unit',
                      theme.textTheme.bodySmall ?? const TextStyle(),
                    ),
                ],
              ),
            ),
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                isCurved: false,
                barWidth: 2,
                color: theme.colorScheme.primary,
                dotData: FlDotData(show: present.length <= 14),
                belowBarData: BarAreaData(
                  show: true,
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _frame(BuildContext context, {required Widget child, double? latest}) {
    final theme = Theme.of(context);
    final missing = values.where((v) => v.$2 == null).length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                if (latest != null)
                  Text('${_format(latest)} $unit',
                      style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            child,
            if (missing > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('欠測 $missing 日', style: theme.textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }

  static String _format(double v) =>
      v >= 100 ? v.round().toString() : v.toStringAsFixed(1);
}
