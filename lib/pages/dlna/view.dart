import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/loading_widget/loading_widget.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/view_sliver_safe_area.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/pages/dlna/cast_queue.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:dlna_dart/dlna.dart';
import 'package:dlna_dart/xmlParser.dart' show PositionParser, TransportInfoParser, VideoMime;
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class DLNAPage extends StatefulWidget {
  const DLNAPage({super.key});

  @override
  State<DLNAPage> createState() => _DLNAPageState();
}

class _DLNAPageState extends State<DLNAPage> {
  final _searcher = DLNAManager();
  final Map<String, DLNADevice> _deviceList = {};
  late final _url = Get.parameters['url']!;
  late final _title = Get.parameters['title'] ?? '视频';
  late final CastQueue? _queue = Get.arguments is CastQueue
      ? Get.arguments as CastQueue
      : null;

  Timer? _timer;
  Timer? _positionTimer;
  bool _isSearching = false;
  bool _polling = false;
  bool _isCasting = false;
  bool _autoNext = true;
  bool _isPlaying = false;
  bool _seenPlaying = false;
  int _stoppedTicks = 0;
  int _atEndTicks = 0;
  int _lastPosition = 0;
  int _duration = 0;
  int _currentIndex = 0;
  int _session = 0;
  String? _lastDeviceKey;
  DLNADevice? _currentDevice;
  String? _stage;
  String? _castError;
  String? _searchError;
  PermissionStatus? _permissionStatus;

  bool get _hasQueue => _queue != null && _queue!.items.isNotEmpty;
  bool get _hasNext => _hasQueue && _currentIndex < _queue!.items.length - 1;
  bool get _hasPrevious => _hasQueue && _currentIndex > 0;

  @override
  void initState() {
    super.initState();
    _currentIndex = _queue?.initialIndex ?? 0;
    _onSearch(isInit: true);
  }

  @override
  void dispose() {
    _session++;
    _positionTimer?.cancel();
    _timer?.cancel();
    _searcher.stop();
    super.dispose();
  }

  bool _isXiaomi(DLNADevice device) {
    final name = device.info.friendlyName.toLowerCase();
    return name.contains('小米') || name.contains('xiaomi') ||
        name.contains('mi tv');
  }

  bool _isDangbei(DLNADevice device) {
    final name = device.info.friendlyName.toLowerCase();
    return name.contains('当贝') || name.contains('dangbei');
  }

  VideoMime _mime(String? format, String url) {
    final name = (format ?? '').toLowerCase();
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    if (name.contains('flv') || path.endsWith('.flv')) return VideoMime.flv;
    if (name.contains('mp4') || path.endsWith('.mp4')) return VideoMime.mp4;
    return VideoMime.any;
  }

  String _failure(Object error, String stage) {
    final msg = error.toString().replaceAll(
      RegExp(r'https?://[^\s<>"]+'), '[URL]',
    );
    final code = RegExp(r'<errorCode>(\d+)</errorCode>').firstMatch(msg);
    if (code != null) return '$stage: UPnP ${code.group(1)}';
    final safe = msg.length > 180 ? '${msg.substring(0, 180)}…' : msg;
    return '$stage: $safe';
  }

  bool _connectionDropped(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('connection closed before full header') ||
        msg.contains('connection reset by peer') ||
        msg.contains('connection terminated before');
  }

