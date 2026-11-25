import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

final notifications = FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppDb.init();
  try {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await notifications.initialize(const InitializationSettings(android: android));
  } catch (_) {}
  runApp(const RecursiveStudyApp());
}

// ───────────────────────── Palette ─────────────────────────
class C {
  static const bg = Color(0xFF0B0B0D);
  static const card = Color(0xFF151518);
  static const accent = Color(0xFF8B7CFF);
  static const cyan = Color(0xFF06B6D4);
  static const blue = Color(0xFF3B82F6);
  static const violet = Color(0xFF6C5CE7);
  static const orange = Color(0xFFFF9F43);
  static const green = Color(0xFF34D399);
}

// ───────────────────────── Database (schema v1 unchanged) ─────────────────────────
class AppDb {
  static late Database db;
  static Future<void> init() async {
    db = await openDatabase(
      p.join(await getDatabasesPath(), 'recursive_study.db'),
      version: 1,
      onCreate: (db, v) async {
        await db.execute('CREATE TABLE subjects(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)');
        await db.execute('''CREATE TABLE topics(
          id INTEGER PRIMARY KEY AUTOINCREMENT, subjectId INTEGER NOT NULL,
          title TEXT NOT NULL, notes TEXT DEFAULT '', createdAt TEXT NOT NULL,
          completedAt TEXT, revisionCount INTEGER DEFAULT 0, nextRevision TEXT
        )''');
        await db.execute('''CREATE TABLE sessions(
          id INTEGER PRIMARY KEY AUTOINCREMENT, topicId INTEGER, kind TEXT NOT NULL,
          minutes INTEGER NOT NULL, startedAt TEXT NOT NULL, completed INTEGER DEFAULT 0
        )''');
      },
    );
  }

  static Future<void> deleteTopic(int id) async {
    await db.transaction((txn) async {
      await txn.delete('sessions', where: 'topicId=?', whereArgs: [id]);
      await txn.delete('topics', where: 'id=?', whereArgs: [id]);
    });
  }

  static Future<void> deleteSubject(int id) async {
    await db.transaction((txn) async {
      await txn.rawDelete('DELETE FROM sessions WHERE topicId IN (SELECT id FROM topics WHERE subjectId=?)', [id]);
      await txn.delete('topics', where: 'subjectId=?', whereArgs: [id]);
      await txn.delete('subjects', where: 'id=?', whereArgs: [id]);
    });
  }
}

// ───────────────────────── Stats (computed, no schema change) ─────────────────────────
String dayKey(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
DateTime dayAgo(DateTime d, int n) => DateTime(d.year, d.month, d.day - n);

int daysFromToday(DateTime d) {
  final n = DateTime.now();
  return DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(n.year, n.month, n.day)).inDays;
}

String fmtMin(int m) => m < 60 ? '${m}m' : (m % 60 == 0 ? '${m ~/ 60}h' : '${m ~/ 60}h ${m % 60}m');

class Stats {
  int streak = 0, todayMin = 0, todaySessions = 0, totalMin = 0, totalSessions = 0, revisionSessions = 0;
  List<int> week = List.filled(7, 0); // oldest -> today
  List<DateTime> weekDays = [];

  static Future<Stats> load() async {
    final s = Stats();
    final rows = await AppDb.db.rawQuery(
        "SELECT substr(startedAt,1,10) d, SUM(minutes) m, COUNT(*) c FROM sessions WHERE completed=1 GROUP BY d");
    final mins = <String, int>{};
    final cnt = <String, int>{};
    for (final r in rows) {
      final d = r['d'] as String?;
      if (d == null) continue;
      final m = (r['m'] as num?)?.toInt() ?? 0;
      final c = (r['c'] as num?)?.toInt() ?? 0;
      mins[d] = m;
      cnt[d] = c;
      s.totalMin += m;
      s.totalSessions += c;
    }
    final today = DateTime.now();
    s.todayMin = mins[dayKey(today)] ?? 0;
    s.todaySessions = cnt[dayKey(today)] ?? 0;
    var d = mins.containsKey(dayKey(today)) ? today : dayAgo(today, 1);
    while (mins.containsKey(dayKey(d))) {
      s.streak++;
      d = dayAgo(d, 1);
    }
    s.weekDays = List.generate(7, (i) => dayAgo(today, 6 - i));
    s.week = s.weekDays.map((x) => mins[dayKey(x)] ?? 0).toList();
    s.revisionSessions = Sqflite.firstIntValue(
            await AppDb.db.rawQuery("SELECT COUNT(*) FROM sessions WHERE completed=1 AND kind='revision'")) ??
        0;
    return s;
  }
}

