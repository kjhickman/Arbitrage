#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
compile_error!("arbitrage-companion supports only macOS and Windows");

use chrono::{DateTime, Local, TimeZone, Utc};
use rfd::{MessageButtons, MessageDialog, MessageDialogResult, MessageLevel};
use std::{
    collections::HashMap,
    env, fmt, io, mem,
    panic::{self, AssertUnwindSafe},
    path::PathBuf,
    thread,
    time::{Duration, Instant},
};
use tray_icon::{
    TrayIcon, TrayIconBuilder,
    menu::{
        CheckMenuItem, IsMenuItem, Menu, MenuEvent, MenuId, MenuItem, PredefinedMenuItem, Submenu,
    },
};
use ureq::Agent;
use winit::{
    application::ApplicationHandler,
    event::{StartCause, WindowEvent},
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop, EventLoopProxy},
    window::WindowId,
};

mod atomic_file;
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
const AUTOMATIC_UPDATE_INTERVAL: Duration = Duration::from_hours(24);
const MENU_FAILED: &str = "failed to create tray menu";

enum UserEvent {
    Menu(MenuEvent),
    BattleNet(BattleNetUpdate),
    Sync(Result<(), sync::Error>),
    SavedVariablesChanged,
    UpdateChecked(Result<update::Check, update::Error>),
    UpdateInstalled(Result<(), update::Error>),
    TaskPanicked(Task),
}

/// A background task, named so a panic in it can be undone.
#[derive(Debug, Clone, Copy)]
enum Task {
    Session,
    UpdateCheck,
    UpdateInstall,
}

#[derive(Debug, Clone, Copy)]
enum Trigger {
    Automatic,
    Manual,
}

enum Update {
    Idle,
    Checking(Trigger),
    Available(update::Release),
    Installing(update::Release),
}

struct SignedIn {
    session: sign_in::Session,
    account: sign_in::Account,
    persisted: bool,
}

impl SignedIn {
    fn label(&self) -> String {
        if self.persisted {
            self.account.battletag.clone()
        } else {
            format!("{} (not saved)", self.account.battletag)
        }
    }
}

enum BattleNetUpdate {
    SignedIn(SignedIn),
    SignedOut,
    Unchanged,
    SignInFailed(sign_in::Error),
    SignOutFailed(sign_in::Error),
    ForgetFailed(keyring::Error),
}

#[derive(Debug, Clone, Copy)]
enum MenuAction {
    SignIn,
    SignOut,
    ChooseFolder,
    InstallUpdate,
    CheckForUpdates,
    ToggleAutomaticUpdateChecks,
    ToggleLaunchAtLogin,
    Quit,
}

#[derive(Default)]
struct MenuBuilder {
    items: Vec<Box<dyn IsMenuItem>>,
    actions: HashMap<MenuId, MenuAction>,
}

impl MenuBuilder {
    fn label(&mut self, text: impl AsRef<str>) {
        self.items.push(Box::new(MenuItem::new(text, false, None)));
    }

    fn action(&mut self, text: impl AsRef<str>, enabled: bool, action: MenuAction) {
        let item = MenuItem::new(text, enabled, None);
        self.actions.insert(item.id().clone(), action);
        self.items.push(Box::new(item));
    }

    fn check(&mut self, text: &str, checked: bool, action: MenuAction) {
        let item = CheckMenuItem::new(text, true, checked, None);
        self.actions.insert(item.id().clone(), action);
        self.items.push(Box::new(item));
    }

    fn separator(&mut self) {
        self.items.push(Box::new(PredefinedMenuItem::separator()));
    }

    fn submenu(&mut self, text: &str, build: impl FnOnce(&mut Self)) {
        let outer = mem::take(&mut self.items);
        build(self);
        let inner = mem::replace(&mut self.items, outer);
        let submenu = Submenu::with_items(text, true, &borrowed(&inner)).expect(MENU_FAILED);
        self.items.push(Box::new(submenu));
    }

    fn build(self) -> (Menu, HashMap<MenuId, MenuAction>) {
        let menu = Menu::with_items(&borrowed(&self.items)).expect(MENU_FAILED);
        (menu, self.actions)
    }
}

fn borrowed(items: &[Box<dyn IsMenuItem>]) -> Vec<&dyn IsMenuItem> {
    items.iter().map(AsRef::as_ref).collect()
}

