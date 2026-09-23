use std::{
    env, fmt, fs,
    path::{Path, PathBuf},
};

pub const OVERRIDE_VARIABLE: &str = "ARBITRAGE_SAVED_VARIABLES";
pub const FILE_NAME: &str = "Arbitrage.lua";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LocateError {
    InvalidOverride { path: PathBuf },
    NotFound,
    Ambiguous(Vec<PathBuf>),
}

impl fmt::Display for LocateError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidOverride { path } => write!(
                formatter,
                "{OVERRIDE_VARIABLE} is not a file: {}",
                path.display()
            ),
            Self::NotFound => write!(formatter, "Run Arbitrage in WoW once"),
            Self::Ambiguous(paths) => {
                write!(
                    formatter,
                    "Several accounts have Arbitrage data. Set {OVERRIDE_VARIABLE} to one of:"
                )?;
                for path in paths {
                    write!(formatter, " {}", path.display())?;
                }
                Ok(())
            }
        }
    }
}

pub fn locate() -> Result<PathBuf, LocateError> {
    let over = env::var_os(OVERRIDE_VARIABLE).map(PathBuf::from);
    locate_with(over.as_deref(), &product_roots())
}

pub fn product_roots() -> Vec<PathBuf> {
    platform_product_roots()
}

pub fn locate_with(over: Option<&Path>, roots: &[PathBuf]) -> Result<PathBuf, LocateError> {
    if let Some(path) = over {
        return if path.is_file() {
            Ok(path.to_path_buf())
        } else {
            Err(LocateError::InvalidOverride {
                path: path.to_path_buf(),
            })
        };
    }

    let mut found: Vec<PathBuf> = roots.iter().flat_map(|root| locate_in(root)).collect();
    found.sort();
    found.dedup();

    match found.len() {
        0 => Err(LocateError::NotFound),
        1 => Ok(found.remove(0)),
        _ => Err(LocateError::Ambiguous(found)),
    }
}

pub fn locate_in(root: &Path) -> Vec<PathBuf> {
    let Ok(accounts) = fs::read_dir(root.join("WTF").join("Account")) else {
        return Vec::new();
    };

    let mut found: Vec<PathBuf> = accounts
        .flatten()
        .map(|account| account.path().join("SavedVariables").join(FILE_NAME))
        .filter(|path| path.is_file())
        .collect();
    found.sort();
    found
}

#[cfg(target_os = "macos")]
fn platform_product_roots() -> Vec<PathBuf> {
    vec![PathBuf::from(
        "/Applications/World of Warcraft/_classic_beta_",
    )]
}

#[cfg(target_os = "windows")]
fn platform_product_roots() -> Vec<PathBuf> {
    ["ProgramFiles(x86)", "ProgramFiles"]
        .into_iter()
        .filter_map(env::var_os)
        .map(|base| {
            Path::new(&base)
                .join("World of Warcraft")
                .join("_classic_beta_")
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{FILE_NAME, LocateError, locate_in, locate_with};
    use crate::saved_variables::temp;
    use std::{fs, path::PathBuf};

    fn account(root: &temp::Dir, name: &str) -> PathBuf {
        let directory = root.path().join("WTF").join("Account").join(name);
        fs::create_dir_all(&directory).expect("the account directory should be creatable");
        let path = directory.join("SavedVariables");
        fs::create_dir_all(&path).expect("the SavedVariables directory should be creatable");
        let file = path.join(FILE_NAME);
        fs::write(&file, b"\nARBITRAGE_DATABASE = {\n}\n").expect("the file should be writable");
        file
    }

    #[test]
    fn finds_nothing_under_an_empty_root() {
        let root = temp::Dir::new("locate-zero");

        assert!(locate_in(root.path()).is_empty());
        assert_eq!(
            locate_with(None, &[root.path().to_path_buf()]),
            Err(LocateError::NotFound)
        );
    }

    #[test]
    fn finds_one_account_file() {
        let root = temp::Dir::new("locate-one");
        let file = account(&root, "ACCOUNT_ONE");

        assert_eq!(locate_in(root.path()), vec![file.clone()]);
        assert_eq!(locate_with(None, &[root.path().to_path_buf()]), Ok(file));
    }

    #[test]
    fn refuses_to_pick_between_two_account_files() {
        let root = temp::Dir::new("locate-two");
        let first = account(&root, "ACCOUNT_ONE");
        let second = account(&root, "ACCOUNT_TWO");

        let mut expected = vec![first, second];
        expected.sort();

        assert_eq!(locate_in(root.path()), expected);
        assert_eq!(
            locate_with(None, &[root.path().to_path_buf()]),
            Err(LocateError::Ambiguous(expected))
        );
    }

    #[test]
    fn reports_a_missing_override_instead_of_the_run_once_message() {
        let root = temp::Dir::new("locate-override");
        let present = account(&root, "ACCOUNT_ONE");
        let missing = root.path().join("nowhere").join(FILE_NAME);

        assert_eq!(
            locate_with(Some(&missing), &[root.path().to_path_buf()]),
            Err(LocateError::InvalidOverride {
                path: missing.clone()
            })
        );
        assert_ne!(
            locate_with(Some(&missing), &[root.path().to_path_buf()]),
            Err(LocateError::NotFound)
        );
        assert_eq!(
            locate_with(Some(&present), &[root.path().to_path_buf()]),
            Ok(present)
        );
    }

    #[test]
    fn an_override_skips_the_product_search() {
        let root = temp::Dir::new("locate-override-only");
        let first = account(&root, "ACCOUNT_ONE");
        account(&root, "ACCOUNT_TWO");

        assert_eq!(
            locate_with(Some(&first), &[root.path().to_path_buf()]),
            Ok(first)
        );
    }
}
