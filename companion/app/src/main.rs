#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
compile_error!("arbitrage-companion supports only macOS and Windows");

use chrono::{DateTime, Local, TimeZone, Utc};
use rfd::{MessageButtons, MessageDialog, MessageDialogResult, MessageLevel};
use std::{env, fmt, mem, path::PathBuf, thread, time::Duration};
use tray_icon::{
    TrayIcon, TrayIconBuilder,
    menu::{CheckMenuItem, Menu, MenuEvent, MenuId, MenuItem, PredefinedMenuItem, Submenu},
};
use ureq::Agent;
use winit::{
    application::ApplicationHandler,
    event::{StartCause, WindowEvent},
    event_loop::{ActiveEventLoop, EventLoop, EventLoopProxy},
    window::WindowId,
};

mod icon;
mod keychain;
mod launch_at_login;
mod saved_variables;
mod settings;
mod sign_in;
mod sync;
mod update;
mod watch;

const DEFAULT_WORKER_URL: &str = "https://arbitrage-wow.fyi";
const WORKER_REQUEST_TIMEOUT: Duration = Duration::from_secs(2);
const SYNC_REQUEST_TIMEOUT: Duration = Duration::from_mins(1);
const UPDATE_CHECK_TIMEOUT: Duration = Duration::from_secs(10);
const UPDATE_DOWNLOAD_TIMEOUT: Duration = Duration::from_mins(10);

enum UserEvent {
    Menu(MenuEvent),
    BattleNet(BattleNetUpdate),
    Sync(Result<(), String>),
    SavedVariablesChanged,
    UpdateChecked(Result<update::Check, String>),
    UpdateInstalled(Result<(), String>),
}

enum Trigger {
    Startup,
    Manual,
}

enum Update {
    Idle,
    Checking {
        trigger: Trigger,
        task: thread::JoinHandle<()>,
    },
    Available(update::Release),
    Installing {
        release: update::Release,
        task: thread::JoinHandle<()>,
    },
}

enum BattleNetUpdate {
    SignedIn {
        account: sign_in::Account,
        session: sign_in::Session,
        persisted: bool,
    },
    SignedOut,
    Unchanged,
}

struct Application {
    sign_in: Option<MenuItem>,
    sign_out: Option<MenuItem>,
    choose_folder_id: MenuId,
    install_update: Option<MenuItem>,
    check_for_updates_id: MenuId,
    check_on_startup: Option<CheckMenuItem>,
    launch_at_login: Option<CheckMenuItem>,
    quit_id: MenuId,
    tray_icon: Option<TrayIcon>,
    battle_net_task: Option<thread::JoinHandle<()>>,
    sync_task: Option<thread::JoinHandle<()>>,
    battle_net_session: Option<sign_in::Session>,
    battletag: Option<String>,
    account_id: Option<String>,
    sync_needed: bool,
    sync_error: Option<String>,
    update: Update,
    settings: settings::Settings,
    saved_variables: Result<PathBuf, saved_variables::LocateError>,
    saved_variables_watch: Option<watch::Watch>,
    event_proxy: EventLoopProxy<UserEvent>,
    worker_url: String,
}

impl Application {
    fn new(
        event_proxy: EventLoopProxy<UserEvent>,
        worker_url: String,
        settings: settings::Settings,
    ) -> Self {
        Self {
            sign_in: None,
            sign_out: None,
            choose_folder_id: MenuId::new(""),
            install_update: None,
            check_for_updates_id: MenuId::new(""),
            check_on_startup: None,
            launch_at_login: None,
            quit_id: MenuId::new(""),
            tray_icon: None,
            battle_net_task: None,
            sync_task: None,
            battle_net_session: None,
            battletag: None,
            account_id: None,
            sync_needed: false,
            sync_error: None,
            update: Update::Idle,
            settings,
            saved_variables: Err(saved_variables::LocateError::NotFound),
            saved_variables_watch: None,
            event_proxy,
            worker_url,
        }
    }

