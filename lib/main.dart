import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
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
  );
  runApp(const VibeMusicApp());
}

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

class _PlayerScreenState extends State<PlayerScreen> {
  final AudioPlayer _player = AudioPlayer();
  final List<SongItem> _library = [];
  List<SongItem> _queue = [];
  int _currentIndex = 0;
  bool _isShuffle = false;
  bool _isDownloading = false;
  late Directory _musicDir;

  static const _musicExts = ['.mp3', '.m4a', '.wav', '.ogg'];
  static const _imgExts = ['.jpg', '.jpeg', '.png', '.webp'];

  @override
  void initState() {
    super.initState();
    _initApp();

    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed && _queue.isNotEmpty) {
        _nextSong();
      }
    });
  }

  Future<void> _initApp() async {
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
    await _scanMusicFolder();
  }

  Future<void> _scanMusicFolder() async {
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

    setState(() {
      _library
        ..clear()
        ..addAll(loaded);
      _queue = List.from(_library);
      if (_isShuffle) _queue.shuffle(Random());
      _currentIndex = 0;
    });

    if (_queue.isNotEmpty) {
      await _playAt(0, autoPlay: false);
    }
  }

  String _getBaseName(String filePath) {
    final name = filePath.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    return dot == -1 ? name : name.substring(0, dot);
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

  Future<void> _playAt(int index, {bool autoPlay = true}) async {
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

    await _player.setAudioSource(source);
    if (autoPlay) {
      await _player.play();
    }
  }

  void _nextSong() {
    if (_queue.isEmpty) return;
    int next = _currentIndex + 1;
    if (next >= _queue.length) {
      if (_isShuffle) _queue.shuffle(Random());
      next = 0;
    }
    _playAt(next);
  }

  void _prevSong() {
    if (_queue.isEmpty) return;
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
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentSong = _queue.isNotEmpty ? _queue[_currentIndex] : null;

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
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _buildPlayerPane(currentSong, compact: true),
                    const SizedBox(height: 12),
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
    final coverSize = compact ? 140.0 : 220.0;

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
                  child: const Icon(Icons.music_note, size: 60, color: Colors.white38),
                ),
        ),
        const SizedBox(height: 12),
        Text(
          song?.title ?? 'Chưa có bài nhạc nào',
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
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
                    onChanged: (v) => _player.seek(Duration(milliseconds: v.toInt())),
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
              icon: Icon(Icons.shuffle, color: _isShuffle ? const Color(0xFFA78BFA) : Colors.white54),
              onPressed: _toggleShuffle,
            ),
            IconButton(
              icon: const Icon(Icons.skip_previous, size: 32),
              onPressed: _prevSong,
            ),
            StreamBuilder<PlayerState>(
              stream: _player.playerStateStream,
              builder: (context, snapshot) {
                final playing = snapshot.data?.playing ?? false;
                return IconButton(
                  icon: Icon(
                    playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
                    size: 54,
                    color: Colors.white,
                  ),
                  onPressed: () {
                    if (_queue.isEmpty) return;
                    playing ? _player.pause() : _player.play();
                  },
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.skip_next, size: 32),
              onPressed: _nextSong,
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
    final upcomingCount = _queue.length > _currentIndex + 1 ? _queue.length - (_currentIndex + 1) : 0;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF141414),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Danh sách chờ', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              Text('$upcomingCount bài tiếp theo', style: const TextStyle(fontSize: 12, color: Colors.white54)),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: upcomingCount == 0
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
                    },
                    itemBuilder: (context, idx) {
                      final queuePos = _currentIndex + 1 + idx;
                      final item = _queue[queuePos];

                      return Container(
                        key: ValueKey('${item.id}_$queuePos'),
                        decoration: const BoxDecoration(
                          border: Border(bottom: BorderSide(color: Color(0xFF222222))),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          onTap: () => _playAt(queuePos),
                          leading: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ReorderableDragStartListener(
                                index: idx,
                                child: const Padding(
                                  padding: EdgeInsets.only(right: 10),
                                  child: Icon(Icons.drag_handle, color: Colors.white38),
                                ),
                              ),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: item.thumbPath != null
                                    ? Image.file(
                                        File(item.thumbPath!),
                                        width: 44,
                                        height: 44,
                                        fit: BoxFit.cover,
                                      )
                                    : Container(
                                        width: 44,
                                        height: 44,
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
                            onSelected: (value) {
                              setState(() {
                                if (value == 'next' && queuePos > _currentIndex + 1) {
                                  final moved = _queue.removeAt(queuePos);
                                  _queue.insert(_currentIndex + 1, moved);
                                } else if (value == 'remove') {
                                  _queue.removeAt(queuePos);
                                }
                              });
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'next', child: Text('Phát kế tiếp')),
                              PopupMenuItem(value: 'remove', child: Text('Xóa khỏi hàng chờ')),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
