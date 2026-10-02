import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:device_calendar/device_calendar.dart';
import 'package:timezone/data/latest.dart' as tzdata;

void main() => runApp(const JarvisApp());

// ===================== Farbwelt: dunkel, mystisch, rot =====================
const kRed = Color(0xFFE11D2E);
const kRedBright = Color(0xFFFF3B47);
const kRedDeep = Color(0xFF6E0912);
const kBg = Color(0xFF0B0709);
const kSurface = Color(0xFF170E12);
const kSurfaceHi = Color(0xFF211318);
const kOnBg = Color(0xFFF1E7E8);
const kMuted = Color(0xFF9A8A8E);

// Kühler Akzent für die Kugel/Mic (Idle/Hört zu) – wird beim Sprechen rot.
const kCyan = Color(0xFF34E0E8);
const kCyanBright = Color(0xFF8CF8FF);
const kCyanDeep = Color(0xFF0A3A44);

// ------------------------- Einstellungen -------------------------
class Settings {
  String host;
  int port;
  bool tls;
  String clientToken;
  bool autoRead;
  double rate;
  double pitch;
  String voiceName;
  String voiceLocale;
  String sshHost;
  String sshUser;
  String sshPass;
  Settings({
    this.host = '100.82.245.85',
    this.port = 8080,
    this.tls = false,
    this.clientToken = '',
    this.autoRead = true,
    this.rate = 0.46,
    this.pitch = 0.92,
    this.voiceName = '',
    this.voiceLocale = 'de-DE',
    this.sshHost = '100.82.238.73',
    this.sshUser = 'USER',
    this.sshPass = '',
  });

  static Future<Settings> load() async {
    final p = await SharedPreferences.getInstance();
    return Settings(
      host: p.getString('host') ?? '100.82.245.85',
      port: p.getInt('port') ?? 8080,
      tls: p.getBool('tls') ?? false,
      clientToken: p.getString('clientToken') ?? '',
      autoRead: p.getBool('autoRead') ?? true,
      rate: p.getDouble('rate') ?? 0.46,
      pitch: p.getDouble('pitch') ?? 0.92,
      voiceName: p.getString('voiceName') ?? '',
      voiceLocale: p.getString('voiceLocale') ?? 'de-DE',
      sshHost: p.getString('sshHost') ?? '100.82.238.73',
      sshUser: p.getString('sshUser') ?? 'USER',
      sshPass: p.getString('sshPass') ?? '',
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('host', host);
    await p.setInt('port', port);
    await p.setBool('tls', tls);
    await p.setString('clientToken', clientToken);
    await p.setBool('autoRead', autoRead);
    await p.setDouble('rate', rate);
    await p.setDouble('pitch', pitch);
    await p.setString('voiceName', voiceName);
    await p.setString('voiceLocale', voiceLocale);
    await p.setString('sshHost', sshHost);
    await p.setString('sshUser', sshUser);
    await p.setString('sshPass', sshPass);
  }

  bool get voiceReady =>
      sshHost.trim().isNotEmpty && sshUser.trim().isNotEmpty && sshPass.isNotEmpty;

  String get scheme => tls ? 'https' : 'http';
  String get wsScheme => tls ? 'wss' : 'ws';
  String get wsUrl => '$wsScheme://$host:$port/stream?token=$clientToken';
  String get httpBase => '$scheme://$host:$port';
  bool get configured =>
      clientToken.trim().isNotEmpty && host.trim().isNotEmpty;
}

// ------------------------- Nachricht -------------------------
class GMsg {
  final int id;
  final String title;
  final String message;
  final int priority;
  final DateTime date;
  GMsg(this.id, this.title, this.message, this.priority, this.date);
  factory GMsg.fromJson(Map<String, dynamic> j) => GMsg(
        (j['id'] ?? 0) as int,
        (j['title'] ?? 'Jarvis').toString(),
        (j['message'] ?? '').toString(),
        (j['priority'] ?? 0) as int,
        DateTime.tryParse((j['date'] ?? '').toString())?.toLocal() ??
            DateTime.now(),
      );
}

class P3 {
  final double x, y, z;
  const P3(this.x, this.y, this.z);
}

// ------------------------- App -------------------------
class JarvisApp extends StatelessWidget {
  const JarvisApp({super.key});
  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: kRed,
      brightness: Brightness.dark,
    ).copyWith(
      primary: kRed,
      surface: kBg,
      onSurface: kOnBg,
      surfaceContainer: kSurface,
      surfaceContainerHigh: kSurfaceHi,
    );
    return MaterialApp(
      title: 'JARVIS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: scheme,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: const CardThemeData(color: kSurface, elevation: 0),
      ),
      home: const HomePage(),
    );
  }
}

