# Graph Report - wallet_log  (2026-11-01)

## Corpus Check
- Corpus is ~29,419 words - fits in a single context window. You may not need a graph.

## Summary
- 908 nodes · 1099 edges · 34 communities (29 shown, 5 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 14 edges (avg confidence: 0.83)
- Token cost: 252,693 input · 0 output

## Community Hubs (Navigation)
- SMS Parser
- Tab Screens UI
- Account Logic & Stats
- Excel Import
- SQLite Database Layer
- Gemini AI Client
- Android Native Receivers
- Excel Export & Review
- App Shell & Lifecycle
- Onboarding Wizard
- AI Tab Screen
- Exclusion Rules
- README Product Docs
- Pubspec Dependencies
- APK Build Workflow
- Tab Widget Classes
- Filter Widget Tests
- Review Widget Tests
- Review Home Test
- Logic & Filter Tests
- Exclusions DB Test
- Importer Test
- Parser & Gemini Tests
- graphify Workflow Rules
- App Logo Image
- Launcher Icon hdpi
- Launcher Icon xhdpi
- Launcher Icon xxhdpi
- Launcher Icon xxxhdpi
- Launcher Icon mdpi
- Gemini Exception
- Direction Enum
- Transaction Type Enum
- Setup Script

## God Nodes (most connected - your core abstractions)
1. `MainActivity` - 11 edges
2. `dependencies` - 10 edges
3. `Gemini AI Classification` - 8 edges
4. `Dir` - 7 edges
5. `with` - 6 edges
6. `TxType` - 6 edges
7. `Reminder` - 6 edges
8. `graphify Knowledge Graph (graphify-out/)` - 6 edges
9. `steps` - 5 edges
10. `Accuracy Safeguards` - 5 edges

## Surprising Connections (you probably didn't know these)
- `graphify Skill (/graphify trigger)` --conceptually_related_to--> `graphify Knowledge Graph (graphify-out/)`  [INFERRED]
  .claude/CLAUDE.md → CLAUDE.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Amwali App Tab Screens** — readme_transactions_screen, readme_daily_screen, readme_reports_screen, readme_accounts_screen, readme_ai_screen [EXTRACTED 1.00]
- **Keep Uncertain Amounts Out of Totals** — readme_accuracy_safeguards, readme_review_view, readme_confidence_threshold, readme_deduction_rule, readme_user_corrections_preserved [INFERRED 0.85]
- **graphify Agent Workflow Rules** — claude_graphify_query_first_rule, claude_graphify_wiki_navigation, claude_graph_report, claude_graphify_update_rule, claude_graph_json_rebuild_policy [EXTRACTED 1.00]

## Communities (34 total, 5 thin omitted)

### Community 0 - "SMS Parser"
Cohesion: 0.02
Nodes (86): amount, _amountRe, amounts, _amt, ar, b, balance, _balanceRe (+78 more)

### Community 1 - "Tab Screens UI"
Cohesion: 0.02
Nodes (75): accounts, _activeFilters, _apply, askAmount, build, c, _card, _closeSearch (+67 more)

### Community 2 - "Account Logic & Stats"
Cohesion: 0.03
Nodes (68): Account, account, accountFor, accountId, accountLabel, accountStats, AccStat, add (+60 more)

### Community 3 - "Excel Import"
Cohesion: 0.03
Nodes (69): amount, best, bestCols, bestLen, body, cellAt, columns, contains (+61 more)

### Community 4 - "SQLite Database Layer"
Cohesion: 0.03
Nodes (68): accounts, _addColumn, ai, aiNote, AiUpdate, allSettings, allTx, amount (+60 more)

### Community 5 - "Gemini AI Client"
Cohesion: 0.03
Nodes (58): AiClass, AiItem, amount, _asDir, _asDouble, _asInt, _asType, _base (+50 more)

### Community 6 - "Android Native Receivers"
Cohesion: 0.07
Nodes (4): BootReceiver, DailyReminderReceiver, MainActivity, Reminder

### Community 7 - "Excel Export & Review"
Cohesion: 0.05
Nodes (32): accSheet, buildReportXlsx, byAccount, daily, days, encode, excel, exportExcelReport (+24 more)

### Community 8 - "App Shell & Lifecycle"
Cohesion: 0.05
Nodes (33): TxFilter, _accounts, _afterSetup, _boot, build, createState, _denied, didChangeAppLifecycleState (+25 more)

### Community 9 - "Onboarding Wizard"
Cohesion: 0.05
Nodes (39): active, _addManualNumber, _aiError, _autoName, _back, build, carrier, createState (+31 more)

### Community 10 - "AI Tab Screen"
Cohesion: 0.05
Nodes (34): _applied, _batch, build, createState, dispose, _done, _eligible, _error (+26 more)

### Community 11 - "Exclusion Rules"
Cohesion: 0.06
Nodes (30): Tx, dispositionFromString, ExclusionMatch, ExclusionRule, id, match, matches, matchingExclusionRule (+22 more)

### Community 12 - "README Product Docs"
Cohesion: 0.09
Nodes (24): Accounts Screen (الحسابات), Classification Batches of 10, AI Screen (الذكاء), Amwali (أموالي) Wallet Log App, Daily Reminder Notification, Daily Screen (اليومي), Egyptian Wallet Types (Vodafone Cash, InstaPay, Orange Cash, Etisalat Cash/Fawry), Transaction and Report Excel Export (+16 more)

### Community 13 - "Pubspec Dependencies"
Cohesion: 0.07
Nodes (26): dependencies, excel, file_selector, flutter, flutter_localizations, http, path, path_provider (+18 more)

### Community 14 - "APK Build Workflow"
Cohesion: 0.11
Nodes (18): runs-on, steps, jobs, build, name, on, push, workflow_dispatch (+10 more)

### Community 15 - "Tab Widget Classes"
Cohesion: 0.17
Nodes (14): AiTab, _AiTabState, AccountsTab, _AccountsTabState, DailyPage, _DailyPageState, DailyTab, _DailyTabState (+6 more)

### Community 16 - "Filter Widget Tests"
Cohesion: 0.13
Nodes (13): accounts, app, chip, closeFilters, firstDay, main, openFilters, pumpAndSettle (+5 more)

### Community 17 - "Review Widget Tests"
Cohesion: 0.15
Nodes (10): app, chooseBucket, ensureVisible, item, main, messages, pumpAndSettle, review (+2 more)

### Community 19 - "Logic & Filter Tests"
Cohesion: 0.20
Nodes (5): main, tx, accounts, main, transaction

### Community 20 - "Exclusions DB Test"
Cohesion: 0.22
Nodes (4): body, dir, main, sms

### Community 21 - "Importer Test"
Cohesion: 0.22
Nodes (5): excel, fromList, main, sample, sheet

### Community 22 - "Parser & Gemini Tests"
Cohesion: 0.25
Nodes (4): _items, main, main, p

### Community 23 - "graphify Workflow Rules"
Cohesion: 0.33
Nodes (4): graphify Skill (/graphify trigger), GRAPH_REPORT.md, graphify Knowledge Graph (graphify-out/), graphify Wiki Index Navigation

### Community 24 - "App Logo Image"
Cohesion: 0.50
Nodes (5): Wallet Log App Logo, Gold Coin with Plus Sign, Rounded-Square App Icon Format, Teal-Green Brand Palette, White Wallet Illustration

### Community 25 - "Launcher Icon hdpi"
Cohesion: 0.67
Nodes (4): Gold Coin with Plus Sign, Green Brand Color, Wallet Log Android Launcher Icon (hdpi), Wallet Motif

### Community 26 - "Launcher Icon xhdpi"
Cohesion: 0.83
Nodes (4): Gold Coin with Plus Motif, Green Brand Background, Wallet Log Launcher Icon (xhdpi), White Wallet Motif

### Community 27 - "Launcher Icon xxhdpi"
Cohesion: 0.67
Nodes (4): Wallet Log Launcher Icon (xxhdpi), Plus Coin Motif, Teal and Gold Brand Palette, Wallet Motif

### Community 28 - "Launcher Icon xxxhdpi"
Cohesion: 0.67
Nodes (4): Wallet Log Launcher Icon (xxxhdpi), Gold Coin with Plus Sign, Dark Teal-Green Brand Palette, Wallet Motif

### Community 29 - "Launcher Icon mdpi"
Cohesion: 1.00
Nodes (3): Wallet Log App Branding, Wallet Log Launcher Icon (mdpi), Wallet and Coin Motif

## Ambiguous Edges - Review These
- `White Wallet Motif` → `Green Brand Background`  [AMBIGUOUS]
  native/res/mipmap-xhdpi/ic_launcher.png · relation: conceptually_related_to

## Knowledge Gaps
- **629 isolated node(s):** `_green`, `_red`, `_orange`, `txs`, `_batch` (+624 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 714 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **5 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Dir` connect `Direction Enum` to `SMS Parser`, `Tab Screens UI`, `Account Logic & Stats`, `Excel Import`, `SQLite Database Layer`, `Gemini AI Client`?**
  _High betweenness centrality (0.071) - this node is a cross-community bridge._
- **What connects `_green`, `_red`, `_orange` to the rest of the system?**
  _629 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `SMS Parser` be split into smaller, more focused modules?**
  _Cohesion score 0.022727272727272728 - nodes in this community are weakly interconnected._
- **Why does `TxType` connect `Transaction Type Enum` to `SMS Parser`, `Tab Screens UI`, `Excel Import`, `SQLite Database Layer`, `Gemini AI Client`?**
  _High betweenness centrality (0.054) - this node is a cross-community bridge._
- **Should `Tab Screens UI` be split into smaller, more focused modules?**
  _Cohesion score 0.024691358024691357 - nodes in this community are weakly interconnected._
- **Why does `TxFilter` connect `App Shell & Lifecycle` to `Tab Screens UI`, `Account Logic & Stats`?**
  _High betweenness centrality (0.009) - this node is a cross-community bridge._

### Low-confidence Hints
_AMBIGUOUS edges — the extractor was unsure. Verify before acting on these._

- **What is the exact relationship between `White Wallet Motif` and `Green Brand Background`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._