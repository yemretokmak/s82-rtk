package com.s82rtk

import kotlin.math.*

/** Alıcıdan gelen son durum. Thread'ler arası paylaşılır, basitlik için @Volatile alanlar. */
object Gnss {
    @Volatile var lat = 0.0          // derece (+K)
    @Volatile var lon = 0.0          // derece (+D)
    @Volatile var alt = 0.0          // ortometrik (GGA alan 9), m
    @Volatile var geoidSep = 0.0     // GGA alan 11, m
    @Volatile var fix = 0            // GGA kalite
    @Volatile var sats = 0
    @Volatile var hdop = 0.0
    @Volatile var diffAge = -1.0     // düzeltme yaşı, s
    @Volatile var sigLat = -1.0      // GST
    @Volatile var sigLon = -1.0
    @Volatile var sigAlt = -1.0
    @Volatile var utc = ""
    @Volatile var satsInView = 0
    @Volatile var lastGga = ""       // NTRIP'e gönderilecek ham GGA
    @Volatile var lastUpdateMs = 0L
    @Volatile var nmeaCount = 0L
    @Volatile var boardHint = ""     // $PTNL -> Trimble

    val ellHeight get() = alt + geoidSep

    fun fixText(q: Int = fix) = when (q) {
        0 -> "YOK"
        1 -> "TEKİL"
        2 -> "DGPS"
        3 -> "PPS"
        4 -> "RTK FIX"
        5 -> "RTK FLOAT"
        6 -> "TAHMİNİ"
        else -> "?($q)"
    }

    /** Ham log (son satırlar) */
    private val log = ArrayDeque<String>()
    @Synchronized fun addLog(s: String) { log.addLast(s); while (log.size > 40) log.removeFirst() }
    @Synchronized fun logText() = log.joinToString("\n")
}

object Nmea {
    fun checksumOk(line: String): Boolean {
        val star = line.lastIndexOf('*')
        if (!line.startsWith("$") || star < 0 || star + 3 > line.length) return false
        var c = 0
        for (i in 1 until star) c = c xor line[i].code
        return line.substring(star + 1, star + 3).equals("%02X".format(c), ignoreCase = true)
    }

    private fun d(s: String?) = s?.toDoubleOrNull()

    /** ddmm.mmmm -> derece */
    fun dm(v: String, hemi: String): Double? {
        val x = v.toDoubleOrNull() ?: return null
        val deg = floor(x / 100)
        val r = deg + (x - deg * 100) / 60.0
        return if (hemi == "S" || hemi == "W") -r else r
    }

    fun parse(line: String) {
        Gnss.nmeaCount++
        Gnss.addLog(line)
        if (!checksumOk(line)) return
        val body = line.substring(1, line.lastIndexOf('*'))
        val f = body.split(',')
        val type = f[0]
        when {
            type.endsWith("GGA") && f.size >= 14 -> {
                Gnss.utc = f[1]
                Gnss.fix = f[6].toIntOrNull() ?: 0
                Gnss.sats = f[7].toIntOrNull() ?: 0
                Gnss.hdop = d(f[8]) ?: 0.0
                if (Gnss.fix > 0) {
                    dm(f[2], f[3])?.let { Gnss.lat = it }
                    dm(f[4], f[5])?.let { Gnss.lon = it }
                    Gnss.alt = d(f[9]) ?: 0.0
                    Gnss.geoidSep = d(f[11]) ?: 0.0
                }
                Gnss.diffAge = d(f[13]) ?: -1.0
                Gnss.lastGga = line
                Gnss.lastUpdateMs = System.currentTimeMillis()
            }
            type.endsWith("GST") && f.size >= 9 -> {
                Gnss.sigLat = d(f[6]) ?: -1.0
                Gnss.sigLon = d(f[7]) ?: -1.0
                Gnss.sigAlt = d(f[8]) ?: -1.0
            }
            type == "GPGSV" && f.size >= 4 -> {
                // GPS uydu sayısı; GLONASS'ı da eklemek için ayrı tutuyoruz
                gpsView = f[3].toIntOrNull() ?: 0; Gnss.satsInView = gpsView + glView
            }
            type == "GLGSV" && f.size >= 4 -> {
                glView = f[3].toIntOrNull() ?: 0; Gnss.satsInView = gpsView + glView
            }
            type == "PTNL" -> Gnss.boardHint = "Trimble"
        }
    }
    private var gpsView = 0
    private var glView = 0
}

/**
 * GRS80 elipsoidi üzerinde Transverse Mercator (Türkiye TM 3°: k0=1, sağa ek 500000).
 * ITRF96 enlem/boylam -> Y (sağa), X (yukarı).
 */
object Tm {
    private const val a = 6378137.0
    private const val f = 1 / 298.257222101
    private val e2 = f * (2 - f)
    private val ep2 = e2 / (1 - e2)

    fun autoCm(lonDeg: Double): Int = (Math.round(lonDeg / 3.0) * 3).toInt()

    /** @return Pair(Y sağa, X yukarı) */
    fun forward(latDeg: Double, lonDeg: Double, cm: Int, k0: Double = 1.0, fe: Double = 500000.0): Pair<Double, Double> {
        val phi = Math.toRadians(latDeg)
        val dl = Math.toRadians(lonDeg - cm)
        val sin = sin(phi); val cos = cos(phi); val t = tan(phi)
        val N = a / sqrt(1 - e2 * sin * sin)
        val T = t * t
        val C = ep2 * cos * cos
        val A = dl * cos
        val e4 = e2 * e2; val e6 = e4 * e2
        val M = a * ((1 - e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256) * phi
                - (3 * e2 / 8 + 3 * e4 / 32 + 45 * e6 / 1024) * sin(2 * phi)
                + (15 * e4 / 256 + 45 * e6 / 1024) * sin(4 * phi)
                - (35 * e6 / 3072) * sin(6 * phi))
        val y = k0 * N * (A + (1 - T + C) * A.pow(3) / 6
                + (5 - 18 * T + T * T + 72 * C - 58 * ep2) * A.pow(5) / 120) + fe
        val x = k0 * (M + N * t * (A * A / 2 + (5 - T + 9 * C + 4 * C * C) * A.pow(4) / 24
                + (61 - 58 * T + T * T + 600 * C - 330 * ep2) * A.pow(6) / 720))
        return Pair(y, x)
    }
}
