import '../../core/app_time.dart';
import '../../models/generated/generated.dart' as m;

/// 暦日 1 日ぶんの枠。データが無い日は [summary] が null になる。
class DaySlot {
  const DaySlot(this.date, this.summary);

  final String date;
  final m.DailySummary? summary;

  bool get hasData => summary != null;
}

/// Firestore から読んだ日次サマリーを、日付の抜けが無い並びに直す。
///
/// 同期エンジンは計測が無かった日のドキュメントを作らない。「計測ゼロ」と
/// 「未同期」を区別するための仕様だが、そのままグラフに渡すと
/// リストの並び順が日付軸として扱われ、**欠測日が詰められて消える**。
/// 2 週間バンドを着けなかった期間が、切れ目のない線として描かれてしまう。
///
/// ここで先頭から末尾までの暦日を全部並べ直し、無い日は null で埋める。
List<DaySlot> denseSlots(List<m.DailySummary> days, AppTime time) {
  if (days.isEmpty) return const [];

  final sorted = [...days]..sort((a, b) => a.date.compareTo(b.date));
  final byDate = {for (final d in sorted) d.date: d};

  return [
    for (final date in time.daysBetween(sorted.first.date, sorted.last.date))
      DaySlot(date, byDate[date]),
  ];
}