// ───────────────────────── Shared widgets ─────────────────────────
Future<bool> confirmDialog(BuildContext context, String title, String body, String action) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
      ],
    ),
  );
  return r == true;
}

class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap, onLongPress;
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap, this.onLongPress});
  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(20);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: C.card,
        borderRadius: r,
        child: InkWell(
          borderRadius: r,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            padding: padding,
            decoration: BoxDecoration(borderRadius: r, border: Border.all(color: Colors.white.withOpacity(0.06))),
            child: child,
          ),
        ),
      ),
    );
  }
}

class IconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  const IconBadge(this.icon, this.color, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: color.withOpacity(0.16), borderRadius: BorderRadius.circular(14)),
        child: Icon(icon, color: color, size: 22),
      );
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  const EmptyState(this.icon, this.text, {super.key});
  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 18),
        child: Row(children: [
          Icon(icon, color: Colors.white38),
          const SizedBox(width: 14),
          Expanded(child: Text(text, style: const TextStyle(color: Colors.white54))),
        ]),
      );
}

Widget pageTitle(BuildContext context, String t, [String? sub]) => Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
        if (sub != null) ...[const SizedBox(height: 4), Text(sub, style: const TextStyle(color: Colors.grey))],
      ]),
    );

// ───────────────────────── App ─────────────────────────
class RecursiveStudyApp extends StatelessWidget {
  const RecursiveStudyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Recursive Study',
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: C.bg,
          cardColor: C.card,
          colorScheme: ColorScheme.fromSeed(seedColor: C.accent, brightness: Brightness.dark),
          navigationBarTheme: NavigationBarThemeData(
            backgroundColor: C.card,
            indicatorColor: C.accent.withOpacity(0.25),
          ),
        ),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;
  void refresh() => setState(() {});
  @override
  Widget build(BuildContext context) {
    final pages = [Dashboard(onChanged: refresh), SubjectsPage(onChanged: refresh), const ProgressPage()];
    return Scaffold(
      body: SafeArea(child: pages[tab]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.today_outlined), selectedIcon: Icon(Icons.today), label: 'Today'),
          NavigationDestination(icon: Icon(Icons.menu_book_outlined), selectedIcon: Icon(Icons.menu_book), label: 'Subjects'),
          NavigationDestination(icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights), label: 'Progress'),
        ],
      ),
    );
  }
}

