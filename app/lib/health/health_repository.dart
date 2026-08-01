import 'package:flutter/foundation.dart';
import 'package:health/health.dart';

import 'health_types.dart';

/// Health Connect が使えるかどうかの状態。
enum HealthAvailability {
  /// 使える。
  available,

  /// 端末に Health Connect が入っていない、またはアップデートが必要。
  needsInstall,

  /// この端末では利用できない（Android 以外、または非対応端末）。
  unsupported,
}

/// 権限の取得状況。
class HealthPermissionStatus {
  const HealthPermissionStatus({
    required this.dataTypesGranted,
    required this.historyGranted,
    required this.backgroundGranted,
  });

  /// 要求したデータ型の読み取りが許可されているか。
  final bool dataTypesGranted;

  /// 30日より前のデータを読む権限。これが無いと初回バックフィルが頭打ちになる。
  final bool historyGranted;

  /// アプリが前面に無い状態で読む権限。定期同期に必要。
  final bool backgroundGranted;

  bool get isMinimallyUsable => dataTypesGranted;
}

/// health パッケージの薄いラッパー。
///
/// 呼び出し側が `Health()` を直接触らないようにして、
/// 権限やプラットフォーム差の扱いを 1 箇所に閉じ込める。
class HealthRepository {
  HealthRepository({Health? health}) : _health = health ?? Health();

  final Health _health;
  bool _configured = false;

  /// 要求するデータ型。Android の Health Connect で読める型に限る。
  List<HealthDataType> get requestedTypes => HealthTypeCatalog.androidTypes;

  Future<void> configure() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  Future<HealthAvailability> availability() async {
    if (!defaultTargetPlatform.isAndroid) return HealthAvailability.unsupported;
    await configure();
    final status = await _health.getHealthConnectSdkStatus();
    return switch (status) {
      HealthConnectSdkStatus.sdkAvailable => HealthAvailability.available,
      HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired =>
        HealthAvailability.needsInstall,
      HealthConnectSdkStatus.sdkUnavailable => HealthAvailability.unsupported,
      null => HealthAvailability.unsupported,
    };
  }

  /// Play ストアの Health Connect のページを開く。
  Future<void> openHealthConnectInstall() => _health.installHealthConnect();

  Future<HealthPermissionStatus> permissionStatus() async {
    await configure();
    // hasPermissions は Android では「拒否されていない」までしか判定できず null を返しうる。
    // null は「不明」なので未許可扱いにし、requestAuthorization を試させる。
    final granted = await _health.hasPermissions(requestedTypes) ?? false;
    return HealthPermissionStatus(
      dataTypesGranted: granted,
      historyGranted: await _health.isHealthDataHistoryAuthorized(),
      backgroundGranted: await _health.isHealthDataInBackgroundAuthorized(),
    );
  }

  /// データ型の読み取り権限を要求する。
  ///
  /// Android では一度「許可しない」を選ぶと以降ダイアログが出なくなることがある。
  /// その場合は false が返るので、呼び出し側は設定アプリへの導線を出すこと。
  Future<bool> requestDataTypePermissions() async {
    await configure();
    return _health.requestAuthorization(requestedTypes);
  }

  /// 30日より前のデータを読む権限を要求する。
  Future<bool> requestHistoryPermission() async {
    await configure();
    if (!await _health.isHealthDataHistoryAvailable()) return false;
    return _health.requestHealthDataHistoryAuthorization();
  }

  /// バックグラウンド読み取り権限を要求する。
  Future<bool> requestBackgroundPermission() async {
    await configure();
    if (!await _health.isHealthDataInBackgroundAvailable()) return false;
    return _health.requestHealthDataInBackgroundAuthorization();
  }

  /// 指定期間のデータ点を取得する。
  ///
  /// 手入力のデータは除外する。ウェアラブルの実測値を評価したいのであって、
  /// ユーザーが後から打ち込んだ値を混ぜると LLM の判断材料が濁るため。
  Future<List<HealthDataPoint>> fetch({
    required List<HealthDataType> types,
    required DateTime start,
    required DateTime end,
  }) async {
    await configure();
    if (types.isEmpty) return const [];
    return _health.getHealthDataFromTypes(
      types: types,
      startTime: start,
      endTime: end,
      recordingMethodsToFilter: const [RecordingMethod.manual],
    );
  }
}

extension on TargetPlatform {
  bool get isAndroid => this == TargetPlatform.android;
}
