package com.s82rtk

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.util.Base64
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.UUID

/** S82 ile klasik Bluetooth (SPP) bağlantısı */
object Bt {
    private val SPP = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    @Volatile var socket: BluetoothSocket? = null
    @Volatile var out: OutputStream? = null
    @Volatile var status = "Bağlı değil"
    @Volatile var deviceName = ""
    @Volatile var bytesIn = 0L
    @Volatile var rtcmOut = 0L

    val connected get() = socket?.isConnected == true

    @SuppressLint("MissingPermission")
    fun connect(dev: BluetoothDevice) {
        disconnect()
        deviceName = dev.name ?: dev.address
        status = "Bağlanıyor: $deviceName"
        Thread {
            try {
                var s: BluetoothSocket = dev.createRfcommSocketToServiceRecord(SPP)
                try { s.connect() } catch (e: Exception) {
                    // Bazı eski cihazlarda SDP çalışmaz; kanal 1'i doğrudan dene
                    try { s.close() } catch (_: Exception) {}
                    val m = dev.javaClass.getMethod("createRfcommSocket", Int::class.javaPrimitiveType)
                    s = m.invoke(dev, 1) as BluetoothSocket
                    s.connect()
                }
                socket = s; out = s.outputStream
                status = "Bağlı: $deviceName"
                readLoop(s.inputStream)
            } catch (e: Exception) {
                status = "Hata: ${e.message}"
            } finally {
                if (socket != null) { status = "Bağlantı koptu"; disconnect(keepStatus = true) }
            }
        }.start()
    }

    private fun readLoop(inp: InputStream) {
        val buf = ByteArray(1024)
        val line = StringBuilder()
        while (true) {
            val n = inp.read(buf)
            if (n < 0) break
            bytesIn += n
            for (i in 0 until n) {
                val c = (buf[i].toInt() and 0xFF).toChar()
                when {
                    c == '\n' || c == '\r' -> {
                        if (line.isNotEmpty() && line[0] == '$') Nmea.parse(line.toString())
                        line.setLength(0)
                    }
                    c == '$' -> { line.setLength(0); line.append(c) }
                    line.length < 300 && c.code in 32..126 -> line.append(c)
                }
            }
        }
    }

    fun write(b: ByteArray, n: Int) {
        try { out?.write(b, 0, n); rtcmOut += n } catch (_: Exception) {}
    }

    fun disconnect(keepStatus: Boolean = false) {
        try { socket?.close() } catch (_: Exception) {}
        socket = null; out = null
        if (!keepStatus) status = "Bağlı değil"
    }
}

/** NTRIP v1 istemcisi (TUSAGA-Aktif). GGA'yı periyodik gönderir, RTCM'i Bluetooth'a aktarır. */
object Ntrip {
    @Volatile var status = "Kapalı"
    @Volatile var bytes = 0L
    @Volatile var running = false
    private var sock: Socket? = null

    private fun auth(u: String, p: String) =
        Base64.encodeToString("$u:$p".toByteArray(), Base64.NO_WRAP)

    /** Kaynak tablosundan mountpoint listesi */
    fun sourceTable(host: String, port: Int, user: String, pass: String): List<String> {
        Socket().use { s ->
            s.connect(InetSocketAddress(host, port), 8000)
            s.soTimeout = 8000
            val req = "GET / HTTP/1.0\r\nUser-Agent: NTRIP S82RTK/0.1\r\n" +
                    (if (user.isNotEmpty()) "Authorization: Basic ${auth(user, pass)}\r\n" else "") + "\r\n"
            s.getOutputStream().write(req.toByteArray())
            val txt = s.getInputStream().readBytes().toString(Charsets.ISO_8859_1)
            val list = txt.lines().filter { it.startsWith("STR;") }.map {
                val p = it.split(';')
                // STR;mount;id;format;details;...
                p.getOrElse(1) { "?" } + "  [" + p.getOrElse(3) { "" } + "]"
            }
            if (list.isEmpty()) throw Exception(txt.lineSequence().firstOrNull() ?: "Boş cevap")
            return list
        }
    }

    fun start(host: String, port: Int, user: String, pass: String, mount: String) {
        stop()
        running = true
        status = "Bağlanıyor..."
        Thread {
            while (running) {
                try {
                    val s = Socket(); sock = s
                    s.connect(InetSocketAddress(host, port), 10000)
                    s.soTimeout = 15000
                    val o = s.getOutputStream()
                    val req = "GET /$mount HTTP/1.0\r\nUser-Agent: NTRIP S82RTK/0.1\r\n" +
                            "Authorization: Basic ${auth(user, pass)}\r\n\r\n"
                    o.write(req.toByteArray())
                    val inp = s.getInputStream()
                    // Cevap başlığı
                    val head = StringBuilder()
                    while (!head.endsWith("\r\n")) {
                        val c = inp.read(); if (c < 0) break; head.append(c.toChar())
                        if (head.length > 200) break
                    }
                    val h = head.toString().trim()
                    if (!h.contains("200")) { status = "Red: $h"; running = false; break }
                    status = "Bağlı ($mount)"
                    if (Gnss.lastGga.isNotEmpty()) o.write((Gnss.lastGga + "\r\n").toByteArray())
                    var lastGga = System.currentTimeMillis()
                    val buf = ByteArray(2048)
                    while (running) {
                        val n = try { inp.read(buf) } catch (e: java.net.SocketTimeoutException) { 0 }
                        if (n < 0) throw Exception("sunucu kapattı")
                        if (n > 0) {
                            // Başlıktan sonra HTTP 1.1 boş satır kalırsa atla
                            bytes += n; Bt.write(buf, n)
                        }
                        val now = System.currentTimeMillis()
                        if (now - lastGga > 5000 && Gnss.lastGga.isNotEmpty()) {
                            o.write((Gnss.lastGga + "\r\n").toByteArray()); lastGga = now
                        }
                    }
                } catch (e: Exception) {
                    if (running) { status = "Koptu (${e.message}), 5 sn sonra tekrar"; Thread.sleep(5000) }
                } finally {
                    try { sock?.close() } catch (_: Exception) {}
                }
            }
            if (status.startsWith("Bağlı") || status.startsWith("Bağlanıyor")) status = "Kapalı"
        }.start()
    }

    fun stop() {
        running = false
        try { sock?.close() } catch (_: Exception) {}
        status = "Kapalı"
    }
}