// ───────────────────────── Today ─────────────────────────
class Dashboard extends StatefulWidget {
  final VoidCallback onChanged;
  const Dashboard({super.key, required this.onChanged});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  List<Map<String, dynamic>> revisions = [];
  List<Map<String, dynamic>> newTopics = [];
  Stats stats = Stats();
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final now = DateTime.now().toIso8601String();
    revisions = await AppDb.db.rawQuery(
        "SELECT t.*, s.name subject FROM topics t JOIN subjects s ON s.id=t.subjectId WHERE t.nextRevision IS NOT NULL AND t.nextRevision <= ? ORDER BY t.nextRevision",
        [now]);
    newTopics = await AppDb.db.rawQuery(
        "SELECT t.*, s.name subject FROM topics t JOIN subjects s ON s.id=t.subjectId WHERE t.completedAt IS NULL ORDER BY t.createdAt");
    stats = await Stats.load();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(20), children: [
        _hero(),
        const SizedBox(height: 26),
        _section('Revision', revisions, true),
        const SizedBox(height: 14),
        _section('New study', newTopics, false),
        const SizedBox(height: 20),
      ]),
    );
  }

  Widget _hero() {
    final h = DateTime.now().hour;
    final greet = h < 12 ? 'Good morning' : (h < 18 ? 'Good afternoon' : 'Good evening');
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [C.violet, C.blue, C.cyan],
        ),
        boxShadow: [BoxShadow(color: C.violet.withOpacity(0.35), blurRadius: 30, offset: const Offset(0, 12))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(greet, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white)),
        const SizedBox(height: 4),
        Text(DateFormat('EEEE, MMM d').format(DateTime.now()), style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 22),
        Row(children: [
          _pill(Icons.local_fire_department, '${stats.streak}', 'day streak'),
          const SizedBox(width: 10),
          _pill(Icons.timer_outlined, fmtMin(stats.todayMin), 'today'),
          const SizedBox(width: 10),
          _pill(Icons.event_repeat, '${revisions.length}', 'due'),
        ]),
      ]),
    );
  }

  Widget _pill(IconData icon, String value, String label) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
          decoration: BoxDecoration(color: Colors.black.withOpacity(0.22), borderRadius: BorderRadius.circular(16)),
          child: Column(children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white)),
            Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ]),
        ),
      );

  Widget _section(String title, List<Map<String, dynamic>> items, bool revision) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.08), borderRadius: BorderRadius.circular(10)),
            child: Text('${items.length}', style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
      if (items.isEmpty)
        EmptyState(revision ? Icons.check_circle_outline : Icons.library_add_outlined,
            revision ? 'No revisions due.' : 'No new topics. Add one from Subjects.'),
      ...items.map((t) => _tile(t, revision)),
    ]);
  }

  Widget _tile(Map<String, dynamic> t, bool revision) {
    String sub;
    Color color = revision ? C.orange : C.accent;
    if (revision) {
      final days = daysFromToday(DateTime.parse(t['nextRevision'] as String));
      sub = days < 0 ? 'Overdue ${-days}d' : 'Due today';
      if (days < 0) color = Colors.redAccent;
    } else {
      sub = '70 min';
    }
    return Panel(
      onTap: () => _start(t, revision),
      child: Row(children: [
        IconBadge(revision ? Icons.refresh_rounded : Icons.auto_stories, color),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t['title'] as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text('${t['subject']}  ·  ${revision ? 'Revision' : 'New study'}  ·  $sub',
                style: const TextStyle(color: Colors.grey, fontSize: 13)),
          ]),
        ),
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: color.withOpacity(0.18), shape: BoxShape.circle),
          child: Icon(Icons.play_arrow_rounded, color: color),
        ),
      ]),
    );
  }

  Future<void> _start(Map<String, dynamic> t, bool revision) async {
    final minutes = revision ? 20 : 70;
    final ok = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) => TimerPage(
                title: t['title'] as String,
                minutes: minutes,
                topicId: t['id'] as int,
                kind: revision ? 'revision' : 'new')));
    if (ok == true) {
      if (revision) {
        await _completeRevision(t['id'] as int, (t['revisionCount'] as int?) ?? 0);
      } else {
        await _completeNew(t['id'] as int);
      }
    }
    await load();
    widget.onChanged();
  }

  Future<void> _completeNew(int id) async {
    final now = DateTime.now();
    await AppDb.db.update(
        'topics',
        {
          'completedAt': now.toIso8601String(),
          'revisionCount': 0,
          'nextRevision': now.add(const Duration(days: 1)).toIso8601String()
        },
        where: 'id=?',
        whereArgs: [id]);
  }

  Future<void> _completeRevision(int id, int count) async {
    // Recursive spacing: 1, 3, 7, 14, 30 days, then 60 days.
    final days = [1, 3, 7, 14, 30, 60][count.clamp(0, 5)];
    await AppDb.db.update(
        'topics',
        {'revisionCount': count + 1, 'nextRevision': DateTime.now().add(Duration(days: days)).toIso8601String()},
        where: 'id=?',
        whereArgs: [id]);
  }
}

