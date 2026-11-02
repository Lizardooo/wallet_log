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
import 'guide_screen.dart';
import 'more_tab.dart';
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
      // Arabic, right to left everywhere, whatever the phone's language.
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
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
  int _tab = _home;
  int _dashRefresh = 0;
  bool _denied = false;
  bool _scanning = false;
  bool _ready = false;
  bool _setupDone = false;
  String? _promptedDay;

  // Tab order. The first tab sits on the right in Arabic (right to left).
  static const _home = 0;
  static const _transactions = 1;
  static const _reports = 3;
  static const _titles = [
    'أموالي',
    'المعاملات',
    'المراجعة',
    'التقارير',
    'الإعدادات',
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
    // The owner finished (or skipped) the wizard: start on the home tab.
    setState(() => _tab = _home);
    await _scan();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('محتاج شرح؟ هتلاقيه في الإعدادات.'),
      action: SnackBarAction(label: 'افتح الشرح', onPressed: _openGuide),
      duration: const Duration(seconds: 8),
    ));
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

  /// Reads the inbox again. [manual] tells the owner what was found.
  Future<void> _scan({bool manual = false}) async {
    if (_scanning) return;
    _scanning = true;
    var ok = false;
    final before = _txs.length;
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
      if (manual && mounted) {
        final added = _txs.length - before;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(added > 0
              ? 'اتقرت الرسايل: $added معاملة جديدة.'
              : 'اتقرت الرسايل: مفيش جديد.'),
        ));
      }
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

  Future<void> _push(Widget page) async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => page));
    await _reload();
  }

  void _openGuide() => _push(const GuideScreen());

  void _openAccounts() => _push(_AccountsPage(onChanged: _reload));

  void _openAi() => _push(_AiPage(onChanged: _reload));

  void _openSuggestions() => _push(const SuggestionsScreen());

  void _openBackup() => _push(SettingsScreen(onRestored: _reload));

  void _import() =>
      importExcelReport(context, accounts: _accounts, onDone: _reload);

  /// Notices at the top of the home tab: only what needs doing now.
  List<Widget> _homeNotices() {
    final cs = Theme.of(context).colorScheme;
    final missing = _accounts.where((a) => a.number.isEmpty).length;
    Widget notice(Key key, IconData icon, String text, String action,
            VoidCallback onTap) =>
        Card(
          key: key,
          color: Colors.orange.withAlpha(36),
          child: ListTile(
            leading: Icon(icon, color: Colors.orange.shade800),
            title: Text(text, style: const TextStyle(fontSize: 14)),
            trailing: TextButton(onPressed: onTap, child: Text(action)),
          ),
        );
    return [
      if (_accounts.isEmpty)
        notice(
            const ValueKey('notice-no-accounts'),
            Icons.sim_card_outlined,
            'لسه ما ضفتش أرقام محافظك. ضيفها عشان نقرا رسايلها.',
            'ضيف',
            _openAccounts)
      else if (missing > 0)
        notice(
            const ValueKey('notice-missing-number'),
            Icons.dialpad,
            missing == 1
                ? 'في محفظة من غير رقم. الموبايل ما عرفش رقمها، اكتبه بنفسك.'
                : 'في $missing محافظ من غير رقم. الموبايل ما عرفش أرقامها، '
                    'اكتبها بنفسك.',
            'اكتب الرقم',
            _openAccounts),
      if (_txs.isEmpty)
        Card(
          key: const ValueKey('notice-guide'),
          color: cs.primaryContainer,
          child: ListTile(
            leading: Icon(Icons.menu_book, color: cs.onPrimaryContainer),
            title: Text('أول مرة؟ شوف الشرح خطوة بخطوة',
                style: TextStyle(color: cs.onPrimaryContainer)),
            trailing: Icon(Icons.chevron_right, color: cs.onPrimaryContainer),
            onTap: _openGuide,
          ),
        ),
    ];
  }

  Future<void> _excludeTx(Tx t, {String? note}) async {
    final decision = await showExclusionDialog(context, t, _txs);
    if (decision == null) return;
    await TxDb.exclude(t.id, decision.disposition,
        match: decision.match,
        text: decision.text,
        similar: decision.similar);
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
    final canExport = _tab == _transactions || _tab == _reports;
    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.all(8),
          child: Image.asset('assets/logo.png'),
        ),
        title: Text(_titles[_tab], maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (canExport)
            IconButton(
              icon: const Icon(Icons.download),
              tooltip: 'تصدير تقرير Excel',
              onPressed: () => exportExcelReport(
                context,
                txs: _tab == _transactions
                    ? _txs.where((t) => _filter.matches(t, _accounts)).toList()
                    : _txs
                        .where((t) => _reportFilter.matchesBase(t, _accounts))
                        .toList(),
                accounts: _accounts,
              ),
            ),
          IconButton(
            key: const ValueKey('refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: 'قراءة الرسايل الجديدة',
            onPressed: () => _scan(manual: true),
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
                    const Icon(Icons.sms_outlined, size: 48),
                    const SizedBox(height: 12),
                    const Text(
                      'التطبيق محتاج إذن قراءة الرسايل عشان يقرا رسايل المحافظ. '
                      'كل حاجة بتتعمل على الموبايل ده بس.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                        onPressed: _scan, child: const Text('اسمح بالقراءة')),
                  ],
                ),
              ),
            )
          : IndexedStack(
              index: _tab,
              children: [
                DashboardTab(refresh: _dashRefresh, header: _homeNotices()),
                TransactionsTab(
                  txs: _txs,
                  accounts: _accounts,
                  filter: _filter,
                  mismatches: _mismatch,
                  onChanged: () => setState(() {}),
                  onTap: _openTx,
                  onRefresh: _scan,
                ),
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
                ReportsTab(
                  filter: _reportFilter,
                  txs: _txs,
                  accounts: _accounts,
                  onChanged: _reload,
                ),
                MoreTab(
                  accounts: _accounts,
                  onGuide: _openGuide,
                  onAccounts: _openAccounts,
                  onDaily: _openDaily,
                  onSuggestions: _openSuggestions,
                  onImport: _import,
                  onAi: _openAi,
                  onBackup: _openBackup,
                ),
              ],
            ),
      floatingActionButton: _tab == _transactions
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
              },
            )
          : null,
      bottomNavigationBar: NavigationBar(
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'الرئيسية'),
          const NavigationDestination(
              icon: Icon(Icons.list_alt), label: 'المعاملات'),
          NavigationDestination(
              icon: Badge(
                isLabelVisible: _reviewCount > 0,
                label: Text(_reviewCount > 99 ? '99+' : '$_reviewCount'),
                child: const Icon(Icons.rule),
              ),
              label: 'المراجعة'),
          const NavigationDestination(
              icon: Icon(Icons.bar_chart), label: 'التقارير'),
          NavigationDestination(
              icon: Badge(
                isLabelVisible: _accounts.isEmpty ||
                    _accounts.any((a) => a.number.isEmpty),
                smallSize: 8,
                child: const Icon(Icons.settings_outlined),
              ),
              label: 'الإعدادات'),
        ],
      ),
    );
  }

  /// Messages waiting for the owner's decision, shown on the review tab.
  int get _reviewCount =>
      _txs.where((t) => !t.isExcluded && (t.review || t.isUnknown)).length;
}

