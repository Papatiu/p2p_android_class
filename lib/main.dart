// lib/main.dart — Multipeer + Mesh entegrasyonu (izin + kalıcı deviceId + init + UI state)
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'multipeer_service.dart';
import 'mesh/mesh_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: HomePage(),
    );
  }
}

class Peer {
  final String id;
  final String name;
  Peer({required this.id, required this.name});
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const MethodChannel _methodChannel = MethodChannel('com.example.multipeer/methods');

  List<Peer> discoveredPeers = [];
  String? connectedPeerId;
  final TextEditingController _messageController = TextEditingController();

  StreamSubscription<Map<String, dynamic>>? _eventSub;
  StreamSubscription<Map<String, dynamic>>? _meshSub;

  late String _localId;
  late String _localName;

  bool _initializing = true;
  bool _isAdvertising = false;
  bool _isBrowsing = false;
  bool _buttonLocked = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }


  Future<void> _bootstrap() async {
    setState(() => _initializing = true);

    // 1. İzinleri kontrol et ve iste
    final permissionsGranted = await _requestAndValidatePermissions();
    if (!permissionsGranted) {
      // İzinler verilmediyse, hiçbir şey başlatma ve durumu kullanıcıya bildir.
      if (mounted) _showStatus('Gerekli izinler verilmedi. Uygulama çalışamaz.');
      setState(() => _initializing = false);
      return;
    }
    
    // İzinler tamsa, devam et
    _localId = await _getOrCreateDeviceId();
    _localName = 'Device-${_localId.substring(0, 6)}';

    try {
      await MeshService().init(deviceId: _localId, deviceName: _localName);
      _meshSub = MeshService().onMessage.listen((msg) {
        final payload = msg['payload'] as String? ?? '';
        if (mounted) {
          _showStatus('Mesh gelen: $payload');
        }
      });
    } catch (e) {
      debugPrint('Mesh init error: $e');
    }

    _startListening();
    setState(() => _initializing = false);
  }

   Future<bool> _requestAndValidatePermissions() async {
    final permissions = [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
    ];

    for (final permission in permissions) {
      final status = await permission.status;
      if (status.isDenied) {
        // İzin daha önce istenmemiş veya reddedilmiş, tekrar iste.
        final newStatus = await permission.request();
        if (!newStatus.isGranted) {
          // Kullanıcı yine reddetti.
          if(await permission.isPermanentlyDenied && mounted){
             // Kalıcı olarak reddetti, ayarlara yönlendir.
             await _showPermissionPermanentlyDeniedDialog();
          }
          return false;
        }
      } else if (status.isPermanentlyDenied) {
        // Kullanıcı kalıcı olarak reddetmiş, ayarlara yönlendirmeliyiz.
        if (mounted) await _showPermissionPermanentlyDeniedDialog();
        return false;
      }
    }
    
    // Buraya geldiyse tüm izinler verilmiştir.
    return true;
  }


