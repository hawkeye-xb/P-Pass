package android.os;

// NET-19 行为测试桩：同 android/util/Log.java 的影子思路。等待循环用
// SystemClock.elapsedRealtime() 量「本地信号沉默了多久」，JVM 里换毫秒
// 时钟即可，语义（单调毫秒）不变。
public final class SystemClock {
    private SystemClock() {}

    public static long elapsedRealtime() { return System.currentTimeMillis(); }
    public static long uptimeMillis() { return System.nanoTime() / 1_000_000L; }
}
