import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VibeMusicApp());
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
          secondary: Color(0xFFC4B5FD),
          surface: Color(0xFF141414),
        ),
      ),
      home: const PlayerHomePage(),
    );
  }
}

class SongItem {
  String id;
  String title;
  String audioPath;
  String? thumbPath;

  SongItem({
    required this.id,
    required this.title,
    required this.audioPath,
    this.thumbPath,
  });
}

class PlayerHomePage extends StatefulWidget {
  const PlayerHomePage({super.key});

  @override
  State<PlayerHomePage> createState() => _PlayerHomePageState();
}

class _PlayerHomePageState extends State<PlayerHomePage> {
  static const List<String> musicExts = ['.mp3', '.m4a', '.wav', '.ogg', '.flac'];
  static const List<String> imgExts = ['.png', '.jpg', '.jpeg', '.webp', '.gif'];

  final AudioPlayer _player = AudioPlayer();
  final TextEditingController _searchCtrl = TextEditingController();

  late Directory _baseDir;
  late Directory _musicDir;
  late Directory _thumbDir;
  late Directory _assetDir;
  late File _configFile;
  late File _stateFile;

  List<SongItem> _library = [];
  List<SongItem> _queue = [];
  int _currentIndex = 0;

  bool _isPlaying = false;
  bool _isShuffle = false;
  int _repeatMode = 1; // 0: off, 1: all, 2: one
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isSeeking = false;
  String _searchQuery = '';