enum Conn { off, connecting, online, error }

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  Settings _s = Settings();
  final _tts = FlutterTts();
  final List<GMsg> _msgs = [];
  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  Conn _conn = Conn.off;
  bool _speaking = false;
  Timer? _retry;
  late final AnimationController _pulse;

  final List<P3> _nodes = [];
  final List<List<int>> _edges = [];

  final _textCtl = TextEditingController();
  bool _recording = false;
  bool _sending = false;
  final _rec = FlutterSoundRecorder();
  bool _recOpened = false;
  String? _recPath;

  int _tab = 0; // 0 = Audio, 1 = Verlauf, 2 = Kalender
  Timer? _recTimer;
  Duration _recDur = Duration.zero;

  @override
  void initState() {
    super.initState();
    _buildSphere();
    _pulse = AnimationController(
        vsync: this, duration: const Duration(seconds: 12))
      ..repeat();
    _init();
  }

  void _buildSphere() {
    const n = 120;
    final ga = math.pi * (3 - math.sqrt(5)); // goldener Winkel
    for (var i = 0; i < n; i++) {
      final y = 1 - (i / (n - 1)) * 2;
      final rad = math.sqrt(math.max(0.0, 1 - y * y));
      final th = ga * i;
      _nodes.add(P3(math.cos(th) * rad, y, math.sin(th) * rad));
    }
    const thr = 0.40;
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        final dx = _nodes[i].x - _nodes[j].x;
        final dy = _nodes[i].y - _nodes[j].y;
        final dz = _nodes[i].z - _nodes[j].z;
        if (dx * dx + dy * dy + dz * dz < thr * thr) _edges.add([i, j]);
      }
    }
  }

  Future<void> _applyTts() async {
    await _tts.setLanguage(
        _s.voiceLocale.isNotEmpty ? _s.voiceLocale : 'de-DE');
    if (_s.voiceName.isNotEmpty) {
      try {
        await _tts.setVoice({'name': _s.voiceName, 'locale': _s.voiceLocale});
      } catch (_) {}
    }
    await _tts.setSpeechRate(_s.rate);
    await _tts.setPitch(_s.pitch);
  }

  Future<void> _init() async {
    _s = await Settings.load();
    await _tts.awaitSpeakCompletion(true);
    await _applyTts();
    _tts.setStartHandler(() { if (mounted) setState(() => _speaking = true); });
    _tts.setCompletionHandler(() { if (mounted) setState(() => _speaking = false); });
    _tts.setCancelHandler(() { if (mounted) setState(() => _speaking = false); });
    _tts.setErrorHandler((_) { if (mounted) setState(() => _speaking = false); });
    if (_s.configured) _connect();
    setState(() {});
  }

  Future<void> _fetchHistory() async {
    if (!_s.configured) return;
    try {
      final r = await http.get(
        Uri.parse('${_s.httpBase}/message?limit=25'),
        headers: {'X-Gotify-Key': _s.clientToken},
      ).timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final list = (j['messages'] as List?) ?? [];
        final hist =
            list.map((e) => GMsg.fromJson(e as Map<String, dynamic>)).toList();
        hist.sort((a, b) => b.date.compareTo(a.date));
        if (mounted) setState(() { _msgs..clear()..addAll(hist); });
      }
    } catch (_) {}
  }

  void _connect() {
    _retry?.cancel();
    _disconnect(keepState: true);
    if (!_s.configured) {
      setState(() => _conn = Conn.off);
      return;
    }
    setState(() => _conn = Conn.connecting);
    try {
      _ch = WebSocketChannel.connect(Uri.parse(_s.wsUrl));
      _ch!.ready.then((_) {
        if (mounted) setState(() => _conn = Conn.online);
        _fetchHistory();
      }).catchError((_) => _scheduleReconnect());
      _sub = _ch!.stream.listen(
        (data) {
          if (mounted) setState(() => _conn = Conn.online);
          try {
            final j = jsonDecode(data as String) as Map<String, dynamic>;
            final m = GMsg.fromJson(j);
            if (_msgs.any((x) => x.id == m.id)) return;
            setState(() => _msgs.insert(0, m));
            if (_s.autoRead) _speak(m);
          } catch (_) {}
        },
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (!mounted) return;
    setState(() => _conn = Conn.error);
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 4), () {
      if (mounted && _s.configured) _connect();
    });
  }

  void _disconnect({bool keepState = false}) {
    _sub?.cancel();
    _sub = null;
    _ch?.sink.close();
    _ch = null;
    if (!keepState && mounted) setState(() => _conn = Conn.off);
  }

  Future<void> _speak(GMsg m) async {
    final text = m.title.isNotEmpty ? '${m.title}. ${m.message}' : m.message;
    await _tts.stop();
    await _applyTts();
    await _tts.speak(text);
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), backgroundColor: kSurfaceHi),
      );
    }
  }

  Future<void> _uploadNote(List<int> bytes, String ext) async {
    if (!_s.voiceReady) {
      _snack('Erst Sprach-Einstellungen (SSH-Passwort) ausfüllen');
      return;
    }
    setState(() => _sending = true);
    SSHClient? client;
    try {
      final socket = await SSHSocket.connect(_s.sshHost, 22,
          timeout: const Duration(seconds: 12));
      client = SSHClient(socket,
          username: _s.sshUser, onPasswordRequest: () => _s.sshPass);
      final sftp = await client.sftp();
      final name = 'note-${DateTime.now().millisecondsSinceEpoch}.$ext';
      final path = 'C:/Users/USER/jarvis-agent/voice-intake/$name';
      final file = await sftp.open(path,
          mode: SftpFileOpenMode.create |
              SftpFileOpenMode.write |
              SftpFileOpenMode.truncate);
      await file.writeBytes(Uint8List.fromList(bytes));
      await file.close();
      _snack('An Jarvis gesendet – Bestätigung kommt gleich');
    } catch (e) {
      _snack('Senden fehlgeschlagen: $e');
    } finally {
      client?.close();
      if (mounted) setState(() => _sending = false);
    }
  }


  Future<void> _startRec() async {
    if (!_s.voiceReady) {
      _snack('Erst Sprach-Einstellungen (SSH-Passwort) ausfüllen');
      return;
    }
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      _snack('Mikrofon-Berechtigung fehlt');
      return;
    }
    try {
      if (!_recOpened) {
        await _rec.openRecorder();
        _recOpened = true;
      }
      final dir = await getTemporaryDirectory();
      _recPath = '${dir.path}/note.wav';
      await _rec.startRecorder(
        toFile: _recPath,
        codec: Codec.pcm16WAV,
        sampleRate: 16000,
        numChannels: 1,
      );
      _recDur = Duration.zero;
      _recTimer?.cancel();
      _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recDur += const Duration(seconds: 1));
      });
      setState(() => _recording = true);
    } catch (e) {
      _snack('Aufnahme fehlgeschlagen: $e');
    }
  }

  Future<void> _stopRecAndSend() async {
    if (!_recording) return;
    _recTimer?.cancel();
    _recTimer = null;
    try {
      await _rec.stopRecorder();
    } catch (_) {}
    if (mounted) setState(() => _recording = false);
    if (_recPath == null) return;
    final f = File(_recPath!);
    if (!await f.exists()) return;
    final bytes = await f.readAsBytes();
    if (bytes.length < 3200) {
      _snack('Aufnahme zu kurz');
      return;
    }
    await _uploadNote(bytes, 'wav');
  }

  Future<void> _sendText() async {
    final t = _textCtl.text.trim();
    if (t.isEmpty) return;
    _textCtl.clear();
    FocusScope.of(context).unfocus();
    await _uploadNote(utf8.encode(t), 'txt');
  }

  @override
  void dispose() {
    _pulse.dispose();
    _retry?.cancel();
    _recTimer?.cancel();
    _disconnect();
    _tts.stop();
    if (_recOpened) _rec.closeRecorder();
    _textCtl.dispose();
    super.dispose();
  }

  Future<void> _openSettings() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => SettingsPage(settings: _s)),
    );
    if (changed == true) {
      await _s.save();
      await _applyTts();
      _connect();
      setState(() {});
    }
  }

  String get _statusLine {
    if (!_s.configured) return 'Nicht eingerichtet';
    if (_speaking) return 'Jarvis spricht …';
    switch (_conn) {
      case Conn.online:
        return 'Verbunden · hört zu';
      case Conn.connecting:
        return 'Verbinde …';
      case Conn.error:
        return 'Getrennt · neuer Versuch';
      case Conn.off:
        return 'Aus';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Row(children: [
          const Text('JARVIS',
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 4,
                  fontSize: 20,
                  color: kOnBg)),
          const SizedBox(width: 8),
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: _conn == Conn.online ? kRedBright : kMuted,
              shape: BoxShape.circle,
              boxShadow: _conn == Conn.online
                  ? [BoxShadow(color: kRedBright.withValues(alpha: 0.8), blurRadius: 8)]
                  : null,
            ),
          ),
        ]),
        actions: [
          IconButton(
            tooltip: _s.autoRead ? 'Vorlesen an' : 'Vorlesen aus',
            icon: Icon(
                _s.autoRead ? Icons.graphic_eq_rounded : Icons.volume_off_rounded,
                color: kOnBg),
            onPressed: () async {
              setState(() => _s.autoRead = !_s.autoRead);
              await _s.save();
            },
          ),
          IconButton(
            tooltip: 'Einstellungen',
            icon: const Icon(Icons.tune_rounded, color: kOnBg),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.5),
            radius: 1.1,
            colors: [Color(0xFF14090D), kBg],
            stops: [0.0, 0.72],
          ),
        ),
        child: SafeArea(
          child: IndexedStack(
            index: _tab,
            children: [
              _audioTab(),
              _inboxTab(),
              CalendarPage(settings: _s),
            ],
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        height: 64,
        backgroundColor: kSurface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: kRed.withValues(alpha: 0.20),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.graphic_eq_rounded, color: kMuted),
            selectedIcon: Icon(Icons.graphic_eq_rounded, color: kRedBright),
            label: 'Audio',
          ),
          NavigationDestination(
            icon: Icon(Icons.inbox_rounded, color: kMuted),
            selectedIcon: Icon(Icons.inbox_rounded, color: kRedBright),
            label: 'Verlauf',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_rounded, color: kMuted),
            selectedIcon: Icon(Icons.calendar_month_rounded, color: kRedBright),
            label: 'Kalender',
          ),
        ],
      ),
    );
  }

  // ---- Audio-Tab: Kugel + grosser Mic-Button + Textzeile ----
  Widget _audioTab() {
    if (!_s.configured) return _setupHint();
    final sub = _recording
        ? '● ${_fmtDur(_recDur)}  ·  loslassen zum Senden'
        : (_s.voiceReady
            ? 'Halten zum Sprechen'
            : 'SSH-Passwort fehlt – Einstellungen');
    return Column(
      children: [
        const SizedBox(height: 4),
        SizedBox(
          height: 300,
          child: Center(
            child: GestureDetector(
              onTap: () {
                if (_speaking) {
                  _tts.stop();
                } else if (_msgs.isNotEmpty) {
                  _speak(_msgs.first);
                }
              },
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (_, __) => CustomPaint(
                  size: const Size(300, 300),
                  painter: NetworkOrbPainter(
                    t: _pulse.value,
                    speaking: _speaking,
                    alive: _conn == Conn.online,
                    nodes: _nodes,
                    edges: _edges,
                  ),
                ),
              ),
            ),
          ),
        ),
        Text(_statusLine.toUpperCase(),
            style: TextStyle(
                color: _speaking
                    ? kRedBright
                    : (_conn == Conn.online ? kCyanBright : kMuted),
                fontSize: 13,
                letterSpacing: 2.5,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 22),
        _bigMic(),
        const SizedBox(height: 12),
        Text(sub,
            style: TextStyle(
                color: _recording ? kRedBright : kMuted,
                fontSize: 12.5,
                letterSpacing: 0.3,
                fontWeight: FontWeight.w600)),
        const Spacer(),
        _voiceInputRow(),
      ],
    );
  }

  Widget _bigMic() {
    return Listener(
      onPointerDown: (_) {
        if (!_s.voiceReady) {
          _snack('Erst space-SSH-Passwort in den Einstellungen eintragen');
          _openSettings();
          return;
        }
        _startRec();
      },
      onPointerUp: (_) => _stopRecAndSend(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: _recording ? 104 : 92,
        height: _recording ? 104 : 92,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: _recording ? [kRedBright, kRed] : [kCyanBright, kCyan],
          ),
          boxShadow: [
            BoxShadow(
              color: (_recording ? kRed : kCyan)
                  .withValues(alpha: _recording ? 0.9 : 0.5),
              blurRadius: _recording ? 36 : 18,
              spreadRadius: _recording ? 4 : 0,
            ),
          ],
        ),
        child: Icon(
          _recording ? Icons.mic_rounded : Icons.mic_none_rounded,
          size: 40,
          color: _recording ? Colors.white : kBg,
        ),
      ),
    );
  }

  Widget _voiceInputRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: TextField(
        controller: _textCtl,
        style: const TextStyle(color: kOnBg),
        minLines: 1,
        maxLines: 3,
        textInputAction: TextInputAction.send,
        onSubmitted: (_) => _sendText(),
        decoration: InputDecoration(
          hintText: 'Textnotiz an Jarvis …',
          hintStyle: const TextStyle(color: kMuted),
          filled: true,
          fillColor: kSurface,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide.none),
          suffixIcon: IconButton(
            icon: Icon(Icons.send_rounded, color: _sending ? kMuted : kRed),
            onPressed: _sending ? null : _sendText,
          ),
        ),
      ),
    );
  }

  Widget _inboxTab() {
    if (!_s.configured) return _setupHint();
    if (_msgs.isEmpty) return _emptyState();
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
      itemCount: _msgs.length,
      itemBuilder: (_, i) => _card(_msgs[i]),
    );
  }

  String _fmtDur(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }


  Color _prioColor(int p) {
    if (p >= 8) return kRedBright;
    if (p >= 5) return kRed;
    return const Color(0xFF8A5A66);
  }

  Widget _card(GMsg m) {
    final accent = _prioColor(m.priority);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: kRed.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 10,
              offset: const Offset(0, 4)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            width: 4,
            decoration: BoxDecoration(
              color: accent,
              boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.7), blurRadius: 8)],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(m.title,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                              color: kOnBg)),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.replay_rounded, size: 20, color: kMuted),
                      tooltip: 'Nochmal vorlesen',
                      onPressed: () => _speak(m),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  Text(m.message,
                      style: const TextStyle(
                          fontSize: 15, height: 1.4, color: Color(0xFFD9CDCF))),
                  const SizedBox(height: 8),
                  Text(DateFormat('EEE HH:mm').format(m.date),
                      style: const TextStyle(fontSize: 12, color: kMuted)),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Bereit. Warte auf Jarvis …',
              style: TextStyle(color: kMuted.withValues(alpha: 0.8), fontSize: 15)),
        ),
      );

  Widget _setupHint() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Einrichtung nötig',
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700, color: kOnBg)),
            const SizedBox(height: 10),
            const Text(
              'Server + Gotify-CLIENT-Token in den Einstellungen eintragen, dann erwacht Jarvis.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kMuted),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor: kRed, foregroundColor: Colors.white),
              onPressed: _openSettings,
              icon: const Icon(Icons.tune_rounded),
              label: const Text('Einstellungen'),
            ),
          ]),
        ),
      );
}

