use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::{
    env, fs, io,
    path::{Path, PathBuf},
};

const DIRECTORY_NAME: &str = "Arbitrage Companion";
const FILE_NAME: &str = "settings.json";

#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wow_directory: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_synced: Option<DateTime<Utc>>,
}

impl Settings {
    pub fn load() -> Self {
        settings_path().map_or_else(Self::default, |path| Self::load_from(&path))
    }

    pub fn save(&self) -> io::Result<()> {
        let path = settings_path().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "no settings directory is available",
            )
        })?;
        self.save_to(&path)
    }

    fn load_from(path: &Path) -> Self {
        fs::read(path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    fn save_to(&self, path: &Path) -> io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_vec_pretty(self).map_err(io::Error::other)?;
        fs::write(path, json)
    }
}

#[cfg(target_os = "macos")]
fn settings_path() -> Option<PathBuf> {
    env::var_os("HOME").map(|home| {
        Path::new(&home)
            .join("Library")
            .join("Application Support")
            .join(DIRECTORY_NAME)
            .join(FILE_NAME)
    })
}

#[cfg(target_os = "windows")]
fn settings_path() -> Option<PathBuf> {
    env::var_os("APPDATA").map(|base| Path::new(&base).join(DIRECTORY_NAME).join(FILE_NAME))
}

#[cfg(test)]
mod tests {
    use super::Settings;
    use crate::saved_variables::temp;
    use chrono::{TimeZone, Utc};
    use std::{fs, path::PathBuf};

    #[test]
    fn saved_settings_load_back_unchanged() {
        let directory = temp::Dir::new("settings-round-trip");
        let path = directory.path().join("nested").join("settings.json");
        let settings = Settings {
            wow_directory: Some(PathBuf::from(r"C:\Games\World of Warcraft")),
            last_synced: Some(Utc.with_ymd_and_hms(2026, 9, 25, 21, 15, 0).unwrap()),
        };

        settings.save_to(&path).expect("settings should save");

        assert_eq!(Settings::load_from(&path), settings);
    }

    #[test]
    fn a_missing_file_loads_the_defaults() {
        let directory = temp::Dir::new("settings-missing");

        assert_eq!(
            Settings::load_from(&directory.path().join("settings.json")),
            Settings::default()
        );
    }

    #[test]
    fn a_malformed_file_loads_the_defaults() {
        let directory = temp::Dir::new("settings-malformed");
        let path = directory.path().join("settings.json");
        fs::write(&path, b"{ not json").expect("the file should be writable");

        assert_eq!(Settings::load_from(&path), Settings::default());
    }

    #[test]
    fn reads_the_literal_settings_file() {
        let directory = temp::Dir::new("settings-literal");
        let path = directory.path().join("settings.json");
        fs::write(
            &path,
            br#"{"wow_directory":"C:\\Games\\World of Warcraft","last_synced":"2026-09-25T21:15:00Z"}"#,
        )
        .expect("the file should be writable");

        assert_eq!(
            Settings::load_from(&path),
            Settings {
                wow_directory: Some(PathBuf::from(r"C:\Games\World of Warcraft")),
                last_synced: Some(Utc.with_ymd_and_hms(2026, 9, 25, 21, 15, 0).unwrap()),
            }
        );
    }
}