  Timer? _sleepTimer;
  DateTime? _sleepEndTime;
  String _sleepRemainingText = '';

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    await _requestPermissions();
    await _initDirectories();
    _setupAudioListeners();
    await _scanMusicFolder(restoreState: true);
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.storage,
        Permission.audio,
        Permission.photos,
        Permission.manageExternalStorage,
      ].request();
    }
  }

  Future<void> _initDirectories() async {
    if (Platform.isAndroid) {
      _baseDir = Directory('/storage/emulated/0/VibeMusic');
    } else {
      _baseDir = Directory(p.join(Directory.current.path, 'VibeMusicData'));
    }
    if (!await _baseDir.exists()) {
      await _baseDir.create(recursive: true);
    }

    _configFile = File(p.join(_baseDir.path, 'config.json'));
    _stateFile = File(p.join(_baseDir.path, 'vibe_music_state.json'));

    Map<String, dynamic> cfg = {};
    if (await _configFile.exists()) {
      try {
        cfg = jsonDecode(await _configFile.readAsString());
      } catch (_) {}
    }

    final mPath = cfg['music_folder'] as String?;
    _musicDir = (mPath != null && Directory(mPath).existsSync())
        ? Directory(mPath)
        : Directory(p.join(_baseDir.path, 'Drop_Music_Here'));

    final tPath = cfg['thumb_folder'] as String?;
    _thumbDir = (tPath != null && Directory(tPath).existsSync())
        ? Directory(tPath)
        : Directory(p.join(_baseDir.path, 'Thumbnails'));

    final aPath = cfg['asset_folder'] as String?;
    _assetDir = (aPath != null && Directory(aPath).existsSync())
        ? Directory(aPath)
        : Directory(p.join(_baseDir.path, 'asset'));

    await _musicDir.create(recursive: true);
    await _thumbDir.create(recursive: true);
    await _assetDir.create(recursive: true);
    await _saveConfig();
  }

  Future<void> _saveConfig() async {
    try {
      await _configFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'music_folder': _musicDir.path,
          'thumb_folder': _thumbDir.path,
          'asset_folder': _assetDir.path,
        }),
      );
    } catch (_) {}
  }

  void _setupAudioListeners() {
    _player.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() {
        _isPlaying = state == PlayerState.playing;
      });
    });

    _player.onDurationChanged.listen((d) {
      if (!mounted) return;
      setState(() {
        _duration = d;
      });
    });

    _player.onPositionChanged.listen((pos) {
      if (!mounted || _isSeeking) return;
      setState(() {
        _position = pos;
      });
    });

    _player.onPlayerComplete.listen((_) {
      if (_repeatMode == 2) {
        _playAt(_currentIndex, autoPlay: true, startSec: 0);
      } else {
        _nextSong(autoAdvance: true);
      }
    });
  }

  String? _findThumb(String baseName) {
    if (!_thumbDir.existsSync()) return null;
    final target = baseName.toLowerCase();
    for (final entity in _thumbDir.listSync()) {
      if (entity is File) {
        final ext = p.extension(entity.path).toLowerCase();
        final stem = p.basenameWithoutExtension(entity.path).toLowerCase();
        if (imgExts.contains(ext) && stem == target) {
          return entity.path;
        }
      }
    }
    return null;
  }

  File? _findAssetIcon(List<String> names) {
    if (!_assetDir.existsSync()) return null;
    for (final name in names) {
      final f = File(p.join(_assetDir.path, name));
      if (f.existsSync()) return f;
    }
    return null;
  }

  Future<void> _scanMusicFolder({bool restoreState = false}) async {
    if (!await _musicDir.exists()) {
      await _musicDir.create(recursive: true);
    }

    final files = _musicDir
        .listSync()
        .whereType<File>()
        .where((f) => musicExts.contains(p.extension(f.path).toLowerCase()))
        .toList()
      ..sort((a, b) => p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase()));

    final loaded = files.map((f) {
      final title = p.basenameWithoutExtension(f.path);
      return SongItem(
        id: f.path,
        title: title,
        audioPath: f.path,
        thumbPath: _findThumb(title),
      );
    }).toList();

    Map<String, dynamic> saved = {};
    if (restoreState && await _stateFile.exists()) {
      try {
        saved = jsonDecode(await _stateFile.readAsString());
      } catch (_) {}
    }

    setState(() {
      _library = loaded;
      if (saved.isNotEmpty) {
        _isShuffle = saved['is_shuffle'] == true;
        _repeatMode = (saved['repeat_mode'] as int?) ?? 1;

        final savedPaths = List<String>.from(saved['queue_paths'] ?? []);
        final byPath = {for (final s in _library) s.audioPath: s};
        final restored = <SongItem>[];
        for (final path in savedPaths) {
          final item = byPath.remove(path);
          if (item != null) restored.add(item);
        }
        restored.addAll(byPath.values);
        _queue = restored;

        final lastPath = saved['current_path'] as String?;
        final idx = _queue.indexWhere((s) => s.audioPath == lastPath);
        _currentIndex = idx >= 0 ? idx : 0;
      } else {
        _queue = List<SongItem>.from(_library);
        if (_isShuffle) _queue.shuffle(Random());
        _currentIndex = 0;
      }
    });

    if (_queue.isNotEmpty) {
      final startSec = (saved['position_sec'] as num?)?.toInt() ?? 0;
      await _playAt(_currentIndex, autoPlay: false, startSec: startSec);
    }
  }

  Future<void> _saveState() async {
    try {
      final current = (_queue.isNotEmpty && _currentIndex < _queue.length) ? _queue[_currentIndex] : null;
      await _stateFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'current_path': current?.audioPath,
          'position_sec': _position.inSeconds,
          'is_shuffle': _isShuffle,
          'repeat_mode': _repeatMode,
          'queue_paths': _queue.map((s) => s.audioPath).toList(),
        }),
      );
    } catch (_) {}
  }

  Future<void> _playAt(int index, {bool autoPlay = true, int startSec = 0}) async {
    if (_queue.isEmpty || index < 0 || index >= _queue.length) return;

    final song = _queue[index];
    song.thumbPath = _findThumb(song.title);

    setState(() {
      _currentIndex = index;
      _position = Duration(seconds: startSec);
    });

    await _player.stop();
    await _player.setSourceDeviceFile(song.audioPath);
    if (startSec > 0) {
      await _player.seek(Duration(seconds: startSec));
    }
    if (autoPlay) {
      await _player.resume();
    }
    await _saveState();
  }

  Future<void> _togglePlayPause() async {
    if (_queue.isEmpty) return;
    if (_isPlaying) {
      await _player.pause();
      await _saveState();
    } else {
      if (_player.source == null) {
        await _playAt(_currentIndex, autoPlay: true, startSec: _position.inSeconds);
      } else {
        await _player.resume();
      }
    }
  }

  Future<void> _nextSong({bool autoAdvance = false}) async {
    if (_queue.isEmpty) return;
    int nxt = _currentIndex + 1;
    if (nxt >= _queue.length) {
      if (autoAdvance && _repeatMode == 0) {
        await _player.stop();
        setState(() {
          _isPlaying = false;
          _position = Duration.zero;
        });
        return;
      }
      if (_isShuffle) {
        _queue.shuffle(Random());
      }
      nxt = 0;
    }
    await _playAt(nxt, autoPlay: true);
  }

  Future<void> _prevSong() async {
    if (_queue.isEmpty) return;
    if (_position.inSeconds > 3) {
      await _playAt(_currentIndex, autoPlay: true, startSec: 0);
      return;
    }
    int prv = _currentIndex - 1;
    if (prv < 0) prv = _queue.length - 1;
    await _playAt(prv, autoPlay: true);
  }

  void _toggleShuffle() {
    if (_queue.isEmpty) return;
    final current = _queue[_currentIndex];
    final rest = _library.where((s) => s.id != current.id).toList();
    setState(() {
      _isShuffle = !_isShuffle;
      if (_isShuffle) rest.shuffle(Random());
      _queue = [current, ...rest];
      _currentIndex = 0;
    });
    _saveState();
  }

  void _cycleRepeatMode() {
    setState(() {
      _repeatMode = (_repeatMode + 1) % 3;
    });
    _saveState();
  }

  Future<void> _importLocalFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'm4a', 'wav', 'ogg', 'flac'],
      allowMultiple: true,
    );
    if (result == null) return;

    for (final file in result.files) {
      if (file.path == null) continue;
      final src = File(file.path!);
      final dst = File(p.join(_musicDir.path, p.basename(src.path)));
      if (!await dst.exists()) {
        await src.copy(dst.path);
      }
    }
    await _scanMusicFolder(restoreState: true);
  }

  Future<void> _renameSong(SongItem song) async {
    final ctrl = TextEditingController(text: song.title);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Đổi tên bài hát'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );

    if (newName == null || newName.isEmpty) return;
    final safeName = newName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (safeName.isEmpty || safeName == song.title) return;

    final oldAudio = File(song.audioPath);
    final newAudioPath = p.join(oldAudio.parent.path, '$safeName${p.extension(oldAudio.path)}');
    if (await File(newAudioPath).exists()) return;

    final isCurrent = _queue.isNotEmpty && _queue[_currentIndex].id == song.id;
    final wasPlaying = _isPlaying;
    final savedSec = _position.inSeconds;

    if (isCurrent) await _player.stop();
    await oldAudio.rename(newAudioPath);

    String? newThumbPath;
    if (song.thumbPath != null && await File(song.thumbPath!).exists()) {
      final oldThumb = File(song.thumbPath!);
      newThumbPath = p.join(oldThumb.parent.path, '$safeName${p.extension(oldThumb.path)}');
      await oldThumb.rename(newThumbPath);
    }

    setState(() {
      song.id = newAudioPath;
      song.title = safeName;
      song.audioPath = newAudioPath;
      song.thumbPath = newThumbPath;
    });

    if (isCurrent) {
      await _playAt(_currentIndex, autoPlay: wasPlaying, startSec: savedSec);
    } else {
      await _saveState();
    }
  }

  Future<void> _deleteSong(SongItem song) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Xóa bài hát'),
        content: Text("Xóa vĩnh viễn '${song.title}' khỏi máy?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );

    if (ok != true) return;
    final isCurrent = _queue.isNotEmpty && _queue[_currentIndex].id == song.id;
    if (isCurrent) await _player.stop();

    try {
      if (await File(song.audioPath).exists()) await File(song.audioPath).delete();
      if (song.thumbPath != null && await File(song.thumbPath!).exists()) {
        await File(song.thumbPath!).delete();
      }
    } catch (_) {}

    setState(() {
      _library.removeWhere((s) => s.id == song.id);
      final removedIdx = _queue.indexWhere((s) => s.id == song.id);
      if (removedIdx != -1) {
        _queue.removeAt(removedIdx);
        if (_currentIndex > removedIdx) {
          _currentIndex--;
        } else if (_currentIndex >= _queue.length) {
          _currentIndex = max(0, _queue.length - 1);
        }
      }
    });

    if (isCurrent && _queue.isNotEmpty) {
      await _playAt(_currentIndex, autoPlay: false);
    }
    await _saveState();
  }

  void _openSleepDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Hẹn giờ tắt nhạc'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: 'Nhập số phút (0 để hủy)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng')),
          ElevatedButton(
            onPressed: () {
              final mins = int.tryParse(ctrl.text.trim()) ?? 0;
              _sleepTimer?.cancel();
              if (mins <= 0) {
                setState(() {
                  _sleepEndTime = null;
                  _sleepRemainingText = '';
                });
              } else {
                _sleepEndTime = DateTime.now().add(Duration(minutes: mins));
                _sleepTimer = Timer.periodic(const Duration(seconds: 1), (t) {
                  final rem = _sleepEndTime!.difference(DateTime.now());
                  if (rem.isNegative) {
                    t.cancel();
                    if (_isPlaying) _player.pause();
                    setState(() {
                      _sleepEndTime = null;
                      _sleepRemainingText = '';
                    });
                  } else {
                    setState(() {
                      _sleepRemainingText = 'Tắt sau ${_fmtDuration(rem)}';
                    });
                  }
                });
              }
              Navigator.pop(ctx);
            },
            child: const Text('Xác nhận'),
          ),
        ],
      ),
    );
  }

  void _openSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161616),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          Widget folderTile(String title, Directory dir, Future<void> Function(Directory) onPicked) {
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF202020),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 4),
                        Text(
                          dir.path,
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2A2438),
                      foregroundColor: const Color(0xFFC4B5FD),
                    ),
                    onPressed: () async {
                      final selected = await FilePicker.platform.getDirectoryPath();
                      if (selected != null) {
                        await onPicked(Directory(selected));
                        setModalState(() {});
                      }
                    },
                    child: const Text('Chọn'),
                  ),
                ],
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Cài đặt thư mục', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                folderTile('🎵 Thư mục Nhạc (Drop_Music_Here)', _musicDir, (d) async {
                  _musicDir = d;
                  await _saveConfig();
                  await _scanMusicFolder(restoreState: false);
                }),
                folderTile('🖼 Thư mục Ảnh bìa (Thumbnails)', _thumbDir, (d) async {
                  _thumbDir = d;
                  await _saveConfig();
                  await _scanMusicFolder(restoreState: true);
                }),
                folderTile('🎨 Thư mục Icon nút bấm (Asset)', _assetDir, (d) async {
                  _assetDir = d;
                  await _saveConfig();
                  setState(() {});
                }),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('Quét lại thư mục ngay'),
                    onPressed: () async {
                      await _scanMusicFolder(restoreState: true);
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _fmtDuration(Duration d) {
    final mins = d.inMinutes;
    final secs = d.inSeconds % 60;
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }

  Widget _buildCustomIcon(List<String> assetNames, IconData fallbackIcon, {double size = 24, Color? color}) {
    final file = _findAssetIcon(assetNames);
    if (file != null) {
      return Image.file(file, width: size, height: size, fit: BoxFit.contain);
    }
    return Icon(fallbackIcon, size: size, color: color);
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _player.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentSong = (_queue.isNotEmpty && _currentIndex < _queue.length) ? _queue[_currentIndex] : null;
    final filtered = _searchQuery.isEmpty
        ? _queue.asMap().entries.toList()
        : _queue
            .asMap()
            .entries
            .where((e) => e.value.title.toLowerCase().contains(_searchQuery.toLowerCase()))
            .toList();

    final maxSec = max(_duration.inSeconds.toDouble(), 1.0);
    final curSec = _position.inSeconds.toDouble().clamp(0.0, maxSec);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // === KHUNG TRÌNH PHÁT ===
            Container(
              margin: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF141414),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          width: 84,
                          height: 84,
                          color: const Color(0xFF1F1F1F),
                          child: (currentSong?.thumbPath != null && File(currentSong!.thumbPath!).existsSync())
                              ? Image.file(File(currentSong.thumbPath!), fit: BoxFit.cover)
                              : const Icon(Icons.music_note, size: 38, color: Colors.grey),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              currentSong?.title ?? 'Chưa có bài nhạc nào',
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _sleepRemainingText.isNotEmpty
                                  ? _sleepRemainingText
                                  : (_isPlaying ? 'Đang phát' : 'Đã tạm dừng'),
                              style: const TextStyle(fontSize: 12, color: Color(0xFFA78BFA)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                    ),
                    child: Slider(
                      value: curSec,
                      min: 0,
                      max: maxSec,
                      activeColor: const Color(0xFFA78BFA),
                      inactiveColor: const Color(0xFF2B2B2B),
                      onChangeStart: (_) => _isSeeking = true,
                      onChanged: (v) => setState(() => _position = Duration(seconds: v.toInt())),
                      onChangeEnd: (v) async {
                        _isSeeking = false;
                        await _player.seek(Duration(seconds: v.toInt()));
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_fmtDuration(_position), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                        Text(_fmtDuration(_duration), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        onPressed: _toggleShuffle,
                        style: IconButton.styleFrom(
                          backgroundColor: _isShuffle ? const Color(0xFF2A2438) : Colors.transparent,
                        ),
                        icon: _buildCustomIcon(
                          ['shuffle_button.png', 'shuffle.png'],
                          Icons.shuffle,
                          color: _isShuffle ? const Color(0xFFA78BFA) : Colors.grey,
                        ),
                      ),
                      IconButton(
                        onPressed: _prevSong,
                        icon: _buildCustomIcon(['prev_button.png', 'prev.png'], Icons.skip_previous, size: 28),
                      ),
                      GestureDetector(
                        onTap: _togglePlayPause,
                        child: Container(
                          width: 54,
                          height: 54,
                          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                          alignment: Alignment.center,
                          child: _buildCustomIcon(
                            _isPlaying ? ['pause_button.png', 'pause.png'] : ['play_button.png', 'play.png'],
                            _isPlaying ? Icons.pause : Icons.play_arrow,
                            size: 30,
                            color: Colors.black,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => _nextSong(autoAdvance: false),
                        icon: _buildCustomIcon(['next_button.png', 'next.png'], Icons.skip_next, size: 28),
                      ),
                      IconButton(
                        onPressed: _cycleRepeatMode,
                        style: IconButton.styleFrom(
                          backgroundColor: _repeatMode > 0 ? const Color(0xFF2A2438) : Colors.transparent,
                        ),
                        icon: _buildCustomIcon(
                          ['repeat_button.png', 'repeat.png'],
                          _repeatMode == 2 ? Icons.repeat_one : Icons.repeat,
                          color: _repeatMode > 0 ? const Color(0xFFA78BFA) : Colors.grey,
                        ),
                      ),
                      IconButton(
                        onPressed: _openSleepDialog,
                        style: IconButton.styleFrom(
                          backgroundColor: _sleepEndTime != null ? const Color(0xFF2A2438) : Colors.transparent,
                        ),
                        icon: _buildCustomIcon(
                          ['sleep_button.png', 'sleep.png'],
                          Icons.bedtime_outlined,
                          color: _sleepEndTime != null ? const Color(0xFFA78BFA) : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _importLocalFiles,
                          icon: const Icon(Icons.folder_open, size: 18),
                          label: const Text('Thêm nhạc'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _openSettingsSheet,
                          icon: const Icon(Icons.settings, size: 18),
                          label: const Text('Cài đặt'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // === DANH SÁCH PHÁT ===
            Expanded(
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF141414),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Danh sách phát', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        Text('Tổng ${_queue.length} bài', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _searchCtrl,
                      onChanged: (v) => setState(() => _searchQuery = v.trim()),
                      decoration: InputDecoration(
                        hintText: 'Tìm kiếm bài hát...',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        filled: true,
                        fillColor: const Color(0xFF1E1E1E),
                        contentPadding: const EdgeInsets.symmetric(vertical: 0),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(
                              child: Text(
                                'Chưa có bài hát.\nHãy bỏ nhạc vào thư mục VibeMusic/Drop_Music_Here!',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey),
                              ),
                            )
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (ctx, idx) {
                                final entry = filtered[idx];
                                final qIdx = entry.key;
                                final song = entry.value;
                                final isActive = qIdx == _currentIndex;

                                return Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  decoration: BoxDecoration(
                                    color: isActive ? const Color(0xFF2A2438) : const Color(0xFF1B1B1B),
                                    borderRadius: BorderRadius.circular(10),
                                    border: isActive
                                        ? Border.all(color: const Color(0xFFA78BFA), width: 1)
                                        : null,
                                  ),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                                    leading: ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: Container(
                                        width: 44,
                                        height: 44,
                                        color: const Color(0xFF262626),
                                        child: (song.thumbPath != null && File(song.thumbPath!).existsSync())
                                            ? Image.file(File(song.thumbPath!), fit: BoxFit.cover)
                                            : const Icon(Icons.music_note, color: Colors.grey),
                                      ),
                                    ),
                                    title: Text(
                                      '${isActive ? "▶ " : ""}${song.title}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                                        color: isActive ? const Color(0xFFE9D5FF) : Colors.white,
                                      ),
                                    ),
                                    onTap: () => _playAt(qIdx, autoPlay: true),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.edit, size: 18, color: Colors.grey),
                                          onPressed: () => _renameSong(song),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                                          onPressed: () => _deleteSong(song),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
