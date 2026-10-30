import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'db.dart';

void main() => runApp(const WalletLogApp());

class WalletLogApp extends StatelessWidget {
  const WalletLogApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wallet Log',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

const _wallets = [
  'Vodafone Cash',
  'InstaPay',
  'Orange Cash',
  'Etisalat Cash / Fawry',
];

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const _sms = MethodChannel('wallet_log/sms');
  List<Tx> _items = [];
  String? _filter;
  bool _denied = false;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scan();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_denied) _scan();
  }

  Future<void> _scan() async {
    if (_scanning) return;
    _scanning = true;
    try {
      final granted = await _sms.invokeMethod<bool>('requestPermission') ?? false;
      if (!granted) {
        if (mounted) setState(() => _denied = true);
        return;
      }
      if (mounted) setState(() => _denied = false);

      final msgs = await _sms.invokeMethod<List<dynamic>>('readInbox') ?? [];
      for (final raw in msgs) {
        final m = Map<String, dynamic>.from(raw as Map);
        await TxDb.addSms(
          (m['address'] ?? '') as String,
          (m['body'] ?? '') as String,
          (m['date'] ?? 0) as int,
        );
      }
      await _load();
    } finally {
      _scanning = false;
    }
  }

  Future<void> _load() async {
    final items = await TxDb.all(wallet: _filter);
    if (mounted) setState(() => _items = items);
  }

  String _fmt(double v) => v.toStringAsFixed(2);

  String _date(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month).millisecondsSinceEpoch;
    double inSum = 0, outSum = 0;
    for (final t in _items.where((t) => t.ts >= monthStart)) {
      if (t.isIn) {
        inSum += t.amount;
      } else {
        outSum += t.amount;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallet Log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rescan messages',
            onPressed: _scan,
          ),
        ],
      ),
      body: _denied
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'SMS permission is needed to read your wallet messages. '
                      'They are only processed on this phone.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _scan, child: const Text('Grant access')),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      _stat('In this month', inSum, Colors.green),
                      _stat('Out this month', outSum, Colors.red),
                      _stat('Net', inSum - outSum, Colors.teal),
                    ],
                  ),
                ),
                SizedBox(
                  height: 48,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final w in [null, ..._wallets])
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: ChoiceChip(
                            label: Text(w ?? 'All'),
                            selected: _filter == w,
                            onSelected: (_) {
                              setState(() => _filter = w);
                              _load();
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _items.isEmpty
                      ? const Center(child: Text('No transactions found yet'))
                      : RefreshIndicator(
                          onRefresh: _scan,
                          child: ListView.separated(
                            itemCount: _items.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final t = _items[i];
                              final color = t.isIn ? Colors.green : Colors.red;
                              return ListTile(
                                leading: Icon(
                                  t.isIn ? Icons.south_west : Icons.north_east,
                                  color: color,
                                ),
                                title: Text(
                                  '${t.isIn ? '+' : '-'}${_fmt(t.amount)} EGP',
                                  style: TextStyle(
                                    color: color,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: Text(
                                  '${t.wallet} · ${_date(t.ts)}'
                                  '${t.party != null ? '\n${t.party}' : ''}',
                                ),
                                trailing: t.balance == null
                                    ? null
                                    : Text('Bal ${_fmt(t.balance!)}'),
                                isThreeLine: t.party != null,
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _stat(String label, double v, Color c) => Expanded(
        child: Column(
          children: [
            Text(label, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            Text(
              _fmt(v),
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: c),
            ),
          ],
        ),
      );
}
