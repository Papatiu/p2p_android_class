package com.example.p2p_data_transfer

import android.os.Handler
import android.os.Looper
import com.google.android.gms.common.api.ApiException
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.*
import com.google.android.gms.nearby.connection.Strategy
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.PayloadTransferUpdate

class MainActivity : FlutterActivity() {
    private val TAG = "MainActivityNearby"
    private val METHOD_CHANNEL = "com.example.multipeer/methods"
    private val EVENT_CHANNEL = "com.example.multipeer/events"

    private var eventSink: EventChannel.EventSink? = null
    private lateinit var connectionsClient: ConnectionsClient

    private val discoveredEndpoints = mutableMapOf<String, String>()
    private val connectedEndpoints = mutableSetOf<String>()

    private var isAdvertising = false
    private var isDiscovering = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        connectionsClient = Nearby.getConnectionsClient(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "startAdvertising" -> {
                            val args = call.arguments as? Map<String, Any?>
                            val name = args?.get("displayName") as? String ?: android.os.Build.MODEL
                            startAdvertising(name)
                            result.success(null)
                        }
                        "startBrowsing" -> {
                            startDiscovery()
                            result.success(null)
                        }
                        "startBoth" -> {
                            val args = call.arguments as? Map<String, Any?>
                            val name = args?.get("displayName") as? String ?: android.os.Build.MODEL
                            startBothWithDelay(name)
                            result.success(null)
                        }
                        "stop" -> {
                            stopAll()
                            result.success(null)
                        }
                        "sendData" -> {
                            val args = call.arguments as? Map<String, Any?>
                            val dataObj = args?.get("data")
                            val bytes = toByteArray(dataObj)
                            if (bytes != null) {
                                sendDataToAll(bytes)
                                result.success(null)
                            } else {
                                result.error("INVALID", "No data or invalid data", null)
                            }
                        }
                        "invitePeer" -> {
                            val args = call.arguments as? Map<String, Any?>
                            val peerId = args?.get("peerId") as? String
                            if (peerId != null) {
                                requestConnectionToPeer(peerId)
                                result.success(null)
                            } else {
                                result.error("INVALID", "peerId required", null)
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Method handler error", e)
                    result.error("EXCEPTION", e.message, null)
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }
    
    // ----------- YARDIMCI FONKSİYONLAR VE CALLBACK'LER -----------
    // Önceki denemede buradaki fonksiyonlar dışarıda kalmıştı, şimdi hepsi class içinde.

    private fun toByteArray(obj: Any?): ByteArray? {
        if (obj == null) return null
        if (obj is ByteArray) return obj
        if (obj is ArrayList<*>) {
            try {
                val list = obj as ArrayList<*>
                val b = ByteArray(list.size)
                for (i in list.indices) {
                    b[i] = (list[i] as Number).toByte()
                }
                return b
            } catch (e: Exception) {
                return null
            }
        }
        return null
    }

    private val endpointDiscoveryCallback = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) {
            Log.d(TAG, "onEndpointFound: id=$endpointId name=${info.endpointName}")
            discoveredEndpoints[endpointId] = info.endpointName
            sendEvent(mapOf("event" to "peerFound", "peerId" to endpointId, "displayName" to info.endpointName))
        }

        override fun onEndpointLost(endpointId: String) {
            val name = discoveredEndpoints.remove(endpointId)
            sendEvent(mapOf("event" to "peerLost", "peerId" to endpointId, "displayName" to name))
        }
    }

    private val connectionLifecycleCallback = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(endpointId: String, info: ConnectionInfo) {
            connectionsClient.acceptConnection(endpointId, payloadCallback)
            sendEvent(mapOf("event" to "invitationReceived", "peerId" to endpointId, "displayName" to info.endpointName))
        }

        override fun onConnectionResult(endpointId: String, resolution: ConnectionResolution) {
            if (resolution.status.isSuccess) {
                connectedEndpoints.add(endpointId)
                sendEvent(mapOf("event" to "connectionState", "peerId" to endpointId, "state" to "connected"))
            } else {
                connectedEndpoints.remove(endpointId)
                sendEvent(mapOf("event" to "connectionState", "peerId" to endpointId, "state" to "notConnected"))
            }
        }