/// Wallet numbers and the daily reminder, opened from the settings tab. It
/// reloads its own data so edits show at once.
class _AccountsPage extends StatefulWidget {
  final Future<void> Function() onChanged;
  const _AccountsPage({required this.onChanged});

  @override
  State<_AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<_AccountsPage> {
  List<Account>? _accounts;
  List<Tx> _txs = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final a = await TxDb.accounts();
    final t = await TxDb.allTx();
    if (mounted) {
      setState(() {
        _accounts = a;
        _txs = t;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _accounts;
    return Scaffold(
      appBar: AppBar(title: const Text('محافظي وأرقامي')),
      body: accounts == null
          ? const Center(child: CircularProgressIndicator())
          : AccountsTab(
              txs: _txs,
              accounts: accounts,
              onSave: (a) async {
                await TxDb.saveAccount(a);
                await _load();
                await widget.onChanged();
              },
              onDelete: (id) async {
                await TxDb.deleteAccount(id);
                await _load();
                await widget.onChanged();
              },
              onOpenDaily: () async {
                final openings = await TxDb.openings();
                if (!context.mounted) return;
                await Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => DailyPage(
                      txs: _txs, accounts: accounts, openings: openings),
                ));
              },
            ),
    );
  }
}

/// The optional Gemini classification, opened from the settings tab.
class _AiPage extends StatefulWidget {
  final Future<void> Function() onChanged;
  const _AiPage({required this.onChanged});

  @override
  State<_AiPage> createState() => _AiPageState();
}

class _AiPageState extends State<_AiPage> {
  List<Tx>? _txs;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = await TxDb.allTx();
    if (mounted) setState(() => _txs = t);
  }

  @override
  Widget build(BuildContext context) {
    final txs = _txs;
    return Scaffold(
      appBar: AppBar(title: const Text('الذكاء الاصطناعي')),
      body: txs == null
          ? const Center(child: CircularProgressIndicator())
          : AiTab(
              txs: txs,
              onChanged: () async {
                await _load();
                await widget.onChanged();
              },
            ),
    );
  }
}
