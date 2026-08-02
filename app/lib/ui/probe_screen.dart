import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../health/capability_probe.dart';
import '../health/health_repository.dart';
import '../health/health_types.dart';
import 'permission_flow.dart';

/// Mi Fitness が Health Connect に実際に何を書いているかを確認する画面。
///
/// 実装を進める前にここを実機で 1 回通し、結果に合わせて集計項目と
/// ダッシュボードの構成を決める。推測で先に作ると後で総取り替えになる。
class ProbeScreen extends StatefulWidget {
  const ProbeScreen({super.key, required this.health});

  final HealthRepository health;

  @override
  State<ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<ProbeScreen> {
  ProbeReport? _report;
  bool _running = false;
  int _done = 0;
  int _total = 0;
  String? _error;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
      _done = 0;
      _total = HealthTypeCatalog.androidTypes.length;
    });

    try {
      // 権限が下りていないと全項目が 0 件になり、
      // 「Mi Fitness が書いていない」と誤診してしまう。先に権限を確保する。
      final ok = await ensureHealthPermissions(context, widget.health);
      if (!ok) {
        setState(() {
          _running = false;
          _error = '権限が許可されていないため調査できません';
        });
        return;
      }

      final report = await CapabilityProbe(widget.health).run(
        days: 30,
        onProgress: (done, total) {
          if (mounted) setState(() => _done = done);
        },
      );
      if (mounted) setState(() => _report = report);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Scaffold(
      appBar: AppBar(
        title: const Text('取得できるデータの確認'),
        actions: [
          if (report != null)
            IconButton(
              tooltip: 'レポートをコピー',
              icon: const Icon(Icons.copy_all),
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: report.toReportText()),
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('レポートをコピーしました')));
                }
              },
            ),
        ],
      ),
      body: Column(
        children: [
          if (_running)
            LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
          Expanded(
            child: report == null ? _intro(context) : _results(context, report),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _running ? null : _run,
        icon: const Icon(Icons.play_arrow),
        label: Text(report == null ? '調査を開始' : '再調査'),
      ),
    );
  }

  Widget _intro(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('何を調べるか', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text(
          'Xiaomi の Mi Fitness が Health Connect にどの指標を書き込んでいるかは公表されていません。\n'
          '歩数・睡眠・心拍・ワークアウトは確認できていますが、SpO2 や心拍変動は '
          '端末とアプリのバージョン次第で書かれないことがあります。\n\n'
          '過去30日分を型ごとに 1 件ずつ問い合わせ、実際に返ってくるものを確定させます。',
        ),
        const SizedBox(height: 16),
        Text('前提', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text(
          '・Mi Fitness アプリ側で Health Connect 連携を ON にしてあること\n'
          '・バンドとの同期が済んでいること',
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!),
            ),
          ),
        ],
      ],
    );
  }

  Widget _results(BuildContext context, ProbeReport report) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('結果', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text('取得できた: ${report.available.length} 種類'),
                Text('データ無し: ${report.missing.length} 種類'),
                if (report.failed.isNotEmpty)
                  Text(
                    'エラー: ${report.failed.length} 種類',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (final entry in HealthTypeCatalog.groups.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
            child: Text(entry.key, style: theme.textTheme.titleSmall),
          ),
          for (final type in entry.value)
            _row(context, report.results.firstWhere((r) => r.type == type)),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, ProbeResult r) {
    final theme = Theme.of(context);
    final (icon, color) = switch (r) {
      ProbeResult(error: != null) => (
        Icons.error_outline,
        theme.colorScheme.error,
      ),
      ProbeResult(hasData: true) => (Icons.check_circle, Colors.green),
      _ => (Icons.remove_circle_outline, theme.disabledColor),
    };

    return ListTile(
      dense: true,
      leading: Icon(icon, color: color),
      title: Text(r.label),
      subtitle: Text(
        r.error != null
            ? r.error!
            : r.hasData
            ? '${r.count} 件'
                  '${r.sample == null ? '' : ' / 例: ${r.sample}'}'
                  '${r.sources.isEmpty ? '' : '\n提供元: ${r.sources.join(", ")}'}'
            : 'データ無し',
        style: theme.textTheme.bodySmall,
      ),
      isThreeLine: r.hasData && r.sources.isNotEmpty,
    );
  }
}
