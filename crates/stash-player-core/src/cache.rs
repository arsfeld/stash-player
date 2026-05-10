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