// ───────────────────────── Subjects ─────────────────────────
Future<bool> topicDialog(BuildContext context, {required int subjectId, Map<String, dynamic>? topic}) async {
  final title = TextEditingController(text: (topic?['title'] ?? '') as String);
  final notes = TextEditingController(text: (topic?['notes'] ?? '') as String);
  var changed = false;
  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Text(topic == null ? 'Add topic' : 'Edit topic'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
            controller: title,
            autofocus: topic == null,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Topic / chapter')),
        const SizedBox(height: 8),
        TextField(
            controller: notes,
            minLines: 1,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Notes (optional)')),
      ]),
      actions: [
        if (topic != null)
          TextButton(
            onPressed: () async {
              final ok = await confirmDialog(ctx, 'Delete topic?', 'This also removes its sessions.', 'Delete');
              if (!ok) return;
              await AppDb.deleteTopic(topic['id'] as int);
              changed = true;
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            final t = title.text.trim();
            if (t.isNotEmpty) {
              if (topic == null) {
                await AppDb.db.insert('topics', {
                  'subjectId': subjectId,
                  'title': t,
                  'notes': notes.text.trim(),
                  'createdAt': DateTime.now().toIso8601String(),
                  'revisionCount': 0
                });
              } else {
                await AppDb.db.update('topics', {'title': t, 'notes': notes.text.trim()},
                    where: 'id=?', whereArgs: [topic['id']]);
              }
              changed = true;
            }
            if (ctx.mounted) Navigator.pop(ctx);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  return changed;
}

class SubjectsPage extends StatefulWidget {
  final VoidCallback onChanged;
  const SubjectsPage({super.key, required this.onChanged});
  @override
  State<SubjectsPage> createState() => _SubjectsPageState();
}

class _SubjectsPageState extends State<SubjectsPage> {
  List<Map<String, dynamic>> subjects = [];
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    subjects = await AppDb.db.rawQuery(
        "SELECT s.id, s.name, COUNT(t.id) total, SUM(CASE WHEN t.completedAt IS NOT NULL THEN 1 ELSE 0 END) done FROM subjects s LEFT JOIN topics t ON t.subjectId=s.id GROUP BY s.id ORDER BY s.name");
    if (mounted) setState(() {});
  }

  Future<void> addSubject() async {
    final c = TextEditingController();
    await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('Add subject'),
                content: TextField(
                    controller: c,
                    autofocus: true,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(hintText: 'e.g. English')),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () async {
                        if (c.text.trim().isNotEmpty) await AppDb.db.insert('subjects', {'name': c.text.trim()});
                        if (ctx.mounted) Navigator.pop(ctx);
                        load();
                      },
                      child: const Text('Add'))
                ]));
  }

  Future<void> renameSubject(Map<String, dynamic> s) async {
    final c = TextEditingController(text: s['name'] as String);
    await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('Rename subject'),
                content: TextField(controller: c, autofocus: true, textCapitalization: TextCapitalization.words),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () async {
                        if (c.text.trim().isNotEmpty) {
                          await AppDb.db.update('subjects', {'name': c.text.trim()}, where: 'id=?', whereArgs: [s['id']]);
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                        load();
                      },
                      child: const Text('Save'))
                ]));
  }

  Future<void> subjectMenu(Map<String, dynamic> s) async {
    final choice = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Rename'), onTap: () => Navigator.pop(ctx, 'rename')),
              ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  title: const Text('Delete subject', style: TextStyle(color: Colors.redAccent)),
                  onTap: () => Navigator.pop(ctx, 'delete')),
            ])));
    if (choice == 'rename') {
      await renameSubject(s);
    } else if (choice == 'delete') {
      if (!mounted) return;
      final ok = await confirmDialog(context, 'Delete "${s['name']}"?', 'All its topics and sessions will be removed.', 'Delete');
      if (ok) {
        await AppDb.deleteSubject(s['id'] as int);
        await load();
      }
    }
  }

  Future<void> addTopic(int subjectId) async {
    final changed = await topicDialog(context, subjectId: subjectId);
    if (changed) await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: FloatingActionButton(onPressed: addSubject, child: const Icon(Icons.add)),
        body: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 90), children: [
          pageTitle(context, 'Subjects', 'Tap to open · long-press for options'),
          if (subjects.isEmpty) const EmptyState(Icons.menu_book_outlined, 'No subjects yet. Tap + to add one.'),
          ...subjects.map((s) {
            final total = (s['total'] as num?)?.toInt() ?? 0;
            final done = (s['done'] as num?)?.toInt() ?? 0;
            return Panel(
              onTap: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => TopicList(subject: s)));
                load();
              },
              onLongPress: () => subjectMenu(s),
              child: Row(children: [
                const IconBadge(Icons.menu_book_outlined, C.accent),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s['name'] as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text('$total topics  ·  $done studied', style: const TextStyle(color: Colors.grey, fontSize: 13)),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(value: total == 0 ? 0 : done / total, minHeight: 5),
                    ),
                  ]),
                ),
                IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () => addTopic(s['id'] as int)),
              ]),
            );
          }),
        ]),
      );
}

