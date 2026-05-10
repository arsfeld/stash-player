//! On-disk caches under `XDG_CACHE_HOME/stash-player/`.

use std::path::PathBuf;

use directories::ProjectDirs;

use crate::config::Error;

fn project_dirs() -> Result<ProjectDirs, Error> {
    ProjectDirs::from("one", "arsfeld", "stash-player").ok_or(Error::NoConfigDir)
}

/// Directory for cached thumbnail bitmaps. Caller is responsible for
/// `fs::create_dir_all` before writing.
pub fn thumb_dir() -> Result<PathBuf, Error> {
    Ok(project_dirs()?.cache_dir().join("thumbs"))
}

/// Directory we materialize bundled icons into at startup so GTK's
/// `IconTheme` can pick them up via `add_search_path`. Layout follows the
/// XDG icon-theme spec (`<root>/hicolor/scalable/actions/<name>.svg`).
pub fn icon_root() -> Result<PathBuf, Error> {
    Ok(project_dirs()?.cache_dir().join("icons"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thumb_dir_lives_under_cache_dir_and_is_named_thumbs() {
        let dir = thumb_dir().expect("XDG cache dir should resolve");
        assert_eq!(dir.file_name().and_then(|s| s.to_str()), Some("thumbs"));
        let parent = dir.parent().unwrap();
        // Parent should be the project's cache dir; assert by membership
        // rather than exact path so this works on Linux/macOS/Windows.
        let expected_parent = project_dirs().unwrap().cache_dir().to_owned();
        assert_eq!(parent, expected_parent);
    }
}
