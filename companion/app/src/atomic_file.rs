use std::{
    fs::{self, File, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
};

const TEMP_PREFIX: &str = ".companion-";
const TEMP_ATTEMPTS: usize = 16;

/// Replaces `target` with `contents` so readers see either the old file or the new one, never a
/// partial write.
pub fn replace(target: &Path, contents: &[u8]) -> io::Result<()> {
    let directory = target.parent().unwrap_or_else(|| Path::new("."));
    let (path, file) = create_temp(directory, target)?;

    if let Err(error) = write_all(file, contents).and_then(|()| fs::rename(&path, target)) {
        let _ = fs::remove_file(&path);
        return Err(error);
    }

    Ok(())
}

fn write_all(mut file: File, contents: &[u8]) -> io::Result<()> {
    file.write_all(contents)?;
    file.sync_all()
}

fn create_temp(directory: &Path, target: &Path) -> io::Result<(PathBuf, File)> {
    let stem = target.file_name().unwrap_or_default().to_os_string();

    for _ in 0..TEMP_ATTEMPTS {
        let mut bytes = [0_u8; 8];
        getrandom::getrandom(&mut bytes).map_err(|error| io::Error::other(error.to_string()))?;

        let mut name = stem.clone();
        name.push(format!(
            "{TEMP_PREFIX}{:016x}.tmp",
            u64::from_le_bytes(bytes)
        ));
        let path = directory.join(name);

        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => return Ok((path, file)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
    }

    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "could not create a unique temporary file",
    ))
}