class TopicList extends StatefulWidget {
  final Map<String, dynamic> subject;
  const TopicList({super.key, required this.subject});
  @override
  State<TopicList> createState() => _TopicListState();
}

class _TopicListState extends State<TopicList> {
  List<Map<String, dynamic>> topics = [];
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    topics = await AppDb.db.query('topics', where: 'subjectId=?', whereArgs: [widget.subject['id']], orderBy: 'createdAt DESC');
    if (mounted) setState(() {});
  }

  String status(Map<String, dynamic> t) {
    final next = t['nextRevision'] as String?;
    if (next == null) return 'Not studied yet';
    final d = daysFromToday(DateTime.parse(next));
    if (d < 0) return 'Revision overdue ${-d}d';
    if (d == 0) return 'Revision due today';
    return 'Next revision: ${DateFormat('MMM d').format(DateTime.parse(next))}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.subject['name'] as String)),
        floatingActionButton: FloatingActionButton(
          onPressed: () async {
            if (await topicDialog(context, subjectId: widget.subject['id'] as int)) await load();
          },
          child: const Icon(Icons.add),
        ),
        body: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
          itemCount: topics.isEmpty ? 1 : topics.length,
          itemBuilder: (_, i) {
            if (topics.isEmpty) return const EmptyState(Icons.library_add_outlined, 'No topics yet. Tap + to add one.');
            final t = topics[i];
            final next = t['nextRevision'] as String?;
            final overdue = next != null && daysFromToday(DateTime.parse(next)) <= 0;
            final notes = (t['notes'] as String?) ?? '';
            final rc = (t['revisionCount'] as int?) ?? 0;
            return Panel(
              onTap: () async {
                if (await topicDialog(context, subjectId: widget.subject['id'] as int, topic: t)) await load();
              },
              child: Row(children: [
                IconBadge(
                    next == null ? Icons.fiber_new_outlined : (overdue ? Icons.refresh_rounded : Icons.check_circle_outline),
                    next == null ? C.accent : (overdue ? C.orange : C.green)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t['title'] as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(status(t), style: const TextStyle(color: Colors.grey, fontSize: 13)),
                    if (notes.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(notes, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ],
                  ]),
                ),
                if (next != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(color: Colors.white.withOpacity(0.08), borderRadius: BorderRadius.circular(10)),
                    child: Text('R$rc', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                  ),
              ]),
            );
          },
        ),
      );
}

// ───────────────────────── Timer ─────────────────────────
class RingPainter extends CustomPainter {
  final double remaining; // 1 -> 0
  RingPainter(this.remaining);
  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 14.0;
    final rect = Offset(stroke / 2, stroke / 2) & Size(size.width - stroke, size.height - stroke);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = Colors.white.withOpacity(0.08);
    canvas.drawArc(rect, 0, 2 * math.pi, false, track);
    final sweep = 2 * math.pi * remaining.clamp(0.0, 1.0);
    if (sweep <= 0.001) return;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = const SweepGradient(
        colors: [C.cyan, C.accent, C.cyan],
        transform: GradientRotation(-math.pi / 2),
      ).createShader(rect);
    canvas.drawArc(rect, -math.pi / 2, sweep, false, arc);
  }

  @override
  bool shouldRepaint(RingPainter old) => old.remaining != remaining;
}

