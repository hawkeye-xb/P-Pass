package com.hawkeyexb.ppass.io

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * 写盘的最后一步：把写好的 [tmp] 原子地换成 [target]，[target] 已存在就覆盖。
 * 返回是否成功，调用方照旧 `check(atomicReplace(tmp, file)) { "cannot persist …" }`。
 *
 * 各 store 原先用 `tmp.renameTo(target)`，它依赖的是 POSIX rename(2) 的「覆盖已存在目标」
 * 语义——`java.io.File.renameTo` 本身不承诺这一点（Windows 的 JVM 上目标存在就返回 false，
 * 于是 JVM 单测在 Windows 上第二次写必失败）。这里显式要求原子 + 覆盖（API 26 起可用，
 * minSdk 即 26）；同目录内的移动在 Android 上就是一次 rename(2)，行为与原先相同。
 */
fun atomicReplace(tmp: File, target: File): Boolean =
    try {
        Files.move(
            tmp.toPath(),
            target.toPath(),
            StandardCopyOption.ATOMIC_MOVE,
            StandardCopyOption.REPLACE_EXISTING,
        )
        true
    } catch (e: IOException) {
        false
    }
