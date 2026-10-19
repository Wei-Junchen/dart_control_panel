package com.litwei.dart_control_panel;

import org.junit.Test;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;
import static org.junit.Assert.*;

public class LogZipTest {
    @Test public void completeSessionIncludesNestedMetadataVideoAndCsvWithoutChangingOriginals() throws Exception {
        Path temp = Files.createTempDirectory("log-zip-test");
        try {
            File log = new File(temp.toFile(), "10月18日_试飞"); log.mkdirs();
            File segment = new File(log, "0001"); segment.mkdir();
            Files.write(new File(log, "metadata.json").toPath(), "{\"started_at\":\"2026-10-18T00:00:00Z\"}".getBytes("UTF-8"));
            Files.write(new File(segment, "samples.csv").toPath(), "t,pitch\n0,12\n".getBytes("UTF-8"));
            byte[] video = new byte[100000]; new Random(42).nextBytes(video);
            File original = new File(log, "1.h264"); Files.write(original.toPath(), video);
            Files.write(new File(log, "unfinished.csv.part").toPath(), new byte[]{1});
            Files.write(new File(log, "metadata.json.tmp").toPath(), new byte[]{1});
            File result = LogZip.create(log, new File(temp.toFile(), "cache"));
            assertTrue(result.length() > 0);
            try (ZipFile zip = new ZipFile(result)) {
                assertEquals(3, zip.size());
                assertArrayEquals(video, zip.getInputStream(zip.getEntry(log.getName() + "/1.h264")).readAllBytes());
                assertTrue(zip.getEntry(log.getName() + "/metadata.json") != null);
                assertTrue(zip.getEntry(log.getName() + "/0001/samples.csv") != null);
            }
            assertArrayEquals(video, Files.readAllBytes(original.toPath()));
            assertTrue(new File(log, "unfinished.csv.part").exists());
            assertNotEquals(result, LogZip.create(log, result.getParentFile()));
        } finally { delete(temp); }
    }
    @Test public void excludesSymlinkTargetsAndRejectsRecursiveOutput() throws Exception {
        Path temp = Files.createTempDirectory("log-zip-safety");
        try {
            Path log = Files.createDirectory(temp.resolve("flight_1"));
            Files.write(log.resolve("metadata.json"), new byte[]{1});
            Path outside = Files.write(temp.resolve("unrelated.txt"), new byte[]{2});
            try { Files.createSymbolicLink(log.resolve("escape.txt"), outside); }
            catch (UnsupportedOperationException | IOException e) { org.junit.Assume.assumeNoException(e); }
            File result = LogZip.create(log.toFile(), temp.resolve("cache").toFile());
            try (ZipFile zip = new ZipFile(result)) { assertEquals(1, zip.size()); }
            try { LogZip.create(log.toFile(), log.resolve("output").toFile()); fail("recursive output accepted"); }
            catch (IOException expected) { }
        } finally { delete(temp); }
    }
    @Test public void emptyLogFailsWithoutLeavingPartialArchive() throws Exception {
        Path temp = Files.createTempDirectory("log-zip-empty");
        try {
            Path log = Files.createDirectory(temp.resolve("empty"));
            File cache = temp.resolve("cache").toFile();
            try { LogZip.create(log.toFile(), cache); fail("empty log accepted"); }
            catch (IOException expected) { }
            assertEquals(0, Objects.requireNonNull(cache.list()).length);
        } finally { delete(temp); }
    }
    private static void delete(Path root) throws IOException {
        try (java.util.stream.Stream<Path> entries = Files.walk(root)) {
            for (Path path : (Iterable<Path>) entries.sorted(Comparator.reverseOrder())::iterator) Files.deleteIfExists(path);
        }
    }
}
