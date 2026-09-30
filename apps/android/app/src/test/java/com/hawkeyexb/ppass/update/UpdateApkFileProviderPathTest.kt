package com.hawkeyexb.ppass.update

import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * 下载好的更新 APK 必须能被 FileProvider 映射成 content:// URI，否则系统安装器
 * 根本拉不起来。
 *
 * 2026-09-30 三星真机（0.6.0-test.2 release 与 main debug 同样复现）：APK 完整
 * 下载 60932766 字节，随后 `FileProvider.getUriForFile` 抛
 * `StringIndexOutOfBoundsException: length=53; index=54`，安装器从未出现。
 * 原因：`<cache-path path="ppass-update.apk">` 把**文件本身**声明成了根目录。
 * androidx 的 SimplePathStrategy 找到根之后按「根不以 / 结尾就再跳过一个分隔符」
 * 截取相对路径——文件路径和根路径等长，截取越界。
 *
 * 这里不跑 FileProvider（本仓无 Robolectric），而是钉住它的前提：APK 所在路径
 * 必须严格位于某个 `<cache-path>` 声明的目录**之下**（不能等于它）。
 *
 * 反证：把 file_paths.xml 的 update 条目改回 `path="ppass-update.apk"`，或把
 * [updateApkFile] 改回直接放在 cacheDir 根下，本测试红。
 */
class UpdateApkFileProviderPathTest {

    private fun appMain(): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found above ${System.getProperty("user.dir")}")
        }
        return File(dir, "apps/android/app/src/main")
    }

    /** file_paths.xml 里所有 `<cache-path>` 的 path 属性。 */
    private fun cachePathRoots(): List<String> {
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File(appMain(), "res/xml/file_paths.xml"))
        val nodes = doc.getElementsByTagName("cache-path")
        return (0 until nodes.length).map { (nodes.item(it) as Element).getAttribute("path") }
    }

    @Test
    fun update_apk_sits_strictly_inside_a_declared_cache_path_directory() {
        val cacheDir = File("/data/user/0/com.hawkeyexb.ppass/cache")
        val apk = updateApkFile(cacheDir).path
        val roots = cachePathRoots().map { File(cacheDir, it).path.trimEnd('/') }
        assertTrue(
            "更新 APK $apk 不在任何 <cache-path> 目录之下（声明的根：$roots）；" +
                "FileProvider.getUriForFile 会越界抛异常，安装器拉不起来",
            roots.any { apk.startsWith("$it/") },
        )
    }

    /**
     * 第二道坎：targetSdk ≥ 26 时不声明 REQUEST_INSTALL_PACKAGES，系统安装器收到
     * ACTION_VIEW 后约 0.1 秒自行退出、不提示（同日三星真机：修好路径后 InstallStart
     * 起来又立刻销毁；加上声明后才出现「允许安装未知应用」→ 安装确认页）。
     * 这里只钉「接线还在」，行为证据在 PR 的真机记录里。
     *
     * 反证：删掉 manifest 里这一行，本测试红。
     */
    @Test
    fun manifest_declares_request_install_packages() {
        val manifest = File(appMain(), "AndroidManifest.xml").readText()
        assertTrue(
            "manifest 缺 <uses-permission android:name=\"android.permission.REQUEST_INSTALL_PACKAGES\" />",
            manifest.contains("android:name=\"android.permission.REQUEST_INSTALL_PACKAGES\""),
        )
    }
}
