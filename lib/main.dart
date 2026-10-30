import 'package:flutter/material.dart';

import 'db.dart';
import 'logic.dart';
import 'tabs.dart';

void main() => runApp(const WalletLogApp());

class WalletLogApp extends StatelessWidget {
  const WalletLogApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wallet Log',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  List<Tx> _txs = [];
  List<Account> _accounts = [];
  Map<String, double> _openings = {};
  int? _accountFilter;
  int _tab = 0;
  bool _denied = false;
  bool _scanning = false;
  String? _promptedDay;

  static const _titles = ['المعاملات', 'اليومي', 'التقارير', 'الحسابات'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
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

  Future<void> _reload() async {
    final txs = await TxDb.allTx();
    final accounts = await TxDb.accounts();
    final openings = await TxDb.openings();
    if (!mounted) return;
    setState(() {
      _txs = txs;
      _accounts = accounts;
      _openings = openings;
    });
  }

  Future<void> _scan() async {
    if (_scanning) return;
    _scanning = true;
    var ok = false;
    try {
      final granted =
          await smsChannel.invokeMethod<bool>('requestPermission') ?? false;
      if (!granted) {
        if (mounted) setState(() => _denied = true);
        return;
      }
      if (mounted) setState(() => _denied = false);

      final msgs =
          await smsChannel.invokeMethod<List<dynamic>>('readInbox') ?? [];
      for (final raw in msgs) {
        final m = Map<String, dynamic>.from(raw as Map);
        final s = m['subId'];
        await TxDb.addSms(
          (m['address'] ?? '') as String,
          (m['body'] ?? '') as String,
          (m['date'] ?? 0) as int,
          (s is int && s >= 0) ? s : null,
        );
      }
      await _reload();
      ok = true;
    } finally {
      _scanning = false;
    }
    if (ok) await _maybePromptOpening();
  }

  /// Once a day, asks for the opening balance of every account that has none.
  Future<void> _maybePromptOpening() async {
    final today = dayKey(DateTime.now());
    if (!mounted || _promptedDay == today || _accounts.isEmpty) return;
    final missing = _accounts
        .where((a) => !_openings.containsKey('${a.id}|$today'))
        .toList();
    _promptedDay = today;
    if (missing.isEmpty) return;

    final rows = dailyRows(today, _txs, _accounts, _openings);
    final prefill = <int, double?>{};
    for (final r in rows) {
      final id = r.account?.id;
      if (id != null) prefill[id] = r.opening;
    }
    final result = await showOpeningDialog(context, today, missing, prefill);
    if (result == null) return;
    for (final e in result.entries) {
      await TxDb.setOpening(e.key, today, e.value);
    }
    await _reload();
  }

  Future<void> _editNote(Tx t) async {
    final text = await askText(context, 'ملاحظة على المعاملة', t.note);
    if (text == null) return;
    await TxDb.setNote(t.id, text);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_tab]),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'إعادة قراءة الرسائل',
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
                      'يحتاج التطبيق إذن قراءة الرسائل لقراءة رسائل المحافظ. تتم المعالجة على هذا الهاتف فقط.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _scan,
                      child: const Text('السماح'),
                    ),
                  ],
                ),
              ),
            )
          : IndexedStack(
              index: _tab,
              children: [
                TransactionsTab(
                  txs: _txs,
                  accounts: _accounts,
                  accountFilter: _accountFilter,
                  onFilter: (id) => setState(() => _accountFilter = id),
                  onTap: _editNote,
                  onRefresh: _scan,
                ),
                DailyTab(
                  txs: _txs,
                  accounts: _accounts,
                  openings: _openings,
                  onSetOpening: (id, day, amount) async {
                    await TxDb.setOpening(id, day, amount);
                    await _reload();
                  },
                ),
                ReportsTab(txs: _txs, accounts: _accounts),
                AccountsTab(
                  txs: _txs,
                  accounts: _accounts,
                  onSave: (a) async {
                    await TxDb.saveAccount(a);
                    await _reload();
                  },
                  onDelete: (id) async {
                    await TxDb.deleteAccount(id);
                    await _reload();
                  },
                ),
              ],
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.list_alt), label: 'المعاملات'),
          NavigationDestination(icon: Icon(Icons.today), label: 'اليومي'),
          NavigationDestination(icon: Icon(Icons.bar_chart), label: 'التقارير'),
          NavigationDestination(
              icon: Icon(Icons.account_balance_wallet), label: 'الحسابات'),
        ],
      ),
    );
  }
}
