package com.s82rtk

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.*
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.*
import java.io.File
import java.util.Locale
import kotlin.math.*

class MainActivity : Activity(), SensorEventListener {

    private val ui = Handler(Looper.getMainLooper())
    private lateinit var content: FrameLayout
    private lateinit var prefs: android.content.SharedPreferences
    private lateinit var measured: PointStore
    private lateinit var stake: PointStore
    private var tab = 0
    private var refresher: (() -> Unit)? = null
    private var heading = Float.NaN   // telefonun baktığı yön (manyetik), derece
    private var tone: ToneGenerator? = null

    // Renkler
    private val BG = Color.rgb(18, 20, 24)
    private val CARD = Color.rgb(32, 36, 44)
    private val FG = Color.rgb(230, 232, 236)
    private val DIM = Color.rgb(150, 156, 168)
    private val ACC = Color.rgb(255, 176, 32)
    private val GREEN = Color.rgb(60, 200, 90)
    private val RED = Color.rgb(230, 70, 60)
    private val BLUE = Color.rgb(70, 150, 240)

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        prefs = getSharedPreferences("s82", Context.MODE_PRIVATE)
        measured = PointStore(File(filesDir, "olcum.ncn"))
        stake = PointStore(File(filesDir, "aplikasyon.ncn"))
        try { tone = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 80) } catch (_: Exception) {}

        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(BG) }
        root.addView(statusBar(), LinearLayout.LayoutParams(-1, -2))
        content = FrameLayout(this)
        root.addView(content, LinearLayout.LayoutParams(-1, 0, 1f))
        root.addView(tabBar(), LinearLayout.LayoutParams(-1, dp(56)))
        setContentView(root)

        if (Build.VERSION.SDK_INT >= 31 &&
            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED)
            requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), 1)

        show(0)
        ui.post(object : Runnable {
            override fun run() { updateStatusBar(); refresher?.invoke(); ui.postDelayed(this, 400) }
        })
    }

    override fun onResume() {
        super.onResume()
        val sm = getSystemService(SENSOR_SERVICE) as SensorManager
        sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)?.let { sm.registerListener(this, it, SensorManager.SENSOR_DELAY_UI) }
    }
    override fun onPause() { super.onPause(); (getSystemService(SENSOR_SERVICE) as SensorManager).unregisterListener(this) }
    override fun onAccuracyChanged(s: Sensor?, a: Int) {}
    override fun onSensorChanged(e: SensorEvent) {
        val r = FloatArray(9); val o = FloatArray(3)
        SensorManager.getRotationMatrixFromVector(r, e.values)
        SensorManager.getOrientation(r, o)
        heading = ((Math.toDegrees(o[0].toDouble()) + 360) % 360).toFloat()
    }

    // ---------- Üst durum çubuğu ----------
    private lateinit var sbFix: TextView
    private lateinit var sbInfo: TextView
    private fun statusBar(): View {
        val l = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(dp(12), dp(10), dp(12), dp(10)); setBackgroundColor(CARD); gravity = Gravity.CENTER_VERTICAL }
        sbFix = TextView(this).apply { textSize = 18f; setTypeface(null, Typeface.BOLD); setPadding(dp(10), dp(4), dp(10), dp(4)) }
        sbInfo = TextView(this).apply { textSize = 13f; setTextColor(FG); setPadding(dp(12), 0, 0, 0) }
        l.addView(sbFix); l.addView(sbInfo)
        return l
    }
    private fun fixColor(q: Int) = when (q) { 4 -> GREEN; 5 -> ACC; 1, 2 -> BLUE; else -> RED }
    private fun updateStatusBar() {
        val stale = System.currentTimeMillis() - Gnss.lastUpdateMs > 3000
        val q = if (stale) 0 else Gnss.fix
        sbFix.text = if (!Bt.connected) "BT YOK" else Gnss.fixText(q)
        sbFix.setTextColor(Color.BLACK)
        sbFix.setBackgroundColor(if (!Bt.connected) Color.GRAY else fixColor(q))
        val h = if (Gnss.sigLat >= 0) "±%.3f m".format(Locale.US, hypot(Gnss.sigLat, Gnss.sigLon)) else "±?"
        sbInfo.text = "Uydu ${Gnss.sats}/${Gnss.satsInView}   $h\nNTRIP: ${Ntrip.status}" +
                (if (Gnss.diffAge >= 0) "  yaş ${"%.0f".format(Gnss.diffAge)}s" else "")
    }

    // ---------- Sekmeler ----------
    private val tabNames = listOf("Bağlantı", "Durum", "Ölçüm", "Aplikasyon")
    private val tabButtons = mutableListOf<TextView>()
    private fun tabBar(): View {
        val l = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setBackgroundColor(CARD) }
        tabNames.forEachIndexed { i, n ->
            val t = TextView(this).apply { text = n; gravity = Gravity.CENTER; textSize = 14f; setOnClickListener { show(i) } }
            tabButtons.add(t); l.addView(t, LinearLayout.LayoutParams(0, -1, 1f))
        }
        return l
    }
    private fun show(i: Int) {
        tab = i
        tabButtons.forEachIndexed { j, t -> t.setTextColor(if (j == i) ACC else DIM); t.setTypeface(null, if (j == i) Typeface.BOLD else Typeface.NORMAL) }
        content.removeAllViews(); refresher = null
        content.addView(when (i) { 0 -> pageConnect(); 1 -> pageStatus(); 2 -> pageMeasure(); else -> pageStake() })
    }

    // ---------- Yardımcılar ----------
    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    private fun scroll(inner: LinearLayout) = ScrollView(this).apply { addView(inner) }
    private fun column() = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(14), dp(12), dp(14), dp(24)) }
    private fun title(t: String) = TextView(this).apply { text = t; textSize = 15f; setTextColor(ACC); setTypeface(null, Typeface.BOLD); setPadding(0, dp(14), 0, dp(6)) }
    private fun label(t: String, size: Float = 14f, color: Int = FG) = TextView(this).apply { text = t; textSize = size; setTextColor(color) }
    private fun edit(hint: String, key: String, def: String = "", type: Int = InputType.TYPE_CLASS_TEXT) = EditText(this).apply {
        this.hint = hint; setText(prefs.getString(key, def)); inputType = type; setTextColor(FG); setHintTextColor(DIM); textSize = 15f
        tag = key
    }
    private fun button(t: String, color: Int = BLUE, onClick: () -> Unit) = Button(this).apply {
        text = t; setTextColor(Color.WHITE); isAllCaps = false; textSize = 15f
        background = android.graphics.drawable.GradientDrawable().apply { setColor(color); cornerRadius = dp(8).toFloat() }
        setOnClickListener { onClick() }
        layoutParams = LinearLayout.LayoutParams(-1, dp(48)).apply { topMargin = dp(8) }
    }
    private fun row(vararg v: View) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        v.forEachIndexed { i, x -> addView(x, LinearLayout.LayoutParams(0, -2, 1f).apply { if (i > 0) leftMargin = dp(8) }) }
    }
    private fun savePrefs(vararg e: EditText) { val ed = prefs.edit(); e.forEach { ed.putString(it.tag as String, it.text.toString().trim()) }; ed.apply() }
    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_SHORT).show()
    private fun f3(v: Double) = "%.3f".format(Locale.US, v)

    private fun cm(): Int {
        val s = prefs.getString("cm", "0")!!.toIntOrNull() ?: 0
        return if (s == 0) Tm.autoCm(if (Gnss.lon != 0.0) Gnss.lon else 27.0) else s
    }
    private fun currentYX() = Tm.forward(Gnss.lat, Gnss.lon, cm())

    // ---------- 1) Bağlantı ----------
    @SuppressLint("MissingPermission")
    private fun pageConnect(): View {
        val c = column()
        c.addView(title("S82 Bluetooth"))
        val btStatus = label(""); c.addView(btStatus)
        c.addView(button("Eşleşmiş cihazlardan seç") {
            if (Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), 1); return@button
            }
            val ad = (getSystemService(BLUETOOTH_SERVICE) as BluetoothManager).adapter
            if (ad == null || !ad.isEnabled) { toast("Bluetooth kapalı"); return@button }
            val devs = ad.bondedDevices.toList()
            if (devs.isEmpty()) { toast("Önce telefon ayarlarından S82 ile eşleştir"); return@button }
            AlertDialog.Builder(this).setTitle("Cihaz seç")
                .setItems(devs.map { "${it.name}\n${it.address}" }.toTypedArray()) { _, i ->
                    prefs.edit().putString("btaddr", devs[i].address).apply(); Bt.connect(devs[i])
                }.show()
        })
        c.addView(row(
            button("Son cihaza bağlan", GREEN) {
                val addr = prefs.getString("btaddr", "") ?: ""
                if (addr.isEmpty()) { toast("Önce cihaz seç"); return@button }
                try {
                    val ad = (getSystemService(BLUETOOTH_SERVICE) as BluetoothManager).adapter
                    Bt.connect(ad.getRemoteDevice(addr))
                } catch (e: SecurityException) { toast("Bluetooth izni ver") }
            },
            button("Kes", RED) { Bt.disconnect() }))

        c.addView(title("TUSAGA-Aktif (NTRIP)"))
        val host = edit("Sunucu adresi (IP)", "host")
        val port = edit("Port", "port", "2101", InputType.TYPE_CLASS_NUMBER)
        val user = edit("Kullanıcı adı", "user")
        val pass = edit("Şifre", "pass", "", InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        val mount = edit("Mountpoint (ör. VRS RTCM 3.1)", "mount")
        listOf(host, port, user, pass, mount).forEach { c.addView(it) }
        c.addView(button("Mountpoint listesini getir") {
            savePrefs(host, port, user, pass, mount)
            toast("Liste alınıyor...")
            Thread {
                try {
                    val l = Ntrip.sourceTable(host.text.toString().trim(), port.text.toString().toIntOrNull() ?: 2101,
                        user.text.toString().trim(), pass.text.toString())
                    ui.post {
                        AlertDialog.Builder(this).setTitle("Mountpoint seç (S82 için RTCM 3.0/3.1 öner)")
                            .setItems(l.toTypedArray()) { _, i -> mount.setText(l[i].substringBefore("  ")); savePrefs(mount) }.show()
                    }
                } catch (e: Exception) { ui.post { toast("Hata: ${e.message}") } }
            }.start()
        })
        c.addView(row(
            button("NTRIP Başlat", GREEN) {
                savePrefs(host, port, user, pass, mount)
                if (!Bt.connected) toast("Uyarı: S82 bağlı değil, düzeltme iletilemez")
                Ntrip.start(host.text.toString().trim(), port.text.toString().toIntOrNull() ?: 2101,
                    user.text.toString().trim(), pass.text.toString(), mount.text.toString().trim())
            },
            button("Durdur", RED) { Ntrip.stop() }))
        val nStat = label("", 13f, DIM); c.addView(nStat)

        c.addView(title("Koordinat sistemi"))
        c.addView(label("ITRF96 → TM 3° (GRS80, k=1, sağa +500000). Dilim orta meridyeni: 0 = otomatik (Bodrum/Milas → 27)", 13f, DIM))
        val cmE = edit("Orta meridyen (0=otomatik)", "cm", "0", InputType.TYPE_CLASS_NUMBER)
        c.addView(cmE)
        c.addView(button("Kaydet") { savePrefs(cmE); toast("DOM: ${cm()}") })

        refresher = {
            btStatus.text = "${Bt.status}\nGelen: ${Bt.bytesIn} bayt, NMEA satırı: ${Gnss.nmeaCount}" +
                    (if (Gnss.boardHint.isNotEmpty()) "\nKart: ${Gnss.boardHint}" else "")
            nStat.text = "Durum: ${Ntrip.status}\nAlınan düzeltme: ${Ntrip.bytes} bayt, S82'ye iletilen: ${Bt.rtcmOut} bayt"
        }
        return scroll(c)
    }

    // ---------- 2) Durum ----------
    private fun pageStatus(): View {
        val c = column()
        val big = label("", 16f).apply { typeface = Typeface.MONOSPACE }
        val raw = label("", 10f, DIM).apply { typeface = Typeface.MONOSPACE }
        c.addView(title("Konum")); c.addView(big)
        c.addView(title("Ham NMEA (son satırlar)")); c.addView(raw)
        refresher = {
            val (y, x) = currentYX()
            big.text = buildString {
                append("Fix      : ${Gnss.fixText()}\n")
                append("Uydu     : ${Gnss.sats} kullanılan / ${Gnss.satsInView} görünen\n")
                append("HDOP     : ${"%.1f".format(Locale.US, Gnss.hdop)}\n")
                append("Enlem    : ${"%.9f".format(Locale.US, Gnss.lat)}\n")
                append("Boylam   : ${"%.9f".format(Locale.US, Gnss.lon)}\n")
                append("Elips. h : ${f3(Gnss.ellHeight)} m\n")
                append("Kot(GGA) : ${f3(Gnss.alt)} m\n\n")
                append("TM${cm()}  Y : ${f3(y)}\n")
                append("TM${cm()}  X : ${f3(x)}\n\n")
                if (Gnss.sigLat >= 0) append("σ K/D/Y  : ${f3(Gnss.sigLat)} / ${f3(Gnss.sigLon)} / ${f3(Gnss.sigAlt)} m\n")
                append("UTC      : ${Gnss.utc}")
            }
            raw.text = Gnss.logText()
        }
        return scroll(c)
    }

    // ---------- 3) Ölçüm ----------
    @Volatile private var measuring = false
    private fun pageMeasure(): View {
        val c = column()
        c.addView(title("Nokta ölç"))
        val name = edit("Nokta adı", "nextName", "1")
        val epochs = edit("Epok sayısı", "epochs", "5", InputType.TYPE_CLASS_NUMBER)
        c.addView(row(name, epochs))
        val fixOnly = CheckBox(this).apply { text = "Sadece RTK FIX iken ölç"; setTextColor(FG); isChecked = prefs.getBoolean("fixOnly", true) }
        c.addView(fixOnly)
        val prog = label("", 15f, ACC); c.addView(prog)
        val listV = label("", 13f).apply { typeface = Typeface.MONOSPACE }

        fun refreshList() {
            listV.text = if (measured.list.isEmpty()) "(henüz nokta yok)" else
                measured.list.reversed().joinToString("\n") { PointStore.fmt(it) }
        }

        c.addView(button("ÖLÇ", GREEN) {
            if (measuring) return@button
            savePrefs(name, epochs); prefs.edit().putBoolean("fixOnly", fixOnly.isChecked).apply()
            val n = (epochs.text.toString().toIntOrNull() ?: 5).coerceIn(1, 600)
            val nm = name.text.toString().trim().ifEmpty { "1" }
            if (measured.list.any { it.name == nm }) { toast("$nm zaten var, üzerine yazılacak") }
            measuring = true
            Thread {
                var sy = 0.0; var sx = 0.0; var sz = 0.0; var k = 0; var last = 0L
                val t0 = System.currentTimeMillis(); var worst = 9
                while (k < n && measuring) {
                    if (System.currentTimeMillis() - t0 > 120_000) break
                    val u = Gnss.lastUpdateMs
                    if (u != last) {
                        last = u
                        val ok = if (fixOnly.isChecked) Gnss.fix == 4 else Gnss.fix > 0
                        if (ok) {
                            val (y, x) = currentYX(); sy += y; sx += x; sz += Gnss.alt; k++
                            worst = minOf(worst, Gnss.fix.let { if (it == 4) 9 else it })
                        }
                        ui.post { prog.text = "Ölçülüyor $k/$n  (${Gnss.fixText()})" }
                    }
                    Thread.sleep(50)
                }
                val done = k == n
                measuring = false
                ui.post {
                    if (!done) { prog.text = "İptal / zaman aşımı ($k/$n epok)"; return@post }
                    val p = Pt(nm, sy / k, sx / k, sz / k, if (worst == 9) "FIX" else Gnss.fixText(worst))
                    measured.add(p)
                    prog.text = "Kaydedildi: ${PointStore.fmt(p)}"
                    tone?.startTone(ToneGenerator.TONE_PROP_ACK, 200)
                    name.setText(nextName(nm)); savePrefs(name)
                    refreshList()
                }
            }.start()
        })
        c.addView(button("Durdur", RED) { measuring = false })

        c.addView(title("Ölçülen noktalar (ad Y X Z)"))
        c.addView(listV)
        c.addView(row(
            button("Paylaş (.ncn)") { shareText("olcum.ncn", measured.list.joinToString("\r\n") { PointStore.fmt(it) }) },
            button("Hepsini sil", RED) {
                AlertDialog.Builder(this).setMessage("Tüm ölçülen noktalar silinsin mi?")
                    .setPositiveButton("Sil") { _, _ -> measured.clear(); refreshList() }.setNegativeButton("Vazgeç", null).show()
            }))
        refreshList()
        return scroll(c)
    }

    private fun nextName(s: String): String {
        val m = Regex("^(.*?)(\\d+)$").find(s) ?: return s + "1"
        val num = m.groupValues[2]
        return m.groupValues[1] + (num.toLong() + 1).toString().padStart(num.length, '0')
    }

    private fun shareText(fileName: String, text: String) {
        val i = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"; putExtra(Intent.EXTRA_SUBJECT, fileName); putExtra(Intent.EXTRA_TEXT, text)
        }
        startActivity(Intent.createChooser(i, "Noktaları gönder"))
    }

    // ---------- 4) Aplikasyon ----------
    private var target: Pt? = null
    private var lastBeep = 0L
    private fun pageStake(): View {
        val c = column()
        val tName = label("Hedef: (seçilmedi)", 16f, ACC)
        c.addView(tName)
        c.addView(row(
            button("Listeden seç") {
                if (stake.list.isEmpty() && measured.list.isEmpty()) { toast("Önce nokta yükle"); return@button }
                val all = stake.list + measured.list.map { it.copy(note = "ölçülen") }
                AlertDialog.Builder(this).setTitle("Hedef nokta")
                    .setItems(all.map { "${it.name}   Y ${f3(it.y)}  X ${f3(it.x)}" }.toTypedArray()) { _, i -> target = all[i] }.show()
            },
            button("Elle gir") { manualTarget() }))
        c.addView(row(
            button("◀ Önceki") { stepTarget(-1) },
            button("Sonraki ▶") { stepTarget(1) }))

        val arrow = ArrowView(this)
        c.addView(arrow, LinearLayout.LayoutParams(-1, dp(220)).apply { topMargin = dp(10) })
        val dist = label("", 34f).apply { gravity = Gravity.CENTER; setTypeface(null, Typeface.BOLD) }
        val dir = label("", 20f).apply { gravity = Gravity.CENTER; typeface = Typeface.MONOSPACE }
        val small = label("", 13f, DIM).apply { gravity = Gravity.CENTER; typeface = Typeface.MONOSPACE }
        c.addView(dist); c.addView(dir); c.addView(small)

        val tol = edit("Tolerans (cm)", "tol", "2", InputType.TYPE_CLASS_NUMBER)
        c.addView(title("Ayarlar")); c.addView(tol)
        c.addView(button("Aplikasyon noktalarını yapıştır (ad Y X Z)") { pasteStake() })
        c.addView(label("NetCAD'den .ncn içeriğini kopyalayıp yapıştırabilirsin. Yüklü nokta: ${stake.list.size}", 12f, DIM))

        refresher = {
            val t = target
            tName.text = if (t == null) "Hedef: (seçilmedi)" else "Hedef: ${t.name}   Y ${f3(t.y)}  X ${f3(t.x)}"
            if (t == null || Gnss.fix == 0) {
                dist.text = if (t == null) "" else "Konum yok"; dir.text = ""; small.text = ""; arrow.set(Float.NaN, false)
            } else {
                val (y, x) = currentYX()
                val dy = t.y - y; val dx = t.x - x
                val d = hypot(dy, dx)
                val tolM = (tol.text.toString().toDoubleOrNull() ?: 2.0) / 100.0
                val ok = d <= tolM
                dist.text = if (d < 10) "%.3f m".format(Locale.US, d) else "%.1f m".format(Locale.US, d)
                dist.setTextColor(if (ok) GREEN else FG)
                dir.text = (if (dx >= 0) "KUZEY " else "GÜNEY ") + "%.3f".format(Locale.US, abs(dx)) + "\n" +
                        (if (dy >= 0) "DOĞU  " else "BATI  ") + "%.3f".format(Locale.US, abs(dy))
                val az = (Math.toDegrees(atan2(dy, dx)) + 360) % 360
                val dz = t.z - Gnss.alt
                small.text = "Semt %.1f°  (%.4f g)   ΔZ %s %.3f\nFix: %s".format(Locale.US, az, az * 400 / 360,
                    if (dz >= 0) "dolgu" else "kazı", abs(dz), Gnss.fixText())
                arrow.set(if (heading.isNaN()) az.toFloat() else (az - heading).toFloat(), ok, !heading.isNaN())
                val now = System.currentTimeMillis()
                if (ok && now - lastBeep > 1000) { tone?.startTone(ToneGenerator.TONE_PROP_BEEP, 150); lastBeep = now }
                else if (!ok && d < 0.3 && now - lastBeep > (d * 3000).toLong() + 150) { tone?.startTone(ToneGenerator.TONE_CDMA_PIP, 60); lastBeep = now }
            }
        }
        return scroll(c)
    }

    private fun stepTarget(dir: Int) {
        val l = stake.list
        if (l.isEmpty()) { toast("Aplikasyon listesi boş"); return }
        val i = l.indexOfFirst { it.name == target?.name }
        target = l[((if (i < 0) 0 else i + dir) % l.size + l.size) % l.size]
    }

    private fun manualTarget() {
        val box = column()
        val n = EditText(this).apply { hint = "Ad"; setText("H1") }
        val y = EditText(this).apply { hint = "Y (sağa)"; inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL }
        val x = EditText(this).apply { hint = "X (yukarı)"; inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL }
        box.addView(n); box.addView(y); box.addView(x)
        AlertDialog.Builder(this).setTitle("Hedef koordinat (TM${cm()})").setView(box)
            .setPositiveButton("Tamam") { _, _ ->
                val yy = y.text.toString().replace(',', '.').toDoubleOrNull()
                val xx = x.text.toString().replace(',', '.').toDoubleOrNull()
                if (yy == null || xx == null) toast("Koordinat hatalı") else target = Pt(n.text.toString(), yy, xx, 0.0)
            }.setNegativeButton("Vazgeç", null).show()
    }

    private fun pasteStake() {
        val e = EditText(this).apply {
            hint = "P1 512345.123 4101234.567 12.3\nP2 ..."; minLines = 8; gravity = Gravity.TOP
            val cb = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
            cb.primaryClip?.getItemAt(0)?.text?.let { setText(it) }
        }
        AlertDialog.Builder(this).setTitle("Noktaları yapıştır").setView(e)
            .setPositiveButton("Ekle") { _, _ ->
                val pts = PointStore.parseText(e.text.toString())
                pts.forEach { stake.add(it) }
                toast("${pts.size} nokta eklendi"); show(3)
            }
            .setNeutralButton("Listeyi temizle") { _, _ -> stake.clear(); target = null; show(3) }
            .setNegativeButton("Vazgeç", null).show()
    }

    /** Hedef yönünü gösteren ok. Pusula varsa telefona göre, yoksa kuzeye göre. */
    inner class ArrowView(ctx: Context) : View(ctx) {
        private var ang = Float.NaN; private var ok = false; private var rel = true
        private val p = Paint(Paint.ANTI_ALIAS_FLAG)
        fun set(a: Float, ok: Boolean, relative: Boolean = true) { ang = a; this.ok = ok; rel = relative; invalidate() }
        override fun onDraw(cv: Canvas) {
            val cx = width / 2f; val cy = height / 2f; val r = min(cx, cy) * 0.9f
            p.style = Paint.Style.STROKE; p.strokeWidth = dp(3).toFloat(); p.color = if (ok) GREEN else Color.rgb(70, 76, 90)
            cv.drawCircle(cx, cy, r, p)
            if (ok) { p.style = Paint.Style.FILL; p.color = GREEN; cv.drawCircle(cx, cy, r * 0.35f, p); return }
            if (ang.isNaN()) return
            cv.save(); cv.rotate(ang, cx, cy)
            val path = Path().apply {
                moveTo(cx, cy - r * 0.85f); lineTo(cx + r * 0.3f, cy - r * 0.2f); lineTo(cx + r * 0.1f, cy - r * 0.2f)
                lineTo(cx + r * 0.1f, cy + r * 0.6f); lineTo(cx - r * 0.1f, cy + r * 0.6f); lineTo(cx - r * 0.1f, cy - r * 0.2f)
                lineTo(cx - r * 0.3f, cy - r * 0.2f); close()
            }
            p.style = Paint.Style.FILL; p.color = ACC; cv.drawPath(path, p)
            cv.restore()
            p.color = DIM; p.textSize = dp(11).toFloat(); p.textAlign = Paint.Align.CENTER
            cv.drawText(if (rel) "telefonun baktığı yöne göre" else "yukarı = kuzey", cx, height - dp(4).toFloat(), p)
        }
    }

    override fun onDestroy() { super.onDestroy(); tone?.release() }
}