    fn refresh_menu(&mut self) {
        let menu = Menu::new();
        let app_info = MenuItem::new(
            format!("Arbitrage Companion v{}", env!("CARGO_PKG_VERSION")),
            false,
            None,
        );
        let location = MenuItem::new(
            match &self.saved_variables {
                Ok(_) => "✅ Arbitrage data found".to_owned(),
                Err(error) => format!("⚠️ {error}"),
            },
            false,
            None,
        );
        let choose_folder = MenuItem::new("Choose WoW Folder…", true, None);
        self.choose_folder_id = choose_folder.id().clone();
        let quit = MenuItem::new("Quit", true, None);
        self.quit_id = quit.id().clone();

        menu.append(&app_info).expect("failed to create tray menu");
        self.install_update = None;
        match &self.update {
            Update::Idle => {}
            Update::Checking { .. } => menu
                .append(&MenuItem::new("Checking for updates…", false, None))
                .expect("failed to create tray menu"),
            Update::Available(release) => {
                let install_update =
                    MenuItem::new(format!("Update to v{}", release.version), true, None);
                menu.append(&install_update)
                    .expect("failed to create tray menu");
                self.install_update = Some(install_update);
            }
            Update::Installing { release, .. } => menu
                .append(&MenuItem::new(
                    format!("Installing v{}…", release.version),
                    false,
                    None,
                ))
                .expect("failed to create tray menu"),
        }
        let settings = self.create_settings_menu(&choose_folder);

        menu.append(&PredefinedMenuItem::separator())
            .expect("failed to create tray menu");
        if let Some(battletag) = &self.battletag {
            let status = MenuItem::new(battletag, false, None);
            let last_synced = MenuItem::new(
                last_synced_label(self.settings.last_synced.map(|at| at.with_timezone(&Local))),
                false,
                None,
            );
            menu.append_items(&[&status, &last_synced])
                .expect("failed to create tray menu");
            if let Some(message) = &self.sync_error {
                menu.append(&MenuItem::new(
                    format!("Sync failed: {message}"),
                    false,
                    None,
                ))
                .expect("failed to create tray menu");
            }
            let sign_out = MenuItem::new("Sign out", true, None);
            menu.append(&sign_out).expect("failed to create tray menu");
            self.sign_in = None;
            self.sign_out = Some(sign_out);
        } else {
            let sign_in = MenuItem::new("Sign in with Battle.net", true, None);
            menu.append(&sign_in).expect("failed to create tray menu");
            self.sign_in = Some(sign_in);
            self.sign_out = None;
        }

        menu.append_items(&[
            &PredefinedMenuItem::separator(),
            &location,
            &PredefinedMenuItem::separator(),
            &settings,
            &PredefinedMenuItem::separator(),
            &quit,
        ])
        .expect("failed to create tray menu");

        if let Some(tray) = &self.tray_icon {
            tray.set_menu(Some(Box::new(menu)));
        }
    }

    fn create_settings_menu(&mut self, choose_folder: &MenuItem) -> Submenu {
        let check_for_updates = MenuItem::new(
            "Check for Updates…",
            matches!(self.update, Update::Idle | Update::Available(_)),
            None,
        );
        self.check_for_updates_id = check_for_updates.id().clone();
        let check_on_startup = CheckMenuItem::new(
            "Check for Updates on Startup",
            true,
            self.settings.check_for_updates_on_startup,
            None,
        );
        let launch_at_login = CheckMenuItem::new(
            "Launch at Login",
            true,
            launch_at_login::is_enabled().unwrap_or(false),
            None,
        );
        let menu = Submenu::with_items(
            "Settings",
            true,
            &[
                choose_folder,
                &launch_at_login,
                &check_for_updates,
                &check_on_startup,
            ],
        )
        .expect("failed to create tray menu");
        self.check_on_startup = Some(check_on_startup);
        self.launch_at_login = Some(launch_at_login);
        menu
    }

