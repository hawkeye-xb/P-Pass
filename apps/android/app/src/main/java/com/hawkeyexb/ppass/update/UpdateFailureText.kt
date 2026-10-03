// UPD-02: 失败类 → 用户文案的映射（纯函数，UpdateFailureTextTest 锁完备性
// 与互异性——新增失败类不加文案会红，两类共用一句也会红）。
package com.hawkeyexb.ppass.update

import com.hawkeyexb.ppass.R

fun failureTextRes(kind: UpdateFailureKind): Int = when (kind) {
    UpdateFailureKind.Network -> R.string.update_failed_network
    UpdateFailureKind.Server -> R.string.update_failed_server
    UpdateFailureKind.Stalled -> R.string.update_failed_stalled
    UpdateFailureKind.Write -> R.string.update_failed_write
    UpdateFailureKind.Verify -> R.string.update_failed_verify
    UpdateFailureKind.Install -> R.string.update_failed_install
    UpdateFailureKind.Unexpected -> R.string.update_failed_unexpected
}
