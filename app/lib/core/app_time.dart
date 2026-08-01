import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// 暦日の切り出しをタイムゾーン付きで扱うためのユーティリティ。
///
/// 端末のローカル時刻に暗黙に依存すると、旅行中や端末のタイムゾーン設定変更で
/// 日境界がずれて集計が壊れる。どの時間帯で日を切ったかは daily ドキュメントの
/// `tz` に必ず記録し、後から再現できるようにしてある。
class AppTime {
  AppTime._(this.location);

  final tz.Location location;

  static bool _initialized = false;

  /// 既定のタイムゾーン。ユーザー設定で上書きできるようにしてあるが、既定は日本時間。
  static const defaultTimeZone = 'Asia/Tokyo';

  /// タイムゾーンデータベースを読み込む。アプリ起動時に一度だけ呼ぶ。
  static AppTime init([String timeZoneName = defaultTimeZone]) {
    if (!_initialized) {
      tzdata.initializeTimeZones();
      _initialized = true;
    }
    return AppTime._(tz.getLocation(timeZoneName));
  }

  String get timeZoneName => location.name;

  /// 任意の時刻を、このタイムゾーンでの暦日キー (yyyy-MM-dd) に変換する。
  String dayKey(DateTime instant) {
    final local = tz.TZDateTime.from(instant, location);
    return formatDayKey(local);
  }

  /// 暦日キーの 00:00:00 をこのタイムゾーンで返す。
  tz.TZDateTime startOfDay(String dayKey) {
    final parts = dayKey.split('-');
    if (parts.length != 3) {
      throw ArgumentError.value(dayKey, 'dayKey', '想定形式は yyyy-MM-dd');
    }
    return tz.TZDateTime(
      location,
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }

  /// 暦日キーの翌日 00:00:00（= その日の排他的な終端）。
  ///
  /// startOfDay に 24 時間足すのではなく日付を進めることで、
  /// 夏時間の切り替わる地域でも正しい終端になる。
  tz.TZDateTime endOfDay(String dayKey) {
    final start = startOfDay(dayKey);
    return tz.TZDateTime(location, start.year, start.month, start.day + 1);
  }

  /// 今日の暦日キー。
  String today() => dayKey(DateTime.now());

  /// [from] から [to] までの暦日キーを昇順で列挙する（両端を含む）。
  List<String> daysBetween(String from, String to) {
    final result = <String>[];
    var cursor = startOfDay(from);
    final last = startOfDay(to);
    while (!cursor.isAfter(last)) {
      result.add(formatDayKey(cursor));
      cursor = tz.TZDateTime(location, cursor.year, cursor.month, cursor.day + 1);
    }
    return result;
  }

  /// 今日から遡って [days] 日分の暦日キー（今日を含む）。
  List<String> lastDays(int days) {
    final end = startOfDay(today());
    final start = tz.TZDateTime(location, end.year, end.month, end.day - (days - 1));
    return daysBetween(formatDayKey(start), formatDayKey(end));
  }

  /// このタイムゾーンでのローカル時刻に変換する。
  tz.TZDateTime toLocal(DateTime instant) => tz.TZDateTime.from(instant, location);

  /// yyyy-MM-dd 形式に整形する。intl に依存せず、ゼロ埋めを明示する。
  static String formatDayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
