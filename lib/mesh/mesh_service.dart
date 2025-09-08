// lib/mesh/mesh_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/material.dart';
import '../multipeer_service.dart'; // bizim earlier MethodChannel wrapper (MultipeerService)

class MeshService {
  static final MeshService _instance = MeshService._internal();
  factory MeshService() => _instance;
  MeshService._internal();

  static const String _boxName = 'mesh_messages';
  static const String _metaBox = 'mesh_meta';

  final Uuid _uuid = const Uuid();
  final Set<String> _seen = <String>{};
  final Map<String, DateTime> _seenTimestamps = {};
  final StreamController<Map<String, dynamic>> _incomingController = StreamController.broadcast();
  Stream<Map<String, dynamic>> get onMessage => _incomingController.stream;

  Box<String>? _box;
  Box<dynamic>? _meta;

  String? _localId;
  String? _localName;

  bool _inited = false;

  // neighbor bookkeeping (optional)
  final Set<String> neighbors = <String>{};

  Future<void> init({required String deviceId, required String deviceName}) async {
    if (_inited) return;
    await Hive.initFlutter();
    _box = await Hive.openBox<String>(_boxName);
    _meta = await Hive.openBox(_metaBox);

    _localId = deviceId;
    _localName = deviceName;
    _inited = true;

    // subscribe to underlying transport events
    MultipeerService.events.listen(_handleTransportEvent);

    // periodic cleanup for seen cache
    Timer.periodic(const Duration(minutes: 30), (_) => _cleanupSeen());
  }

  void _cleanupSeen() {
    final now = DateTime.now();
    final keys = _seenTimestamps.keys.toList();
    for (final k in keys) {
      if (now.difference(_seenTimestamps[k]!).inHours > 24) {
        _seenTimestamps.remove(k);
        _seen.remove(k);
      }
    }
    // optionally prune _box older messages if needed
  }

  // Create and send a new message (originated locally)
  Future<void> createAndSendMessage(String payload,
      {String dst = 'BROADCAST', int ttl = 5, int priority = 5}) async {
    if (!_inited) throw Exception('MeshService not init');
    final msgId = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    final msg = {
      'msg_id': msgId,
      'origin': _localId!,
      'origin_name': _localName,
      'dst': dst,
      'ttl': ttl,
      'priority': priority,
      'timestamp': now,
      'payload': payload,
    };
    // store and treat as incoming (so dedup works)
    await _storeMessage(msg);
    await _forwardMessage(msg, fromPeer: null);
  }

  Future<void> _storeMessage(Map<String, dynamic> msg) async {
    final id = msg['msg_id'] as String;
    _box ??= await Hive.openBox<String>(_boxName);
    await _box!.put(id, jsonEncode(msg));
    _seen.add(id);
    _seenTimestamps[id] = DateTime.now();
  }

  Future<void> _handleTransportEvent(Map<String, dynamic> evt) async {
    final type = evt['event'] as String? ?? '';
    if (type == 'peerFound') {
      final id = evt['peerId'] as String? ?? '';
      neighbors.add(id);
    } else if (type == 'peerLost') {
      final id = evt['peerId'] as String? ?? '';
      neighbors.remove(id);
    } else if (type == 'dataReceived') {
      // evt['data'] is List<int> (we converted earlier in Swift)
      final List<dynamic>? arr = evt['data'] as List<dynamic>?;
      if (arr == null) return;
      final bytes = Uint8List.fromList(arr.cast<int>());
      final jsonStr = String.fromCharCodes(bytes);
      Map<String, dynamic> msg;
      try {
        msg = jsonDecode(jsonStr) as Map<String, dynamic>;
      } catch (e) {
        debugPrint('MeshService: invalid message format: $e');
        return;
      }
      final fromPeer = evt['peerId'] as String?;
      await _processIncoming(msg, fromPeer);
    }
  }

  Future<void> _processIncoming(Map<String, dynamic> msg, String? fromPeer) async {
    final id = msg['msg_id'] as String?;
    if (id == null) return;
    if (_seen.contains(id)) return; // dedup
    // mark seen & store
    await _storeMessage(msg);

    // deliver to app if destination matches
    final dst = msg['dst'] as String? ?? 'BROADCAST';
    if (dst == 'BROADCAST' || dst == _localId) {
      // deliver to app-level stream
      _incomingController.add(msg);
    }

    // forward if ttl > 0
    var ttl = (msg['ttl'] as int?) ?? 0;
    ttl = ttl - 1;
    msg['ttl'] = ttl;
    if (ttl > 0) {
      // jitter to avoid storms
      final jitterMs = Random().nextInt(200) + 50;
      Future.delayed(Duration(milliseconds: jitterMs), () async {
        await _forwardMessage(msg, fromPeer: fromPeer);
      });
    }
  }

  Future<void> _forwardMessage(Map<String, dynamic> msg, {String? fromPeer}) async {
    // encode
    final encoded = jsonEncode(msg);
    final bytes = Uint8List.fromList(encoded.codeUnits);

    // get current neighbor snapshot
    final neighborsSnapshot = neighbors.toList();
    for (final peer in neighborsSnapshot) {
      if (fromPeer != null && peer == fromPeer) continue; // don't send back to origin link
      try {
        // MultipeerService.sendData sends to connected peers; our wrapper implementation
        // may not let us direct to a specific peer by id — if it supports sendData(peerId, bytes) use that.
        // For generality we call sendData which sends to connected peer(s). If you have
        // sendData(peerId, ...) API adapt accordingly.
        await MultipeerService.sendData(bytes);
      } catch (e) {
        debugPrint('MeshService forward error to $peer: $e');
      }
    }
  }

  // Simple helper: get stored messages
  List<Map<String, dynamic>> getStoredMessages() {
    if (_box == null) return [];
    return _box!.values.map((s) {
      try {
        return jsonDecode(s) as Map<String, dynamic>;
      } catch (e) {
        return <String, dynamic>{};
      }
    }).toList();
  }

  // for debugging
  void debugPrintState() {
    debugPrint('MeshService localId=$_localId neighbors=${neighbors.length} seen=${_seen.length}');
  }
}
