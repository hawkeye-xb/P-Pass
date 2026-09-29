// #481：向导第 3 步必须如实告知点「完成」后 macOS 会出现什么——
// 开机自启只是通知；本地网络是要用户点「允许」的系统弹窗，系统显示的
// 名字是 ppf-daemon（0.6.1-test.1 实测），界面会先进首页；拒绝后给出
// 系统设置里的恢复路径。
//
// 反证：把第 3 步表格还原成只有「会申请什么：开机自启…」一行，
// 本文件除「不会做什么/如果被拦」外的断言全部变红。
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";

const src = readFileSync(new URL("./Wizard.svelte", import.meta.url), "utf8").replace(
  /\r\n/g,
  "\n",
);
// 只看第 3 步的模板（去掉 HTML 注释，免得注释里的字样让断言假绿）。
const start = src.indexOf("{:else if step === 3}");
const step3 = src.slice(start, src.indexOf("{/if}", start)).replace(/<!--[\s\S]*?-->/g, "");

describe("#481 向导第 3 步：如实告知本地网络弹窗", () => {
  it("能定位到第 3 步模板", () => {
    expect(start).toBeGreaterThan(0);
    expect(step3).toContain("finishSetup");
  });

  it("明确说出本地网络弹窗、要点「允许」", () => {
    expect(step3).toContain("本地网络");
    expect(step3).toContain("请点「允许」");
  });

  it("写出用户实际看到的名字 ppf-daemon，并说明它就是 P-Pass 的后台服务", () => {
    expect(step3).toContain("允许“ppf-daemon”查找本地网络中的设备？");
    expect(step3).toContain("ppf-daemon 就是 P-Pass 的后台服务");
  });

  it("说明界面会先进首页、弹窗照样要点（#481 的困惑点）", () => {
    expect(step3).toContain("界面会先进入首页");
  });

  it("说明拒绝的后果与恢复入口", () => {
    expect(step3).toContain("没法直连");
    expect(step3).toContain("「系统设置 → 隐私与安全性 → 本地网络」把 ppf-daemon 打开");
  });

  it("开机自启标成只是通知，不再用「会申请什么」笼统一行", () => {
    expect(step3).not.toContain("会申请什么");
    expect(step3).toContain("只是通知");
    expect(step3).toContain("「后台项目已添加」");
  });

  it("其它两行保留", () => {
    expect(step3).toContain("不会做什么");
    expect(step3).toContain("如果被拦");
  });
});
