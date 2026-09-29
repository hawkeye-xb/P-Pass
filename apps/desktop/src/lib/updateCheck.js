// REL-07: test 通道 manifest 响应分类（纯函数，vitest 覆盖）。
//
// 404 = 真的没有 test release（Worker 答「no test release」）→ 无更新；
// 其它非 2xx（Worker 502 = 上游 GitHub 出错/限流）→ 检查**失败**，
// 不能报成「已是最新」。
export function testManifestOutcome(status) {
  if (status >= 200 && status < 300) return "ok";
  if (status === 404) return "none";
  return "failed";
}
