use std::net::IpAddr;
use std::path::{Path, PathBuf};

use anyhow::Context;
use serde::Deserialize;

/// The repo's example config doubles as the baseline written on first run, so
/// the documented defaults and the runtime baseline can never drift apart.
const BASELINE_CONFIG: &str = include_str!("../lagoon.toml");

#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    /// Address to listen on — set to the VPS's Tailscale IP for tailnet-only
    /// access, or 127.0.0.1 for local development.
    pub bind: IpAddr,
    pub port: u16,
    /// Directory holding the built frontend served at `/`.
    pub static_dir: PathBuf,
    /// `SQLite` database file backing the canonical store.
    pub db_path: PathBuf,
    /// Directory of the embedding model. When absent on disk, search degrades to
    /// keyword-only (no semantic search or suggestions).
    #[serde(default)]
    pub model_dir: Option<PathBuf>,
}

impl Config {
    /// Load and validate the config from `path`, creating it from the embedded
    /// baseline if it does not yet exist.
    pub fn load_or_create(path: &Path) -> anyhow::Result<Self> {
        if !path.exists() {
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)
                    .with_context(|| format!("creating config directory {}", parent.display()))?;
            }
            std::fs::write(path, BASELINE_CONFIG)
                .with_context(|| format!("writing baseline config to {}", path.display()))?;
        }

        let text = std::fs::read_to_string(path)
            .with_context(|| format!("reading config {}", path.display()))?;
        let config: Config =
            toml::from_str(&text).with_context(|| format!("parsing config {}", path.display()))?;
        Ok(config)
    }
}
