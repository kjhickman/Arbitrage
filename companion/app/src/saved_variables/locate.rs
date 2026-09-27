use std::{
    fmt, fs,
    path::{Path, PathBuf},
};

#[cfg(target_os = "windows")]
use std::env;

pub const FILE_NAME: &str = "Arbitrage.lua";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LocateError {
    InstallNotFound,
    NotFound,
    Ambiguous(Vec<PathBuf>),
}

impl fmt::Display for LocateError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InstallNotFound => write!(formatter, "World of Warcraft folder not found"),
            Self::NotFound => write!(formatter, "No Arbitrage data yet. Log in to WoW once."),
            Self::Ambiguous(paths) => {
                formatter.write_str("Several accounts have Arbitrage data:")?;
                for path in paths {
                    write!(formatter, " {}", path.display())?;
                }
                Ok(())
            }
        }
    }
}

pub fn locate(roots: &[PathBuf], account_id: Option<&str>) -> Result<PathBuf, LocateError> {
    let mut found: Vec<PathBuf> = roots.iter().flat_map(|root| locate_in(root)).collect();
    found.sort();
    found.dedup();

    match found.len() {
        0 if !roots.iter().any(|root| accounts_directory(root).is_dir()) => {
            Err(LocateError::InstallNotFound)
        }
        0 => Err(LocateError::NotFound),
        1 => Ok(found.remove(0)),
        _ => account_id
            .and_then(|id| {
                let prefix = format!("{id}#");
                found
                    .iter()
                    .find(|path| account_name(path).is_some_and(|name| name.starts_with(&prefix)))
                    .cloned()
            })
            .ok_or(LocateError::Ambiguous(found)),
    }
}

fn account_name(saved_variables: &Path) -> Option<&str> {
    saved_variables.parent()?.parent()?.file_name()?.to_str()
}

fn accounts_directory(root: &Path) -> PathBuf {
    root.join("WTF").join("Account")
}

pub fn locate_in(root: &Path) -> Vec<PathBuf> {
    let Ok(accounts) = fs::read_dir(accounts_directory(root)) else {
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

pub fn product_roots(wow_directory: Option<&Path>) -> Vec<PathBuf> {
    wow_directory.map_or_else(default_roots, |directory| {
        vec![directory.to_path_buf(), directory.join("_classic_beta_")]
    })
}

#[cfg(target_os = "macos")]
fn default_roots() -> Vec<PathBuf> {
    vec![PathBuf::from(
        "/Applications/World of Warcraft/_classic_beta_",
    )]
}

#[cfg(target_os = "windows")]
fn default_roots() -> Vec<PathBuf> {
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
    use super::{FILE_NAME, LocateError, locate, locate_in, product_roots};
    use crate::saved_variables::temp;
    use std::{
        fs,
        path::{Path, PathBuf},
    };

    fn account(root: &Path, name: &str) -> PathBuf {
        let directory = root.join("WTF").join("Account").join(name);
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
            locate(&[root.path().to_path_buf()], None),
            Err(LocateError::InstallNotFound)
        );
    }

    #[test]
    fn an_install_without_arbitrage_data_is_not_found() {
        let root = temp::Dir::new("locate-no-data");
        fs::create_dir_all(root.path().join("WTF").join("Account").join("ACCOUNT_ONE"))
            .expect("the account directory should be creatable");

        assert_eq!(
            locate(&[root.path().to_path_buf()], None),
            Err(LocateError::NotFound)
        );
    }

    #[test]
    fn finds_one_account_file() {
        let root = temp::Dir::new("locate-one");
        let file = account(root.path(), "ACCOUNT_ONE");

        assert_eq!(locate_in(root.path()), vec![file.clone()]);
        assert_eq!(locate(&[root.path().to_path_buf()], None), Ok(file));
    }

    #[test]
    fn refuses_to_pick_between_two_account_files() {
        let root = temp::Dir::new("locate-two");
        let first = account(root.path(), "ACCOUNT_ONE");
        let second = account(root.path(), "ACCOUNT_TWO");

        let mut expected = vec![first, second];
        expected.sort();

        assert_eq!(locate_in(root.path()), expected);
        assert_eq!(
            locate(&[root.path().to_path_buf()], None),
            Err(LocateError::Ambiguous(expected))
        );
    }

    #[test]
    fn the_signed_in_account_picks_its_first_license_folder() {
        let root = temp::Dir::new("locate-account-id");
        account(root.path(), "111#1");
        let first = account(root.path(), "222#1");
        account(root.path(), "222#2");

        assert_eq!(locate(&[root.path().to_path_buf()], Some("222")), Ok(first));
    }

    #[test]
    fn an_account_id_without_a_matching_folder_stays_ambiguous() {
        let root = temp::Dir::new("locate-account-miss");
        let first = account(root.path(), "111#1");
        let second = account(root.path(), "2222#1");

        assert_eq!(
            locate(&[root.path().to_path_buf()], Some("222")),
            Err(LocateError::Ambiguous(vec![first, second]))
        );
    }

    #[test]
    fn a_chosen_wow_folder_finds_the_classic_beta_product_inside_it() {
        let wow = temp::Dir::new("locate-chosen-wow");
        account(&wow.path().join("_classic_beta_"), "ACCOUNT_ONE");

        assert_eq!(
            locate(&product_roots(Some(wow.path())), None),
            Ok(wow
                .path()
                .join("_classic_beta_")
                .join("WTF")
                .join("Account")
                .join("ACCOUNT_ONE")
                .join("SavedVariables")
                .join("Arbitrage.lua"))
        );
    }

    #[test]
    fn a_chosen_product_folder_is_searched_directly() {
        let product = temp::Dir::new("locate-chosen-product");
        account(product.path(), "ACCOUNT_ONE");

        assert_eq!(
            locate(&product_roots(Some(product.path())), None),
            Ok(product
                .path()
                .join("WTF")
                .join("Account")
                .join("ACCOUNT_ONE")
                .join("SavedVariables")
                .join("Arbitrage.lua"))
        );
    }
}
