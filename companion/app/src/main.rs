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

mod saved_variables;
mod sign_in;
mod sync;

const DEFAULT_WORKER_URL: &str = "http://127.0.0.1:8787";
const WORKER_CHECK_ATTEMPTS: usize = 120;
const WORKER_CHECK_DELAY: Duration = Duration::from_millis(500);
const WORKER_REQUEST_TIMEOUT: Duration = Duration::from_secs(2);
const SYNC_REQUEST_TIMEOUT: Duration = Duration::from_mins(1);

enum UserEvent {
    Menu(MenuEvent),
    WorkerCheckFinished(WorkerStatus),
    BattleNet(BattleNetUpdate),
    Sync(Result<saved_variables::StoreOutcome, String>),
}

enum BattleNetUpdate {
    SignedIn {
        battletag: String,
        session: sign_in::Session,
    },
    Failed(String),
    SignedOut,
}

enum WorkerStatus {
    Connected(String),
    Unavailable,
}

struct Application {
    menu: Option<Menu>,
    worker_status: MenuItem,
    retry: MenuItem,
    battle_net_status: MenuItem,
    sign_in: MenuItem,
    sign_out: MenuItem,
    sync_status: MenuItem,
    sync: MenuItem,
    quit_id: MenuId,
    tray_icon: Option<TrayIcon>,
    worker_check: Option<thread::JoinHandle<()>>,
    battle_net_task: Option<thread::JoinHandle<()>>,
    sync_task: Option<thread::JoinHandle<()>>,
    battle_net_session: Option<sign_in::Session>,
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
        let battle_net_status = MenuItem::new("Battle.net: signed out", false, None);
        let sign_in = MenuItem::new("Sign in with Battle.net", true, None);
        let sign_out = MenuItem::new("Sign out", false, None);
        let sync_status = MenuItem::new("Sync: ready", false, None);
        let sync = MenuItem::new("Sync", false, None);
        let separator = PredefinedMenuItem::separator();
        let quit = MenuItem::new("Quit", true, None);

        menu.append_items(&[
            &app_info,
            &worker_status,
            &retry,
            &battle_net_status,
            &sign_in,
            &sign_out,
            &sync_status,
            &sync,
            &separator,
            &quit,
        ])
        .expect("failed to create tray menu");

