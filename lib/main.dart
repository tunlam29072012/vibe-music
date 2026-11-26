import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:audio_session/audio_session.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.vibemusic.channel.audio',
    androidNotificationChannelName: 'Vibe Music Playback',
    androidNotificationOngoing: true,
    androidStopForegroundOnPause: false,
  );
  runApp(const VibeMusicApp());
}

enum RepeatMode { off, all, one }

class SongItem {
  final String id;
  final String title;
  final String audioPath;
  final String? thumbPath;

  SongItem({
    required this.id,
    required this.title,
    required this.audioPath,
    this.thumbPath,
  });
}

class VibeMusicApp extends StatelessWidget {
  const VibeMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vibe Music',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F0F0F),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFA78BFA),
          surface: Color(0xFF1A1A1A),
        ),
      ),
      home: const PlayerScreen(),
    );
  }
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WidgetsBindingObserver {
  final AudioPlayer _player = AudioPlayer();
  final TextEditingController _searchCtrl = TextEditingController();
  final List<SongItem> _library = [];
  List<SongItem> _queue = [];
  int _currentIndex = 0;
  bool _isShuffle = false;
  RepeatMode _repeatMode = RepeatMode.all;
  bool _isDownloading = false;
  String _downloadStatus = 'Đang tải...';
  String _searchQuery = '';

  late Directory _musicDir;
  late File _stateFile;
  Timer? _saveDebounce;

  // Sleep Timer state
  Timer? _sleepTimer;
  Timer? _countdownTicker;
  DateTime? _sleepEndTime;
  Duration _remainingSleep = Duration.zero;

  static const _musicExts = ['.mp3', '.m4a', '.wav', '.ogg'];
  static const _imgExts = ['.jpg', '.jpeg', '.png', '.webp'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initApp();

    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed && _queue.isNotEmpty) {
        if (_repeatMode == RepeatMode.one) {
          _player.seek(Duration.zero);
          _player.play();
        } else {
          _nextSong(autoAdvance: true);
        }
      }
    });

    _player.positionStream.listen((pos) {
      if (pos.inSeconds > 0 && pos.inSeconds % 5 == 0) {
        _scheduleSaveState();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _saveStateNow();
    }
  }

  Future<void> _initApp() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    if (Platform.isAndroid) {
      await [
        Permission.notification,
        Permission.audio,
        Permission.storage,
      ].request();
    }
    final docDir = await getApplicationDocumentsDirectory();
    _musicDir = Directory('${docDir.path}/VibeMusic');
    if (!await _musicDir.exists()) {
      await _musicDir.create(recursive: true);
    }
    _stateFile = File('${docDir.path}/vibe_music_state.json');
    await _scanMusicFolder(restoreState: true);
  }

  // --- State Persistence ---
  void _scheduleSaveState() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), _saveStateNow);
  }

  Future<void> _saveStateNow() async {
    try {
      final currentSong = (_queue.isNotEmpty && _currentIndex < _queue.length)
          ? _queue[_currentIndex]
          : null;
      final data = {
        'currentPath': currentSong?.audioPath,
        'positionMs': _player.position.inMilliseconds,
        'isShuffle': _isShuffle,
        'repeatMode': _repeatMode.index,
        'queuePaths': _queue.map((e) => e.audioPath).toList(),
      };
      await _stateFile.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  dynamic _loadSavedState() async {
    try {
      if (await _stateFile.exists()) {
        final content = await _stateFile.readAsString();
        return jsonDecode(content);
      }
    } catch (_) {}
    return null;
  }

  Future<void> _scanMusicFolder({bool restoreState = false}) async {
    final entities = _musicDir.listSync();
    final files = entities.whereType<File>().where((f) {
      final lower = f.path.toLowerCase();
      return _musicExts.any((ext) => lower.endsWith(ext));
    }).toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final List<SongItem> loaded = [];
    for (final file in files) {
      final baseName = _getBaseName(file.path);
      final thumb = _findMatchingThumb(baseName, entities);
      loaded.add(SongItem(
        id: file.path,
        title: baseName,
        audioPath: file.path,
        thumbPath: thumb,
      ));
    }

    dynamic saved;
    if (restoreState) {
      saved = await _loadSavedState();
    }

    setState(() {
      _library
        ..clear()
        ..addAll(loaded);

      if (saved != null && saved is Map) {
        _isShuffle = saved['isShuffle'] == true;
        final repIdx = saved['repeatMode'] is int ? saved['repeatMode'] as int : 1;
        _repeatMode = RepeatMode.values[repIdx.clamp(0, RepeatMode.values.length - 1)];

        final savedQueuePaths = (saved['queuePaths'] as List?)?.cast<String>() ?? [];
        final mapByPath = {for (var s in _library) s.audioPath: s};
        final restoredQueue = <SongItem>[];
        for (final p in savedQueuePaths) {
          if (mapByPath.containsKey(p)) {
            restoredQueue.add(mapByPath.remove(p)!);
          }
        }
        restoredQueue.addAll(mapByPath.values);
        _queue = restoredQueue;

        final lastPath = saved['currentPath'] as String?;
        final foundIdx = lastPath != null ? _queue.indexWhere((s) => s.audioPath == lastPath) : 0;
        _currentIndex = foundIdx >= 0 ? foundIdx : 0;
      } else {
        _queue = List.from(_library);
        if (_isShuffle) _queue.shuffle(Random());
        _currentIndex = 0;
      }
    });

    if (_queue.isNotEmpty) {
      final initialPosMs = (saved is Map && saved['positionMs'] is int) ? saved['positionMs'] as int : 0;
      await _playAt(
        _currentIndex,
        autoPlay: false,
        initialPosition: initialPosMs > 0 ? Duration(milliseconds: initialPosMs) : null,
      );
    }
  }

  String _getBaseName(String filePath) {
    final name = filePath.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    return dot == -1 ? name : name.substring(0, dot);
  }

  String _getExtension(String filePath) {
    final name = filePath.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    return dot == -1 ? '' : name.substring(dot);
  }

  String? _findMatchingThumb(String baseName, List<FileSystemEntity> entities) {
    final target = baseName.toLowerCase();
    for (final e in entities) {
      if (e is File) {
        final lower = e.path.toLowerCase();
        if (_imgExts.any((ext) => lower.endsWith(ext)) &&
            _getBaseName(e.path).toLowerCase() == target) {
          return e.path;
        }
      }
    }
    return null;
  }

  Future<void> _playAt(int index, {bool autoPlay = true, Duration? initialPosition}) async {
    if (index < 0 || index >= _queue.length) return;
    setState(() => _currentIndex = index);

    final song = _queue[index];
    final source = AudioSource.uri(
      Uri.file(song.audioPath),
      tag: MediaItem(
        id: song.id,
        album: 'Vibe Music',
        title: song.title,
        artist: 'Vibe Music Player',
        artUri: song.thumbPath != null ? Uri.file(song.thumbPath!) : null,
      ),
    );

    await _player.setAudioSource(source, initialPosition: initialPosition);
    _saveStateNow();
    if (autoPlay) {
      await _player.play();
    }
  }

  void _nextSong({bool autoAdvance = false}) {
    if (_queue.isEmpty) return;
    int next = _currentIndex + 1;
    if (next >= _queue.length) {
      if (autoAdvance && _repeatMode == RepeatMode.off) {
        _player.pause();
        _player.seek(Duration.zero);
        return;
      }
      if (_isShuffle) _queue.shuffle(Random());
      next = 0;
    }
    _playAt(next);
  }

  void _prevSong()
