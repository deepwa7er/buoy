//! Buoy core library.
//!
//! Shared business logic for the Buoy note-taking app, consumed by the iOS,
//! macOS, and Linux clients. See `docs/plan-poc.md` and `docs/plan-buildout.md`
//! at the repository root for design and roadmap.

mod embed;
mod error;
mod search;
mod store;
mod thought;

pub use embed::{EMBEDDING_DIM, MiniLmEmbedder, TextEmbedder};
pub use error::{Error, Result};
pub use search::{MatchRange, ThoughtMatch};
pub use store::{Cursor, DEFAULT_PAGE_SIZE, Page, ThoughtStore};
pub use thought::{EditEntry, Thought};
