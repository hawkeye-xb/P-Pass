// #1121：应用内更新的下载与安装走壳的具名命令（src-tauri/src/update_install.rs），
// 不再直接调 updater 插件的 download / install——那条路只有 minisign 验签，安装前没有
// 发布者校验，而且网页能绕开任何外加的检查。网页对插件只剩 check（展示版本与说明）。
//
// 返回的对象与插件 Update 的 download / install 同形，runUpdate（updateFlow.js）不用改。
import { Channel, invoke } from "@tauri-apps/api/core";

/** @param {{version: string}} update  插件 check() 返回的、界面上展示给用户的那个更新 */
export function verifiedUpdate(update) {
  return {
    download(onEvent) {
      const channel = new Channel();
      channel.onmessage = onEvent;
      // 壳会再查一次更新，版本必须与界面上的一致，否则拒绝（不装用户没看到的版本）。
      return invoke("update_download", { expected_version: update.version, on_event: channel });
    },
    install() {
      return invoke("update_install");
    },
  };
}
