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

  void _prevSong() {
    if (_queue.isEmpty) return;
    if (_player.position.inSeconds > 3) {
      _player.seek(Duration.zero);
      return;
    }
    int prev = _currentIndex - 1;
    if (prev < 0) prev = _queue.length - 1;
    _playAt(prev);
  }

  void _toggleShuffle() {
    if (_queue.isEmpty) return;
    setState(() {
      _isShuffle = !_isShuffle;
      final current = _queue[_currentIndex];
      final rest = List<SongItem>.from(_library)..removeWhere((s) => s.id == current.id);
      if (_isShuffle) {
        rest.shuffle(Random());
      }
      _queue = [current, ...rest];
      _currentIndex = 0;
    });
    _saveStateNow();
  }

  void _cycleRepeatMode() {
    setState(() {
      _repeatMode = RepeatMode.values[(_repeatMode.index + 1) % RepeatMode.values.length];
    });
    _saveStateNow();
    final label = switch (_repeatMode) {
      RepeatMode.off => 'Lặp lại: Tắt',
      RepeatMode.all => 'Lặp lại: Tất cả danh sách',
      RepeatMode.one => 'Lặp lại: 1 bài hiện tại',
    };
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(label), duration: const Duration(seconds: 1)),
    );
  }

  // --- Rename & Delete Song ---
  Future<void> _renameSong(SongItem song) async {
    final ctrl = TextEditingController(text: song.title);
    final newNameRaw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Đổi tên bài hát'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Nhập tên mới...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );

    if (newNameRaw == null || newNameRaw.isEmpty) return;
    final safeNewName = newNameRaw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (safeNewName.isEmpty || safeNewName == song.title) return;

    final audioExt = _getExtension(song.audioPath);
    final newAudioPath = '${_musicDir.path}/$safeNewName$audioExt';
    if (await File(newAudioPath).exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tên bài hát này đã tồn tại!')),
        );
      }
      return;
    }

    try {
      final isPlayingThis = _queue.isNotEmpty && _queue[_currentIndex].id == song.id;
      final wasPlaying = _player.playing;
      final savedPos = _player.position;

      if (isPlayingThis) {
        await _player.stop();
      }

      await File(song.audioPath).rename(newAudioPath);
      String? newThumbPath;
      if (song.thumbPath != null && await File(song.thumbPath!).exists()) {
        final thumbExt = _getExtension(song.thumbPath!);
        newThumbPath = '${_musicDir.path}/$safeNewName$thumbExt';
        await File(song.thumbPath!).rename(newThumbPath);
      }

      final updatedSong = SongItem(
        id: newAudioPath,
        title: safeNewName,
        audioPath: newAudioPath,
        thumbPath: newThumbPath,
      );

      setState(() {
        final libIdx = _library.indexWhere((s) => s.id == song.id);
        if (libIdx != -1) _library[libIdx] = updatedSong;
        final qIdx = _queue.indexWhere((s) => s.id == song.id);
        if (qIdx != -1) _queue[qIdx] = updatedSong;
      });

      if (isPlayingThis) {
        await _playAt(_currentIndex, autoPlay: wasPlaying, initialPosition: savedPos);
      } else {
        _saveStateNow();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không thể đổi tên: $e')),
        );
      }
    }
  }

  Future<void> _deleteSong(SongItem song) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Xóa bài hát?'),
        content: Text('Xóa vĩnh viễn "${song.title}" khỏi bộ nhớ ứng dụng?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final isPlayingThis = _queue.isNotEmpty && _queue[_currentIndex].id == song.id;
      if (isPlayingThis) {
        await _player.stop();
      }

      if (await File(song.audioPath).exists()) {
        await File(song.audioPath).delete();
      }
      if (song.thumbPath != null && await File(song.thumbPath!).exists()) {
        await File(song.thumbPath!).delete();
      }

      setState(() {
        _library.removeWhere((s) => s.id == song.id);
        final removedQIdx = _queue.indexWhere((s) => s.id == song.id);
        if (removedQIdx != -1) {
          _queue.removeAt(removedQIdx);
          if (_currentIndex > removedQIdx) {
            _currentIndex--;
          } else if (_currentIndex >= _queue.length) {
            _currentIndex = _queue.isEmpty ? 0 : _queue.length - 1;
          }
        }
      });

      if (isPlayingThis && _queue.isNotEmpty) {
        await _playAt(_currentIndex, autoPlay: false);
      }
      _saveStateNow();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi khi xóa file: $e')),
        );
      }
    }
  }

  // --- Sleep Timer Logic ---
  void _setSleepTimer(int minutes) {
    _cancelSleepTimer(notify: false);
    final duration = Duration(minutes: minutes);
    setState(() {
      _sleepEndTime = DateTime.now().add(duration);
      _remainingSleep = duration;
    });

    _sleepTimer = Timer(duration, () {
      _player.pause();
      _cancelSleepTimer(notify: false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã hết giờ hẹn, nhạc đã tạm dừng.')),
        );
      }
    });

    _countdownTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_sleepEndTime == null) return;
      final diff = _sleepEndTime!.difference(DateTime.now());
      if (diff.isNegative) {
        _cancelSleepTimer(notify: false);
      } else if (mounted) {
        setState(() => _remainingSleep = diff);
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Sẽ tự động tắt nhạc sau $minutes phút')),
    );
  }

  void _cancelSleepTimer({bool notify = true}) {
    _sleepTimer?.cancel();
    _countdownTicker?.cancel();
    _sleepTimer = null;
    _countdownTicker = null;
    if (mounted) {
      setState(() {
        _sleepEndTime = null;
        _remainingSleep = Duration.zero;
      });
      if (notify) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã hủy hẹn giờ tắt nhạc')),
        );
      }
    }
  }

  Future<void> _showSleepTimerSheet() async {
    final customCtrl = TextEditingController();
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Hẹn giờ tắt nhạc',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                if (_sleepEndTime != null)
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _cancelSleepTimer();
                    },
                    child: const Text('Hủy hẹn giờ', style: TextStyle(color: Colors.redAccent)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [15, 30, 45, 60, 90].map((mins) {
                return ActionChip(
                  label: Text('$mins phút'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _setSleepTimer(mins);
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: customCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      hintText: 'Nhập số phút tùy chỉnh...',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: () {
                    final val = int.tryParse(customCtrl.text.trim());
                    if (val != null && val > 0) {
                      Navigator.pop(ctx);
                      _setSleepTimer(val);
                    }
                  },
                  child: const Text('Đặt giờ'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importLocalFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: true,
    );
    if (result == null) return;

    for (final picked in result.files) {
      if (picked.path != null) {
        final src = File(picked.path!);
        final fileName = src.path.split(Platform.pathSeparator).last;
        await src.copy('${_musicDir.path}/$fileName');
      }
    }
    await _scanMusicFolder();
    _saveStateNow();
  }

  Future<void> _showYoutubeDialog() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Thêm nhạc từ YouTube'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Dán link video YouTube vào đây...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Tải về'),
          ),
        ],
      ),
    );

    if (url == null || url.isEmpty) return;
    await _downloadFromYoutube(url);
  }

  Future<void> _downloadFromYoutube(String url) async {
    setState(() => _isDownloading = true);
    final yt = YoutubeExplode();

    try {
      final video = await yt.videos.get(url);
      final safeTitle = video.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();

      final manifest = await yt.videos.streamsClient.getManifest(video.id);
      final audioInfo = manifest.audioOnly.withHighestBitrate();
      final audioFile = File('${_musicDir.path}/$safeTitle.m4a');
      final audioStream = yt.videos.streamsClient.get(audioInfo);
      final audioSink = audioFile.openWrite();
      await audioStream.pipe(audioSink);
      await audioSink.flush();
      await audioSink.close();

      try {
        final httpClient = HttpClient();
        final req = await httpClient.getUrl(Uri.parse(video.thumbnails.highResUrl));
        final res = await req.close();
        final thumbFile = File('${_musicDir.path}/$safeTitle.jpg');
        await res.pipe(thumbFile.openWrite());
        httpClient.close();
      } catch (_) {}

      final thumbPath = '${_musicDir.path}/$safeTitle.jpg';
      final newSong = SongItem(
        id: audioFile.path,
        title: safeTitle,
        audioPath: audioFile.path,
        thumbPath: File(thumbPath).existsSync() ? thumbPath : null,
      );

      setState(() {
        _library.add(newSong);
        _queue.add(newSong);
      });

      if (_queue.length == 1) {
        await _playAt(0);
      } else {
        _saveStateNow();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Đã tải xong: $safeTitle')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi tải YouTube: $e')),
        );
      }
    } finally {
      yt.close();
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  String _formatDuration(Duration? d) {
    if (d == null) return '0:00';
    final mins = d.inMinutes;
    final secs = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveDebounce?.cancel();
    _sleepTimer?.cancel();
    _countdownTicker?.cancel();
    _searchCtrl.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentSong = (_queue.isNotEmpty && _currentIndex < _queue.length)
        ? _queue[_currentIndex]
        : null;

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 650;
            if (isWide) {
              return Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    SizedBox(width: 340, child: _buildPlayerPane(currentSong, compact: false)),
                    const VerticalDivider(width: 32, color: Color(0xFF262626)),
                    Expanded(child: _buildQueuePane()),
                  ],
                ),
              );
            } else {
              return Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    _buildPlayerPane(currentSong, compact: true),
                    const SizedBox(height: 10),
                    Expanded(child: _buildQueuePane()),
                  ],
                ),
              );
            }
          },
        ),
      ),
    );
  }

  Widget _buildPlayerPane(SongItem? song, {required bool compact}) {
    final coverSize = compact ? 115.0 : 210.0;

    final repeatIcon = _repeatMode == RepeatMode.one ? Icons.repeat_one : Icons.repeat;
    final repeatColor = _repeatMode == RepeatMode.off ? Colors.white54 : const Color(0xFFA78BFA);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: song?.thumbPath != null
              ? Image.file(
                  File(song!.thumbPath!),
                  width: coverSize,
                  height: coverSize,
                  fit: BoxFit.cover,
                )
              : Container(
                  width: coverSize,
                  height: coverSize,
                  color: const Color(0xFF1F1F1F),
                  child: const Icon(Icons.music_note, size: 52, color: Colors.white38),
                ),
        ),
        const SizedBox(height: 8),
        Text(
          song?.title ?? 'Chưa có bài nhạc nào',
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        if (_sleepEndTime != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: InkWell(
              onTap: _showSleepTimerSheet,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFA78BFA).withOpacity(0.18),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'Tắt nhạc sau ${_formatDuration(_remainingSleep)}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFFA78BFA)),
                ),
              ),
            ),
          ),
        StreamBuilder<Duration>(
          stream: _player.positionStream,
          builder: (context, snapshot) {
            final pos = snapshot.data ?? Duration.zero;
            final total = _player.duration ?? Duration.zero;
            final maxMs = total.inMilliseconds > 0 ? total.inMilliseconds.toDouble() : 1.0;
            final valMs = pos.inMilliseconds.clamp(0, total.inMilliseconds).toDouble();

            return Column(
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  ),
                  child: Slider(
                    value: valMs,
                    max: maxMs,
                    onChanged: (v) {
                      _player.seek(Duration(milliseconds: v.toInt()));
                      _scheduleSaveState();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_formatDuration(pos), style: const TextStyle(fontSize: 11, color: Colors.white54)),
                      Text(_formatDuration(total), style: const TextStyle(fontSize: 11, color: Colors.white54)),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: Icon(Icons.shuffle, size: 22, color: _isShuffle ? const Color(0xFFA78BFA) : Colors.white54),
              tooltip: 'Phát ngẫu nhiên',
              onPressed: _toggleShuffle,
            ),
            IconButton(
              icon: const Icon(Icons.skip_previous, size: 30),
              onPressed: _prevSong,
            ),
            StreamBuilder<PlayerState>(
              stream: _player.playerStateStream,
              builder: (context, snapshot) {
                final playing = snapshot.data?.playing ?? false;
                return IconButton(
                  icon: Icon(
                    playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
                    size: 52,
                    color: Colors.white,
                  ),
                  onPressed: () {
                    if (_queue.isEmpty) return;
                    if (playing) {
                      _player.pause();
                      _saveStateNow();
                    } else {
                      _player.play();
                    }
                  },
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.skip_next, size: 30),
              onPressed: () => _nextSong(autoAdvance: false),
            ),
            IconButton(
              icon: Icon(repeatIcon, size: 22, color: repeatColor),
              tooltip: 'Chế độ lặp lại',
              onPressed: _cycleRepeatMode,
            ),
            IconButton(
              icon: Icon(
                Icons.bedtime_outlined,
                size: 22,
                color: _sleepEndTime != null ? const Color(0xFFA78BFA) : Colors.white54,
              ),
              tooltip: 'Hẹn giờ tắt nhạc',
              onPressed: _showSleepTimerSheet,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 10,
          alignment: WrapAlignment.center,
          children: [
            FilledButton.tonalIcon(
              onPressed: _isDownloading ? null : _showYoutubeDialog,
              icon: _isDownloading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download, size: 18),
              label: Text(_isDownloading ? 'Đang tải...' : 'Thêm từ YouTube'),
            ),
            OutlinedButton.icon(
              onPressed: _importLocalFiles,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('Thêm nhạc máy'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildQueuePane() {
    final isSearching = _searchQuery.trim().isNotEmpty;
    final filteredSongs = isSearching
        ? _library
            .where((s) => s.title.toLowerCase().contains(_searchQuery.trim().toLowerCase()))
            .toList()
        : <SongItem>[];

    final upcomingCount = _queue.length > _currentIndex + 1 ? _queue.length - (_currentIndex + 1) : 0;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF141414),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isSearching ? 'Kết quả tìm kiếm (${filteredSongs.length})' : 'Danh sách chờ',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
              if (!isSearching)
                Text('$upcomingCount bài tiếp theo', style: const TextStyle(fontSize: 12, color: Colors.white54)),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _searchCtrl,
            onChanged: (val) => setState(() => _searchQuery = val),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Tìm kiếm bài hát trong kho...',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: isSearching
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              filled: true,
              fillColor: const Color(0xFF1E1E1E),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: isSearching
                ? (filteredSongs.isEmpty
                    ? const Center(
                        child: Text('Không tìm thấy bài hát phù hợp.', style: TextStyle(color: Colors.white54)),
                      )
                    : ListView.builder(
                        itemCount: filteredSongs.length,
                        itemBuilder: (context, idx) {
                          final item = filteredSongs[idx];
                          return _buildSongTile(
                            item: item,
                            onTap: () {
                              final qIdx = _queue.indexWhere((s) => s.id == item.id);
                              if (qIdx != -1) {
                                _playAt(qIdx);
                              } else {
                                setState(() => _queue.insert(_currentIndex + 1, item));
                                _playAt(_currentIndex + 1);
                              }
                            },
                            menuItems: const [
                              PopupMenuItem(value: 'rename', child: Text('Đổi tên bài hát')),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Xóa khỏi máy', style: TextStyle(color: Colors.redAccent)),
                              ),
                            ],
                            onMenuSelected: (val) {
                              if (val == 'rename') _renameSong(item);
                              if (val == 'delete') _deleteSong(item);
                            },
                          );
                        },
                      ))
                : (upcomingCount == 0
                    ? const Center(
                        child: Text(
                          'Danh sách chờ trống.\nHãy tải từ YouTube hoặc thêm nhạc từ máy!',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54),
                        ),
                      )
                    : ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        itemCount: upcomingCount,
                        onReorder: (oldIndex, newIndex) {
                          setState(() {
                            if (oldIndex < newIndex) newIndex -= 1;
                            final actualOld = _currentIndex + 1 + oldIndex;
                            final actualNew = _currentIndex + 1 + newIndex;
                            final item = _queue.removeAt(actualOld);
                            _queue.insert(actualNew, item);
                          });
                          _saveStateNow();
                        },
                        itemBuilder: (context, idx) {
                          final queuePos = _currentIndex + 1 + idx;
                          final item = _queue[queuePos];

                          return Container(
                            key: ValueKey('${item.id}_$queuePos'),
                            decoration: const BoxDecoration(
                              border: Border(bottom: BorderSide(color: Color(0xFF222222))),
                            ),
                            child: _buildSongTile(
                              item: item,
                              dragIndex: idx,
                              onTap: () => _playAt(queuePos),
                              menuItems: const [
                                PopupMenuItem(value: 'next', child: Text('Phát kế tiếp')),
                                PopupMenuItem(value: 'rename', child: Text('Đổi tên bài hát')),
                                PopupMenuItem(value: 'remove', child: Text('Xóa khỏi hàng chờ')),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Xóa vĩnh viễn khỏi máy', style: TextStyle(color: Colors.redAccent)),
                                ),
                              ],
                              onMenuSelected: (value) {
                                if (value == 'next' && queuePos > _currentIndex + 1) {
                                  setState(() {
                                    final moved = _queue.removeAt(queuePos);
                                    _queue.insert(_currentIndex + 1, moved);
                                  });
                                  _saveStateNow();
                                } else if (value == 'remove') {
                                  setState(() => _queue.removeAt(queuePos));
                                  _saveStateNow();
                                } else if (value == 'rename') {
                                  _renameSong(item);
                                } else if (value == 'delete') {
                                  _deleteSong(item);
                                }
                              },
                            ),
                          );
                        },
                      )),
          ),
        ],
      ),
    );
  }

  Widget _buildSongTile({
    required SongItem item,
    required VoidCallback onTap,
    required List<PopupMenuEntry<String>> menuItems,
    required void Function(String) onMenuSelected,
    int? dragIndex,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      onTap: onTap,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dragIndex != null)
            ReorderableDragStartListener(
              index: dragIndex,
              child: const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Icon(Icons.drag_handle, color: Colors.white38),
              ),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: item.thumbPath != null
                ? Image.file(
                    File(item.thumbPath!),
                    width: 42,
                    height: 42,
                    fit: BoxFit.cover,
                  )
                : Container(
                    width: 42,
                    height: 42,
                    color: const Color(0xFF262626),
                    child: const Icon(Icons.music_note, size: 20, color: Colors.white54),
                  ),
          ),
        ],
      ),
      title: Text(
        item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, color: Colors.white54),
        onSelected: onMenuSelected,
        itemBuilder: (_) => menuItems,
      ),
    );
  }
}
