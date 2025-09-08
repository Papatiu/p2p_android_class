// lib/mesh/message_model.dart
class MeshMessage {
  final String msgId;
  final String origin;
  final String originName;
  final String dst; // 'BROADCAST' or device id
  int ttl;
  final int priority;
  final int timestamp;
  final String payload; // base64 or plain text (for MVP plain text)

  MeshMessage({
    required this.msgId,
    required this.origin,
    required this.originName,
    required this.dst,
    required this.ttl,
    required this.priority,
    required this.timestamp,
    required this.payload,
  });

  Map<String, dynamic> toJson() => {
        'msg_id': msgId,
        'origin': origin,
        'origin_name': originName,
        'dst': dst,
        'ttl': ttl,
        'priority': priority,
        'timestamp': timestamp,
        'payload': payload,
      };

  static MeshMessage fromJson(Map<String, dynamic> j) => MeshMessage(
        msgId: j['msg_id'] as String,
        origin: j['origin'] as String,
        originName: j['origin_name'] as String? ?? j['origin'],
        dst: j['dst'] as String,
        ttl: j['ttl'] as int,
        priority: j['priority'] as int,
        timestamp: j['timestamp'] as int,
        payload: j['payload'] as String,
      );
}
