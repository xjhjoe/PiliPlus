import 'dart:async';
import 'dart:convert';
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

  String _castFailure(Object error, String stage) {
    if (error is TimeoutException) return '$stage：设备响应超时，请重试';
    final message = error.toString();
    final upnpCode = RegExp(r'<errorCode>(\d+)</errorCode>').firstMatch(message);
    if (upnpCode != null) {
      final code = upnpCode.group(1);
      return '$stage：设备返回 UPnP $code（${code == '501' ? '播放操作失败' : '协议错误'}）';
    }
    final httpCode = RegExp(r'status (\d+)').firstMatch(message);
    if (httpCode != null) return '$stage：设备返回 HTTP ${httpCode.group(1)}';
    if (error is SocketException) return '$stage：无法连接设备，请检查电视和手机网络';
    // Keep error specifics visible, but avoid printing signed video CDN URLs.
    final detail = (error is StateError ? error.message : message)
        .replaceAll(RegExp(r'https?://[^\s<>"]+'), '[URL]');
    final brief = detail.length > 160 ? '${detail.substring(0, 160)}…' : detail;
    return '$stage：${error.runtimeType}：$brief';
  }



  bool _isXiaomi(DLNADevice device) {
    final name = device.info.friendlyName.toLowerCase();
    return name.contains('小米') || name.contains('xiaomi') ||
        name.contains('mi tv');
  }

  bool _isConnectionDropped(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('connection closed before full header') ||
        msg.contains('connection reset by peer') ||
        msg.contains('connection terminated before');
  }

  Future<void> _setUrlXiaomiFresh(DLNADevice device) async {
    // A fresh one-off client avoids a stale DLNA HTTP keep-alive socket.
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client
          .postUrl(Uri.parse(device.controlURL('AVTransport')))
          .timeout(const Duration(seconds: 8));
      request.persistentConnection = false;
      request.headers.set(
        HttpHeaders.contentTypeHeader, 'text/xml; charset="utf-8"',
      );
      request.headers.set(
        'SOAPAction',
        '"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"',
      );
      final payload = utf8.encode(
        XmlText.setPlayURLXml(_url, title: _title ?? '', type: _videoMime),
      );
      request.contentLength = payload.length;
      request.add(payload);
      final response =
          await request.close().timeout(const Duration(seconds: 10));
      final responseBody = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != HttpStatus.ok) {
        final code = RegExp(r'<errorCode>(\d+)</errorCode>')
            .firstMatch(responseBody)?.group(1);
        throw HttpException(
          '设备返回 HTTP ${response.statusCode}${code == null ? '' : ' / UPnP $code'}',
        );
      }
    } finally {
      client.close(force: true);
    }
  }

  bool _isDangbei(DLNADevice device) {
    final name = device.info.friendlyName.toLowerCase();
    return name.contains('当贝') || name.contains('dangbei');
  }

  bool _isDangbeiProtocolError(Object error) {
    return RegExp(r'<errorCode>(501|704|714|716)</errorCode>')
        .hasMatch(error.toString());
  }

  Future<void> _setUrlWithoutMetadata(DLNADevice device) async {
    final xml = XmlText.setPlayURLXml(
      _url, title: _title ?? '', type: _videoMime,
    );
    final pattern = RegExp(
      r'<CurrentURIMetaData>.*?</CurrentURIMetaData>', dotAll: true,
    );
    if (!pattern.hasMatch(xml)) throw StateError('Missing DLNA metadata');
    final minimal = xml.replaceFirst(
      pattern, '<CurrentURIMetaData></CurrentURIMetaData>',
    );
    await device.request('SetAVTransportURI', utf8.encode(minimal));
  }

  Future<void> _castTo(String key, DLNADevice device) async {
    if (_castingKey != null) return;
    setState(() {
      _castingKey = key;
      _castStage = '正在发送视频地址…';
      _castError = null;
      _castErrorKey = null;
    });
    var stage = '发送视频地址';
    final dangbei = _isDangbei(device);
    final xiaomi = _isXiaomi(device);
    final modes = <int>[
      0,
      if (dangbei && _videoMime != VideoMime.any) 1,
      if (dangbei) 2,
    ];
    try {
      if (!xiaomi) {
        try {
          await device.stop().timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
      Object? lastError;
      for (final mode in modes) {
        if (!mounted) return;
        final modeName = switch (mode) {
          1 => '通用媒体声明',
          2 => '简化媒体元数据',
          _ => '标准模式',
        };
        try {
          stage = '发送视频地址（$modeName）';
          setState(() => _castStage = '正在发送视频地址（$modeName）…');
          if (mode == 2) {
            await _setUrlWithoutMetadata(device);
          } else {
            try {
              await device.setUrl(
                _url, title: _title ?? '',
                type: mode == 1 ? VideoMime.any : _videoMime,
              );
            } catch (error) {
              if (!xiaomi || !_isConnectionDropped(error)) rethrow;
              stage = '发送视频地址（小米备用连接）';
              if (mounted) {
                setState(() => _castStage = '小米电视断开连接，正在重试…');
              }
              await Future<void>.delayed(
                const Duration(milliseconds: 450),
              );
              await _setUrlXiaomiFresh(device);
            }
          }
          if (!mounted) return;
          stage = '请求电视播放（$modeName）';
          setState(() => _castStage = '正在请求电视播放（$modeName）…');
          await Future<void>.delayed(const Duration(milliseconds: 350));
          await device.play();
          if (!mounted) return;
          setState(() {
            _lastDeviceKey = key;
            _castStage = '已发送（$modeName）；无画面可再次点按重试';
          });
          return;
        } catch (error) {
          lastError = error;
          if (!dangbei || !_isDangbeiProtocolError(error)) break;
          await Future<void>.delayed(const Duration(milliseconds: 350));
        }
      }
      if (mounted && lastError != null) {
        setState(() {
          _castStage = null;
          _castError = _castFailure(lastError!, stage);
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
              maxLines: 4,
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
