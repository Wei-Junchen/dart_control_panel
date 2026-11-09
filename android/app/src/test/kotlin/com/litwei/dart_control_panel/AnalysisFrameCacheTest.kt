package com.litwei.dart_control_panel

import org.junit.Assert.*
import org.junit.Test
import java.io.File

class AnalysisFrameCacheTest {
    @Test fun supportsRandomAccessAndDeletesOnClose() {
        val file = File.createTempFile("analysis-test-", ".cache")
        val cache = AnalysisFrameCache(file)
        try {
            (1..10).forEach { cache.add(it, 4, 2, ByteArray(12) { _ -> it.toByte() }) }
            for (number in listOf(9, 1, 10, 5, 5)) {
                val actual = cache.read(number)
                assertEquals(number, actual.number)
                assertEquals(4, actual.width)
                assertEquals(2, actual.height)
                assertArrayEquals(ByteArray(12) { number.toByte() }, actual.nv21)
            }
            try { cache.read(11); fail("out of range") } catch (_: IllegalArgumentException) { }
        } finally { cache.close() }
        assertFalse(file.exists())
    }
    @Test fun enforcesSizeLimit() {
        val file = File.createTempFile("analysis-test-", ".cache")
        val cache = AnalysisFrameCache(file, 40)
        try {
            cache.add(1, 4, 2, ByteArray(12))
            try { cache.add(2, 4, 2, ByteArray(12)); fail("size limit") } catch (_: IllegalArgumentException) { }
        } finally { cache.close() }
        assertFalse(file.exists())
    }
}
