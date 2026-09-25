fn main() {
    println!("cargo::rerun-if-changed=app.rc");
    println!("cargo::rerun-if-changed=windows/app.ico");
    println!("cargo::rerun-if-changed=windows/tray.ico");

    #[cfg(target_os = "windows")]
    embed_resource::compile("app.rc", embed_resource::NONE)
        .manifest_required()
        .expect("the Windows icon resources should compile");
}
