"""sim-bg-task.sh 的调试器部分（#958）：附加到真机上已在前台的 PPass，造出「只剩短任务窗口」，再模拟系统拉起短任务。

用法（由 sim-bg-task.sh 调，PYTHONPATH=$(xcrun lldb -P)）：
    python3 sim-bg-task-lldb.py <devicectl 设备标识> <App pid> <daemon pid> <short-only|expire|budget> <拉日志用的命令> <N>

为什么这样做（真机 iPhone 16 / iOS 26.3 实测，2026-10-15）：
- `_simulateLaunchForTaskWithIdentifier:` 只是在进程里调一次 launch handler，**不附带系统的后台执行断言**（推断，
  依据：宽限期结束后调它，handler 跑起来约 4 秒后进程被 SIGKILL，exit 9；daemon 一直 STOP、没有任何传输时也一样；
  不调它、App 空闲时只是被挂起不被杀。拿不到设备 syslog，具体杀因不下结论）。所以 App 在后台时唯一真实的执行时间
  是宽限期（beginBackgroundTask）的系统断言，约 28 秒。
- 宽限期一过 App 被挂起，挂起后表达式报 `no JIT compiled function`（attach 与 devicectl --start-stopped 启动都一样）。
- 因此要造的状态是「系统断言还在，但 ExecutionWindow 不把它算进窗口」：断在 PPassApp.swift 里
  `backend.window.setFinishingTime(true)` 那一行，`thread jump --by 1` 跳过它，`beginBackgroundTask` 照常申请。
  窗口里只剩短任务：前台已关（scenePhase=.background 已经 setActive(false)）、宽限期窗口没开、长任务没开。
  先读 `backgroundTimeRemaining`，不足 25 秒判失败（20 秒预算要跑完）。
- daemon 在前台阶段一直 SIGSTOP（照片待传），叫醒短任务前 SIGCONT。
- 断点都在前台先下好：后台时间按秒算，现查符号（正则断点）要好几秒。
- expire：断在 `item start:`（这一张在飞），发 `_simulateExpirationForTaskWithIdentifier:`。
- budget：模拟拉起后不再停进程（20 秒预算是 Task.sleep，停住的时间也会算进去）。一次传不完就再叫醒：
  daemon SIGSTOP → App 回前台（前台那一轮只会「桌面不可达」）→ 切后台（nofinish 断点仍在）→ SIGCONT → 再模拟拉起，直到 N 张送达。
- 拿到 `short task: finished` 就断开调试器；之后宽限期断言到期、App 被挂起 / 杀掉是预期。
"""
import os
import shlex
import signal
import subprocess
import sys
import time

import lldb

SHORT_ID = "com.hawkeyexb.ppass.refresh"
BUNDLE_ID = "com.hawkeyexb.ppass"
DBG = None


def log(*a):
    print("  [lldb %s]" % time.strftime("%H:%M:%S"), *a, flush=True)


def cmd(c, quiet=False):
    ro = lldb.SBCommandReturnObject()
    DBG.GetCommandInterpreter().HandleCommand(c, ro)
    out = ((ro.GetOutput() or "") + (ro.GetError() or "")).strip()
    if not quiet:
        log("(lldb) %s%s" % (c, (" -> " + out[:300]) if out else ""))
    return ro.Succeeded(), out


def pump(proc, states, timeout):
    """异步模式下必须自己取事件，进程状态才会更新。"""
    t0 = time.time()
    lis = DBG.GetListener()
    while time.time() - t0 < timeout:
        ev = lldb.SBEvent()
        lis.WaitForEvent(1, ev)
        if proc.GetState() in states:
            return True
    return False


def resume(proc):
    proc.Continue()
    pump(proc, [lldb.eStateRunning], 10)


def wait_stop(proc, timeout, what):
    if not pump(proc, [lldb.eStateStopped, lldb.eStateExited], timeout):
        die("等 %s 超时（%ds）" % (what, timeout))
    if proc.GetState() == lldb.eStateExited:
        die("App 进程在等 %s 时退出了（exit status %d）" % (what, proc.GetExitStatus()))
    log("停在：%s" % what)


def expr_ok(e, what):
    ok, out = cmd("expr -l objc -- " + e)
    if not ok or "error" in out:
        die("%s 失败：%s" % (what, out))


def die(msg):
    print("FAIL(lldb): " + msg, flush=True)
    sys.exit(2)


