#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
compile_error!("arbitrage-companion supports only macOS and Windows");

use std::{env, thread, time::Duration};
use tray_icon::{
    Icon, TrayIcon, TrayIconBuilder,
    menu::{Menu, MenuEvent, MenuId, MenuItem, PredefinedMenuItem},
};
use ureq::Agent;
use winit::{
    application::ApplicationHandler,
    event::{StartCause, WindowEvent},
    event_loop::{ActiveEventLoop, EventLoop, EventLoopProxy},
    window::WindowId,
};

const DEFAULT_WORKER_URL: &str = "http://127.0.0.1:8787";
const WORKER_CHECK_ATTEMPTS: usize = 120;
const WORKER_CHECK_DELAY: Duration = Duration::from_millis(500);
const WORKER_REQUEST_TIMEOUT: Duration = Duration::from_secs(2);

enum UserEvent {
    Menu(MenuEvent),
    WorkerCheckFinished(WorkerStatus),
}

enum WorkerStatus {
    Connected(String),
    Unavailable,
}

struct Application {
    menu: Option<Menu>,
    worker_status: MenuItem,
    retry: MenuItem,
    quit_id: MenuId,
    tray_icon: Option<TrayIcon>,
    worker_check: Option<thread::JoinHandle<()>>,
    event_proxy: EventLoopProxy<UserEvent>,
    worker_url: String,
}

impl Application {
    fn new(event_proxy: EventLoopProxy<UserEvent>, worker_url: String) -> Self {
        let menu = Menu::new();
        let app_info = MenuItem::new(
            format!("Arbitrage Companion v{}", env!("CARGO_PKG_VERSION")),
            false,
            None,
        );
        let worker_status = MenuItem::new("Worker: connecting…", false, None);
        let retry = MenuItem::new("Retry connection", false, None);
        let separator = PredefinedMenuItem::separator();
        let quit = MenuItem::new("Quit", true, None);

        menu.append_items(&[&app_info, &worker_status, &retry, &separator, &quit])
            .expect("failed to create tray menu");

        Self {
            menu: Some(menu),
            worker_status,
            retry,
            quit_id: quit.id().clone(),
            tray_icon: None,
            worker_check: None,
            event_proxy,
            worker_url,
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

    fn start_worker_check(&mut self) {
        if self.worker_check.is_some() {
            return;
        }

        self.worker_status.set_text("Worker: connecting…");
        self.retry.set_enabled(false);

        let proxy = self.event_proxy.clone();
        let worker_url = self.worker_url.clone();
        self.worker_check = Some(thread::spawn(move || {
            let status = wait_for_worker(&worker_url);
            let _ = proxy.send_event(UserEvent::WorkerCheckFinished(status));
        }));
    }

    fn finish_worker_check(&mut self, status: WorkerStatus) {
        self.worker_check
            .take()
            .expect("worker check is missing")
            .join()
            .expect("worker check panicked");

        match status {
            WorkerStatus::Connected(greeting) => {
                self.worker_status.set_text(format!("Worker: {greeting}"));
            }
            WorkerStatus::Unavailable => {
                self.worker_status.set_text("Worker: unavailable");
            }
        }

        self.retry.set_enabled(true);
    }
}

impl ApplicationHandler<UserEvent> for Application {
    fn resumed(&mut self, _event_loop: &ActiveEventLoop) {}

    fn new_events(&mut self, _event_loop: &ActiveEventLoop, cause: StartCause) {
        if cause != StartCause::Init {
            return;
        }

        self.create_tray_icon();
        self.start_worker_check();

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
        match event {
            UserEvent::Menu(event) if event.id == self.quit_id => {
                self.tray_icon.take();
                event_loop.exit();
            }
            UserEvent::Menu(event) if event.id == *self.retry.id() => {
                self.start_worker_check();
            }
            UserEvent::Menu(_) => {}
            UserEvent::WorkerCheckFinished(status) => self.finish_worker_check(status),
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
    let event_proxy = event_loop.create_proxy();
    let menu_proxy = event_proxy.clone();
    MenuEvent::set_event_handler(Some(move |event| {
        let _ = menu_proxy.send_event(UserEvent::Menu(event));
    }));

    let worker_url =
        env::var("ARBITRAGE_WORKER_URL").unwrap_or_else(|_| DEFAULT_WORKER_URL.to_owned());
    event_loop
        .run_app(&mut Application::new(event_proxy, worker_url))
        .expect("event loop failed");
}

fn wait_for_worker(worker_url: &str) -> WorkerStatus {
    let config = Agent::config_builder()
        .timeout_global(Some(WORKER_REQUEST_TIMEOUT))
        .build();
    let agent = Agent::new_with_config(config);

    for attempt in 1..=WORKER_CHECK_ATTEMPTS {
        if let Ok(greeting) = fetch_worker_greeting(&agent, worker_url) {
            return WorkerStatus::Connected(greeting);
        }

        if attempt < WORKER_CHECK_ATTEMPTS {
            thread::sleep(WORKER_CHECK_DELAY);
        }
    }

    WorkerStatus::Unavailable
}

fn fetch_worker_greeting(agent: &Agent, worker_url: &str) -> Result<String, ureq::Error> {
    agent.get(worker_url).call()?.body_mut().read_to_string()
}

fn companion_icon() -> Icon {
    const SIZE: u32 = 32;
    const BUFFER_LENGTH: usize = 32 * 32 * 4;
    const CENTER_TIMES_TWO: i64 = 31;
    const OUTER_DIAMETER_SQUARED: i64 = 30 * 30;
    const INNER_DIAMETER_SQUARED: i64 = 24 * 24;

    let mut rgba = Vec::with_capacity(BUFFER_LENGTH);

    for y in 0..SIZE {
        for x in 0..SIZE {
            let dx = i64::from(x) * 2 - CENTER_TIMES_TWO;
            let dy = i64::from(y) * 2 - CENTER_TIMES_TWO;
            let distance_squared = dx * dx + dy * dy;

            let pixel = if distance_squared > OUTER_DIAMETER_SQUARED {
                [0, 0, 0, 0]
            } else if distance_squared > INNER_DIAMETER_SQUARED {
                [126, 82, 16, 255]
            } else {
                [241, 183, 45, 255]
            };

            rgba.extend_from_slice(&pixel);
        }
    }

    Icon::from_rgba(rgba, SIZE, SIZE).expect("generated tray icon is invalid")
}