  Future<void> _freshXiaomiSetUrl(
    DLNADevice device, String url, String title, VideoMime mime,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client
          .postUrl(Uri.parse(device.controlURL('AVTransport')))
          .timeout(const Duration(seconds: 8));
      request.persistentConnection = false;
      request.headers.set(HttpHeaders.contentTypeHeader, 'text/xml; charset="utf-8"');
      request.headers.set('SOAPAction',
          '"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"');
      final payload = utf8.encode(
        XmlText.setPlayURLXml(url, title: title, type: mime),
      );
      request.contentLength = payload.length;
      request.add(payload);
      final response = await request.close().timeout(const Duration(seconds: 10));
      final body = await response.transform(utf8.decoder).join().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != HttpStatus.ok) {
        final code = RegExp(r'<errorCode>(\d+)</errorCode>')
            .firstMatch(body)?.group(1);
        throw HttpException('HTTP ${response.statusCode}; UPnP ${code ?? 'unknown'}');
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _setUriWithoutMetadata(
    DLNADevice device, String url, String title, VideoMime mime,
  ) async {
    final xml = XmlText.setPlayURLXml(url, title: title, type: mime);
    final pattern = RegExp(
      r'<CurrentURIMetaData>.*?</CurrentURIMetaData>', dotAll: true,
    );
    if (!pattern.hasMatch(xml)) throw StateError('Missing DLNA metadata');
    await device.request(
      'SetAVTransportURI',
      utf8.encode(xml.replaceFirst(
        pattern, '<CurrentURIMetaData></CurrentURIMetaData>',
      )),
    );
  }

  Future<void> _sendToDevice(
    DLNADevice device, String url, String title, VideoMime mime,
  ) async {
    final isXiaomi = _isXiaomi(device);
    final isDangbei = _isDangbei(device);
    if (!isXiaomi) {
      try {
        await device.stop().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    final modes = <int>[
      0,
      if (isDangbei && mime != VideoMime.any) 1,
      if (isDangbei) 2,
    ];
    Object? lastError;
    for (final mode in modes) {
      final label = switch (mode) {
        1 => '通用媒体声明',
        2 => '简化媒体元数据',
        _ => '标准模式',
      };
      if (mounted) setState(() => _stage = '正在发送视频地址 ($label)');
      try {
        if (mode == 2) {
          await _setUriWithoutMetadata(device, url, title, mime);
        } else {
          try {
            await device.setUrl(
              url, title: title, type: mode == 1 ? VideoMime.any : mime,
            );
          } catch (error) {
            if (!isXiaomi || !_connectionDropped(error)) rethrow;
            if (mounted) setState(() => _stage = '小米电视连接中断，备用连接重试');
            await Future<void>.delayed(const Duration(milliseconds: 400));
            await _freshXiaomiSetUrl(device, url, title, mime);
          }
        }
        if (mounted) setState(() => _stage = '正在请求电视播放 ($label)');
        await Future<void>.delayed(const Duration(milliseconds: 350));
        await device.play();
        return;
      } catch (e) {
        lastError = e;
        final code = RegExp(r'<errorCode>(501|704|714|716)</errorCode>')
            .hasMatch(e.toString());
        if (!isDangbei || !code) break;
      }
    }
    throw lastError ?? StateError('无法发送 DLNA 指令');
  }

  Future<(String, String, VideoMime)> _getEpisodeStream(int index) async {
    if (!_hasQueue) return (_url, _title, _mime(Get.parameters['format'], _url));
    final item = _queue!.items[index];
    if (index == _queue!.initialIndex) {
      return (_url, item.title, _mime(Get.parameters['format'], _url));
    }
    final result = await VideoHttp.tvPlayUrl(
      cid: item.cid,
      objectId: item.objectId,
      playurlType: item.playurlType,
      qn: _queue!.quality,
    );
    if (result case Success(:final response)) {
      final first = response.durl?.firstOrNull;
      if (first == null || first.playUrls.isEmpty) {
        throw StateError('当前剧集没有支持投屏的播放地址');
      }
      final url = VideoUtils.getCdnUrl(first.playUrls);
      return (url, item.title, _mime(response.format, url));
    }
    throw StateError('获取下一集播放地址失败: $result');
  }

  Future<void> _playIndex(DLNADevice device, int index) async {
    if (_isCasting) return;
    final session = ++_session;
    _positionTimer?.cancel();
    setState(() {
      _isCasting = true;
      _stage = '准备投屏…';
      _castError = null;
      _isPlaying = false;
    });
    try {
      final (url, title, mime) = await _getEpisodeStream(index);
      if (!mounted || session != _session) return;
      await _sendToDevice(device, url, title, mime);
      if (!mounted || session != _session) return;
      setState(() {
        _currentDevice = device;
        _currentIndex = index;
        _isPlaying = true;
        _stage = '已发送：$title';
        _lastPosition = 0;
        _duration = _hasQueue ? (_queue!.items[index].durationSeconds ?? 0) : 0;
        _seenPlaying = false;
        _stoppedTicks = 0;
        _atEndTicks = 0;
      });
      _positionTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        _pollStatus(session);
      });
      _pollStatus(session);
    } catch (error) {
      if (mounted && session == _session) {
        setState(() {
          _castError = _failure(error, _stage ?? '投屏失败');
          _stage = null;
        });
      }
    } finally {
      if (mounted && session == _session) {
        setState(() => _isCasting = false);
      }
    }
  }

  Future<void> _pollStatus(int session) async {
    if (_polling || !_isPlaying || _isCasting || !mounted || session != _session) {
      return;
    }
    final device = _currentDevice;
    if (device == null) return;
    _polling = true;
    try {
      String? state;
      try {
        final result = await device.getTransportInfo().timeout(
          const Duration(seconds: 6),
        );
        state = TransportInfoParser(result).CurrentTransportState.toUpperCase();
      } catch (_) {}
      if (!mounted || session != _session || !_isPlaying) return;
      try {
        final info = PositionParser(
          await device.position().timeout(const Duration(seconds: 6)),
        );
        if (info.RelTimeInt > _lastPosition) _lastPosition = info.RelTimeInt;
        if (info.TrackDurationInt > 0) _duration = info.TrackDurationInt;
      } catch (_) {}
      if (!mounted || session != _session || !_isPlaying) return;
      if (state == 'PLAYING') _seenPlaying = true;
      final nearEnd = _duration > 0 && _lastPosition >= _duration - 2 &&
          _lastPosition > 0;
      if (nearEnd) {
        _atEndTicks++;
      } else {
        _atEndTicks = 0;
      }
      final wasRunning = _seenPlaying && _lastPosition > 0;
      final stopped = state == 'STOPPED' || state == 'NO_MEDIA_PRESENT';
      _stoppedTicks = wasRunning && stopped ? _stoppedTicks + 1 : 0;
      // Require playback progress and two status confirmations to avoid
      // skipping on transient STOPPED during buffering or device handoff.
      final ended = (_atEndTicks >= 2 && state != 'PAUSED_PLAYBACK') ||
          (_stoppedTicks >= 2 &&
              (_duration > 0
                  ? _lastPosition >= _duration * 0.7
                  : _lastPosition >= 30));
      if (ended) {
        _positionTimer?.cancel();
        if (_autoNext && _hasNext) {
          _polling = false;
          await _playIndex(device, _currentIndex + 1);
          return;
        }
        setState(() {
          _isPlaying = false;
          _stage = '播放完毕';
        });
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _changeEpisode(int delta) async {
    final device = _currentDevice;
    if (device == null || _isCasting || !_hasQueue) return;
    final nextIndex = _currentIndex + delta;
    if (nextIndex < 0 || nextIndex >= _queue!.items.length) return;
    await _playIndex(device, nextIndex);
  }

  Future<void> _pauseResume() async {
    final device = _currentDevice;
    if (device == null || _isCasting) return;
    try {
      if (_isPlaying) {
        await device.pause();
        _positionTimer?.cancel();
        if (mounted) setState(() {
          _isPlaying = false;
          _stage = '已暂停';
        });
      } else {
        await device.play();
        if (mounted) setState(() {
          _isPlaying = true;
          _stage = '已继续播放';
        });
        final session = _session;
        _positionTimer = Timer.periodic(
          const Duration(seconds: 3), (_) => _pollStatus(session),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _castError = _failure(e, '控制失败'));
    }
  }

  Future<void> _onSearch({bool isInit = false}) async {
    if (_isSearching) return;
    _isSearching = true;
    _permissionStatus = null;
    _searchError = null;
    if (!isInit && mounted) {
      _deviceList.clear();
      setState(() {});
    }
    try {
      if (Platform.isAndroid && DeviceUtils.sdkInt >= 37) {
        final status = await Permission.accessLocalNetwork.request();
        if (!mounted) return;
        _permissionStatus = status;
        if (!status.isGranted) return;
      }
      final manager = await _searcher.start();
      if (!mounted) return;
      _timer?.cancel();
      _timer = Timer(const Duration(seconds: 20), _searcher.stop);
      await for (final devices in manager.devices.stream) {
        if (mounted) {
          _deviceList.addAll(devices);
          setState(() {});
        }
      }
    } catch (_) {
      _searchError = '搜索设备失败，请检查网络后重试';
    } finally {
      _timer?.cancel();
      _timer = null;
      _searcher.stop();
      if (mounted) setState(() => _isSearching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.of(context);
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('投屏 / 自动连播'),
        actions: [
          IconButton(
            tooltip: '重新搜索',
            onPressed: _isCasting ? null : () => _onSearch(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          if (_isSearching) linearLoading,
          ViewSliverSafeArea(sliver: _buildBody(scheme)),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_deviceList.isEmpty && !_isSearching) {
      if (_permissionStatus case final status? when !status.isGranted) {
        return HttpError(
          errMsg: '请允许 PiliPlus 访问局域网，然后重试',
          onReload: status.isPermanentlyDenied
              ? () { openAppSettings(); }
              : _onSearch,
        );
      }
      return HttpError(
        errMsg: _searchError ?? '没有设备',
        onReload: _onSearch,
      );
    }
    return SliverList(
      delegate: SliverChildListDelegate([
        if (_hasQueue)
          SwitchListTile(
            title: const Text('自动播放下一集'),
            subtitle: Text('共 ${_queue!.items.length} 集 · 手机保持投屏页面'),
            value: _autoNext,
            onChanged: (value) => setState(() => _autoNext = value),
          ),
        if (_currentDevice != null)
          ListTile(
            title: Text(_queue == null
                ? _title
                : _queue!.items[_currentIndex].title),
            subtitle: Text(_stage ?? '已连接电视'),
            trailing: Text(_hasQueue
                ? '${_currentIndex + 1}/${_queue!.items.length}'
                : '1/1'),
          ),
        if (_currentDevice != null)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '上一集',
                onPressed: _hasPrevious && !_isCasting
                    ? () => _changeEpisode(-1)
                    : null,
                icon: const Icon(Icons.skip_previous),
              ),
              IconButton(
                tooltip: _isPlaying ? '暂停' : '继续',
                onPressed: _isCasting ? null : _pauseResume,
                icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
              ),
              IconButton(
                tooltip: '下一集',
                onPressed: _hasNext && !_isCasting
                    ? () => _changeEpisode(1)
                    : null,
                icon: const Icon(Icons.skip_next),
              ),
            ],
          ),
        if (_castError != null)
          ListTile(
            leading: const Icon(Icons.error_outline),
            title: Text(_castError!),
          ),
        for (final entry in _deviceList.entries)
          ListTile(
            title: Text(entry.value.info.friendlyName),
            subtitle: Text(entry.key == _lastDeviceKey
                ? '当前设备 · ${_stage ?? ''}'
                : entry.key),
            trailing: _isCasting ? const Icon(Icons.hourglass_empty) : null,
            onTap: _isCasting ? null : () {
              _lastDeviceKey = entry.key;
              _playIndex(entry.value, _currentIndex);
            },
          ),
      ]),
    );
  }
}
