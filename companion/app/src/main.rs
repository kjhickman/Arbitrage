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

mod keychain;
mod saved_variables;
mod sign_in;
mod sync;
mod watch;

const DEFAULT_WORKER_URL: &str = "https://arbitrage-wow.fyi";
const WORKER_REQUEST_TIMEOUT: Duration = Duration::from_secs(2);
const SYNC_REQUEST_TIMEOUT: Duration = Duration::from_mins(1);

enum UserEvent {
    Menu(MenuEvent),
    BattleNet(BattleNetUpdate),
    Sync {
        result: Result<saved_variables::StoreOutcome, String>,
        automatic: bool,
    },
    SavedVariablesChanged,
}

enum BattleNetUpdate {
    SignedIn {
        battletag: String,
        session: sign_in::Session,
        persisted: bool,
    },
    SignedOut,
    Unchanged,
}

enum MenuView {
    SignedOut,
    SignedIn { battletag: String },
}

struct Application {
    sign_in: Option<MenuItem>,
    sign_out: Option<MenuItem>,
    quit_id: MenuId,
    sync_status_text: String,
    tray_icon: Option<TrayIcon>,
    battle_net_task: Option<thread::JoinHandle<()>>,
    sync_task: Option<thread::JoinHandle<()>>,
    battle_net_session: Option<sign_in::Session>,
    battletag: Option<String>,
    sync_needed: bool,
    preserve_saved_on_unchanged: bool,
    saved_variables_watch: Option<watch::Watch>,
    event_proxy: EventLoopProxy<UserEvent>,
    worker_url: String,
}

impl Application {
    fn new(event_proxy: EventLoopProxy<UserEvent>, worker_url: String) -> Self {
        Self {
            sign_in: None,
            sign_out: None,
            quit_id: MenuId::new(""),
            sync_status_text: String::new(),
            tray_icon: None,
            battle_net_task: None,
            sync_task: None,
            battle_net_session: None,
            battletag: None,
            sync_needed: false,
            preserve_saved_on_unchanged: false,
            saved_variables_watch: None,
            event_proxy,
            worker_url,
        }
    }

    fn show_menu(&mut self, view: MenuView) {
        let menu = Menu::new();
        let app_info = MenuItem::new(
            format!("Arbitrage Companion v{}", env!("CARGO_PKG_VERSION")),
            false,
            None,
        );
        let separator = PredefinedMenuItem::separator();
        let quit = MenuItem::new("Quit", true, None);
        self.quit_id = quit.id().clone();

        match view {
            MenuView::SignedOut => {
                let sign_in = MenuItem::new("Sign in with Battle.net", true, None);
                menu.append_items(&[&app_info, &sign_in, &separator, &quit])
                    .expect("failed to create tray menu");
                self.sign_in = Some(sign_in);
                self.sign_out = None;
            }
            MenuView::SignedIn { battletag } => {
                let status = MenuItem::new(battletag, false, None);
                let sign_out = MenuItem::new("Sign out", true, None);
                menu.append_items(&[&app_info, &status, &sign_out, &separator, &quit])
                    .expect("failed to create tray menu");
                self.sign_in = None;
                self.sign_out = Some(sign_out);
            }
        }

        if let Some(tray) = &self.tray_icon {
            tray.set_menu(Some(Box::new(menu)));
        }
    }

    fn create_tray_icon(&mut self) {
        self.tray_icon = Some(
            TrayIconBuilder::new()
                .with_tooltip("Arbitrage Companion")
                .with_icon(companion_icon())
                .with_icon_as_template(true)
                .build()
                .expect("failed to create tray icon"),
        );
        self.show_menu(MenuView::SignedOut);
    }

    fn start_saved_variables_watch(&mut self) {
        let Ok(path) = saved_variables::locate() else {
            return;
        };
        let Some(watch) = watch::Watch::start(&path, {
            let proxy = self.event_proxy.clone();
            move || {
                let _ = proxy.send_event(UserEvent::SavedVariablesChanged);
            }
        }) else {
            return;
        };
        self.saved_variables_watch = Some(watch);
    }

    fn on_saved_variables_changed(&mut self) {
        if self.sync_task.is_some() || self.battle_net_task.is_some() {
            self.sync_needed = true;
            return;
        }
        if self.battle_net_session.is_none() {
            self.sync_needed = true;
            return;
        }
        self.start_sync(true);
    }

    fn start_session_restore(&mut self) {
        if self.battle_net_task.is_some() || self.sync_task.is_some() {
            return;
        }

        let proxy = self.event_proxy.clone();
        let worker_url = self.worker_url.clone();
        self.battle_net_task = Some(thread::spawn(move || {
            let update = keychain::load().map_or(BattleNetUpdate::Unchanged, |session| {
                let agent = agent(WORKER_REQUEST_TIMEOUT);
                match sign_in::resume(&agent, &worker_url, &session) {
                    sign_in::Resume::SignedIn { battletag } => BattleNetUpdate::SignedIn {
                        battletag,
                        session,
                        persisted: true,
                    },
                    sign_in::Resume::Forget => {
                        let _ = keychain::delete();
                        BattleNetUpdate::Unchanged
                    }
                    sign_in::Resume::Unavailable => BattleNetUpdate::Unchanged,
                }
            });
            let _ = proxy.send_event(UserEvent::BattleNet(update));
        }));
    }