    fn create_tray_icon(&mut self, event_loop: &ActiveEventLoop) {
        self.tray_icon = Some(
            TrayIconBuilder::new()
                .with_tooltip("Arbitrage Companion")
                .with_icon(icon::tray(event_loop))
                .with_icon_as_template(true)
                .build()
                .expect("failed to create tray icon"),
        );
    }

    fn roots(&self) -> Vec<PathBuf> {
        saved_variables::product_roots(self.settings.wow_directory.as_deref())
    }

    fn refresh_saved_variables(&mut self) {
        self.saved_variables_watch = None;
        self.saved_variables = saved_variables::locate(&self.roots(), self.account_id.as_deref());
        if let Ok(path) = &self.saved_variables {
            let proxy = self.event_proxy.clone();
            self.saved_variables_watch = watch::Watch::start(path, move || {
                let _ = proxy.send_event(UserEvent::SavedVariablesChanged);
            });
        }
    }

    fn choose_wow_folder(&mut self) {
        let mut dialog = rfd::FileDialog::new().set_title("Choose your World of Warcraft folder");
        if let Some(directory) = &self.settings.wow_directory {
            dialog = dialog.set_directory(directory);
        }

        let Some(directory) = dialog.pick_folder() else {
            self.refresh_saved_variables();
            self.refresh_menu();
            return;
        };

        self.settings.wow_directory = Some(directory);
        let _ = self.settings.save();
        self.refresh_saved_variables();
        self.refresh_menu();
        if self.saved_variables.is_ok() {
            self.on_saved_variables_changed();
        }
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
        self.start_sync();
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
                    sign_in::Resume::SignedIn { account } => BattleNetUpdate::SignedIn {
                        account,
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
                Some((session, account)) => {
                    let persisted = keychain::save(&session).is_ok();
                    BattleNetUpdate::SignedIn {
                        account,
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

    fn start_sync(&mut self) {
        let Some(session) = self.battle_net_session.clone() else {
            return;
        };
        if self.battle_net_task.is_some() || self.sync_task.is_some() {
            return;
        }
        let Ok(path) = self.saved_variables.clone() else {
            return;
        };
        self.sync_needed = false;

        let proxy = self.event_proxy.clone();
        let worker_url = self.worker_url.clone();
        let roots = self.roots();
        self.sync_task = Some(thread::spawn(move || {
            let agent = agent(SYNC_REQUEST_TIMEOUT);
            let result = sync::run(&agent, &worker_url, &session, &path, &roots);
            let _ = proxy.send_event(UserEvent::Sync(result));
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
                account,
                session,
                persisted,
            } => {
                self.battle_net_session = Some(session);
                let label = if persisted {
                    account.battletag
                } else {
                    format!("{} (not saved)", account.battletag)
                };
                self.battletag = Some(label);
                self.account_id = Some(account.id);
                self.refresh_saved_variables();
                self.refresh_menu();
                if self.sync_needed && self.sync_task.is_none() {
                    self.start_sync();
                }
            }
            BattleNetUpdate::SignedOut => {
                self.battle_net_session = None;
                self.battletag = None;
                self.account_id = None;
                self.sync_needed = false;
                self.sync_error = None;
                self.refresh_saved_variables();
                self.refresh_menu();
            }
            BattleNetUpdate::Unchanged => self.refresh_menu(),
        }
    }

    fn finish_sync(&mut self, result: Result<(), String>) {
        self.sync_task
            .take()
            .expect("sync task is missing")
            .join()
            .expect("sync task panicked");

        match result {
            Ok(()) => {
                self.settings.last_synced = Some(Utc::now());
                let _ = self.settings.save();
                self.sync_error = None;
            }
            Err(message) => self.sync_error = Some(message),
        }
        self.refresh_menu();

        if self.sync_needed && self.battle_net_session.is_some() && self.battle_net_task.is_none() {
            self.start_sync();
        }
    }

    fn start_update_check(&mut self, trigger: Trigger) {
        if !matches!(self.update, Update::Idle | Update::Available(_)) {
            return;
        }

        let proxy = self.event_proxy.clone();
        let worker_url = self.worker_url.clone();
        let task = thread::spawn(move || {
            let result = update::check(&agent(UPDATE_CHECK_TIMEOUT), &worker_url);
            let _ = proxy.send_event(UserEvent::UpdateChecked(result));
        });
        self.update = Update::Checking { trigger, task };
        self.refresh_menu();
    }

    fn finish_update_check(&mut self, result: Result<update::Check, String>) {
        let Update::Checking { trigger, task } = mem::replace(&mut self.update, Update::Idle)
        else {
            panic!("update check task is missing");
        };
        task.join().expect("update check task panicked");

        let current = env!("CARGO_PKG_VERSION");
        match (trigger, result) {
            (Trigger::Startup, Ok(update::Check::Available(release))) => {
                self.update = Update::Available(release);
                self.refresh_menu();
            }
            (Trigger::Startup, Ok(update::Check::UpToDate) | Err(_)) => self.refresh_menu(),
            (Trigger::Manual, Ok(update::Check::Available(release))) => {
                let description = format!(
                    "Arbitrage Companion v{} is available. You have v{current}.",
                    release.version
                );
                self.update = Update::Available(release);
                self.refresh_menu();
                let choice = MessageDialog::new()
                    .set_title("Update available")
                    .set_description(description)
                    .set_buttons(MessageButtons::OkCancelCustom(
                        "Update".to_owned(),
                        "Later".to_owned(),
                    ))
                    .show();
                if accepted(&choice, "Update") {
                    self.start_install();
                }
            }
            (Trigger::Manual, Ok(update::Check::UpToDate)) => {
                self.refresh_menu();
                MessageDialog::new()
                    .set_title("You're up to date")
                    .set_description(format!(
                        "Arbitrage Companion v{current} is the latest version."
                    ))
                    .show();
            }
            (Trigger::Manual, Err(message)) => {
                self.refresh_menu();
                MessageDialog::new()
                    .set_level(MessageLevel::Warning)
                    .set_title("Couldn't check for updates")
                    .set_description(message)
                    .show();
            }
        }
    }

    fn start_install(&mut self) {
        let Update::Available(release) = &self.update else {
            return;
        };
        let release = release.clone();

        let proxy = self.event_proxy.clone();
        let download = release.clone();
        let task = thread::spawn(move || {
            let result = update::install(&agent(UPDATE_DOWNLOAD_TIMEOUT), &download);
            let _ = proxy.send_event(UserEvent::UpdateInstalled(result));
        });
        self.update = Update::Installing { release, task };
        self.refresh_menu();
    }

    fn finish_install(&mut self, event_loop: &ActiveEventLoop, result: Result<(), String>) {
        let Update::Installing { release, task } = mem::replace(&mut self.update, Update::Idle)
        else {
            panic!("update install task is missing");
        };
        task.join().expect("update install task panicked");

        match result {
            Ok(()) => self.quit(event_loop),
            Err(message) => {
                let url = release.url.clone();
                self.update = Update::Available(release);
                self.refresh_menu();
                let choice = MessageDialog::new()
                    .set_level(MessageLevel::Warning)
                    .set_title("Couldn't install the update")
                    .set_description(message)
                    .set_buttons(MessageButtons::OkCancelCustom(
                        "Download".to_owned(),
                        "Close".to_owned(),
                    ))
                    .show();
                if accepted(&choice, "Download") {
                    let _ = open::that(url);
                }
            }
        }
    }

    fn toggle_check_on_startup(&mut self) {
        let Some(item) = &self.check_on_startup else {
            return;
        };
        self.settings.check_for_updates_on_startup = item.is_checked();
        let _ = self.settings.save();
        self.refresh_menu();
    }

    fn toggle_launch_at_login(&mut self) {
        let Some(item) = &self.launch_at_login else {
            return;
        };
        let enabled = item.is_checked();
        if let Err(error) = launch_at_login::set_enabled(enabled) {
            self.refresh_menu();
            MessageDialog::new()
                .set_level(MessageLevel::Warning)
                .set_title("Couldn't update login settings")
                .set_description(error.to_string())
                .show();
            return;
        }
        self.refresh_menu();
    }

    fn quit(&mut self, event_loop: &ActiveEventLoop) {
        self.saved_variables_watch.take();
        self.tray_icon.take();
        event_loop.exit();
    }
}

impl ApplicationHandler<UserEvent> for Application {
    fn resumed(&mut self, _event_loop: &ActiveEventLoop) {}

    fn new_events(&mut self, event_loop: &ActiveEventLoop, cause: StartCause) {
        if cause != StartCause::Init {
            return;
        }

        self.create_tray_icon(event_loop);
        self.refresh_saved_variables();
        self.refresh_menu();
        self.start_session_restore();
        if self.settings.check_for_updates_on_startup {
            self.start_update_check(Trigger::Startup);
        }

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
            UserEvent::Menu(event) if event.id == self.quit_id => self.quit(event_loop),
            UserEvent::Menu(event) if event.id == self.choose_folder_id => {
                self.choose_wow_folder();
            }
            UserEvent::Menu(event) if event.id == self.check_for_updates_id => {
                self.start_update_check(Trigger::Manual);
            }
            UserEvent::Menu(event)
                if self
                    .install_update
                    .as_ref()
                    .is_some_and(|item| event.id == *item.id()) =>
            {
                self.start_install();
            }
            UserEvent::Menu(event)
                if self
                    .check_on_startup
                    .as_ref()
                    .is_some_and(|item| event.id == *item.id()) =>
            {
                self.toggle_check_on_startup();
            }
            UserEvent::Menu(event)
                if self
                    .launch_at_login
                    .as_ref()
                    .is_some_and(|item| event.id == *item.id()) =>
            {
                self.toggle_launch_at_login();
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
            UserEvent::Sync(result) => self.finish_sync(result),
            UserEvent::SavedVariablesChanged => self.on_saved_variables_changed(),
            UserEvent::UpdateChecked(result) => self.finish_update_check(result),
            UserEvent::UpdateInstalled(result) => self.finish_install(event_loop, result),
        }
    }
}

fn agent(timeout: Duration) -> Agent {
    let config = Agent::config_builder()
        .timeout_global(Some(timeout))
        .build();
    Agent::new_with_config(config)
}

fn accepted(choice: &MessageDialogResult, label: &str) -> bool {
    match choice {
        // Windows shows OK/Cancel instead of custom labels without rfd's common-controls-v6.
        MessageDialogResult::Ok => true,
        MessageDialogResult::Custom(chosen) => chosen == label,
        _ => false,
    }
}

fn last_synced_label<Tz: TimeZone>(at: Option<DateTime<Tz>>) -> String
where
    Tz::Offset: fmt::Display,
{
    at.map_or_else(
        || "Last synced never".to_owned(),
        |at| format!("Last synced {}", at.format("%b %-d, %-I:%M %p")),
    )
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
        .run_app(&mut Application::new(
            event_proxy,
            worker_url,
            settings::Settings::load(),
        ))
        .expect("event loop failed");
}

#[cfg(test)]
mod tests {
    use super::last_synced_label;
    use chrono::{DateTime, TimeZone, Utc};

    #[test]
    fn labels_the_last_sync_time() {
        assert_eq!(
            last_synced_label(Some(Utc.with_ymd_and_hms(2026, 9, 25, 21, 15, 0).unwrap())),
            "Last synced Sep 25, 9:15 PM"
        );
        assert_eq!(
            last_synced_label(None::<DateTime<Utc>>),
            "Last synced never"
        );
    }
}
