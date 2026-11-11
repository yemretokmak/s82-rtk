package com.s82rtk
import org.junit.Test
class TmTest {
    @Test fun print() {
        for ((la, lo) in listOf(37.0345 to 27.4305, 37.3120 to 27.7810, 36.9800 to 26.2000)) {
            val (y, x) = Tm.forward(la, lo, 27)
            println("TMOUT %.7f %.7f %.4f %.4f".format(java.util.Locale.US, la, lo, y, x))
        }
        // NMEA
        Nmea.parse("\$GPGGA,000000.00,0000.00000000,N,00000.00000000,E,0,00,0.0,0.000,M,-0.000,M,,*70")
        println("TMOUT chk " + Nmea.checksumOk("\$GPGGA,000000.00,0000.00000000,N,00000.00000000,E,0,00,0.0,0.000,M,-0.000,M,,*70"))
        val g = "GPGGA,123519.00,3702.07000000,N,02725.83000000,E,4,12,0.8,45.123,M,36.500,M,1.0,0000"
        var c = 0; g.forEach { c = c xor it.code }
        Nmea.parse("$" + g + "*%02X".format(c))
        println("TMOUT gga fix=${Gnss.fix} lat=${Gnss.lat} lon=${Gnss.lon} h=${Gnss.ellHeight} age=${Gnss.diffAge}")
        println("TMOUT parse " + PointStore.parseLine("P12;512345,123;4101234,567"))
        println("TMOUT parse2 " + PointStore.parseLine("P12 512345.123 4101234.567 12.5"))
    }
}
