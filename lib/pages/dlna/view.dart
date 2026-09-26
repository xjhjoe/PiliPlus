import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/loading_widget/loading_widget.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/view_sliver_safe_area.dart';
import 'package:dlna_dart/dlna.dart';
import 'package:dlna_dart/xmlParser.dart' show VideoMime;
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class DLNAPage extends StatefulWidget {
  const DLNAPage({super.key});

  @override
  State<DLNAPage> createState() => _DLNAPageState();
}

class _DLNAPageState extends State<DLNAPage> {
  static const _localNetwork = MethodChannel('piliplus/local_network');
  final _searcher = DLNAManager();
  final Map<String, DLNADevice> _deviceList = {};
  late final _url = Get.parameters['url']!;
  late final _title = Get.parameters['title'];
  late final VideoMime _videoMime = _detectVideoMime();

  Timer? _timer;
  bool _isSearching = false;
  bool _permissionDenied = false;
  String? _lastDeviceKey;
  String? _castingKey;
  String? _castStage;
  String? _castError;
  String? _castErrorKey;

  VideoMime _detectVideoMime() {
    final format = (Get.parameters['format'] ?? '').toLowerCase();
    final path = Uri.tryParse(_url)?.path.toLowerCase() ?? '';
    if (format.contains('flv') || path.endsWith('.flv')) {
      return VideoMime.flv;
    }
    if (format.contains('mp4') || path.endsWith('.mp4')) {
      return VideoMime.mp4;
    }
    return VideoMime.any;
  }

  String _castFailure(Object error) {
    if (error is TimeoutException) return '设备响应超时，请重试';
    final message = error.toString();
    final upnpCode = RegExp(r'<errorCode>(\d+)</errorCode>').firstMatch(message);
    if (upnpCode != null) return '设备拒绝播放（UPnP ${upnpCode.group(1)}）';
    final httpCode = RegExp(r'status (\d+)').firstMatch(message);
    if (httpCode != null) return '设备返回 HTTP ${httpCode.group(1)}';
    if (error is SocketException) return '无法连接设备，请检查电视和手机网络';
    return '设备未接受播放命令（${error.runtimeType}）';
  }

  Future<void> _castTo(String key, DLNADevice device) async {
    if (_castingKey != null) return;
    setState(() {
      _castingKey = key;
      _castStage = '正在发送视频地址…';
      _castError = null;
      _castErrorKey = null;
    });
    try {
      await device.setUrl(_url, title: _title ?? '', type: _videoMime);
      if (!mounted) return;
      setState(() => _castStage = '正在请求电视播放…');
      await device.play();
      if (!mounted) return;
      setState(() {
        _lastDeviceKey = key;
        _castStage = '已发送（${_videoMime.name}）；无画面可再次点按重试';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _castStage = null;
          _castError = _castFailure(error);
          _castErrorKey = key;
        });
      }
    } finally {
      if (mounted) setState(() => _castingKey = null);
    }
  }

  @override
  void initState() {
    super.initState();
    _onSearch(isInit: true);
  }

  Future<void> _onSearch({bool isInit = false}) async {
    if (_isSearching) return;
    _isSearching = true;
    if (!isInit && mounted) {
      _lastDeviceKey = null;
      _castError = null;
      _castErrorKey = null;
      _castStage = null;
      _deviceList.clear();
      setState(() {});
    }
    if (Platform.isAndroid) {
      bool granted;
      try {
        granted = await _localNetwork.invokeMethod<bool>('requestPermission') ?? false;
      } on PlatformException {
        granted = false;
      }
      if (!mounted) {
        _isSearching = false;
        return;
      }
      if (!granted) {
        setState(() {
          _permissionDenied = true;
          _isSearching = false;
        });
        return;
      }
    }
    _permissionDenied = false;
    final deviceManager = await _searcher.start();
    if (!mounted) {
      return;
    }
    _timer = Timer(const Duration(seconds: 20), _searcher.stop);
    await for (final deviceList in deviceManager.devices.stream) {
      if (mounted) {
        _deviceList.addAll(deviceList);
        setState(() {});
      }
    }
    if (mounted) {
      setState(() {
        _isSearching = false;
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _searcher.stop();
    _lastDeviceKey = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('投屏'),
        actions: [
          IconButton(
            tooltip: '搜索',
            onPressed: _castingKey == null ? _onSearch : null,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          if (_isSearching) linearLoading,
          ViewSliverSafeArea(sliver: _buildBody(colorScheme)),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme colorScheme) {
    if (!_isSearching && _deviceList.isEmpty) {
      return HttpError(
        errMsg: _permissionDenied ? '请允许 PiliPlus 访问局域网后重试' : '没有设备',
        onReload: _onSearch,
      );
    }
    if (_deviceList.isNotEmpty) {
      final keys = _deviceList.keys.toList();
      return SliverList.builder(
        itemCount: keys.length,
        itemBuilder: (context, index) {
          final key = keys[index];
          final device = _deviceList[key]!;
          final isCurr = key == _lastDeviceKey;
          final isCasting = key == _castingKey;
          return ListTile(
            title: Text(
              device.info.friendlyName,
              style: isCurr ? TextStyle(color: colorScheme.primary) : null,
            ),
            subtitle: Text(
              isCasting || (isCurr && _castStage != null)
                  ? _castStage!
                  : _castError != null && key == _castErrorKey
                  ? _castError!
                  : key,
            ),
            trailing: isCasting
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _castingKey == null ? () => _castTo(key, device) : null,
          );
        },
      );
    }
    return const SliverToBoxAdapter();
  }
}