// ===================== Netzwerk-Sphäre (Graph-Kugel) =====================
class NetworkOrbPainter extends CustomPainter {
  final double t;
  final bool speaking;
  final bool alive;
  final List<P3> nodes;
  final List<List<int>> edges;
  NetworkOrbPainter({
    required this.t,
    required this.speaking,
    required this.alive,
    required this.nodes,
    required this.edges,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final R = size.width * 0.40;
    final ay = t * 2 * math.pi; // langsame Y-Rotation
    const tilt = 0.5; // fixe X-Neigung fuer 3D-Gefuehl
    final ct = math.cos(tilt), st = math.sin(tilt);
    final ca = math.cos(ay), sa = math.sin(ay);

    // Farbwelt: cyan wenn lebendig/leise, rot beim Sprechen.
    final accent = speaking ? kRedBright : (alive ? kCyan : kMuted);
    final accentHi = speaking ? Colors.white : (alive ? kCyanBright : kOnBg);
    final accentDeep = speaking ? kRedDeep : (alive ? kCyanDeep : kSurfaceHi);

    // Einen Einheitsvektor rotieren + projizieren.
    Offset proj(P3 p) {
      var x = p.x * ca + p.z * sa;
      var z = -p.x * sa + p.z * ca;
      var y = p.y;
      final y2 = y * ct - z * st;
      final z2 = y * st + z * ct;
      y = y2;
      z = z2;
      final persp = 1 / (2.0 - z * 0.6);
      return Offset(c.dx + x * R * 2 * persp, c.dy + y * R * 2 * persp);
    }

    // Knoten projizieren (mit Tiefe für Sortierung/Fog).
    final pts = <Offset>[];
    final depth = <double>[];
    for (final p in nodes) {
      var x = p.x * ca + p.z * sa;
      var z = -p.x * sa + p.z * ca;
      var y = p.y;
      final y2 = y * ct - z * st;
      final z2 = y * st + z * ct;
      y = y2;
      z = z2;
      final persp = 1 / (2.0 - z * 0.6);
      pts.add(Offset(c.dx + x * R * 2 * persp, c.dy + y * R * 2 * persp));
      depth.add(z);
    }

    // Aussen-Glow (die "Kugel" als Ganzes).
    final glowStrength = speaking ? 0.55 : (alive ? 0.30 : 0.12);
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [
          accent.withValues(alpha: glowStrength),
          accent.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: c, radius: R * 1.6));
    canvas.drawCircle(c, R * 1.6, glow);

    // --- Draht-Ringe (Globus-Gitter) ---
    const seg = 54;
    void drawRing(List<P3> ring) {
      final path = Path();
      for (var k = 0; k <= ring.length; k++) {
        final o = proj(ring[k % ring.length]);
        if (k == 0) {
          path.moveTo(o.dx, o.dy);
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }
      final rp = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = accent.withValues(alpha: speaking ? 0.16 : 0.11);
      canvas.drawPath(path, rp);
    }

    for (final lat in const [-0.6, -0.3, 0.0, 0.3, 0.6]) {
      final rr = math.sqrt(math.max(0.0, 1 - lat * lat));
      final ring = <P3>[];
      for (var k = 0; k < seg; k++) {
        final a = k / seg * 2 * math.pi;
        ring.add(P3(math.cos(a) * rr, lat.toDouble(), math.sin(a) * rr));
      }
      drawRing(ring);
    }
    for (var m = 0; m < 6; m++) {
      final lon = m / 6 * math.pi;
      final ring = <P3>[];
      for (var k = 0; k < seg; k++) {
        final a = k / seg * 2 * math.pi;
        ring.add(P3(math.cos(a) * math.cos(lon), math.sin(a),
            math.cos(a) * math.sin(lon)));
      }
      drawRing(ring);
    }

    // --- Kanten (Netzwerk) ---
    for (final e in edges) {
      final a = pts[e[0]], b = pts[e[1]];
      final dz = (depth[e[0]] + depth[e[1]]) / 2;
      final front = ((dz + 1) / 2).clamp(0.0, 1.0);
      final op = (front * (speaking ? 0.6 : 0.40) + 0.03).clamp(0.0, 1.0);
      final ep = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (speaking ? 1.3 : 0.9) * (0.4 + front)
        ..color = accent.withValues(alpha: op);
      canvas.drawLine(a, b, ep);
    }

    // --- Knoten (hinten zuerst) ---
    final order = List<int>.generate(nodes.length, (i) => i)
      ..sort((i, j) => depth[i].compareTo(depth[j]));
    for (final i in order) {
      final front = ((depth[i] + 1) / 2).clamp(0.0, 1.0);
      final tw = 0.78 +
          0.22 * math.sin(t * 2 * math.pi * (speaking ? 3 : 1) + i * 0.9);
      final pulse =
          speaking ? (1 + 0.5 * math.sin(t * 2 * math.pi * 3 + i * 0.7)) : 1.0;
      final sz = (1.0 + front * 2.4) * pulse * tw;
      final col = Color.lerp(accentDeep, accentHi, front)!;
      final ng = Paint()
        ..color = col.withValues(alpha: (speaking ? 0.5 : 0.32) * front)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      canvas.drawCircle(pts[i], sz * 2.2, ng);
      final np = Paint()..color = col.withValues(alpha: 0.35 + 0.6 * front);
      canvas.drawCircle(pts[i], sz, np);
    }

    // --- Kern-Funke ---
    final core = Paint()
      ..shader = RadialGradient(colors: [
        accentHi.withValues(alpha: speaking ? 0.9 : 0.55),
        accent.withValues(alpha: 0.0),
      ]).createShader(Rect.fromCircle(center: c, radius: R * 0.55));
    canvas.drawCircle(c, R * 0.55, core);
  }

  @override
  bool shouldRepaint(covariant NetworkOrbPainter old) =>
      old.t != t || old.speaking != speaking || old.alive != alive;
}

// ------------------------- Einstellungen-Seite -------------------------
class SettingsPage extends StatefulWidget {
  final Settings settings;
  const SettingsPage({super.key, required this.settings});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController _host;
  late TextEditingController _port;
  late TextEditingController _token;
  late bool _tls;
  late bool _autoRead;
  late double _rate;
  late double _pitch;
  late String _voiceName;
  late String _voiceLocale;
  late TextEditingController _sshHost;
  late TextEditingController _sshUser;
  late TextEditingController _sshPass;
  final _tts = FlutterTts();
  List<Map<String, String>> _voices = [];

