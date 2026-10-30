package com.hawkeyexb.ppass.testutil

import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.AclEntry
import java.nio.file.attribute.AclEntryPermission
import java.nio.file.attribute.AclEntryType
import java.nio.file.attribute.AclFileAttributeView
import java.nio.file.attribute.PosixFileAttributeView

/**
 * 模拟「存储满」：目录里已有的文件照样能读，之后在这个目录里新建、写文件一律失败。
 *
 * POSIX（Linux CI、macOS）：去掉目录的写权限。
 * Windows：目录不认只读属性（`setWritable(false)` 不生效），改为给目录加一条
 * 「拒绝当前所有者新建文件 / 子目录」的 ACL 项——读不受影响，与 POSIX 的效果一致。
 * 两种都是真实的文件系统拒绝，store 走的是真实的写盘失败路径。
 */
object WriteBlock {
    fun block(dir: File) {
        val path = dir.toPath()
        if (Files.getFileAttributeView(path, PosixFileAttributeView::class.java) != null) {
            check(dir.setWritable(false))
        } else {
            val view = checkNotNull(Files.getFileAttributeView(path, AclFileAttributeView::class.java)) {
                "neither POSIX permissions nor ACLs on $dir"
            }
            view.acl = listOf(denyWrites(path)) + view.acl
        }
        check(!File(dir, "probe").let { runCatching { it.writeText("x") }.isSuccess }) {
            "write-blocked dir is writable (running as root?)"
        }
    }

    fun unblock(dir: File) {
        val path = dir.toPath()
        if (Files.getFileAttributeView(path, PosixFileAttributeView::class.java) != null) {
            check(dir.setWritable(true))
        } else {
            val view = Files.getFileAttributeView(path, AclFileAttributeView::class.java) ?: return
            val deny = denyWrites(path)
            view.acl = view.acl.filterNot { it == deny }
        }
    }

    private fun denyWrites(path: java.nio.file.Path): AclEntry =
        AclEntry.newBuilder()
            .setType(AclEntryType.DENY)
            .setPrincipal(Files.getOwner(path))
            .setPermissions(AclEntryPermission.ADD_FILE, AclEntryPermission.ADD_SUBDIRECTORY)
            .build()
}