        override fun onDisconnected(endpointId: String) {
            connectedEndpoints.remove(endpointId)
            sendEvent(mapOf("event" to "connectionState", "peerId" to endpointId, "state" to "notConnected"))
        }
    }

    private val payloadCallback = object : PayloadCallback() {
        override fun onPayloadReceived(endpointId: String, payload: Payload) {
            if (payload.type == Payload.Type.BYTES) {
                val bytes = payload.asBytes()
                if (bytes != null) {
                    val intList = bytes.map { it.toInt() and 0xFF }
                    sendEvent(mapOf("event" to "dataReceived", "peerId" to endpointId, "data" to intList))
                }
            }
        }
        override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) {}
    }

    private fun startAdvertising(name: String) {
        if (isAdvertising) {
            sendEvent(mapOf("event" to "error", "message" to "Already advertising"))
            return
        }
        val advertisingOptions = AdvertisingOptions.Builder().setStrategy(Strategy.P2P_STAR).build()
        connectionsClient.startAdvertising(name, packageName, connectionLifecycleCallback, advertisingOptions)
            .addOnSuccessListener {
                isAdvertising = true
                Log.d(TAG, "startAdvertising success")
                sendEvent(mapOf("event" to "advertisingStarted"))
            }
            .addOnFailureListener { e ->
                isAdvertising = false
                val code = if (e is ApiException) e.statusCode else -1
                Log.e(TAG, "startAdvertising failed with code $code", e)
                sendEvent(mapOf("event" to "error", "message" to "startAdvertising failed: ${e.message}"))
            }
    }

    private fun startDiscovery() {
        if (isDiscovering) {
            sendEvent(mapOf("event" to "error", "message" to "Already discovering"))
            return
        }
        val discoveryOptions = DiscoveryOptions.Builder().setStrategy(Strategy.P2P_STAR).build()
        connectionsClient.startDiscovery(packageName, endpointDiscoveryCallback, discoveryOptions)
            .addOnSuccessListener {
                isDiscovering = true
                Log.d(TAG, "startDiscovery success")
                sendEvent(mapOf("event" to "browsingStarted"))
            }
            .addOnFailureListener { e ->
                isDiscovering = false
                val code = if (e is ApiException) e.statusCode else -1
                Log.e(TAG, "startDiscovery failed with code $code", e)
                sendEvent(mapOf("event" to "error", "message" to "startDiscovery failed: ${e.message}"))
            }
    }

    private fun startBothWithDelay(name: String) {
        startAdvertising(name)
        Handler(Looper.getMainLooper()).postDelayed({
            startDiscovery()
        }, 500)
    }

    private fun stopAll() {
        try {
            connectionsClient.stopAllEndpoints()
            if (isAdvertising) connectionsClient.stopAdvertising()
            if (isDiscovering) connectionsClient.stopDiscovery()
            
            isAdvertising = false
            isDiscovering = false
            connectedEndpoints.clear()
            discoveredEndpoints.clear()

            Log.d(TAG, "stopAll completed")
            sendEvent(mapOf("event" to "stopped"))
        } catch (e: Exception) {
            Log.e(TAG, "stopAll failed", e)
            sendEvent(mapOf("event" to "error", "message" to "stopAll failed: ${e.message}"))
        }
    }

    private fun sendDataToAll(bytes: ByteArray) {
        if (connectedEndpoints.isEmpty()) {
            sendEvent(mapOf("event" to "error", "message" to "No connected peers"))
            return
        }
        val payload = Payload.fromBytes(bytes)
        connectionsClient.sendPayload(connectedEndpoints.toList(), payload)
    }

    private fun requestConnectionToPeer(peerId: String) {
        val name = discoveredEndpoints[peerId] ?: "FlutterDevice"
        connectionsClient.requestConnection(name, peerId, connectionLifecycleCallback)
            .addOnSuccessListener {
                sendEvent(mapOf("event" to "invitationSent", "peerId" to peerId))
            }.addOnFailureListener { e ->
                sendEvent(mapOf("event" to "error", "message" to "requestConnection failed: ${e.message}"))
            }
    }

    private fun sendEvent(map: Map<String, Any?>) {
        Handler(Looper.getMainLooper()).post {
            try {
                eventSink?.success(map)
            } catch (e: Exception) {
                Log.w(TAG, "Event send failed", e)
            }
        }
    }
}
