import 'package:health/health.dart';

/// このアプリが Health Connect から読もうとするデータ型の一覧。
///
/// Mi Fitness が Health Connect に実際に何を書くかは公表されていない。
/// 歩数・睡眠・心拍・ワークアウトは確認できているが、SpO2 や心拍変動は
/// 端末とアプリのバージョン次第で書かれない。
/// そのため「取れるかもしれない型」も含めて要求し、実際に何が返ってきたかは
/// Capability Probe 画面 (lib/health/capability_probe.dart) で確定させる。
class HealthTypeCatalog {
  const HealthTypeCatalog._();

  /// 睡眠ステージ。Health Connect は 1 セッションの中の各区間を別レコードとして返す。
  static const sleepStages = <HealthDataType>[
    HealthDataType.SLEEP_DEEP,
    HealthDataType.SLEEP_LIGHT,
    HealthDataType.SLEEP_REM,
    HealthDataType.SLEEP_AWAKE,
    HealthDataType.SLEEP_AWAKE_IN_BED,
    HealthDataType.SLEEP_OUT_OF_BED,
    HealthDataType.SLEEP_ASLEEP,
    HealthDataType.SLEEP_UNKNOWN,
  ];

  /// 睡眠セッション全体（就寝〜起床の 1 区間）。
  static const sleepSession = HealthDataType.SLEEP_SESSION;

  /// 日次集計に使う型のうち、Android の Health Connect で読めるもの。
  ///
  /// health パッケージの [dataTypeKeysAndroid] に含まれない型を要求すると
  /// 例外になるため、ここには Android 対応済みの型だけを並べている。
  /// 注意: 心拍変動は Android では RMSSD のみで、SDNN は取得できない。
  static const androidTypes = <HealthDataType>[
    // 活動量
    HealthDataType.STEPS,
    HealthDataType.DISTANCE_DELTA,
    HealthDataType.ACTIVE_ENERGY_BURNED,
    HealthDataType.TOTAL_CALORIES_BURNED,
    HealthDataType.BASAL_ENERGY_BURNED,
    HealthDataType.FLIGHTS_CLIMBED,
    HealthDataType.WORKOUT,
    // 心拍・バイタル
    HealthDataType.HEART_RATE,
    HealthDataType.RESTING_HEART_RATE,
    HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
    HealthDataType.BLOOD_OXYGEN,
    HealthDataType.RESPIRATORY_RATE,
    HealthDataType.BODY_TEMPERATURE,
    HealthDataType.BLOOD_PRESSURE_SYSTOLIC,
    HealthDataType.BLOOD_PRESSURE_DIASTOLIC,
    // 睡眠
    sleepSession,
    ...sleepStages,
    // 体組成
    HealthDataType.WEIGHT,
    HealthDataType.BODY_FAT_PERCENTAGE,
    HealthDataType.BODY_MASS_INDEX,
    // 水分
    HealthDataType.WATER,
  ];

  /// 画面表示用の日本語ラベル。網羅していない型は enum 名をそのまま出す。
  static const _labels = <HealthDataType, String>{
    HealthDataType.STEPS: '歩数',
    HealthDataType.DISTANCE_DELTA: '移動距離',
    HealthDataType.ACTIVE_ENERGY_BURNED: 'アクティブな消費カロリー',
    HealthDataType.TOTAL_CALORIES_BURNED: '総消費カロリー',
    HealthDataType.BASAL_ENERGY_BURNED: '基礎代謝',
    HealthDataType.FLIGHTS_CLIMBED: '上った階数',
    HealthDataType.WORKOUT: 'ワークアウト',
    HealthDataType.HEART_RATE: '心拍数',
    HealthDataType.RESTING_HEART_RATE: '安静時心拍数',
    HealthDataType.HEART_RATE_VARIABILITY_RMSSD: '心拍変動 (RMSSD)',
    HealthDataType.BLOOD_OXYGEN: '血中酸素 (SpO2)',
    HealthDataType.RESPIRATORY_RATE: '呼吸数',
    HealthDataType.BODY_TEMPERATURE: '体温',
    HealthDataType.BLOOD_PRESSURE_SYSTOLIC: '血圧 (収縮期)',
    HealthDataType.BLOOD_PRESSURE_DIASTOLIC: '血圧 (拡張期)',
    HealthDataType.SLEEP_SESSION: '睡眠セッション',
    HealthDataType.SLEEP_DEEP: '深い睡眠',
    HealthDataType.SLEEP_LIGHT: '浅い睡眠',
    HealthDataType.SLEEP_REM: 'レム睡眠',
    HealthDataType.SLEEP_AWAKE: '覚醒',
    HealthDataType.SLEEP_AWAKE_IN_BED: '覚醒 (就床中)',
    HealthDataType.SLEEP_OUT_OF_BED: '離床',
    HealthDataType.SLEEP_ASLEEP: '睡眠 (ステージ不明)',
    HealthDataType.SLEEP_UNKNOWN: '睡眠 (種別不明)',
    HealthDataType.WEIGHT: '体重',
    HealthDataType.BODY_FAT_PERCENTAGE: '体脂肪率',
    HealthDataType.BODY_MASS_INDEX: 'BMI',
    HealthDataType.WATER: '水分摂取',
  };

  static String label(HealthDataType type) => _labels[type] ?? type.name;

  /// Probe 画面のグループ分け。
  static const groups = <String, List<HealthDataType>>{
    '活動量': [
      HealthDataType.STEPS,
      HealthDataType.DISTANCE_DELTA,
      HealthDataType.ACTIVE_ENERGY_BURNED,
      HealthDataType.TOTAL_CALORIES_BURNED,
      HealthDataType.BASAL_ENERGY_BURNED,
      HealthDataType.FLIGHTS_CLIMBED,
      HealthDataType.WORKOUT,
    ],
    '心拍・バイタル': [
      HealthDataType.HEART_RATE,
      HealthDataType.RESTING_HEART_RATE,
      HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
      HealthDataType.BLOOD_OXYGEN,
      HealthDataType.RESPIRATORY_RATE,
      HealthDataType.BODY_TEMPERATURE,
      HealthDataType.BLOOD_PRESSURE_SYSTOLIC,
      HealthDataType.BLOOD_PRESSURE_DIASTOLIC,
    ],
    '睡眠': [sleepSession, ...sleepStages],
    '体組成・その他': [
      HealthDataType.WEIGHT,
      HealthDataType.BODY_FAT_PERCENTAGE,
      HealthDataType.BODY_MASS_INDEX,
      HealthDataType.WATER,
    ],
  };
}