Future<void> _showPermissionPermanentlyDeniedDialog() async {
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('İzin Gerekli'),
        content: const Text(
            'Yakındaki cihazları bulabilmek için Konum ve Bluetooth izinlerini vermeniz zorunludur. Ayarları açıp izinleri manuel olarak verebilirsiniz.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Vazgeç')),
          TextButton(
            onPressed: () {
              openAppSettings(); // permission_handler paketi bu fonksiyonu sağlar.
              Navigator.of(ctx).pop();
            },
            child: const Text('Ayarları Aç'),
          ),
        ],
      ),
    );
  }

  Future<bool> _requestRequiredPermissions() async {
    final permissions = <Permission>[
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.location,
    ];
    final statuses = await permissions.request();
    return statuses.values.every((status) => status.isGranted);
  }

  Future<String> _getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    const key = 'mesh_device_id';
    var id = prefs.getString(key);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString(key, id);
    }
    return id;
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _meshSub?.cancel();
    _messageController.dispose();
    MultipeerService.stop();
    MeshService().debugPrintState();
    super.dispose();
  }

  void _startListening() {
    _eventSub = MultipeerService.events.listen((evt) {
      debugPrint('Event: $evt');
      final type = evt['event'] as String? ?? '';
      
      switch (type) {
        case 'peerFound':
          final id = evt['peerId'] as String? ?? '';
          final name = evt['displayName'] as String? ?? id;
          if (!discoveredPeers.any((p) => p.id == id)) {
            setState(() => discoveredPeers.add(Peer(id: id, name: name)));
          }
          break;
        case 'peerLost':
          final id = evt['peerId'] as String? ?? '';
          setState(() => discoveredPeers.removeWhere((p) => p.id == id));
          break;
        case 'connectionState':
          final state = evt['state'] as String? ?? '';
          final id = evt['peerId'] as String?;
          if (state == 'connected' && id != null) {
            setState(() => connectedPeerId = id);
          } else if (state == 'notConnected' && id != null) {
            if (connectedPeerId == id) setState(() => connectedPeerId = null);
          }
          break;
        case 'dataReceived':
          final List<dynamic>? arr = evt['data'] as List<dynamic>?;
          if (arr != null) {
            final bytes = Uint8List.fromList(arr.cast<int>());
            final msg = String.fromCharCodes(bytes);
            if (mounted) _showStatus('Raw transport: $msg');
          }
          break;
        case 'advertisingStarted':
          setState(() => _isAdvertising = true);
          _showStatus('Advertise started');
          break;
        case 'browsingStarted':
          setState(() => _isBrowsing = true);
          _showStatus('Browsing started');
          break;
        case 'advertisingStopped':
          setState(() => _isAdvertising = false);
          break;
        case 'browsingStopped':
          setState(() => _isBrowsing = false);
          break;
        case 'invitationSent':
        case 'invitationReceived':
           _showStatus('$type: ${evt['displayName'] ?? evt['peerId']}');
          break;
        case 'error':
          final message = evt['message'] as String? ?? 'Unknown';
          if (message.contains('Already advertising')) {
            setState(() => _isAdvertising = true);
          } else if (message.contains('Already discovering')) {
            setState(() => _isBrowsing = true);
          }
          if(mounted) _showStatus('Hata: $message');
          break;
        default:
      }
    }, onError: (err) {
      debugPrint('Event stream error: $err');
    });
  }

  void _lockButtonTemporarily() {
    setState(() => _buttonLocked = true);
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) setState(() => _buttonLocked = false);
    });
  }

  Future<void> _startAdvertising() async {
    if (_isAdvertising || _buttonLocked) return;
    _lockButtonTemporarily();
    setState(() => _isAdvertising = true);
    try {
      await _methodChannel.invokeMethod('startAdvertising', {'displayName': _localName});
    } catch (e) {
      setState(() => _isAdvertising = false);
      _showStatus('Advertise error: $e');
    }
  }

  Future<void> _startBrowsing() async {
    if (_isBrowsing || _buttonLocked) return;
    _lockButtonTemporarily();
    setState(() => _isBrowsing = true);
    try {
      await _methodChannel.invokeMethod('startBrowsing');
    } catch (e) {
      setState(() => _isBrowsing = false);
      _showStatus('Browsing error: $e');
    }
  }
  
  Future<void> _startBoth() async {
    if ((_isAdvertising && _isBrowsing) || _buttonLocked) return;
    _lockButtonTemporarily();
    setState(() { _isAdvertising = true; _isBrowsing = true; });
    try {
      await _methodChannel.invokeMethod('startBoth', {'displayName': _localName});
    } catch (e) {
      setState(() { _isAdvertising = false; _isBrowsing = false; });
      _showStatus('Both start error: $e');
    }
  }

  void _invitePeer(Peer peer) {
    MultipeerService.invitePeer(peer.id)
        .then((_) => _showStatus('Davet gönderildi: ${peer.name}'))
        .catchError((e) => _showStatus('Davet gönderme hatası: $e'));
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return _showStatus('Mesaj boş.');
    try {
      await MeshService().createAndSendMessage(text, dst: 'BROADCAST');
      _messageController.clear();
      _showStatus('Mesh üzerinden gönderildi');
    } catch (e) {
      _showStatus('Gönderme hatası: $e');
    }
  }

  void _showStatus(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('P2P — Multipeer + Mesh')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: _initializing
            ? const Center(child: CircularProgressIndicator())
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // *** DÜZELTİLMİŞ KISIM BURASI ***
                // Row yerine Wrap kullanıldı.
                Wrap(
                  spacing: 8.0, // Butonlar arası yatay boşluk
                  runSpacing: 4.0, // Butonlar alt satıra geçerse aradaki dikey boşluk
                  alignment: WrapAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: _isAdvertising || _buttonLocked ? null : _startAdvertising,
                      child: const Text('Görünür Ol'),
                    ),
                    ElevatedButton(
                      onPressed: _isBrowsing || _buttonLocked ? null : _startBrowsing,
                      child: const Text('Cihaz Ara'),
                    ),
                    ElevatedButton(
                      onPressed: (_isAdvertising && _isBrowsing || _buttonLocked) ? null : _startBoth,
                      child: const Text('İkisini de Yap'),
                    ),
                  ],
                ),
                // *** DÜZELTİLMİŞ KISIM BİTTİ ***
                const SizedBox(height: 20),
                Text(
                  connectedPeerId != null ? 'BAĞLANDI: $connectedPeerId' : 'BAĞLANTI YOK',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: connectedPeerId != null ? Colors.green : Colors.red,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: const InputDecoration(labelText: 'Gönderilecek mesaj'),
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.send), onPressed: _sendMessage),
                ]),
                const Divider(height: 30),
                const Text('Bulunan Cihazlar', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                Expanded(
                  child: ListView.builder(
                    itemCount: discoveredPeers.length,
                    itemBuilder: (context, index) {
                      final peer = discoveredPeers[index];
                      return ListTile(
                        title: Text(peer.name),
                        subtitle: Text(peer.id),
                        trailing: connectedPeerId == null
                            ? ElevatedButton(onPressed: () => _invitePeer(peer), child: const Text('Bağlan'))
                            : null,
                      );
                    },
                  ),
                ),
              ]),
      ),
    );
  }
}
