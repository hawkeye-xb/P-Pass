//! 视频解码子进程：从 stdin 读 H.264 MP4 字节，向 stdout 写首帧像素，然后退出。
//! 仅在 Windows 上有真实解码（Media Foundation）；非 Windows 端编译为桩。
fn main() {
    std::process::exit(decode_worker::main_stdio_video());
}
