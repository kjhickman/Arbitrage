#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
compile_error!("arbitrage-companion supports only macOS and Windows");

use tray_icon::{
    Icon, TrayIcon, TrayIconBuilder,
    menu::{Menu, MenuEvent, MenuId, MenuItem, PredefinedMenuItem},
};
use winit::{
    application::ApplicationHandler,
    event::{StartCause, WindowEvent},
    event_loop::{ActiveEventLoop, EventLoop},
    window::WindowId,
};

enum UserEvent {
    Menu(MenuEvent),
}

struct Application {
    menu: Option<Menu>,
    quit_id: MenuId,
    tray_icon: Option<TrayIcon>,
}

impl Application {
    fn new() -> Self {
        let menu = Menu::new();
        let app_info = MenuItem::new(
            format!("Arbitrage Companion v{}", env!("CARGO_PKG_VERSION")),
            false,
            None,
        );
        let separator = PredefinedMenuItem::separator();
        let quit = MenuItem::new("Quit", true, None);

        menu.append_items(&[&app_info, &separator, &quit])
            .expect("failed to create tray menu");

        Self {
            menu: Some(menu),
            quit_id: quit.id().clone(),
            tray_icon: None,
        }
    }

    fn create_tray_icon(&mut self) {
        let menu = self.menu.take().expect("tray menu already used");
        self.tray_icon = Some(
            TrayIconBuilder::new()
                .with_menu(Box::new(menu))
                .with_tooltip("Arbitrage Companion")
                .with_icon(companion_icon())
                .with_icon_as_template(true)
                .build()
                .expect("failed to create tray icon"),
        );
    }
}

impl ApplicationHandler<UserEvent> for Application {
    fn resumed(&mut self, _event_loop: &ActiveEventLoop) {}

    fn new_events(&mut self, _event_loop: &ActiveEventLoop, cause: StartCause) {
        if cause != StartCause::Init {
            return;
        }

        self.create_tray_icon();

        #[cfg(target_os = "macos")]
        {
            use objc2_core_foundation::CFRunLoop;

            let run_loop = CFRunLoop::main().expect("main run loop is unavailable");
            CFRunLoop::wake_up(&run_loop);
        }
    }

    fn window_event(
        &mut self,
        _event_loop: &ActiveEventLoop,
        _window_id: WindowId,
        _event: WindowEvent,
    ) {
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, event: UserEvent) {
        let UserEvent::Menu(event) = event;
        if event.id == self.quit_id {
            self.tray_icon.take();
            event_loop.exit();
        }
    }
}

fn main() {
    let mut event_loop_builder = EventLoop::<UserEvent>::with_user_event();

    #[cfg(target_os = "macos")]
    {
        use winit::platform::macos::{ActivationPolicy, EventLoopBuilderExtMacOS};

        event_loop_builder.with_activation_policy(ActivationPolicy::Accessory);
    }

    let event_loop = event_loop_builder
        .build()
        .expect("failed to create event loop");
    let proxy = event_loop.create_proxy();
    MenuEvent::set_event_handler(Some(move |event| {
        let _ = proxy.send_event(UserEvent::Menu(event));
    }));

    event_loop
        .run_app(&mut Application::new())
        .expect("event loop failed");
}

fn companion_icon() -> Icon {
    const SIZE: u32 = 32;
    const CENTER: f32 = (SIZE - 1) as f32 / 2.0;
    const OUTER_RADIUS_SQUARED: f32 = 15.0 * 15.0;
    const INNER_RADIUS_SQUARED: f32 = 12.0 * 12.0;

    let mut rgba = Vec::with_capacity((SIZE * SIZE * 4) as usize);

    for y in 0..SIZE {
        for x in 0..SIZE {
            let dx = x as f32 - CENTER;
            let dy = y as f32 - CENTER;
            let distance_squared = dx * dx + dy * dy;

            let pixel = if distance_squared > OUTER_RADIUS_SQUARED {
                [0, 0, 0, 0]
            } else if distance_squared > INNER_RADIUS_SQUARED {
                [126, 82, 16, 255]
            } else {
                [241, 183, 45, 255]
            };

            rgba.extend_from_slice(&pixel);
        }
    }

    Icon::from_rgba(rgba, SIZE, SIZE).expect("generated tray icon is invalid")
}
