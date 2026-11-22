use std::process::Command;

fn main() {
    #[cfg(target_os = "macos")]
    {
        if let Ok(output) = Command::new("clang").arg("--print-resource-dir").output() {
            if output.status.success() {
                let dir = String::from_utf8_lossy(&output.stdout).trim().to_string();
                println!("cargo:rustc-link-search={dir}/lib/darwin");
                println!("cargo:rustc-link-lib=clang_rt.osx");
            }
        }
    }
}
