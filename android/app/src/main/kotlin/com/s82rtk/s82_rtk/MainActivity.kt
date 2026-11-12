package com.s82rtk.s82_rtk

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.util.UUID

/**
 * S82'ye klasik Bluetooth (SPP) bağlantısı — Flutter'a platform kanalıyla açılır.
 *   MethodChannel "s82/spp": bonded, connect(address), disconnect, write(bytes)
 *   EventChannel  "s82/spp/events": {t:"data", b:ByteArray} | {t:"state", ok:Bool, msg:String}
 */
class MainActivity : FlutterActivity() {
    private val spp = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    @Volatile private var socket: BluetoothSocket? = null
    @Volatile private var out: OutputStream? = null

    private fun emit(m: Map<String, Any>) = main.post { sink?.success(m) }
    private fun state(ok: Boolean, msg: String) = emit(mapOf("t" to "state", "ok" to ok, "msg" to msg))

    private fun hasPerm() = Build.VERSION.SDK_INT < 31 ||
            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        EventChannel(engine.dartExecutor.binaryMessenger, "s82/spp/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(a: Any?, s: EventChannel.EventSink) { sink = s }
                override fun onCancel(a: Any?) { sink = null }
            })
        MethodChannel(engine.dartExecutor.binaryMessenger, "s82/spp").setMethodCallHandler { call, res ->
            when (call.method) {
                "bonded" -> {
                    if (!hasPerm()) {
                        requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), 7)
                        res.error("perm", "Bluetooth izni gerekli, izin verip tekrar deneyin", null); return@setMethodCallHandler
                    }
                    try {
                        val ad = (getSystemService(BLUETOOTH_SERVICE) as BluetoothManager).adapter
                        if (ad == null || !ad.isEnabled) { res.error("off", "Bluetooth kapalı", null); return@setMethodCallHandler }
                        @SuppressLint("MissingPermission")
                        val l = ad.bondedDevices.map { mapOf("name" to (it.name ?: it.address), "address" to it.address) }
                        res.success(l)
                    } catch (e: Exception) { res.error("err", e.message, null) }
                }
                "connect" -> { connect(call.argument<String>("address")!!); res.success(null) }
                "disconnect" -> { close(); state(false, "Bağlı değil"); res.success(null) }
                "write" -> {
                    val b = call.arguments as ByteArray
                    try { out?.write(b); res.success(true) } catch (e: Exception) { res.success(false) }
                }
                else -> res.notImplemented()
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun connect(address: String) {
        close()
        Thread {
            try {
                val ad = (getSystemService(BLUETOOTH_SERVICE) as BluetoothManager).adapter
                val dev = ad.getRemoteDevice(address)
                val name = dev.name ?: address
                state(false, "Bağlanıyor: $name")
                ad.cancelDiscovery()
                var s: BluetoothSocket = dev.createRfcommSocketToServiceRecord(spp)
                try { s.connect() } catch (e: Exception) {
                    try { s.close() } catch (_: Exception) {}
                    // Eski cihazlarda SDP çalışmayabilir: doğrudan kanal 1
                    val m = dev.javaClass.getMethod("createRfcommSocket", Int::class.javaPrimitiveType)
                    s = m.invoke(dev, 1) as BluetoothSocket
                    s.connect()
                }
                socket = s; out = s.outputStream
                state(true, "Bağlı: $name")
                val inp = s.inputStream
                val buf = ByteArray(2048)
                while (true) {
                    val n = inp.read(buf)
                    if (n < 0) break
                    if (n > 0) emit(mapOf("t" to "data", "b" to buf.copyOf(n)))
                }
                state(false, "Bağlantı koptu")
            } catch (e: Exception) {
                state(false, "Hata: ${e.message}")
            } finally { close() }
        }.start()
    }

    private fun close() {
        try { socket?.close() } catch (_: Exception) {}
        socket = null; out = null
    }
}
