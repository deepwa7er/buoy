use std::path::PathBuf;

use uuid::Uuid;

/// Errors produced by the Buoy core.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// The underlying `SQLite` operation failed.
    #[error("storage error: {0}")]
    Storage(#[from] rusqlite::Error),

    /// The database file could not be opened at the requested path.
    #[error("could not open database at {path}: {source}")]
    OpenDatabase {
        path: PathBuf,
        #[source]
        source: rusqlite::Error,
    },

    /// A stored row contained data the application could not interpret.
    /// Indicates corruption or an out-of-sync schema, not a user error.
    #[error("corrupt row in `{table}`: {detail}")]
    CorruptRow { table: &'static str, detail: String },

    /// No thought with the given id exists.
    #[error("no thought with id {id}")]
    NotFound { id: Uuid },

    /// The embedding model could not be loaded from disk.
    #[error("could not load embedding model: {detail}")]
    ModelLoad { detail: String },

    /// Computing an embedding failed.
    #[error("embedding failed: {detail}")]
    Embedding { detail: String },

    /// A semantic operation was requested but no embedder is attached to
    /// the store (e.g. the model file isn't available on this device).
    #[error("no embedder attached to the store")]
    NoEmbedder,
}

pub type Result<T> = std::result::Result<T, Error>;
