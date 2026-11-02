import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'ai_tab.dart';
import 'db.dart';
import 'exporter.dart';
import 'logic.dart';
import 'onboarding.dart';
import 'tabs.dart';
import 'exclusions.dart';
import 'review_actions.dart';
import 'review_strings.dart';
import 'review_tab.dart';
import 'add_tx_screen.dart';
import 'dashboard_tab.dart';
import 'settings_screen.dart';
import 'tx_detail_screen.dart';
import 'suggestions_screen.dart';

void main() => runApp(const WalletLogApp());

class WalletLogApp extends StatelessWidget {
  const WalletLogApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'أموالي',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF0F766E),
        useMaterial3: true,
      ),
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
  List<ExclusionRule> _exclusionRules = [];
  Map<String, double> _openings = {};
  Map<int, double> _mismatch = {};
  final TxFilter _filter = TxFilter();
  final TxFilter _reportFilter = TxFilter(period: DatePeriod.thisMonth);
  int _tab = 5;
  int _dashRefresh = 0;
  bool _denied = false;
  bool _scanning = false;
  bool _ready = false;
  bool _setupDone = false;
  String? _promptedDay;

  static const _titles = [
    'المعاملات',
    'التقارير',
    'الحسابات',
    'الذكاء الاصطناعي',
    'المراجعة',
    'الرئيسية',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  /// First run opens the setup wizard; later runs go straight to the data.
  Future<void> _boot() async {
    await _reload();
    if (!mounted) return;
    if (_setupDone) await _scan();
  }

  Future<void> _afterSetup() async {
    await _reload();
    if (!mounted) return;
    // The owner finished (or skipped) the wizard: show the reports first.
    setState(() => _tab = 5);
    await _scan();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_denied && _setupDone) {
      _scan();
    }
  }

  Future<void> _reload() async {
    final txs = await TxDb.allTx();
    final exclusionRules = await TxDb.exclusionRules();
    final accounts = await TxDb.accounts();
    final openings = await TxDb.openings();
    final settings = await TxDb.allSettings();
    final mismatch = balanceMismatches(txs, accounts);
    // A deleted account must not leave a hidden filter with no possible match.
    final accountIds = accounts.map((a) => a.id).toSet();
    for (final filter in [_filter, _reportFilter]) {
      if (filter.accountId != null && !accountIds.contains(filter.accountId)) {
        filter.accountId = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _txs = txs;
      _exclusionRules = exclusionRules;
      _accounts = accounts;
      _openings = openings;
      _mismatch = mismatch;
      _setupDone = settings[TxDb.settingsSetupDone] == '1';
      _ready = true;
      _dashRefresh++;
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
      final raw = <RawSms>[];
      for (final r in msgs) {
        final m = Map<String, dynamic>.from(r as Map);
        final s = m['subId'];
        raw.add(
          RawSms(
            (m['address'] ?? '') as String,
            (m['body'] ?? '') as String,
            (m['date'] ?? 0) as int,
            (s is int && s >= 0) ? s : null,
          ),
        );
      }
      await TxDb.importSms(raw, accounts: _accounts);
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

  Future<void> _openDaily() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DailyPage(
          txs: _txs,
          accounts: _accounts,
          openings: _openings,
        ),
      ),
    );
    await _reload();
  }

  Future<void> _excludeTx(Tx t, {String? note}) async {
    final decision = await showExclusionDialog(context, t, _txs);
    if (decision == null) return;
    await TxDb.exclude(t.id, decision.disposition,
        match: decision.match, text: decision.text);
    if (note != null && note != t.note) await TxDb.setNote(t.id, note);
    await _reload();
  }

  Future<void> _restoreTx(Tx t) async {
    await TxDb.restoreToReview(t.id);
    await _reload();
  }

  Future<void> _openTx(Tx t) async {
    if (t.isExcluded) {
      final action = await showExcludedMessage(context, t);
      if (!mounted) return;
      if (action == ExcludedMessageAction.restore) await _restoreTx(t);
      if (action == ExcludedMessageAction.change) await _excludeTx(t);
      return;
    }
    final go = await Navigator.push<String>(
        context, MaterialPageRoute(builder: (_) => TxDetailScreen(txId: t.id)));
    await _reload();
    if (go != 'edit' || !mounted) return;
    final r = await showTxDialog(context, t, _mismatch[t.id]);
    if (r == null || !mounted) return;
    if (r.exclude) {
      await _excludeTx(t, note: r.note);
      return;
    }
    if (r.note != t.note) await TxDb.setNote(t.id, r.note);
    // Confirming a flagged message (or changing its type/direction) is what
    // makes it count; saving only the note leaves it waiting for review.
    if (r.confirm && (t.review || r.type != t.type || r.dir != t.dir)) {
      await TxDb.setClass(t.id, r.type, r.dir);
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_setupDone) {
      return OnboardingPage(onDone: _afterSetup);
    }
    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.all(8),
          child: Image.asset('assets/logo.png'),
        ),
        title: Text(
            'أموالي · ${_tab == 4 ? reviewText(context, 'المراجعة', 'Review') : _titles[_tab]}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: reviewText(
                context, 'الإعدادات والنسخ الاحتياطي', 'Settings & backup'),
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => SettingsScreen(onRestored: () async {
                          await _reload();
                          if (mounted) setState(() => _dashRefresh++);
                        }))),
          ),
          IconButton(
            icon: const Icon(Icons.lightbulb_outline),
            tooltip: reviewText(context, 'الاقتراحات', 'Suggestions'),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SuggestionsScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'تصدير تقرير Excel',
            onPressed: _tab == 4
                ? null
                : () => exportExcelReport(
                      context,
                      txs: _tab == 0
                          ? _txs
                              .where((t) => _filter.matches(t, _accounts))
                              .toList()
                          : _tab == 1
                              ? _txs
                                  .where((t) =>
                                      _reportFilter.matchesBase(t, _accounts))
                                  .toList()
                              : _txs,
                      accounts: _accounts,
                    ),
          ),
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: 'استيراد تقرير Excel',
            onPressed: () => importExcelReport(context,
                accounts: _accounts, onDone: _reload),
          ),
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
                    FilledButton(onPressed: _scan, child: const Text('السماح')),
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
                  filter: _filter,
                  mismatches: _mismatch,
                  onChanged: () => setState(() {}),
                  onTap: _openTx,
                  onRefresh: _scan,
                ),
                ReportsTab(
                  filter: _reportFilter,
                  txs: _txs,
                  accounts: _accounts,
                  onChanged: _reload,
                ),
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
                  onOpenDaily: _openDaily,
                ),
                AiTab(txs: _txs, onChanged: _reload),
                ReviewTab(
                  txs: _txs,
                  accounts: _accounts,
                  rules: _exclusionRules,
                  onOpen: _openTx,
                  onExclude: _excludeTx,
                  onRestore: _restoreTx,
                  onDeleteRule: (rule) async {
                    await TxDb.deleteExclusionRule(rule.id);
                    await _reload();
                  },
                ),
                DashboardTab(refresh: _dashRefresh),
              ],
            ),
      floatingActionButton: (_tab == 0 || _tab == 5)
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label:
                  Text(reviewText(context, 'تسجيل معاملة', 'Add transaction')),
              onPressed: () async {
                await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const AddTransactionScreen()));
                await _reload();
                if (mounted) setState(() => _dashRefresh++);
              },
            )
          : null,
      bottomNavigationBar: NavigationBar(
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(
              icon: Icon(Icons.list_alt), label: 'المعاملات'),
          const NavigationDestination(
              icon: Icon(Icons.bar_chart), label: 'التقارير'),
          const NavigationDestination(
            icon: Icon(Icons.account_balance_wallet),
            label: 'الحسابات',
          ),
          const NavigationDestination(
            icon: Icon(Icons.auto_awesome),
            label: 'الذكاء',
          ),
          NavigationDestination(
              icon: const Icon(Icons.rule),
              label: reviewText(context, 'المراجعة', 'Review')),
          NavigationDestination(
              icon: const Icon(Icons.home_outlined),
              label: reviewText(context, 'الرئيسية', 'Home')),
        ],
      ),
    );
  }
}