struct Application {
    tray_icon: Option<TrayIcon>,
    menu_actions: HashMap<MenuId, MenuAction>,
    /// Battle.net and sync tasks both use the session, so at most one of them runs at a time.
    session_busy: bool,
    signed_in: Option<SignedIn>,
    sync_needed: bool,
    sync_error: Option<sync::Error>,
    update: Update,
    settings: settings::Settings,
    settings_load_error: Option<settings::LoadError>,
    settings_save_error: Option<io::Error>,
    saved_variables: Result<PathBuf, saved_variables::LocateError>,
    saved_variables_watch: Option<watch::Watch>,
    event_proxy: EventLoopProxy<UserEvent>,
    worker_url: String,
}

impl Application {
    fn new(
        event_proxy: EventLoopProxy<UserEvent>,
        worker_url: String,
        settings: Result<settings::Settings, settings::LoadError>,
    ) -> Self {
        let (settings, settings_load_error) = match settings {
            Ok(settings) => (settings, None),
            Err(error) => (settings::Settings::default(), Some(error)),
        };
        Self {
            tray_icon: None,
            menu_actions: HashMap::new(),
            session_busy: false,
            signed_in: None,
            sync_needed: false,
            sync_error: None,
            update: Update::Idle,
            settings,
            settings_load_error,
            settings_save_error: None,
            saved_variables: Err(saved_variables::LocateError::NotFound),
            saved_variables_watch: None,
            event_proxy,
            worker_url,
        }
    }

    fn refresh_menu(&mut self) {
        let mut menu = MenuBuilder::default();
        menu.label(format!(
            "Arbitrage Companion v{}",
            env!("CARGO_PKG_VERSION")
        ));
        match &self.update {
            Update::Idle => {}
            Update::Checking(_) => menu.label("Checking for updates…"),
            Update::Available(release) => menu.action(
                format!("Update to v{}", release.version),
                true,
                MenuAction::InstallUpdate,
            ),
            Update::Installing(release) => {
                menu.label(format!("Installing v{}…", release.version));
            }
        }

        menu.separator();
        if let Some(signed_in) = &self.signed_in {
            menu.label(signed_in.label());
            menu.label(last_synced_label(
                self.settings.last_synced.map(|at| at.with_timezone(&Local)),
            ));
            if let Some(error) = &self.sync_error {
                menu.label(format!("Sync failed: {error}"));
            }
            menu.action("Sign out", true, MenuAction::SignOut);
        } else {
            menu.action("Sign in with Battle.net", true, MenuAction::SignIn);
        }

        menu.separator();
        menu.label(match &self.saved_variables {
            Ok(_) => "✅ Arbitrage data found".to_owned(),
            Err(error) => format!("⚠️ {error}"),
        });
        if let Some(error) = &self.settings_save_error {
            menu.label(format!("⚠️ Couldn't save settings: {error}"));
        }

        menu.separator();
        menu.submenu("Settings", |settings| {
            settings.action("Choose WoW Folder…", true, MenuAction::ChooseFolder);
            settings.check(
                "Launch at Login",
                launch_at_login::is_enabled().unwrap_or(false),
                MenuAction::ToggleLaunchAtLogin,
            );
            settings.action(
                "Check for Updates…",
                matches!(self.update, Update::Idle | Update::Available(_)),
                MenuAction::CheckForUpdates,
            );
            settings.check(
                "Automatically Check for Updates",
                self.settings.automatically_check_for_updates,
                MenuAction::ToggleAutomaticUpdateChecks,
            );
        });

        menu.separator();
        menu.action("Quit", true, MenuAction::Quit);

        let (menu, actions) = menu.build();
        self.menu_actions = actions;
        if let Some(tray) = &self.tray_icon {
            tray.set_menu(Some(Box::new(menu)));
        }
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

    fn perform(&mut self, event_loop: &ActiveEventLoop, action: MenuAction) {
        match action {
            MenuAction::SignIn => self.start_sign_in(),
            MenuAction::SignOut => self.start_sign_out(),
            MenuAction::ChooseFolder => self.choose_wow_folder(),
            MenuAction::InstallUpdate => self.start_install(),
            MenuAction::CheckForUpdates => self.start_update_check(event_loop, Trigger::Manual),
            MenuAction::ToggleAutomaticUpdateChecks => {
                self.toggle_automatic_update_checks(event_loop);
            }
            MenuAction::ToggleLaunchAtLogin => self.toggle_launch_at_login(),
            MenuAction::Quit => self.quit(event_loop),
        }
    }

    fn roots(&self) -> Vec<PathBuf> {
        saved_variables::product_roots(self.settings.wow_directory.as_deref())
    }

    fn account_id(&self) -> Option<&str> {
        self.signed_in
            .as_ref()
            .map(|signed_in| signed_in.account.id.as_str())
    }

    fn notify_saved_variables_changed(&self) -> impl Fn() + Send + 'static {
        let proxy = self.event_proxy.clone();
        move || {
            let _ = proxy.send_event(UserEvent::SavedVariablesChanged);
        }
    }

