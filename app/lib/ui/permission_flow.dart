import 'package:flutter/material.dart';

import '../health/health_repository.dart';

/// Health Connect の権限を確保する。必要ならダイアログを出して案内する。
///
/// Android は「許可しない」を 2 回選ぶと以降ダイアログ自体が出なくなる。
/// その状態で黙って false を返すと、ユーザーには何も起きていないように見えるので、
/// 設定アプリで直す必要があることを明示する。
Future<bool> ensureHealthPermissions(
  BuildContext context,
  HealthRepository health,
) async {
  final availability = await health.availability();

  if (!context.mounted) return false;

  switch (availability) {
    case HealthAvailability.unsupported:
      await _alert(
        context,
        'Health Connect を利用できません',
        'この端末では Health Connect が使えません。Android 8.0 以降の端末が必要です。',
      );
      return false;

    case HealthAvailability.needsInstall:
      final install = await _confirm(
        context,
        'Health Connect が必要です',
        'Xiaomi のデータを読むには Health Connect が必要です。Play ストアを開きますか。',
        confirmLabel: 'ストアを開く',
      );
      if (install) await health.openHealthConnectInstall();
      return false;

    case HealthAvailability.available:
      break;
  }

  var status = await health.permissionStatus();
  if (!status.dataTypesGranted) {
    final granted = await health.requestDataTypePermissions();
    if (!granted) {
      if (!context.mounted) return false;
      await _alert(
        context,
        '読み取りが許可されていません',
        'Health Connect の設定画面で、healthtool に対する読み取りを許可してください。\n\n'
        '一度「許可しない」を選ぶとアプリからダイアログを出せなくなります。'
        'その場合は 設定 → セキュリティとプライバシー → Health Connect → アプリの権限 から変更できます。',
      );
      return false;
    }
    status = await health.permissionStatus();
  }

  // 履歴とバックグラウンドは無くても同期自体は動く。
  // 断られても止めずに、取得範囲が狭くなることだけ伝える。
  if (!status.historyGranted) {
    await health.requestHistoryPermission();
  }
  if (!status.backgroundGranted) {
    await health.requestBackgroundPermission();
  }

  return true;
}

Future<void> _alert(BuildContext context, String title, String body) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('閉じる'),
        ),
      ],
    ),
  );
}

Future<bool> _confirm(
  BuildContext context,
  String title,
  String body, {
  required String confirmLabel,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
