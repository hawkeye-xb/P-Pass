package android.util;

// NET-19 行为测试桩：JVM 单测的 mockable android.jar 里 Log.* 一律抛
// Stub!，而 NativeFlowDeliveryPort 的交付循环合法地写日志——要在 JVM
// 里驱动真 start()/stop()，需要它不炸。test 源集同名类在 classpath 上
// 先于 mockable jar（仓内 IrohBlobsProviderBridgeTest 同款思路的类级
// 影子），全 no-op 实现只影响单测运行时，不进任何产物。
public final class Log {
    private Log() {}

    public static int v(String tag, String msg) { return 0; }
    public static int v(String tag, String msg, Throwable tr) { return 0; }
    public static int d(String tag, String msg) { return 0; }
    public static int d(String tag, String msg, Throwable tr) { return 0; }
    public static int i(String tag, String msg) { return 0; }
    public static int i(String tag, String msg, Throwable tr) { return 0; }
    public static int w(String tag, String msg) { return 0; }
    public static int w(String tag, String msg, Throwable tr) { return 0; }
    public static int w(String tag, Throwable tr) { return 0; }
    public static int e(String tag, String msg) { return 0; }
    public static int e(String tag, String msg, Throwable tr) { return 0; }
    public static int println(String tag, String msg) { return 0; }
    public static boolean isLoggable(String tag, int level) { return false; }
    public static String getStackTraceString(Throwable tr) { return ""; }
}
