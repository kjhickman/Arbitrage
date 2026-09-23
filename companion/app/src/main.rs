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

const DEFAULT_WORKER_URL: &str = "http://127.0.0.1:8787";
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
    Failed(String),
    SignedOut,
    Idle,
}

struct Application {
    menu: Option<Menu>,
    battle_net_status: MenuItem,
    sign_in: MenuItem,
    sign_out: MenuItem,
    sync_status: MenuItem,
    sync_status_text: String,
    sync: MenuItem,
    quit_id: MenuId,
    tray_icon: Option<TrayIcon>,
    battle_net_task: Option<thread::JoinHandle<()>>,
    sync_task: Option<thread::JoinHandle<()>>,
    battle_net_session: Option<sign_in::Session>,
    sync_needed: bool,
    preserve_saved_on_unchanged: bool,
    saved_variables_watch: Option<watch::Watch>,
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
        let battle_net_status = MenuItem::new("Battle.net: signed out", false, None);
        let sign_in = MenuItem::new("Sign in with Battle.net", true, None);
        let sign_out = MenuItem::new("Sign out", false, None);
        let sync_status = MenuItem::new("Sync: ready", false, None);
        let sync = MenuItem::new("Sync", false, None);
        let separator = PredefinedMenuItem::separator();
        let quit = MenuItem::new("Quit", true, None);

        menu.append_items(&[
            &app_info,
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
            battle_net_status,
            sign_in,
            sign_out,
            sync_status,
            sync_status_text: "Sync: ready".to_owned(),
            sync,
            quit_id: quit.id().clone(),
            tray_icon: None,
            battle_net_task: None,
            sync_task: None,
            battle_net_session: None,
            sync_needed: false,
            preserve_saved_on_unchanged: false,
            saved_variables_watch: None,
            event_proxy,
            worker_url,
        }
    }

    fn set_sync_status(&mut self, text: &str) {
        self.sync_status.set_text(text);
        text.clone_into(&mut self.sync_status_text);
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

    fn start_saved_variables_watch(&mut self) {
        match saved_variables::locate() {
            Ok(path) => match watch::Watch::start(&path, {
                let proxy = self.event_proxy.clone();
                move || {
                    let _ = proxy.send_event(UserEvent::SavedVariablesChanged);
                }
            }) {
                Ok(watch) => {
                    self.saved_variables_watch = Some(watch);
                }
                Err(error) => {
                    self.set_sync_status(&error.to_string());
                }
            },
            Err(error) => {
                self.set_sync_status(&error.to_string());
            }
        }
    }

    fn on_saved_variables_changed(&mut self) {
        if self.sync_task.is_some() || self.battle_net_task.is_some() {
            self.sync_needed = true;
            return;
        }
        if self.battle_net_session.is_none() {
            self.sync_needed = true;
            self.set_sync_status("Sync: sign in to sync");
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
            let update = match keychain::load() {
                Ok(Some(session)) => {
                    let agent = worker_agent();
                    match sign_in::resume(&agent, &worker_url, &session) {
                        sign_in::Resume::SignedIn { battletag } => BattleNetUpdate::SignedIn {
                            battletag,
                            session,
                            persisted: true,
                        },
                        sign_in::Resume::Forget => {
                            let _ = keychain::delete();
                            BattleNetUpdate::Idle
                        }
                        sign_in::Resume::Unavailable => {
                            BattleNetUpdate::Failed("could not reach the worker".to_owned())
                        }
                    }
                }
                Ok(None) | Err(_) => BattleNetUpdate::Idle,
            };
            let _ = proxy.send_event(UserEvent::BattleNet(update));
        }));
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
                Ok((session, account)) => {
                    let persisted = keychain::save(&session).is_ok();
                    BattleNetUpdate::SignedIn {
                        battletag: account.battletag,
                        session,
                        persisted,
                    }
                }
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
                Ok(()) => match keychain::delete() {
                    Ok(()) => BattleNetUpdate::SignedOut,
                    Err(_) => BattleNetUpdate::Failed("could not forget the sign-in".to_owned()),
                },
                Err(error) => BattleNetUpdate::Failed(sign_in_message(error)),
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
        self.set_sync_status("Sync: working…");
        self.sync.set_enabled(false);
        self.sign_in.set_enabled(false);
        self.sign_out.set_enabled(false);

        let proxy = self.event_proxy.clone();
        let worker_url = self.worker_url.clone();
        self.sync_task = Some(thread::spawn(move || {
            let agent = sync_agent();
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

        let sync_idle = self.sync_task.is_none();
        match update {
            BattleNetUpdate::SignedIn {
                battletag,
                session,
                persisted,
            } => {
                self.battle_net_session = Some(session);
                let status = if persisted {
                    format!("Battle.net: {battletag}")
                } else {
                    format!("Battle.net: {battletag} (not saved)")
                };
                self.battle_net_status.set_text(status);
                self.sign_in.set_enabled(false);
                self.sign_out.set_enabled(sync_idle);
                self.sync.set_enabled(sync_idle);
                if self.sync_needed && sync_idle {
                    self.start_sync(true);
                }
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
                self.sync_needed = false;
                self.battle_net_status.set_text("Battle.net: signed out");
                self.sign_in.set_enabled(sync_idle);
                self.sign_out.set_enabled(false);
                self.set_sync_status("Sync: ready");
                self.sync.set_enabled(false);
            }
            BattleNetUpdate::Idle => {
                self.sign_in
                    .set_enabled(self.battle_net_session.is_none() && sync_idle);
                self.sign_out
                    .set_enabled(self.battle_net_session.is_some() && sync_idle);
                self.sync
                    .set_enabled(self.battle_net_session.is_some() && sync_idle);
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
                self.set_sync_status("Sync: saved");
            }
            Ok(saved_variables::StoreOutcome::Unchanged) => {
                if automatic && self.preserve_saved_on_unchanged {
                    self.set_sync_status("Sync: saved");
                } else {
                    self.set_sync_status("Sync: already up to date");
                }
                self.preserve_saved_on_unchanged = false;
            }
            Err(message) => {
                self.preserve_saved_on_unchanged = false;
                self.set_sync_status(&format!("Sync: {message}"));
            }
        }

        let battle_net_idle = self.battle_net_task.is_none();
        self.sync
            .set_enabled(self.battle_net_session.is_some() && battle_net_idle);
        self.sign_in
            .set_enabled(self.battle_net_session.is_none() && battle_net_idle);
        self.sign_out
            .set_enabled(self.battle_net_session.is_some() && battle_net_idle);

        if self.sync_needed {
            if self.battle_net_session.is_some() && battle_net_idle {
                self.start_sync(true);
            } else if self.battle_net_session.is_none() {
                self.set_sync_status("Sync: sign in to sync");
            }
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
            UserEvent::Menu(event) if event.id == *self.sign_in.id() => {
                self.start_sign_in();
            }
            UserEvent::Menu(event) if event.id == *self.sign_out.id() => {
                self.start_sign_out();
            }
            UserEvent::Menu(event) if event.id == *self.sync.id() => {
                self.start_sync(false);
            }
            UserEvent::Menu(_) => {}
            UserEvent::BattleNet(update) => self.finish_battle_net(update),
            UserEvent::Sync { result, automatic } => self.finish_sync(result, automatic),
            UserEvent::SavedVariablesChanged => self.on_saved_variables_changed(),
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
