use std::{env, io};

pub fn is_enabled() -> io::Result<bool> {
    platform::is_enabled(&env::current_exe()?)
}

pub fn set_enabled(enabled: bool) -> io::Result<()> {
    let executable = env::current_exe()?;
    if enabled {
        platform::enable(&executable)
    } else {
        platform::disable()
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use std::{
        env, fs, io,
        path::{Path, PathBuf},
    };

    const LABEL: &str = "io.github.kjhickman.arbitrage-companion";

    pub fn is_enabled(executable: &Path) -> io::Result<bool> {
        match fs::read_to_string(launch_agent_path()?) {
            Ok(contents) => Ok(contents == launch_agent(executable)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(error),
        }
    }

    pub fn enable(executable: &Path) -> io::Result<()> {
        let path = launch_agent_path()?;
        if let Some(directory) = path.parent() {
            fs::create_dir_all(directory)?;
        }
        fs::write(path, launch_agent(executable))
    }

    pub fn disable() -> io::Result<()> {
        match fs::remove_file(launch_agent_path()?) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error),
        }
    }

    fn launch_agent_path() -> io::Result<PathBuf> {
        let home = env::var_os("HOME").ok_or_else(|| {
            io::Error::new(io::ErrorKind::NotFound, "the home directory is unavailable")
        })?;
        Ok(Path::new(&home)
            .join("Library")
            .join("LaunchAgents")
            .join(format!("{LABEL}.plist")))
    }

    fn launch_agent(executable: &Path) -> String {
        let executable = escape_xml(&executable.to_string_lossy());
        format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{executable}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
"#
        )
    }

    fn escape_xml(value: &str) -> String {
        value
            .replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
            .replace('"', "&quot;")
            .replace('\'', "&apos;")
    }

    #[cfg(test)]
    mod tests {
        use super::launch_agent;
        use std::path::Path;

        #[test]
        fn launch_agent_contains_an_escaped_executable_path() {
            let plist = launch_agent(Path::new("/Applications/Arbitrage & More.app/Companion"));

            assert!(
                plist.contains("<string>/Applications/Arbitrage &amp; More.app/Companion</string>")
            );
            assert!(plist.contains("<key>RunAtLoad</key>\n    <true/>"));
        }
    }
}

#[cfg(target_os = "windows")]
mod platform {
    use std::{io, path::Path};
    use winreg::{
        RegKey,
        enums::{HKEY_CURRENT_USER, KEY_READ, KEY_WRITE},
    };

    const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
    const VALUE_NAME: &str = "Arbitrage Companion";

    pub fn is_enabled(executable: &Path) -> io::Result<bool> {
        let current_user = RegKey::predef(HKEY_CURRENT_USER);
        let key = match current_user.open_subkey_with_flags(RUN_KEY, KEY_READ) {
            Ok(key) => key,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
            Err(error) => return Err(error),
        };
        match key.get_value::<String, _>(VALUE_NAME) {
            Ok(command) => Ok(command == command_line(executable)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(error),
        }
    }

    pub fn enable(executable: &Path) -> io::Result<()> {
        let current_user = RegKey::predef(HKEY_CURRENT_USER);
        let (key, _) = current_user.create_subkey(RUN_KEY)?;
        key.set_value(VALUE_NAME, &command_line(executable))
    }

    pub fn disable() -> io::Result<()> {
        let current_user = RegKey::predef(HKEY_CURRENT_USER);
        let key = match current_user.open_subkey_with_flags(RUN_KEY, KEY_WRITE) {
            Ok(key) => key,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(error),
        };
        match key.delete_value(VALUE_NAME) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error),
        }
    }

    fn command_line(executable: &Path) -> String {
        format!("\"{}\"", executable.display())
    }

    #[cfg(test)]
    mod tests {
        use super::command_line;
        use std::path::Path;

        #[test]
        fn command_line_quotes_the_executable_path() {
            assert_eq!(
                command_line(Path::new(
                    r"C:\Program Files\Arbitrage Companion\arbitrage-companion.exe"
                )),
                r#""C:\Program Files\Arbitrage Companion\arbitrage-companion.exe""#
            );
        }
    }
}
