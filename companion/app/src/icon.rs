use tray_icon::Icon;
use winit::event_loop::ActiveEventLoop;

#[cfg(target_os = "macos")]
pub fn tray(_event_loop: &ActiveEventLoop) -> Icon {
    let (rgba, width, height) = decode_png(include_bytes!("../assets/tray-macos.png"));
    Icon::from_rgba(rgba, width, height).expect("the tray icon should be RGBA")
}

#[cfg(target_os = "macos")]
fn decode_png(png: &[u8]) -> (Vec<u8>, u32, u32) {
    let mut reader = png::Decoder::new(std::io::Cursor::new(png))
        .read_info()
        .expect("the tray icon should be a PNG");
    let mut rgba = vec![
        0;
        reader
            .output_buffer_size()
            .expect("the tray icon should fit in memory")
    ];
    let frame = reader
        .next_frame(&mut rgba)
        .expect("the tray icon should decode");
    (rgba, frame.width, frame.height)
}

// The tray ICON ID in app.rc.
#[cfg(target_os = "windows")]
const TRAY_ICON_RESOURCE: u16 = 2;

// The sizes scripts/render-icons writes into windows/tray.ico.
#[cfg(target_os = "windows")]
const TRAY_ICON_SIZES: [u32; 6] = [16, 20, 24, 32, 40, 48];

#[cfg(target_os = "windows")]
pub fn tray(event_loop: &ActiveEventLoop) -> Icon {
    let scale = event_loop
        .primary_monitor()
        .map_or(1.0, |monitor| monitor.scale_factor());
    let size = TRAY_ICON_SIZES
        .into_iter()
        .find(|&size| f64::from(size) >= 16.0 * scale)
        .unwrap_or(TRAY_ICON_SIZES[TRAY_ICON_SIZES.len() - 1]);
    Icon::from_resource(TRAY_ICON_RESOURCE, Some((size, size)))
        .expect("the tray icon resource should be embedded")
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::decode_png;
    use tray_icon::Icon;

    #[test]
    fn the_tray_icon_is_a_36_pixel_rgba_image() {
        let (rgba, width, height) = decode_png(include_bytes!("../assets/tray-macos.png"));
        assert_eq!((width, height), (36, 36));
        assert!(Icon::from_rgba(rgba, width, height).is_ok());
    }
}
