//! 视频解码子进程：从 stdin 读 H.264 MP4 字节，向 stdout 写首帧像素，然后退出。
//! 仅在 Windows 上有真实解码（Media Foundation，经 platform）；非 Windows 端为桩。
fn main() {
    std::process::exit(media_codec::video::main_stdio());
}
