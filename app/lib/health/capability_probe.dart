import 'package:health/health.dart';

import 'health_repository.dart';
import 'health_types.dart';

/// 1 つのデータ型について「実際に取れたか」の結果。
class ProbeResult {
  const ProbeResult({
    required this.type,
    required this.count,
    required this.earliest,
    required this.latest,
    required this.sample,
    required this.sources,
    this.error,
  });

  final HealthDataType type;
  final int count;
  final DateTime? earliest;
  final DateTime? latest;

  /// 代表値の文字列表現。単位の解釈が合っているかを目視確認するために出す。
  final String? sample;

  /// このデータを書いたアプリのパッケージ名。Mi Fitness 以外が混ざっていないかを見る。
  final Set<String> sources;

  /// 取得中に例外が出た場合の内容。
  final String? error;

  bool get hasData => count > 0;

  String get label => HealthTypeCatalog.label(type);
}

/// 探索の全体結果。
class ProbeReport {
  const ProbeReport({
    required this.results,
    required this.from,
    required this.to,
  });

  final List<ProbeResult> results;
  final DateTime from;
  final DateTime to;

  List<ProbeResult> get available => results.where((r) => r.hasData).toList();
  List<ProbeResult> get missing =>
      results.where((r) => !r.hasData && r.error == null).toList();
  List<ProbeResult> get failed =>
      results.where((r) => r.error != null).toList();

  /// 調査結果を貼り付け可能なテキストにする。
  /// どの指標が取れたかを記録に残し、後続の実装判断に使う。
  String toReportText() {
    final b = StringBuffer()
      ..writeln('# Health Connect 取得可能性レポート')
      ..writeln('期間: ${from.toIso8601String()} 〜 ${to.toIso8601String()}')
      ..writeln()
      ..writeln('## 取得できた (${available.length})');
    for (final r in available) {
      b.writeln(
        '- ${r.label} (${r.type.name}): ${r.count} 件'
        '${r.sample == null ? '' : ' / 例: ${r.sample}'}'
        '${r.sources.isEmpty ? '' : ' / 提供元: ${r.sources.join(", ")}'}',
      );
    }
    b
      ..writeln()
      ..writeln('## 取得できなかった (${missing.length})');
    for (final r in missing) {
      b.writeln('- ${r.label} (${r.type.name})');
    }
    if (failed.isNotEmpty) {
      b
        ..writeln()
        ..writeln('## エラー (${failed.length})');
      for (final r in failed) {
        b.writeln('- ${r.label} (${r.type.name}): ${r.error}');
      }
    }
    return b.toString();
  }
}

/// Mi Fitness が Health Connect に何を書いているかを実データで確定させる。
///
/// 公開資料では歩数・睡眠・心拍・ワークアウトしか確認できず、
/// SpO2 や心拍変動が書かれるかは端末とアプリのバージョン次第。
/// 推測で集計項目やダッシュボードを作ると後で総取り替えになるので、
/// 実装を進める前にここで確定させる。
class CapabilityProbe {
  CapabilityProbe(this.health);

  final HealthRepository health;

  /// 型ごとに 1 つずつ問い合わせる。
  ///
  /// まとめて 1 回で聞くと、1 つの型が例外を投げた時点で全体が落ちて
  /// 「何が取れて何が取れないか」が分からなくなる。遅くても型ごとに分ける。
  Future<ProbeReport> run({
    int days = 30,
    void Function(int done, int total)? onProgress,
  }) async {
    final to = DateTime.now();
    final from = to.subtract(Duration(days: days));
    final types = HealthTypeCatalog.androidTypes;
    final results = <ProbeResult>[];

    for (var i = 0; i < types.length; i++) {
      final type = types[i];
      try {
        final points = await health.fetch(types: [type], start: from, end: to);
        points.sort((a, b) => a.dateFrom.compareTo(b.dateFrom));
        results.add(
          ProbeResult(
            type: type,
            count: points.length,
            earliest: points.isEmpty ? null : points.first.dateFrom,
            latest: points.isEmpty ? null : points.last.dateTo,
            sample: points.isEmpty ? null : _describe(points.last),
            sources: points
                .map((p) => p.sourceId)
                .where((s) => s.isNotEmpty)
                .toSet(),
          ),
        );
      } catch (e) {
        results.add(
          ProbeResult(
            type: type,
            count: 0,
            earliest: null,
            latest: null,
            sample: null,
            sources: const {},
            error: e.toString(),
          ),
        );
      }
      onProgress?.call(i + 1, types.length);
    }

    return ProbeReport(results: results, from: from, to: to);
  }

  static String _describe(HealthDataPoint p) {
    final v = p.value;
    if (v is NumericHealthValue) {
      return '${v.numericValue} ${p.unit.name}';
    }
    if (v is WorkoutHealthValue) {
      return '${v.workoutActivityType.name} '
          '${p.dateTo.difference(p.dateFrom).inMinutes}分';
    }
    return v.toString();
  }
}
