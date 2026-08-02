import 'package:flutter_test/flutter_test.dart';
import 'package:healthtool/core/app_time.dart';
import 'package:healthtool/models/generated/generated.dart' as m;
import 'package:healthtool/ui/charts/day_slots.dart';

m.DailySummary day(String date, {int steps = 1000}) => m.DailySummary(
  schemaVersion: 1,
  date: date,
  tz: 'Asia/Tokyo',
  activity: m.Activity(steps: steps),
  sources: const ['com.mi.health'],
  coverage: m.Coverage(
    hrCoveredMin: 1200,
    wornHours: 20,
    hasSleep: false,
    hasSteps: true,
  ),
  updatedAt: DateTime.utc(2026, 8, 1),
);

void main() {
  final time = AppTime.init('Asia/Tokyo');

  test('データが無い日を null で埋めて日付軸を連続させる', () {
    // Firestore は計測が無かった日のドキュメントを持たない。
    // そのまま並べるとグラフ上で 07-02 と 07-05 が隣り合ってしまい、
    // 3 日空いていたことが消える。
    final slots = denseSlots([
      day('2026-07-01'),
      day('2026-07-02'),
      day('2026-07-05'),
    ], time);

    expect(slots.map((s) => s.date), [
      '2026-07-01',
      '2026-07-02',
      '2026-07-03',
      '2026-07-04',
      '2026-07-05',
    ]);
    expect(slots.map((s) => s.hasData), [true, true, false, false, true]);
  });

  test('欠測日は summary が null になり、0 にはならない', () {
    final slots = denseSlots([day('2026-07-01'), day('2026-07-03')], time);
    expect(slots[1].summary, isNull);
    // 「歩かなかった 0 歩」と混同させないため
    expect(slots[1].summary?.activity?.steps, isNull);
  });

  test('入力の順序が乱れていても日付順に整える', () {
    final slots = denseSlots([
      day('2026-07-03'),
      day('2026-07-01'),
      day('2026-07-02'),
    ], time);
    expect(slots.map((s) => s.date), [
      '2026-07-01',
      '2026-07-02',
      '2026-07-03',
    ]);
    expect(slots.every((s) => s.hasData), isTrue);
  });

  test('月をまたいでも連続する', () {
    final slots = denseSlots([day('2026-07-30'), day('2026-08-02')], time);
    expect(slots.map((s) => s.date), [
      '2026-07-30',
      '2026-07-31',
      '2026-08-01',
      '2026-08-02',
    ]);
  });

  test('空の入力は空を返す', () {
    expect(denseSlots([], time), isEmpty);
  });

  test('1 日だけならその 1 日', () {
    final slots = denseSlots([day('2026-08-01')], time);
    expect(slots.length, 1);
    expect(slots.single.hasData, isTrue);
  });
}