        Self {
            menu: Some(menu),
            worker_status,
            retry,
            battle_net_status,
            sign_in,
            sign_out,
            sync_status,
            sync,
            quit_id: quit.id().clone(),
            tray_icon: None,
            worker_check: None,
            battle_net_task: None,
            sync_task: None,
            battle_net_session: None,
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

    fn start_sign_in(&mut self) {
        if self.battle_net_task.is_some() || self.sync_task.is_some() {
            return;
        }
        self.sign_in.set_enabled(false);
        self.sign_out.set_enabled(false);
        self.sync.set_enabled(false);
        self.battle_net_status
            .set_text("Battle.net: opening browser…");

        let proxy = self.event_proxy.clone();
        let worker_url = self.worker_url.clone();
        self.battle_net_task = Some(thread::spawn(move || {
            let agent = worker_agent();
            let update = match sign_in::start(&agent, &worker_url) {
                Ok((session, account)) => BattleNetUpdate::SignedIn {
                    battletag: account.battletag,
                    session,
                },
                Err(error) => BattleNetUpdate::Failed(sign_in_message(error)),
            };
            let _ = proxy.send_event(UserEvent::BattleNet(update));
        }));
    }

    fn start_sign_out(&mut self) {
        let Some(session) = self.battle_net_session.clone() else {
            return;
        };
        if self.battle_net_task.is_some() || self.sync_task.is_some() {
            return;
        }
        self.sign_in.set_enabled(false);
        self.sign_out.set_enabled(false);
        self.sync.set_enabled(false);
        self.battle_net_status.set_text("Battle.net: signing out…");

        let proxy = self.event_proxy.clone();
        let worker_url = self.worker_url.clone();
        self.battle_net_task = Some(thread::spawn(move || {
            let agent = worker_agent();
            let update = match sign_in::sign_out(&agent, &worker_url, &session) {
                Ok(()) => BattleNetUpdate::SignedOut,
                Err(error) => BattleNetUpdate::Failed(sign_in_message(error)),
            };
            let _ = proxy.send_event(UserEvent::BattleNet(update));
        }));
    }

    fn start_sync(&mut self) {
        let Some(session) = self.battle_net_session.clone() else {
            return;
        };
        if self.battle_net_task.is_some() || self.sync_task.is_some() {
            return;
        }
        self.sync_status.set_text("Sync: working…");
        self.sync.set_enabled(false);
        self.sign_in.set_enabled(false);
        self.sign_out.set_enabled(false);

        let proxy = self.event_proxy.clone();
        let worker_url = self.worker_url.clone();
        self.sync_task = Some(thread::spawn(move || {
            let agent = sync_agent();
            let result = sync::run(&agent, &worker_url, &session);
            let _ = proxy.send_event(UserEvent::Sync(result));
        }));
    }

    fn finish_battle_net(&mut self, update: BattleNetUpdate) {
        self.battle_net_task
            .take()
            .expect("Battle.net task is missing")
            .join()
            .expect("Battle.net task panicked");

        let sync_idle = self.sync_task.is_none();
        match update {
            BattleNetUpdate::SignedIn { battletag, session } => {
                self.battle_net_session = Some(session);
                self.battle_net_status
                    .set_text(format!("Battle.net: {battletag}"));
                self.sign_in.set_enabled(false);
                self.sign_out.set_enabled(sync_idle);
                self.sync.set_enabled(sync_idle);
            }
            BattleNetUpdate::Failed(message) => {
                self.battle_net_status
                    .set_text(format!("Battle.net: {message}"));
                self.sign_in
                    .set_enabled(self.battle_net_session.is_none() && sync_idle);
                self.sign_out
                    .set_enabled(self.battle_net_session.is_some() && sync_idle);
                self.sync
                    .set_enabled(self.battle_net_session.is_some() && sync_idle);
            }
            BattleNetUpdate::SignedOut => {
                self.battle_net_session = None;
                self.battle_net_status.set_text("Battle.net: signed out");
                self.sign_in.set_enabled(sync_idle);
                self.sign_out.set_enabled(false);
                self.sync_status.set_text("Sync: ready");
                self.sync.set_enabled(false);
            }
        }
    }

    fn finish_sync(&mut self, result: Result<saved_variables::StoreOutcome, String>) {
        self.sync_task
            .take()
            .expect("sync task is missing")
            .join()
            .expect("sync task panicked");

        match result {
            Ok(saved_variables::StoreOutcome::Written) => {
                self.sync_status.set_text("Sync: saved");
            }
            Ok(saved_variables::StoreOutcome::Unchanged) => {
                self.sync_status.set_text("Sync: already up to date");
            }
            Err(message) => {
                self.sync_status.set_text(format!("Sync: {message}"));
            }
        }

        let battle_net_idle = self.battle_net_task.is_none();
        self.sync
            .set_enabled(self.battle_net_session.is_some() && battle_net_idle);
        self.sign_in
            .set_enabled(self.battle_net_session.is_none() && battle_net_idle);
        self.sign_out
            .set_enabled(self.battle_net_session.is_some() && battle_net_idle);
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
            UserEvent::Menu(event) if event.id == *self.sign_in.id() => {
                self.start_sign_in();
            }
            UserEvent::Menu(event) if event.id == *self.sign_out.id() => {
                self.start_sign_out();
            }
            UserEvent::Menu(event) if event.id == *self.sync.id() => {
                self.start_sync();
            }
            UserEvent::Menu(_) => {}
            UserEvent::WorkerCheckFinished(status) => self.finish_worker_check(status),
            UserEvent::BattleNet(update) => self.finish_battle_net(update),
            UserEvent::Sync(result) => self.finish_sync(result),
        }
    }
}

fn worker_agent() -> Agent {
    let config = Agent::config_builder()
        .timeout_global(Some(WORKER_REQUEST_TIMEOUT))
        .build();
    Agent::new_with_config(config)
}

fn sync_agent() -> Agent {
    let config = Agent::config_builder()
        .timeout_global(Some(SYNC_REQUEST_TIMEOUT))
        .build();
    Agent::new_with_config(config)
}

fn sign_in_message(error: sign_in::SignInFailure) -> String {
    match error {
        sign_in::SignInFailure::Worker(message) => message,
        sign_in::SignInFailure::Denied => "Battle.net denied the sign-in.".to_owned(),
        sign_in::SignInFailure::Expired => "The sign-in expired.".to_owned(),
        sign_in::SignInFailure::Failed => "Battle.net sign-in failed.".to_owned(),
        sign_in::SignInFailure::Browser => "Could not open the browser.".to_owned(),
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
