import 'package:flutter/material.dart';

/// グラフの配色。
///
/// 値は検証済みの既定パレットから採っている。ライトとダークは
/// 自動反転ではなく、それぞれの背景色に対して個別に選ばれた組み合わせ。
///
/// 色相の割り当て順は見た目の好みではなく色覚多様性への配慮そのもので、
/// 隣り合う系列が識別できる順序が選ばれている。系列を足すときは
/// スロット順を飛ばさず、9 つ目を作らないこと。
@immutable
class ChartPalette {
  const ChartPalette({
    required this.series,
    required this.surface,
    required this.gridline,
    required this.axis,
    required this.muted,
  });

  /// カテゴリ系列の色。スロット順に使う。循環させない。
  final List<Color> series;
  final Color surface;
  final Color gridline;
  final Color axis;
  final Color muted;

  static const _light = ChartPalette(
    series: [
      Color(0xFF2A78D6), // 1 青
      Color(0xFFEB6834), // 2 橙
      Color(0xFF1BAF7A), // 3 アクア
      Color(0xFFEDA100), // 4 黄
    ],
    surface: Color(0xFFFCFCFB),
    gridline: Color(0xFFE1E0D9),
    axis: Color(0xFFC3C2B7),
    muted: Color(0xFF898781),
  );

  static const _dark = ChartPalette(
    series: [
      Color(0xFF3987E5),
      Color(0xFFD95926),
      Color(0xFF199E70),
      Color(0xFFC98500),
    ],
    surface: Color(0xFF1A1A19),
    gridline: Color(0xFF2C2C2A),
    axis: Color(0xFF383835),
    muted: Color(0xFF898781),
  );

  static ChartPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? _dark : _light;

  /// ライトモードではアクアと黄が背景に対して 3:1 に届かない。
  /// その場合は色だけに頼らず、数値を必ず併記する。
  bool get needsValueLabels => surface == _light.surface;

  Color slot(int index) => series[index % series.length];
}

/// 系列の凡例。色だけで identity を伝えないための最小構成。
class ChartLegend extends StatelessWidget {
  const ChartLegend({super.key, required this.entries});

  /// (ラベル, 色, 併記する値)。値は null なら出さない。
  final List<(String, Color, String?)> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        for (final (label, color, value) in entries)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 5),
              Text(label, style: theme.textTheme.bodySmall),
              if (value != null) ...[
                const SizedBox(width: 4),
                Text(
                  value,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
      ],
    );
  }
}

/// グラフを囲む共通の枠。見出しと補足を同じ位置に揃える。
class ChartCard extends StatelessWidget {
  const ChartCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.footnote,
    this.legend,
  });

  final String title;
  final Widget child;

  /// 見出しの右に出す代表値。
  final String? trailing;

  /// グラフの下に出す注記。欠測日数など。
  final String? footnote;
  final Widget? legend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                Flexible(child: Text(title, style: theme.textTheme.titleSmall)),
                if (trailing != null)
                  Text(
                    trailing!,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
            if (legend != null) ...[const SizedBox(height: 8), legend!],
            const SizedBox(height: 10),
            child,
            if (footnote != null) ...[
              const SizedBox(height: 6),
              Text(footnote!, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}
