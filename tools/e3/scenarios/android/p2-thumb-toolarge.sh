# A-P2：桩回 4000×3000 的缩略图 → 手机拒收（TooLarge）、内存增量 < 100MB、不崩。反证：还原后正常显示。
DESC="超尺寸缩略图被拒收、不爆内存；还原后正常（注入类，带反证）"
KIND=big
source "$E3_LIB/android-thumb.sh"
