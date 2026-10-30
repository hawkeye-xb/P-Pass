//! 解码子进程：从 stdin 读一张图，向 stdout 写像素，然后退出。
fn main() {
    std::process::exit(decode_worker::main_stdio());
}