def main():
    global DBG
    dev, pid, daemon_pid, mode, pull = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]  # argv[6] = N
    DBG = lldb.SBDebugger.Create()
    DBG.SetAsync(True)
    cmd("device select " + dev)
    cmd("device process attach --pid %d" % pid)
    proc = DBG.GetSelectedTarget().GetProcess()
    wait_stop(proc, 60, "附加")
    expr_ok("(int)getpid()", "前台表达式预热")
    # 网络代码会收到 SIGPIPE 等信号：调试器默认停下，App 就卡住了。只透传、不停。
    cmd("process handle -s false -n false -p true SIGPIPE SIGUSR1 SIGUSR2 SIGALRM SIGURG SIGCHLD SIGIO")
    # 断点都在前台先下好（后台里时间按秒算，现查符号要好几秒）。
    # nofinish：App 进后台时「打开宽限期窗口」那一行——跳过它，beginBackgroundTask 照常申请（系统执行断言还在），
    # 只是 ExecutionWindow 不知道有这段时间。
    cmd("breakpoint set -p 'backend\\.window\\.setFinishingTime\\(true\\)' -f PPassApp.swift -N nofinish")
    if mode == "expire":
        cmd("breakpoint set -p 'log\\(\"item start:' -f FlowEngine.swift -N item2")
        cmd("breakpoint disable item2")
    resume(proc)

    def proc_log():
        """本进程（process start: pid=<pid>）的落盘日志。"""
        out = subprocess.run(shlex.split(pull), capture_output=True, text=True).stdout
        return out.split("process start: pid=%d " % pid)[-1]

    def to_background_and_wake():
        # 把 PPass 送到后台：前台换成「设置」。
        r = subprocess.run(["xcrun", "devicectl", "device", "process", "launch", "--device", dev, "com.apple.Preferences"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            die("把「设置」切到前台失败（手机锁屏？解锁后重跑）：%s" % (r.stderr or r.stdout).strip()[-300:])
        log("已切到后台")
        wait_stop(proc, 30, "进后台、打开宽限期窗口之前（PPassApp.swift setFinishingTime(true)）")
        ok, out = cmd("thread jump --by 1")
        if not ok:
            die("跳过 setFinishingTime(true) 失败：" + out)
        resume(proc)
        time.sleep(1.5)
        proc.Stop()
        wait_stop(proc, 15, "后台（系统断言在、宽限期窗口没开）")
        ok, out = cmd("expr -l objc -- (double)[[UIApplication sharedApplication] backgroundTimeRemaining]")
        try:
            remaining = float(out.split("=")[-1])
        except ValueError:
            die("读不到 backgroundTimeRemaining：" + out)
        if remaining < 25:
            die("系统给的后台时间只剩 %.1f 秒（< 25；短任务 20 秒预算要跑完）" % remaining)
        log("后台剩余执行时间 %.1f 秒" % remaining)
        os.kill(daemon_pid, signal.SIGCONT)
        log("daemon 已恢复（SIGCONT）")
        expr_ok('(void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"%s"]' % SHORT_ID, "模拟拉起短任务")

    def wait_finished(n_finished):
        """等第 n_finished 个 `short task: finished` 出现。宽限期断言约 30 秒后到期，之后 App 被挂起是预期。"""
        deadline = time.time() + 45
        while time.time() < deadline:
            pump(proc, [], 0.5)
            state = proc.GetState()
            if state == lldb.eStateStopped:  # 意外停下（信号等）：记下来并继续，不让 App 卡住
                log("意外停下：%s；继续" % proc.GetSelectedThread().GetStopDescription(200))
                resume(proc)
                continue
            if state == lldb.eStateExited:
                die("App 进程在短任务结束前退出了（exit status %d，%s）" % (proc.GetExitStatus(), proc.GetExitDescription()))
            if proc_log().count("short task: finished") >= n_finished:
                return True
        return False

    to_background_and_wake()
    if mode == "expire":
        cmd("breakpoint enable item2", quiet=True)
        resume(proc)
        wait_stop(proc, 40, "item start（这一张在飞）")
        cmd("breakpoint delete item2", quiet=True)
        expr_ok('(void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:@"%s"]' % SHORT_ID,
                "模拟系统喊停")
    resume(proc)
    done = wait_finished(1)

    # budget：一次短任务传不完，就再叫醒下一次，直到 N 张都送达（最多 PPASS_BGTEST_MAX_WAKES 次）。
    # 两次之间要回一趟前台才能再拿到一段后台断言：回前台前先 SIGSTOP daemon，前台那一轮只会以「桌面不可达」收场、不传任何东西；
    # 等它收场再切后台（nofinish 断点还在，照样跳过宽限期窗口）。
    if mode == "budget" and done:
        want = int(sys.argv[6])
        for wake in range(2, int(os.environ.get("PPASS_BGTEST_MAX_WAKES", "6")) + 1):
            text = proc_log()
            delivered = text.count("result=next")
            log("已送达 %d / %d 张" % (delivered, want))
            if delivered >= want:
                break
            os.kill(daemon_pid, signal.SIGSTOP)
            unreachable_before = text.count("desktop unreachable")
            r = subprocess.run(["xcrun", "devicectl", "device", "process", "launch", "--device", dev, BUNDLE_ID],
                               capture_output=True, text=True)
            if r.returncode != 0:
                die("把 PPass 切回前台失败：%s" % (r.stderr or r.stdout).strip()[-300:])
            log("第 %d 次：daemon 暂停，App 回前台，等前台那一轮以「桌面不可达」收场" % wake)
            t_end = time.time() + 45
            while time.time() < t_end:
                pump(proc, [], 0.5)
                if proc.GetState() == lldb.eStateStopped:
                    log("意外停下：%s；继续" % proc.GetSelectedThread().GetStopDescription(200))
                    resume(proc)
                    continue
                if proc_log().count("desktop unreachable") > unreachable_before:
                    break
            else:
                die("前台那一轮 45 秒内没以「桌面不可达」收场")
            to_background_and_wake()
            resume(proc)
            done = wait_finished(wake)
            if not done:
                break
    proc.Detach()
    log("已断开调试器" + ("" if done else "（等 short task: finished 超时）"))

main()