    fn refresh_saved_variables(&mut self) {
        self.saved_variables_watch = None;
        let roots = self.roots();
        let mut located = saved_variables::locate(&roots, self.account_id());
        let mut discovery = None;
        if located.as_ref().is_err_and(is_missing) {
            // Watch before looking again, so a file created in between still gets noticed.
            discovery = watch::Watch::discover(&roots, self.notify_saved_variables_changed());
            located = saved_variables::locate(&roots, self.account_id());
        }

        self.saved_variables_watch = match &located {
            Ok(path) => watch::Watch::start(path, self.notify_saved_variables_changed()),
            Err(error) if is_missing(error) => discovery,
            Err(_) => None,
        };
        self.saved_variables = located;
    }

    fn save_settings(&mut self) {
        self.settings_save_error = self.settings.save().err();
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
        self.save_settings();
        self.on_saved_variables_changed();
    }

    fn on_saved_variables_changed(&mut self) {
        self.refresh_saved_variables();
        self.refresh_menu();
        if self.saved_variables.is_err() {
            return;
        }
        if self.session_busy || self.signed_in.is_none() {
            self.sync_needed = true;
            return;
        }
        self.start_sync();
    }

    /// Runs `work` on a background thread and delivers the event it returns, or
    /// [`UserEvent::TaskPanicked`] if it panics.
    fn spawn(&self, task: Task, work: impl FnOnce() -> UserEvent + Send + 'static) {
        let proxy = self.event_proxy.clone();
        thread::spawn(move || {
            let event = panic::catch_unwind(AssertUnwindSafe(work))
                .unwrap_or(UserEvent::TaskPanicked(task));
            let _ = proxy.send_event(event);
        });
    }

    /// Starts a task that uses the session, unless one is already running.
    fn spawn_session_task(&mut self, work: impl FnOnce() -> UserEvent + Send + 'static) {
        if self.session_busy {
            return;
        }
        self.session_busy = true;
        self.spawn(Task::Session, work);
    }

    fn start_session_restore(&mut self) {
        let worker_url = self.worker_url.clone();
        self.spawn_session_task(move || {
            let Some(session) = keychain::load() else {
                return UserEvent::BattleNet(BattleNetUpdate::Unchanged);
            };
            let agent = agent(WORKER_REQUEST_TIMEOUT);
            let update = match sign_in::resume(&agent, &worker_url, &session) {
                sign_in::Resume::SignedIn { account } => BattleNetUpdate::SignedIn(SignedIn {
                    session,
                    account,
                    persisted: true,
                }),
                sign_in::Resume::Forget => {
                    let _ = keychain::delete();
                    BattleNetUpdate::Unchanged
                }
                sign_in::Resume::Unavailable => BattleNetUpdate::Unchanged,
            };
            UserEvent::BattleNet(update)
        });
    }

    fn start_sign_in(&mut self) {
        let worker_url = self.worker_url.clone();
        self.spawn_session_task(move || {
            let agent = agent(WORKER_REQUEST_TIMEOUT);
            let update = match sign_in::start(&agent, &worker_url) {
                Ok((session, account)) => {
                    let persisted = keychain::save(&session).is_ok();
                    BattleNetUpdate::SignedIn(SignedIn {
                        session,
                        account,
                        persisted,
                    })
                }
                Err(error) => BattleNetUpdate::SignInFailed(error),
            };
            UserEvent::BattleNet(update)
        });
    }

    fn start_sign_out(&mut self) {
        let Some(signed_in) = &self.signed_in else {
            return;
        };
        let session = signed_in.session.clone();
        let worker_url = self.worker_url.clone();
        self.spawn_session_task(move || {
            let agent = agent(WORKER_REQUEST_TIMEOUT);
            let update = match sign_in::sign_out(&agent, &worker_url, &session) {
                // A session the worker no longer knows is already signed out there.
                Ok(()) | Err(sign_in::Error::Forgotten) => match keychain::delete() {
                    Ok(()) => BattleNetUpdate::SignedOut,
                    Err(error) => BattleNetUpdate::ForgetFailed(error),
                },
                Err(error) => BattleNetUpdate::SignOutFailed(error),
            };
            UserEvent::BattleNet(update)
        });
    }