  @override
  void initState() {
    super.initState();
    final s = widget.settings;
    _host = TextEditingController(text: s.host);
    _port = TextEditingController(text: s.port.toString());
    _token = TextEditingController(text: s.clientToken);
    _tls = s.tls;
    _autoRead = s.autoRead;
    _rate = s.rate;
    _pitch = s.pitch;
    _voiceName = s.voiceName;
    _voiceLocale = s.voiceLocale;
    _sshHost = TextEditingController(text: s.sshHost);
    _sshUser = TextEditingController(text: s.sshUser);
    _sshPass = TextEditingController(text: s.sshPass);
    _loadVoices();
  }

  Future<void> _loadVoices() async {
    try {
      final raw = await _tts.getVoices;
      final all = (raw as List)
          .map((e) => Map<String, String>.from(
              (e as Map).map((k, v) => MapEntry('$k', '$v'))))
          .where((v) => (v['locale'] ?? '').toLowerCase().startsWith('de'))
          .toList();
      all.sort((a, b) => (a['name'] ?? '').compareTo(b['name'] ?? ''));
      if (mounted) setState(() => _voices = all);
    } catch (_) {}
  }

  Future<void> _preview() async {
    await _tts.setLanguage(_voiceLocale.isNotEmpty ? _voiceLocale : 'de-DE');
    if (_voiceName.isNotEmpty) {
      try { await _tts.setVoice({'name': _voiceName, 'locale': _voiceLocale}); } catch (_) {}
    }
    await _tts.setSpeechRate(_rate);
    await _tts.setPitch(_pitch);
    await _tts.speak('Guten Tag. Ich bin Jarvis. Wie klingt meine Stimme jetzt?');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: const Text('Einstellungen',
              style: TextStyle(color: kOnBg, fontWeight: FontWeight.w700))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _field(_host, 'Server-Host'),
          const SizedBox(height: 12),
          _field(_port, 'Port', number: true),
          const SizedBox(height: 12),
          _field(_token, 'Gotify CLIENT-Token',
              helper: 'Gotify → Clients → neuer Client (Prefix gtfyc.)'),
          const SizedBox(height: 16),
          const Text('Stimme', style: TextStyle(color: kOnBg, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: kRed.withValues(alpha: 0.3)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: DropdownButton<String>(
              value: _voices.any((v) => v['name'] == _voiceName) ? _voiceName : null,
              isExpanded: true,
              dropdownColor: kSurfaceHi,
              underline: const SizedBox.shrink(),
              hint: const Text('System-Standard', style: TextStyle(color: kMuted)),
              style: const TextStyle(color: kOnBg),
              items: [
                const DropdownMenuItem(value: '', child: Text('System-Standard')),
                ..._voices.map((v) => DropdownMenuItem(
                      value: v['name'],
                      child: Text('${v['name']}  (${v['locale']})',
                          overflow: TextOverflow.ellipsis),
                    )),
              ],
              onChanged: (val) => setState(() {
                _voiceName = val ?? '';
                if (val != null && val.isNotEmpty) {
                  final v = _voices.firstWhere((e) => e['name'] == val,
                      orElse: () => {'locale': _voiceLocale});
                  _voiceLocale = v['locale'] ?? _voiceLocale;
                }
              }),
            ),
          ),
          const SizedBox(height: 10),
          Text('Tempo: ${_rate.toStringAsFixed(2)}', style: const TextStyle(color: kMuted)),
          Slider(activeColor: kRed, min: 0.3, max: 0.7, divisions: 8, value: _rate,
              label: _rate.toStringAsFixed(2), onChanged: (v) => setState(() => _rate = v)),
          Text('Tonhöhe: ${_pitch.toStringAsFixed(2)}', style: const TextStyle(color: kMuted)),
          Slider(activeColor: kRed, min: 0.6, max: 1.3, divisions: 14, value: _pitch,
              label: _pitch.toStringAsFixed(2), onChanged: (v) => setState(() => _pitch = v)),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
                foregroundColor: kRedBright, side: const BorderSide(color: kRed)),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Stimme testen'),
            onPressed: _preview,
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            activeThumbColor: kRed,
            contentPadding: EdgeInsets.zero,
            title: const Text('TLS (wss/https)', style: TextStyle(color: kOnBg)),
            value: _tls,
            onChanged: (v) => setState(() => _tls = v),
          ),
          SwitchListTile(
            activeThumbColor: kRed,
            contentPadding: EdgeInsets.zero,
            title: const Text('Neue Nachrichten vorlesen', style: TextStyle(color: kOnBg)),
            value: _autoRead,
            onChanged: (v) => setState(() => _autoRead = v),
          ),
          const SizedBox(height: 16),
          const Text('Sprachnotizen → space (SSH)',
              style: TextStyle(color: kOnBg, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          _field(_sshHost, 'space-Host (Tailscale)'),
          const SizedBox(height: 12),
          _field(_sshUser, 'SSH-Benutzer'),
          const SizedBox(height: 12),
          _field(_sshPass, 'SSH-Passwort', obscure: true,
              helper: 'Windows-Login von space (für Push-to-Talk + Textnotiz)'),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: kRed,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(50)),
            icon: const Icon(Icons.bolt_rounded),
            label: const Text('Speichern & verbinden'),
            onPressed: () {
              final s = widget.settings;
              s.host = _host.text.trim();
              s.port = int.tryParse(_port.text.trim()) ?? 8080;
              s.clientToken = _token.text.trim();
              s.tls = _tls;
              s.autoRead = _autoRead;
              s.rate = _rate;
              s.pitch = _pitch;
              s.voiceName = _voiceName;
              s.voiceLocale = _voiceLocale;
              s.sshHost = _sshHost.text.trim();
              s.sshUser = _sshUser.text.trim();
              s.sshPass = _sshPass.text;
              Navigator.pop(context, true);
            },
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label,
      {bool number = false, String? helper, bool obscure = false}) {
    return TextField(
      controller: c,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      obscureText: obscure,
      style: const TextStyle(color: kOnBg),
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        labelStyle: const TextStyle(color: kMuted),
        helperStyle: const TextStyle(color: kMuted),
        enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: kRed.withValues(alpha: 0.3))),
        focusedBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: kRed, width: 2)),
      ),
    );
  }
}

