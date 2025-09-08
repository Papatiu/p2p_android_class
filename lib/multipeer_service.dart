import 'dart:async';
import 'package:flutter/services.dart';

class MultipeerService {
  static const MethodChannel _method = MethodChannel('com.example.multipeer/methods');
  static const EventChannel _events = EventChannel('com.example.multipeer/events');

  static Stream<Map<String, dynamic>>? _eventStream;

  /// Event stream: maps with keys: event, peerId, displayName, data (base64 or bytes)
  static Stream<Map<String, dynamic>> get events {
    _eventStream ??= _events.receiveBroadcastStream().map((event) {
      return Map<String, dynamic>.from(event as Map);
    });
    return _eventStream!;
  }

  static Future<void> startAdvertising({String? displayName, String serviceType = 'mpconn'}) async {
    await _method.invokeMethod('startAdvertising', {'displayName': displayName, 'serviceType': serviceType});
  }

  static Future<void> startBrowsing({String? displayName, String serviceType = 'mpconn'}) async {
    await _method.invokeMethod('startBrowsing', {'displayName': displayName, 'serviceType': serviceType});
  }

  static Future<void> stop() async {
    await _method.invokeMethod('stop');
  }

  static Future<void> invitePeer(String peerId) async {
  await _method.invokeMethod('invitePeer', {'peerId': peerId});
}
  /// send bytes to all connected peers
  static Future<void> sendData(Uint8List bytes) async {
    await _method.invokeMethod('sendData', {'data': bytes});
  }
}
