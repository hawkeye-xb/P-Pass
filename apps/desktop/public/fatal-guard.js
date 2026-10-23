// 白屏保险：任何未捕获错误直接显示在窗口里，而不是哑掉。
// #1120：从 index.html 的内联脚本挪出来——CSP 只允许本地打包的脚本文件
// （script-src 'self'），不允许内联脚本。CSP 拦截同样显示出来：被拦下的
// 东西就是坏掉的功能，不能让它静默失效。
(function () {
  function showFatal(msg) {
    var pre = document.createElement("pre");
    pre.style.cssText = "color:#a11212;padding:16px;white-space:pre-wrap;font-size:12px";
    pre.textContent = "前端错误：" + msg;
    document.body.appendChild(pre);
  }
  window.addEventListener("error", function (e) {
    showFatal(e.message + "\n" + (e.filename || "") + ":" + (e.lineno || ""));
  });
  window.addEventListener("unhandledrejection", function (e) {
    showFatal(String(e.reason));
  });
  document.addEventListener("securitypolicyviolation", function (e) {
    showFatal("CSP 拦截 " + e.effectiveDirective + "：" + (e.blockedURI || "inline") +
      (e.sourceFile ? "\n" + e.sourceFile + ":" + e.lineNumber : ""));
  });
})();
