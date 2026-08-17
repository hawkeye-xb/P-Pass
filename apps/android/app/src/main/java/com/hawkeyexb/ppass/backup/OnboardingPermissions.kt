// Onboarding「系统权限」步骤（配对成功后插入的三步 onboarding 第一步）：
// 只问读取照片——必需，不给不能继续（网格/大图/备份全部依赖它）。
//
// 2026-08-17（用户复核后收缩）：这一步原来还打算顺带问「发送通知」和
// 「忽略电池优化」，上线看了实机效果后用户拍板去掉——理由是①这两项
// 本身可跳过，占一屏 onboarding 换来的只是「弹窗前多一句解释」，不值
// 这一步；②即使去掉，既有的契机式提醒机制已经能接住：电池优化走
// DOG-02（HomeScreen 的白名单卡，未加白时常驻显示，跟 onboarding 完全
// 独立、不依赖这里）；通知走 HomeScreen 的 notificationSkipped 卡（同样
// 只看 `hasNotificationPermission` 现状，不依赖这里）。因此原来那套
// 「问过一次不再问」的持久化状态（OnboardingAskState/
// OnboardingPermissionsStore）和判定函数
// （shouldOfferNotificationPermission/shouldOfferBatteryWhitelist）整个
// 没有消费者了，一并删除，不留死代码。
package com.hawkeyexb.ppass.backup

/** 读取照片必需——不给就不能往下走（网格/大图/备份全部依赖它）。 */
fun onboardingCanContinue(photoGranted: Boolean): Boolean = photoGranted
