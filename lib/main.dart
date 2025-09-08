// lib/main.dart — Multipeer + Mesh entegrasyonu (izin + kalıcı deviceId + init)
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'multipeer_service.dart';
import 'mesh/mesh_service.dart'; // yolun doğruysa bırak, değilse 'mesh/mesh_service.dart'
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
  List<Peer> discoveredPeers = [];
  String? connectedPeerId;
  final TextEditingController _messageController = TextEditingController();

  StreamSubscription<Map<String, dynamic>>? _eventSub;
  StreamSubscription<Map<String, dynamic>>? _meshSub;

  // local identity used for MeshService (persistent)
  late String _localId;
  late String _localName;

  bool _initializing = true;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // 1) request runtime permissions
    final ok = await _requestRequiredPermissions();
    if (!ok) {
      // kullanıcı izin vermediyse, uyar ve Settings'e yönlendir
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('İzin gerekli'),
          content: const Text(
              'Uygulamanın yakın cihaz keşfi yapabilmesi için Bluetooth ve konum izinlerine ihtiyaç var. Lütfen izin verin.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Tamam'),
            ),
            TextButton(
              onPressed: () {
                openAppSettings();
                Navigator.of(ctx).pop();
              },
              child: const Text('Ayarlar'),
            ),
          ],
        ),
      );
      // izin yoksa devam etmiyoruz
      setState(() => _initializing = false);
      return;
    }

    // 2) get or create persistent device id
    _localId = await _getOrCreateDeviceId();
    _localName = 'Device-${_localId.substring(0, 6)}';

    // 3) init MeshService (it will subscribe to Multipeer transport events internally)
    try {
      await MeshService().init(deviceId: _localId, deviceName: _localName);
      _meshSub = MeshService().onMessage.listen((msg) {
        final payload = msg['payload'] as String? ?? '';
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Mesh gelen: $payload')));
      });
    } catch (e) {
      debugPrint('Mesh init error: $e');
    }

    // 4) start listening transport events
    _startListening();

    setState(() => _initializing = false);
  }

  Future<bool> _requestRequiredPermissions() async {
    // Compose list depending on platform; permission_handler maps to Android fine
    final permissions = <Permission>[
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.location, // ACCESS_FINE_LOCATION needed for Wi-Fi/Bluetooth discovery on many devices
    ];

    final statuses = await permissions.request();

    // On Android 12+, some permissions might be unavailable on older devices; treat them as granted if not applicable
    bool allGranted = true;
    for (final perm in permissions) {
      final status = statuses[perm];
      if (status == null) continue; // not supported on platform/version
      if (!status.isGranted) {
        allGranted = false;
        break;
      }
    }
    return allGranted;
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
    // Listen native transport events (peerFound, peerLost, connectionState, dataReceived, error)
    _eventSub = MultipeerService.events.listen((evt) {
      final type = evt['event'] as String? ?? '';

      if (type == 'peerFound') {
        final id = evt['peerId'] as String? ?? '';
        final name = evt['displayName'] as String? ?? id;
        if (!discoveredPeers.any((p) => p.id == id)) {
          setState(() => discoveredPeers.add(Peer(id: id, name: name)));
        }
      } else if (type == 'peerLost') {
        final id = evt['peerId'] as String? ?? '';
        setState(() => discoveredPeers.removeWhere((p) => p.id == id));
      } else if (type == 'connectionState') {
        final state = evt['state'] as String? ?? '';
        final id = evt['peerId'] as String?;
        if (state == 'connected' && id != null) {
          setState(() => connectedPeerId = id);
        } else if (state == 'notConnected' && id != null) {
          if (connectedPeerId == id) setState(() => connectedPeerId = null);
        }
      } else if (type == 'dataReceived') {
        // Debug/legacy raw transport messages (MeshService already handles forwarding)
        final List<dynamic>? arr = evt['data'] as List<dynamic>?;
        if (arr != null) {
          final bytes = Uint8List.fromList(arr.cast<int>());
          final msg = String.fromCharCodes(bytes);
          if (!mounted) return;
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Raw transport: $msg')));
        }
      } else if (type == 'error') {
        final message = evt['message'] as String? ?? 'Unknown';
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Hata: $message')));
      }
    }, onError: (err) {
      debugPrint('Event stream error: $err');
    });
  }

  Future<void> _startAdvertising() async {
    try {
      await MultipeerService.startAdvertising(displayName: _localName, serviceType: 'mpconn');
      _showStatus('Advertise started');
    } catch (e) {
      _showStatus('Advertise error: $e');
    }
  }

  Future<void> _startBrowsing() async {
    try {
      await MultipeerService.startBrowsing(displayName: _localName, serviceType: 'mpconn');
      _showStatus('Browsing started');
    } catch (e) {
      _showStatus('Browsing error: $e');
    }
  }

  void _invitePeer(Peer peer) {
    // Gönder: native taraf browser.invitePeer tetikler
    MultipeerService.invitePeer(peer.id).then((_) {
      _showStatus('Davet gönderildi: ${peer.name}');
    }).catchError((e) {
      _showStatus('Davet gönderme hatası: $e');
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return _showStatus('Mesaj boş.');
    try {
      // Use MeshService to create message with TTL/priority and let overlay forward
      await MeshService().createAndSendMessage(
        text,
        dst: 'BROADCAST',
        ttl: 5,
        priority: 5,
      );
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
                Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  ElevatedButton(onPressed: _startAdvertising, child: const Text('Görünür Ol (Host)')),
                  ElevatedButton(onPressed: _startBrowsing, child: const Text('Cihaz Ara (Guest)')),
                ]),
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
