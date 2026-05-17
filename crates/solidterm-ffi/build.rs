use std::path::PathBuf;

fn main() {
    let out_dir: PathBuf = std::env::var("OUT_DIR").unwrap().into();
    let bridges = vec!["src/bridge.rs"];
    for b in &bridges {
        println!("cargo:rerun-if-changed={b}");
    }
    swift_bridge_build::parse_bridges(bridges).write_all_concatenated(&out_dir, "solidterm_ffi");
}
