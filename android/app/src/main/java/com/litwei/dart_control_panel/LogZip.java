package com.litwei.dart_control_panel;

import java.io.*;
import java.util.*;
import java.util.zip.*;

/** Streaming ZIP creation: bounded memory; never mutates source records. */
public final class LogZip {
    private static final int MAX_FILES = 10000;
    private static void collect(File root, File dir, List<File> files, int depth) throws IOException {
        if (depth > 32) throw new IOException("日志目录层级过深");
        File[] children = dir.listFiles();
        if (children == null) throw new IOException("无法读取日志目录");
        Arrays.sort(children, Comparator.comparing(File::getName));
        for (File child : children) {
            String name = child.getName().toLowerCase(Locale.ROOT);
            if (name.startsWith(".") || name.endsWith(".part") || name.endsWith(".tmp")) continue;
            // Do not follow symbolic links, including links within the log.
            if (!child.getCanonicalFile().equals(child.getAbsoluteFile())) continue;
            if (!child.getCanonicalPath().startsWith(root.getPath() + File.separator)) continue;
            if (child.isDirectory()) collect(root, child, files, depth + 1);
            else if (child.isFile()) {
                files.add(child);
                if (files.size() > MAX_FILES) throw new IOException("单次日志文件数过多");
            }
        }
    }
    public static File create(File directory, File outputRoot) throws IOException {
        File source = directory.getCanonicalFile();
        if (!source.isDirectory()) throw new IOException("日志目录不存在");
        File cache = outputRoot.getCanonicalFile();
        if (cache.equals(source) || cache.getPath().startsWith(source.getPath() + File.separator))
            throw new IOException("压缩输出不能位于日志目录内");
        if (!cache.isDirectory() && !cache.mkdirs()) throw new IOException("无法创建分享缓存");
        List<File> files = new ArrayList<>();
        collect(source, source, files, 0);
        if (files.isEmpty()) throw new IOException("没有可分享的完整日志文件");
        String label = source.getName().replaceAll("[^a-zA-Z0-9_\\p{IsHan}.\\-]", "_");
        if (label.isEmpty()) label = "log";
        if (label.length() > 80) label = label.substring(0, 80);
        File target = new File(cache, label + "_" + UUID.randomUUID() + ".zip");
        File part = new File(target.getPath() + ".part");
        boolean done = false;
        try {
            try (ZipOutputStream zip = new ZipOutputStream(new BufferedOutputStream(new FileOutputStream(part)))) {
                zip.setLevel(Deflater.BEST_SPEED);
                byte[] buffer = new byte[64 * 1024];
                for (File file : files) {
                    if (!file.getCanonicalFile().equals(file.getAbsoluteFile())) throw new IOException("日志文件路径已变化");
                    long length = file.length(), modified = file.lastModified();
                    String relative = file.getPath().substring(source.getPath().length() + 1).replace(File.separatorChar, '/');
                    ZipEntry entry = new ZipEntry(label + "/" + relative);
                    entry.setTime(modified);
                    zip.putNextEntry(entry);
                    long copied = 0;
                    try (InputStream input = new BufferedInputStream(new FileInputStream(file))) {
                        int n;
                        while ((n = input.read(buffer)) != -1) {
                            if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException("压缩已中断");
                            zip.write(buffer, 0, n); copied += n;
                        }
                    }
                    zip.closeEntry();
                    if (copied != length || file.length() != length || file.lastModified() != modified)
                        throw new IOException("日志仍在写入，请结束记录后再分享");
                }
            }
            if (!part.renameTo(target)) throw new IOException("无法完成日志压缩");
            done = true;
            return target;
        } finally {
            if (!done) { part.delete(); target.delete(); }
        }
    }
    private LogZip() {}
}