    fn start_sync(&mut self) {
        let (Some(signed_in), Ok(path)) = (&self.signed_in, &self.saved_variables) else {
            return;
        };
        let session = signed_in.session.clone();
        let path = path.clone();
        let worker_url = self.worker_url.clone();
        let roots = self.roots();
        self.spawn_session_task(move || {
            let agent = agent(SYNC_REQUEST_TIMEOUT);
            UserEvent::Sync(sync::run(&agent, &worker_url, &session, &path, &roots))
        });
        self.sync_needed = false;
    }

    fn finish_battle_net(&mut self, update: BattleNetUpdate) {
        self.session_busy = false;
        match update {
            BattleNetUpdate::SignedIn(signed_in) => {
                self.signed_in = Some(signed_in);
                self.refresh_saved_variables();
                self.refresh_menu();
                if self.sync_needed {
                    self.start_sync();
                }
            }
            BattleNetUpdate::SignedOut => {
                self.signed_in = None;
                self.sync_needed = false;
                self.sync_error = None;
                self.refresh_saved_variables();
                self.refresh_menu();
            }
            BattleNetUpdate::Unchanged => self.refresh_menu(),
            BattleNetUpdate::SignInFailed(error) => {
                self.refresh_menu();
                warn("Couldn't sign in", &error);
            }
            BattleNetUpdate::SignOutFailed(error) => {
                self.refresh_menu();
                warn("Couldn't sign out", &error);
            }
            BattleNetUpdate::ForgetFailed(error) => {
                self.refresh_menu();
                warn("Couldn't remove the saved sign-in", &error);
            }
        }
    }

    fn finish_sync(&mut self, result: Result<(), sync::Error>) {
        self.session_busy = false;
        match result {
            Ok(()) => {
                self.settings.last_synced = Some(Utc::now());
                self.save_settings();
                self.sync_error = None;
            }
            Err(error) => self.sync_error = Some(error),
        }
        self.refresh_menu();

        if self.sync_needed {
            self.start_sync();
        }
    }

    fn schedule_automatic_update_check(&mut self, event_loop: &ActiveEventLoop) {
        if !self.settings.automatically_check_for_updates {
            event_loop.set_control_flow(ControlFlow::Wait);
            return;
        }

        let delay = automatic_update_delay(self.settings.last_update_check, Utc::now());
        if delay.is_zero() {
            event_loop.set_control_flow(ControlFlow::Wait);
            self.start_update_check(event_loop, Trigger::Automatic);
        } else {
            event_loop.set_control_flow(ControlFlow::WaitUntil(Instant::now() + delay));
        }
    }

    fn start_update_check(&mut self, event_loop: &ActiveEventLoop, trigger: Trigger) {
        if !matches!(self.update, Update::Idle | Update::Available(_)) {
            return;
        }

        self.settings.last_update_check = Some(Utc::now());
        self.save_settings();
        self.schedule_automatic_update_check(event_loop);

        let worker_url = self.worker_url.clone();
        self.spawn(Task::UpdateCheck, move || {
            UserEvent::UpdateChecked(update::check(&agent(UPDATE_CHECK_TIMEOUT), &worker_url))
        });
        self.update = Update::Checking(trigger);
        self.refresh_menu();
    }

    fn finish_update_check(&mut self, result: Result<update::Check, update::Error>) {
        let Update::Checking(trigger) = self.update else {
            return;
        };
        self.update = Update::Idle;

        let current = env!("CARGO_PKG_VERSION");
        match (trigger, result) {
            (Trigger::Automatic, Ok(update::Check::Available(release))) => {
                self.update = Update::Available(release);
                self.refresh_menu();
            }
            (Trigger::Automatic, Ok(update::Check::UpToDate) | Err(_)) => self.refresh_menu(),
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
            (Trigger::Manual, Err(error)) => {
                self.refresh_menu();
                warn("Couldn't check for updates", &error);
            }
        }
    }

    fn start_install(&mut self) {
        let Update::Available(release) = &self.update else {
            return;
        };
        let release = release.clone();
        let download = release.clone();
        self.spawn(Task::UpdateInstall, move || {
            UserEvent::UpdateInstalled(update::install(&agent(UPDATE_DOWNLOAD_TIMEOUT), &download))
        });
        self.update = Update::Installing(release);
        self.refresh_menu();
    }

