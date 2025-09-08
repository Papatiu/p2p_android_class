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

    // discovered endpoints: endpointId -> endpointName
    private val discoveredEndpoints = mutableMapOf<String, String>()
    // connected endpoints
    private val connectedEndpoints = mutableSetOf<String>()

    // flags to avoid double start
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
                            startAdvertisingWithRetry(name)
                            result.success(null)
                        }
                        "startBrowsing" -> {
                            // start discovery (safe method)
                            startDiscoveryWithRetry()
                            result.success(null)
                        }
                        "startBoth" -> {
                            val args = call.arguments as? Map<String, Any?>
                            val name = args?.get("displayName") as? String ?: android.os.Build.MODEL
                            startBothWithSafety(name)
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

    private fun toByteArray(obj: Any?): ByteArray? {
        if (obj == null) return null
        // If it comes as ByteArray
        if (obj is ByteArray) return obj
        // If it comes as List<Int>
        if (obj is ArrayList<*>) {
            try {
                val list = obj as ArrayList<*>
                val b = ByteArray(list.size)
                for (i in list.indices) {
                    val v = list[i] as Number
                    b[i] = v.toByte()
                }
                return b
            } catch (e: Exception) {
                return null
            }
        }
        return null
    }

    // ---------- Nearby Callbacks ----------

    private val endpointDiscoveryCallback = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) {
            Log.d(TAG, "onEndpointFound: id=$endpointId name=${info.endpointName} serviceId=${info.serviceId}")
            discoveredEndpoints[endpointId] = info.endpointName
            sendEvent(mapOf("event" to "peerFound", "peerId" to endpointId, "displayName" to info.endpointName))
        }

        override fun onEndpointLost(endpointId: String) {
            val name = discoveredEndpoints[endpointId]
            discoveredEndpoints.remove(endpointId)
            sendEvent(mapOf("event" to "peerLost", "peerId" to endpointId, "displayName" to name))
        }
    }

    private val connectionLifecycleCallback = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(endpointId: String, info: ConnectionInfo) {
            // Auto-accept connection
            try {
                connectionsClient.acceptConnection(endpointId, payloadCallback)
                sendEvent(mapOf("event" to "invitationReceived", "peerId" to endpointId, "displayName" to info.endpointName))
            } catch (e: Exception) {
                sendEvent(mapOf("event" to "error", "message" to "acceptConnection failed: ${e.message}"))
            }
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
                    // convert to list of ints so Flutter side receives consistent type
                    val intList = bytes.map { it.toInt() and 0xFF }
                    sendEvent(mapOf("event" to "dataReceived", "peerId" to endpointId, "data" to intList))
                }
            }
        }

        override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) {
            // optionally handle progress
        }
    }

    // ---------- Robust start/stop helpers (retry + logging) ----------

    // safe start discovery with retry and detailed ApiException logging
    private fun startDiscoveryWithRetry(attempt: Int = 0) {
        if (isDiscovering) {
            sendEvent(mapOf("event" to "error", "message" to "Already discovering"))
            return
        }

        // Ensure advertising is stopped to reduce conflicts (optional)
        if (isAdvertising) {
            try {
                connectionsClient.stopAdvertising()
            } catch (e: Exception) { Log.w(TAG, "stopAdvertising pre-discovery failed: ${e.message}") }
            isAdvertising = false
            sendEvent(mapOf("event" to "advertisingStopped"))
        }

        // small delay to let previous state settle
        Handler(Looper.getMainLooper()).postDelayed({
            val discoveryOptions = DiscoveryOptions.Builder().setStrategy(Strategy.P2P_STAR).build()
            Log.d(TAG, "Attempting startDiscovery attempt=${attempt+1}")
            connectionsClient.startDiscovery(packageName, endpointDiscoveryCallback, discoveryOptions)
                .addOnSuccessListener {
                    isDiscovering = true
                    Log.d(TAG, "startDiscovery success")
                    sendEvent(mapOf("event" to "browsingStarted"))
                }
                .addOnFailureListener { e ->
                    isDiscovering = false
                    val code = if (e is ApiException) e.statusCode else -1
                    Log.w(TAG, "startDiscovery failed (attempt=${attempt+1}) code=$code msg=${e?.message}", e)
                    // try small number of retries with backoff
                    if (attempt < 2) {
                        val backoff = 300L * (attempt + 1)
                        Handler(Looper.getMainLooper()).postDelayed({
                            startDiscoveryWithRetry(attempt + 1)
                        }, backoff)
                    } else {
                        sendEvent(mapOf("event" to "error", "message" to "startDiscovery failed: $code: ${e?.message}"))
                    }
                }
        }, 250) // 250ms settle delay
    }

    // safe start advertising with retry and logging
    private fun startAdvertisingWithRetry(name: String, attempt: Int = 0) {
        if (isAdvertising) {
            sendEvent(mapOf("event" to "error", "message" to "Already advertising"))
            return
        }

        // ensure discovery stopped (optional)
        if (isDiscovering) {
            try {
                connectionsClient.stopDiscovery()
            } catch (e: Exception) { Log.w(TAG, "stopDiscovery pre-advertise failed: ${e.message}") }
            isDiscovering = false
            sendEvent(mapOf("event" to "browsingStopped"))
        }

        Handler(Looper.getMainLooper()).postDelayed({
            val advertisingOptions = AdvertisingOptions.Builder().setStrategy(Strategy.P2P_STAR).build()
            Log.d(TAG, "Attempting startAdvertising attempt=${attempt+1}")
            connectionsClient.startAdvertising(name, packageName, connectionLifecycleCallback, advertisingOptions)
                .addOnSuccessListener {
                    isAdvertising = true
                    Log.d(TAG, "startAdvertising success")
                    sendEvent(mapOf("event" to "advertisingStarted"))
                }
                .addOnFailureListener { e ->
                    isAdvertising = false
                    val code = if (e is ApiException) e.statusCode else -1
                    Log.w(TAG, "startAdvertising failed (attempt=${attempt+1}) code=$code msg=${e?.message}", e)
                    if (attempt < 2) {
                        val backoff = 300L * (attempt + 1)
                        Handler(Looper.getMainLooper()).postDelayed({
                            startAdvertisingWithRetry(name, attempt + 1)
                        }, backoff)
                    } else {
                        sendEvent(mapOf("event" to "error", "message" to "startAdvertising failed: $code: ${e?.message}"))
                    }
                }
        }, 250)
    }

    // convenience method to start both, with small delay between them
    private fun startBothWithSafety(name: String) {
        if (!isAdvertising) startAdvertisingWithRetry(name)
        Handler(Looper.getMainLooper()).postDelayed({
            if (!isDiscovering) startDiscoveryWithRetry()
        }, 350)
    }

    // ---------- (legacy) operations kept for compatibility ----------

    private fun startAdvertising(name: String) {
        if (isAdvertising) {
            sendEvent(mapOf("event" to "error", "message" to "Already advertising"))
            return
        }
        // Optionally stop discovery to avoid conflicts
        if (isDiscovering) {
            try {
                connectionsClient.stopDiscovery()
            } catch (e: Exception) {
                Log.w(TAG, "stopDiscovery failed during advertising start: ${e.message}")
            }
            isDiscovering = false
            sendEvent(mapOf("event" to "browsingStopped"))
        }

        val advertisingOptions = AdvertisingOptions.Builder().setStrategy(Strategy.P2P_STAR).build()
        connectionsClient.startAdvertising(
            name,
            packageName,
            connectionLifecycleCallback,
            advertisingOptions
        ).addOnSuccessListener {
            isAdvertising = true
            sendEvent(mapOf("event" to "advertisingStarted"))
        }.addOnFailureListener { e ->
            isAdvertising = false
            sendEvent(mapOf("event" to "error", "message" to "startAdvertising failed: ${e.message}"))
        }
    }

    private fun startDiscovery() {
        if (isDiscovering) {
            sendEvent(mapOf("event" to "error", "message" to "Already discovering"))
            return
        }
        // Optionally stop advertising to avoid conflicts
        if (isAdvertising) {
            try {
                connectionsClient.stopAdvertising()
            } catch (e: Exception) {
                Log.w(TAG, "stopAdvertising failed during discovery start: ${e.message}")
            }
            isAdvertising = false
            sendEvent(mapOf("event" to "advertisingStopped"))
        }

        val discoveryOptions = DiscoveryOptions.Builder().setStrategy(Strategy.P2P_STAR).build()
        connectionsClient.startDiscovery(
            packageName,
            endpointDiscoveryCallback,
            discoveryOptions
        ).addOnSuccessListener {
            isDiscovering = true
            sendEvent(mapOf("event" to "browsingStarted"))
        }.addOnFailureListener { e ->
            isDiscovering = false
            sendEvent(mapOf("event" to "error", "message" to "startDiscovery failed: ${e.message}"))
        }
    }

    private fun stopAll() {
        try {
            connectionsClient.stopAllEndpoints()
            connectionsClient.stopAdvertising()
            connectionsClient.stopDiscovery()
            isAdvertising = false
            isDiscovering = false
            sendEvent(mapOf("event" to "stopped"))
        } catch (e: Exception) {
            sendEvent(mapOf("event" to "error", "message" to "stopAll failed: ${e.message}"))
        }
    }

    private fun sendDataToAll(bytes: ByteArray) {
        val payload = Payload.fromBytes(bytes)
        // send to connected endpoints only
        if (connectedEndpoints.isEmpty()) {
            sendEvent(mapOf("event" to "error", "message" to "No connected peers"))
            return
        }
        for (endpoint in connectedEndpoints) {
            try {
                connectionsClient.sendPayload(endpoint, payload)
            } catch (e: Exception) {
                sendEvent(mapOf("event" to "error", "message" to "sendPayload failed: ${e.message}"))
            }
        }
    }

    private fun requestConnectionToPeer(peerId: String) {
        // get displayName if known
        val name = discoveredEndpoints[peerId] ?: "FlutterDevice"
        connectionsClient.requestConnection(
            name,
            peerId,
            connectionLifecycleCallback
        ).addOnSuccessListener {
            sendEvent(mapOf("event" to "invitationSent", "peerId" to peerId))
        }.addOnFailureListener { e ->
            sendEvent(mapOf("event" to "error", "message" to "requestConnection failed: ${e.message}"))
        }
    }

    private fun sendEvent(map: Map<String, Any?>) {
        try {
            eventSink?.success(map)
        } catch (e: Exception) {
            Log.w(TAG, "Event send failed: ${e.message}")
        }
    }
}