class TimerPage extends StatefulWidget {
  final String title, kind;
  final int minutes, topicId;
  const TimerPage({super.key, required this.title, required this.minutes, required this.topicId, required this.kind});
  @override
  State<TimerPage> createState() => _TimerPageState();
}

class _TimerPageState extends State<TimerPage> {
  late final int totalMs;
  late int remainingMs;
  DateTime? endAt;
  Timer? timer;
  bool running = false, started = false, done = false;

  @override
  void initState() {
    super.initState();
    totalMs = widget.minutes * 60 * 1000;
    remainingMs = totalMs;
  }

  int get leftMs => running && endAt != null ? math.max(0, endAt!.difference(DateTime.now()).inMilliseconds) : remainingMs;

  void start() {
    if (running || done) return;
    HapticFeedback.mediumImpact();
    endAt = DateTime.now().add(Duration(milliseconds: remainingMs));
    started = true;
    running = true;
    timer?.cancel();
    timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (leftMs <= 0) {
        finish();
      } else if (mounted) {
        setState(() {});
      }
    });
    setState(() {});
  }

  void pause() {
    if (!running) return;
    remainingMs = leftMs;
    timer?.cancel();
    running = false;
    setState(() {});
  }

  Future<void> finish() async {
    if (done) return;
    done = true;
    final left = leftMs;
    timer?.cancel();
    running = false;
    final elapsedMs = totalMs - left;
    final mins = left <= 0 ? widget.minutes : math.min(widget.minutes, math.max(1, (elapsedMs / 60000).ceil()));
    await AppDb.db.insert('sessions', {
      'topicId': widget.topicId,
      'kind': widget.kind,
      'minutes': mins,
      'startedAt': DateTime.now().subtract(Duration(milliseconds: elapsedMs)).toIso8601String(),
      'completed': 1
    });
    HapticFeedback.heavyImpact();
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> tryFinish() async {
    if (leftMs > 0) {
      final ok = await confirmDialog(context, 'Finish early?', 'This counts the session as completed.', 'Finish');
      if (!ok) return;
    }
    await finish();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final secs = (leftMs / 1000).ceil();
    final m = (secs ~/ 60).toString().padLeft(2, '0'), s = (secs % 60).toString().padLeft(2, '0');
    final isRev = widget.kind == 'revision';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (!started) {
          Navigator.pop(context, false);
          return;
        }
        final wasRunning = running;
        pause();
        final quit = await confirmDialog(context, 'Quit session?', "Progress won't be saved.", 'Quit');
        if (!mounted) return;
        if (quit) {
          timer?.cancel();
          Navigator.pop(context, false);
        } else if (wasRunning) {
          start();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(children: [
            AppBar(title: Text(isRev ? 'Revision' : 'New Study'), backgroundColor: Colors.transparent),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(widget.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: 280,
              height: 280,
              child: CustomPaint(
                painter: RingPainter(leftMs / totalMs),
                child: Center(
                  child: Text('$m:$s', style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w300, fontFeatures: [FontFeature.tabularFigures()])),
                ),
              ),
            ),
            const SizedBox(height: 36),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              FilledButton.icon(
                  onPressed: running ? pause : start,
                  icon: Icon(running ? Icons.pause : Icons.play_arrow),
                  label: Text(running ? 'Pause' : (started ? 'Resume' : 'Start'))),
              const SizedBox(width: 12),
              OutlinedButton(onPressed: tryFinish, child: const Text('Finish')),
            ]),
            const Spacer(),
            Text('${widget.minutes} minute session', style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 30),
          ]),
        ),
      ),
    );
  }
}