    fn finish_install(&mut self, event_loop: &ActiveEventLoop, result: Result<(), update::Error>) {
        let Update::Installing(release) = &self.update else {
            return;
        };
        let release = release.clone();

        match result {
            Ok(()) => self.quit(event_loop),
            Err(error) => {
                let url = release.url.clone();
                self.update = Update::Available(release);
                self.refresh_menu();
                let choice = MessageDialog::new()
                    .set_level(MessageLevel::Warning)
                    .set_title("Couldn't install the update")
                    .set_description(error.to_string())
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

    fn recover_from_panic(&mut self, task: Task) {
        match task {
            Task::Session => self.session_busy = false,
            Task::UpdateCheck => {
                if matches!(self.update, Update::Checking(_)) {
                    self.update = Update::Idle;
                }
            }
            Task::UpdateInstall => {
                if let Update::Installing(release) = &self.update {
                    self.update = Update::Available(release.clone());
                }
            }
        }
        self.refresh_menu();
        warn(
            "Something went wrong",
            &"Arbitrage Companion hit an unexpected error. Try again.",
        );
    }

    fn toggle_automatic_update_checks(&mut self, event_loop: &ActiveEventLoop) {
        self.settings.automatically_check_for_updates =
            !self.settings.automatically_check_for_updates;
        self.save_settings();
        self.refresh_menu();
        self.schedule_automatic_update_check(event_loop);
    }

    fn toggle_launch_at_login(&mut self) {
        let enabled = !launch_at_login::is_enabled().unwrap_or(false);
        let result = launch_at_login::set_enabled(enabled);
        self.refresh_menu();
        if let Err(error) = result {
            warn("Couldn't update login settings", &error);
        }
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
        if matches!(cause, StartCause::ResumeTimeReached { .. }) {
            self.schedule_automatic_update_check(event_loop);
            return;
        }
        if cause != StartCause::Init {
            return;
        }

        self.create_tray_icon(event_loop);
        self.refresh_saved_variables();
        self.refresh_menu();
        self.start_session_restore();
        self.schedule_automatic_update_check(event_loop);

        #[cfg(target_os = "macos")]
        {
            use objc2_core_foundation::CFRunLoop;

            let run_loop = CFRunLoop::main().expect("main run loop is unavailable");
            CFRunLoop::wake_up(&run_loop);
        }

        if let Some(error) = self.settings_load_error.take() {
            warn("Settings were reset", &error);
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
            UserEvent::Menu(event) => {
                if let Some(&action) = self.menu_actions.get(&event.id) {
                    self.perform(event_loop, action);
                }
            }
            UserEvent::BattleNet(update) => self.finish_battle_net(update),
            UserEvent::Sync(result) => self.finish_sync(result),
            UserEvent::SavedVariablesChanged => self.on_saved_variables_changed(),
            UserEvent::UpdateChecked(result) => self.finish_update_check(result),
            UserEvent::UpdateInstalled(result) => self.finish_install(event_loop, result),
            UserEvent::TaskPanicked(task) => self.recover_from_panic(task),
        }
    }
}

const fn is_missing(error: &saved_variables::LocateError) -> bool {
    matches!(
        error,
        saved_variables::LocateError::NotFound | saved_variables::LocateError::InstallNotFound
    )
}

fn warn(title: &str, message: &impl fmt::Display) {
    MessageDialog::new()
        .set_level(MessageLevel::Warning)
        .set_title(title)
        .set_description(message.to_string())
        .show();
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

fn automatic_update_delay(last_check: Option<DateTime<Utc>>, now: DateTime<Utc>) -> Duration {
    let Some(last_check) = last_check else {
        return Duration::ZERO;
    };
    (last_check + chrono::Duration::hours(24) - now)
        .to_std()
        .unwrap_or(Duration::ZERO)
        .min(AUTOMATIC_UPDATE_INTERVAL)
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
    use super::{automatic_update_delay, last_synced_label};
    use chrono::{DateTime, TimeZone, Utc};
    use std::time::Duration;

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

    #[test]
    fn automatic_update_checks_run_at_most_once_per_day() {
        let now = Utc.with_ymd_and_hms(2026, 9, 25, 22, 0, 0).unwrap();

        assert_eq!(automatic_update_delay(None, now), Duration::ZERO);
        assert_eq!(
            automatic_update_delay(Some(now - chrono::Duration::hours(23)), now),
            Duration::from_hours(1)
        );
        assert_eq!(
            automatic_update_delay(Some(now - chrono::Duration::hours(24)), now),
            Duration::ZERO
        );
        assert_eq!(
            automatic_update_delay(Some(now + chrono::Duration::hours(1)), now),
            Duration::from_hours(24)
        );
    }
}