    fn start_sign_in(&mut self) {
        if self.battle_net_task.is_some() || self.sync_task.is_some() {
            return;
        }

        let proxy = self.event_proxy.clone();
        let worker_url = self.worker_url.clone();
        self.battle_net_task = Some(thread::spawn(move || {
            let agent = agent(WORKER_REQUEST_TIMEOUT);
            let update = match sign_in::start(&agent, &worker_url) {
                Some((session, battletag)) => {
                    let persisted = keychain::save(&session).is_ok();
                    BattleNetUpdate::SignedIn {
                        battletag,
                        session,
                        persisted,
                    }
                }
                None => BattleNetUpdate::Unchanged,
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

        let proxy = self.event_proxy.clone();
        let worker_url = self.worker_url.clone();
        self.battle_net_task = Some(thread::spawn(move || {
            let agent = agent(WORKER_REQUEST_TIMEOUT);
            let update =
                if sign_in::sign_out(&agent, &worker_url, &session) && keychain::delete().is_ok() {
                    BattleNetUpdate::SignedOut
                } else {
                    BattleNetUpdate::Unchanged
                };
            let _ = proxy.send_event(UserEvent::BattleNet(update));
        }));
    }

    fn start_sync(&mut self, automatic: bool) {
        let Some(session) = self.battle_net_session.clone() else {
            return;
        };
        if self.battle_net_task.is_some() || self.sync_task.is_some() {
            return;
        }
        self.sync_needed = false;
        self.preserve_saved_on_unchanged = automatic && self.sync_status_text == "Sync: saved";

        let proxy = self.event_proxy.clone();
        let worker_url = self.worker_url.clone();
        self.sync_task = Some(thread::spawn(move || {
            let agent = agent(SYNC_REQUEST_TIMEOUT);
            let result = sync::run(&agent, &worker_url, &session);
            let _ = proxy.send_event(UserEvent::Sync { result, automatic });
        }));
    }

    fn finish_battle_net(&mut self, update: BattleNetUpdate) {
        self.battle_net_task
            .take()
            .expect("Battle.net task is missing")
            .join()
            .expect("Battle.net task panicked");

        match update {
            BattleNetUpdate::SignedIn {
                battletag,
                session,
                persisted,
            } => {
                self.battle_net_session = Some(session);
                let label = if persisted {
                    battletag
                } else {
                    format!("{battletag} (not saved)")
                };
                self.battletag = Some(label.clone());
                self.show_menu(MenuView::SignedIn { battletag: label });
                if self.sync_needed && self.sync_task.is_none() {
                    self.start_sync(true);
                }
            }
            BattleNetUpdate::SignedOut => {
                self.battle_net_session = None;
                self.battletag = None;
                self.sync_needed = false;
                self.sync_status_text.clear();
                self.show_menu(MenuView::SignedOut);
            }
            BattleNetUpdate::Unchanged => {
                if let Some(battletag) = self.battletag.clone() {
                    self.show_menu(MenuView::SignedIn { battletag });
                } else {
                    self.show_menu(MenuView::SignedOut);
                }
            }
        }
    }

    fn finish_sync(
        &mut self,
        result: Result<saved_variables::StoreOutcome, String>,
        automatic: bool,
    ) {
        self.sync_task
            .take()
            .expect("sync task is missing")
            .join()
            .expect("sync task panicked");

        match result {
            Ok(saved_variables::StoreOutcome::Written) => {
                self.preserve_saved_on_unchanged = false;
                "Sync: saved".clone_into(&mut self.sync_status_text);
            }
            Ok(saved_variables::StoreOutcome::Unchanged) => {
                if automatic && self.preserve_saved_on_unchanged {
                    "Sync: saved".clone_into(&mut self.sync_status_text);
                } else {
                    "Sync: already up to date".clone_into(&mut self.sync_status_text);
                }
                self.preserve_saved_on_unchanged = false;
            }
            Err(message) => {
                self.preserve_saved_on_unchanged = false;
                self.sync_status_text = format!("Sync: {message}");
            }
        }

        if self.sync_needed && self.battle_net_session.is_some() && self.battle_net_task.is_none() {
            self.start_sync(true);
        }
    }
}

impl ApplicationHandler<UserEvent> for Application {
    fn resumed(&mut self, _event_loop: &ActiveEventLoop) {}

    fn new_events(&mut self, _event_loop: &ActiveEventLoop, cause: StartCause) {
        if cause != StartCause::Init {
            return;
        }

        self.create_tray_icon();
        self.start_saved_variables_watch();
        self.start_session_restore();

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
                self.saved_variables_watch.take();
                self.tray_icon.take();
                event_loop.exit();
            }
            UserEvent::Menu(event)
                if self
                    .sign_in
                    .as_ref()
                    .is_some_and(|item| event.id == *item.id()) =>
            {
                self.start_sign_in();
            }
            UserEvent::Menu(event)
                if self
                    .sign_out
                    .as_ref()
                    .is_some_and(|item| event.id == *item.id()) =>
            {
                self.start_sign_out();
            }
            UserEvent::Menu(_) => {}
            UserEvent::BattleNet(update) => self.finish_battle_net(update),
            UserEvent::Sync { result, automatic } => self.finish_sync(result, automatic),
            UserEvent::SavedVariablesChanged => self.on_saved_variables_changed(),
        }
    }
}

fn agent(timeout: Duration) -> Agent {
    let config = Agent::config_builder()
        .timeout_global(Some(timeout))
        .build();
    Agent::new_with_config(config)
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
