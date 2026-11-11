package com.s82rtk

import java.io.File

data class Pt(val name: String, val y: Double, val x: Double, val z: Double, val note: String = "")

/** Ölçülen noktalar ve aplikasyon noktaları; düz metin dosyalarında saklanır. */
class PointStore(private val file: File) {
    val list = mutableListOf<Pt>()

    init { load() }

    fun load() {
        list.clear()
        if (file.exists()) file.readLines().forEach { parseLine(it)?.let(list::add) }
    }

    fun save() = file.writeText(list.joinToString("\n") { fmt(it) })

    fun add(p: Pt) { list.removeAll { it.name == p.name }; list.add(p); save() }

    fun clear() { list.clear(); save() }

    companion object {
        fun fmt(p: Pt) = "%s %.3f %.3f %.3f%s".format(java.util.Locale.US, p.name, p.y, p.x, p.z,
            if (p.note.isNotEmpty()) " " + p.note else "")

        /** "ad Y X [Z]" — boşluk, sekme, virgül veya noktalı virgül ayraçlı. NCN uyumlu. */
        fun parseLine(s: String): Pt? {
            val t = s.trim()
            // Noktalı virgül/sekme ayraçlıysa virgül ondalık işaretidir (Excel TR)
            val p = (if (t.contains(';') || t.contains('\t'))
                t.split(Regex("[;\\t]+")).map { it.trim().replace(',', '.') }
            else t.split(Regex("[\\s,]+"))).filter { it.isNotEmpty() }
            if (p.size < 3) return null
            val y = p[1].toDoubleOrNull() ?: return null
            val x = p[2].toDoubleOrNull() ?: return null
            val z = p.getOrNull(3)?.toDoubleOrNull() ?: 0.0
            val note = if (p.size > 4) p.drop(4).joinToString(" ") else ""
            return Pt(p[0], y, x, z, note)
        }

        fun parseText(t: String) = t.lines().mapNotNull { parseLine(it) }
    }
}