// ───────────────────────── Progress ─────────────────────────
class ProgressPage extends StatefulWidget {
  const ProgressPage({super.key});
  @override
  State<ProgressPage> createState() => _ProgressPageState();
}

class _ProgressPageState extends State<ProgressPage> {
  int topics = 0, done = 0, sessions = 0, mastered = 0;
  Stats stats = Stats();
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    topics = Sqflite.firstIntValue(await AppDb.db.rawQuery('SELECT COUNT(*) FROM topics')) ?? 0;
    done = Sqflite.firstIntValue(await AppDb.db.rawQuery('SELECT COUNT(*) FROM topics WHERE completedAt IS NOT NULL')) ?? 0;
    sessions = Sqflite.firstIntValue(await AppDb.db.rawQuery('SELECT COUNT(*) FROM sessions WHERE completed=1')) ?? 0;
    mastered = Sqflite.firstIntValue(await AppDb.db.rawQuery('SELECT COUNT(*) FROM topics WHERE revisionCount>=6')) ?? 0;
    stats = await Stats.load();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final pct = topics == 0 ? 0.0 : done / topics;
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(20), children: [
        pageTitle(context, 'Progress', 'Your study at a glance'),
        Row(children: [
          Expanded(child: _tile(Icons.local_fire_department, 'Streak', '${stats.streak}d', C.orange)),
          const SizedBox(width: 10),
          Expanded(child: _tile(Icons.timer_outlined, 'Total time', fmtMin(stats.totalMin), C.cyan)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _tile(Icons.school_outlined, 'Study sessions', '$sessions', C.accent)),
          const SizedBox(width: 10),
          Expanded(child: _tile(Icons.refresh_rounded, 'Revisions done', '${stats.revisionSessions}', C.green)),
        ]),
        const SizedBox(height: 10),
        Panel(
          padding: const EdgeInsets.all(20),
          child: Row(children: [
            SizedBox(
              width: 84,
              height: 84,
              child: Stack(alignment: Alignment.center, children: [
                SizedBox(
                  width: 84,
                  height: 84,
                  child: CircularProgressIndicator(value: pct, strokeWidth: 8, backgroundColor: Colors.white.withOpacity(0.08)),
                ),
                Text('${(pct * 100).round()}%', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ]),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Completion', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('$done of $topics topics studied', style: const TextStyle(color: Colors.grey)),
                const SizedBox(height: 2),
                Text('$mastered fully revised', style: const TextStyle(color: Colors.grey)),
              ]),
            ),
          ]),
        ),
        _weekChart(),
      ]),
    );
  }

  Widget _tile(IconData icon, String label, String value, Color color) => Panel(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconBadge(icon, color),
          const SizedBox(height: 12),
          Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
        ]),
      );

  Widget _weekChart() {
    final maxV = math.max(1, stats.week.fold<int>(0, (a, b) => math.max(a, b)));
    return Panel(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Last 7 days', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('${fmtMin(stats.week.fold<int>(0, (a, b) => a + b))} studied this week', style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 18),
        SizedBox(
          height: 150,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: List.generate(7, (i) {
            final v = stats.week.length > i ? stats.week[i] : 0;
            final day = stats.weekDays.length > i ? stats.weekDays[i] : DateTime.now();
            final isToday = i == 6;
            return Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                Text(v > 0 ? fmtMin(v) : '', style: const TextStyle(fontSize: 10, color: Colors.white54)),
                const SizedBox(height: 4),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: v / maxV),
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeOutCubic,
                  builder: (_, f, __) => Container(
                    width: 22,
                    height: 4 + f * 90,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      gradient: v > 0
                          ? const LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [C.violet, C.cyan])
                          : null,
                      color: v > 0 ? null : Colors.white.withOpacity(0.08),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(DateFormat('E').format(day).substring(0, 1),
                    style: TextStyle(fontSize: 12, fontWeight: isToday ? FontWeight.w800 : FontWeight.w400, color: isToday ? Colors.white : Colors.grey)),
              ]),
            );
          })),
        ),
      ]),
    );
  }
}