// ------------------------- Kalender (Woche.md von space) -------------------------
class _CalItem {
  final String when;
  final String text;
  final bool isHeader;
  _CalItem(this.when, this.text, {this.isHeader = false});
}

class CalendarPage extends StatefulWidget {
  final Settings settings;
  const CalendarPage({super.key, required this.settings});
  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  static const _wochePath = 'C:/Users/USER/Obsidian/vault/Coach/Woche.md';
  static const _wd = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
  bool _loading = false;
  bool _loadedOnce = false;
  String? _wocheErr;
  String? _calMsg; // Status/Hinweis zum Geräte-Kalender
  final List<_CalItem> _items = [];
  final List<_CalEvent> _events = [];
  DateTime? _loadedAt;

  void _maybeAutoLoad() {
    if (_loading || _loadedOnce) return;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _wocheErr = null;
      _calMsg = null;
    });
    await _loadDevice();
    await _loadWoche();
    if (mounted) {
      setState(() {
        _loadedAt = DateTime.now();
        _loadedOnce = true;
        _loading = false;
      });
    }
  }

  Future<void> _loadDevice() async {
    try {
      try { tzdata.initializeTimeZones(); } catch (_) {}
      final plugin = DeviceCalendarPlugin();
      var perm = await plugin.hasPermissions();
      if (perm.data != true) perm = await plugin.requestPermissions();
      if (perm.data != true) {
        _events.clear();
        _calMsg = 'Kein Kalender-Zugriff – in den App-Berechtigungen erlauben.';
        return;
      }
      final cals = await plugin.retrieveCalendars();
      final now = DateTime.now();
      final end = now.add(const Duration(days: 14));
      final found = <_CalEvent>[];
      for (final c in (cals.data ?? [])) {
        if (c.id == null) continue;
        final res = await plugin.retrieveEvents(
            c.id, RetrieveEventsParams(startDate: now, endDate: end));
        for (final e in (res.data ?? [])) {
          final st = e.start;
          if (st == null) continue;
          found.add(_CalEvent(
              (e.title ?? '(ohne Titel)').trim(),
              DateTime.fromMillisecondsSinceEpoch(st.millisecondsSinceEpoch),
              e.allDay ?? false));
        }
      }
      found.sort((a, b) => a.start.compareTo(b.start));
      _events
        ..clear()
        ..addAll(found);
      _calMsg = found.isEmpty ? 'Keine Termine in den nächsten 14 Tagen.' : null;
    } catch (e) {
      _calMsg = 'Kalender-Fehler: $e';
    }
  }

  Future<void> _loadWoche() async {
    final s = widget.settings;
    if (!s.voiceReady) {
      _wocheErr = 'Woche.md: SSH-Passwort (space) in Einstellungen nötig.';
      return;
    }
    SSHClient? client;
    try {
      final socket = await SSHSocket.connect(s.sshHost, 22,
          timeout: const Duration(seconds: 12));
      client = SSHClient(socket,
          username: s.sshUser, onPasswordRequest: () => s.sshPass);
      final sftp = await client.sftp();
      final file = await sftp.open(_wochePath, mode: SftpFileOpenMode.read);
      final data = await file.readBytes();
      await file.close();
      final text = utf8.decode(data, allowMalformed: true);
      _items
        ..clear()
        ..addAll(_parse(text));
    } catch (e) {
      _wocheErr = 'Woche.md laden fehlgeschlagen: $e';
    } finally {
      client?.close();
    }
  }

  List<_CalItem> _parse(String text) {
    final out = <_CalItem>[];
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        out.add(_CalItem(line.replaceAll('#', '').trim(), '', isHeader: true));
        continue;
      }
      if (line.startsWith('-') || line.startsWith('*')) {
        var body = line.substring(1).trim();
        var when = '';
        final sep = body.indexOf(': ');
        if (sep > 0) {
          when = body.substring(0, sep).trim();
          body = body.substring(sep + 2).trim();
        }
        if (body.isNotEmpty) out.add(_CalItem(when, body));
      }
    }
    return out;
  }

  String _sectionTitle(String s) => s;

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoLoad());
    final rows = <Widget>[];
    // Kopf
    rows.add(Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 2),
      child: Row(children: [
        const Text('KALENDER',
            style: TextStyle(
                color: kOnBg,
                fontWeight: FontWeight.w800,
                letterSpacing: 3,
                fontSize: 18)),
        const SizedBox(width: 10),
        if (_loading)
          const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: kRedBright)),
        const Spacer(),
        if (_loadedAt != null)
          Text(DateFormat('HH:mm').format(_loadedAt!),
              style: const TextStyle(color: kMuted, fontSize: 12)),
      ]),
    ));
    // Termine (Geräte-Kalender)
    rows.add(_header('TERMINE · 14 TAGE'));
    if (_events.isEmpty) {
      rows.add(_hint(_calMsg ?? (_loading ? 'lädt …' : 'keine Termine')));
    } else {
      DateTime? lastDay;
      for (final ev in _events) {
        final d = DateTime(ev.start.year, ev.start.month, ev.start.day);
        if (lastDay == null || d != lastDay) {
          lastDay = d;
          rows.add(Padding(
            padding: const EdgeInsets.fromLTRB(2, 10, 0, 6),
            child: Text(
                '${_wd[ev.start.weekday - 1]} ${DateFormat('dd.MM.').format(ev.start)}',
                style: const TextStyle(
                    color: kCyanBright,
                    fontWeight: FontWeight.w700,
                    fontSize: 13)),
          ));
        }
        rows.add(_eventTile(ev));
      }
    }
    // Woche-Notizen (Coach)
    rows.add(_header('WOCHE · NOTIZEN'));
    if (_wocheErr != null) {
      rows.add(_hint(_wocheErr!));
    } else if (_items.isEmpty) {
      rows.add(_hint(_loading ? 'lädt …' : 'keine Einträge in Woche.md'));
    } else {
      for (final it in _items) {
        if (it.isHeader) {
          rows.add(Padding(
            padding: const EdgeInsets.fromLTRB(2, 10, 0, 6),
            child: Text(it.when.toUpperCase(),
                style: const TextStyle(
                    color: kRedBright,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                    fontSize: 12)),
          ));
        } else {
          rows.add(_tile(it));
        }
      }
    }

    return RefreshIndicator(
      color: kRedBright,
      backgroundColor: kSurface,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
        children: rows,
      ),
    );
  }

  Widget _header(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 18, 0, 8),
        child: Text(_sectionTitle(t),
            style: const TextStyle(
                color: kMuted,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
                fontSize: 12)),
      );

  Widget _hint(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 2, 2, 6),
        child: Text(t, style: const TextStyle(color: kMuted, fontSize: 13.5)),
      );

  Widget _eventTile(_CalEvent ev) {
    final time = ev.allDay ? 'ganztägig' : DateFormat('HH:mm').format(ev.start);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kCyan.withValues(alpha: 0.18)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(
          width: 62,
          child: Text(time,
              style: const TextStyle(
                  color: kCyanBright, fontWeight: FontWeight.w700, fontSize: 13)),
        ),
        Expanded(
          child: Text(ev.title,
              style: const TextStyle(color: kOnBg, fontSize: 15, height: 1.3)),
        ),
      ]),
    );
  }

  Widget _tile(_CalItem it) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kRed.withValues(alpha: 0.12)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(top: 5, right: 12),
          decoration:
              const BoxDecoration(color: kRedBright, shape: BoxShape.circle),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (it.when.isNotEmpty)
              Text(it.when,
                  style: const TextStyle(
                      color: kCyanBright,
                      fontWeight: FontWeight.w700,
                      fontSize: 14)),
            if (it.when.isNotEmpty) const SizedBox(height: 2),
            Text(it.text,
                style: const TextStyle(
                    color: kOnBg, fontSize: 15, height: 1.35)),
          ]),
        ),
      ]),
    );
  }
}

class _CalEvent {
  final String title;
  final DateTime start;
  final bool allDay;
  _CalEvent(this.title, this.start, this.allDay);
}
