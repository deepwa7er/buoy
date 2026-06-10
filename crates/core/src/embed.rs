//! Sentence embeddings for semantic search.
//!
//! [`TextEmbedder`] is the seam the store depends on: anything that turns
//! text into an L2-normalized vector. [`MiniLmEmbedder`] is the production
//! implementation — all-MiniLM-L6-v2 through candle, validated by the
//! Phase 3 spike (see the `spike/candle-embeddings` branch). Tests use
//! synthetic embedders so store logic doesn't need the 91MB model.

use std::path::Path;

use candle_core::{Device, Tensor};
use candle_nn::VarBuilder;
use candle_transformers::models::bert::{BertModel, Config, DTYPE};
use tokenizers::Tokenizer;

use crate::error::{Error, Result};

/// Dimensionality of the embedding vectors stored and searched.
pub const EMBEDDING_DIM: usize = 384;

/// How many threads candle's rayon pool may use. The Phase 3 spike showed
/// thread-per-core oversubscribes on mobile and makes latency worse *and*
/// unstable (57ms noisy vs 37ms stable on the iOS simulator); two threads
/// is the sweet spot there and costs little on desktop for a model this
/// small.
const EMBED_THREADS: usize = 2;

/// Turns text into an L2-normalized [`EMBEDDING_DIM`]-dim vector.
///
/// `Send` so implementations can sit behind the FFI layer's mutex.
pub trait TextEmbedder: Send {
    fn embed(&self, text: &str) -> Result<Vec<f32>>;
}

/// all-MiniLM-L6-v2 via candle, on CPU.
pub struct MiniLmEmbedder {
    model: BertModel,
    tokenizer: Tokenizer,
    device: Device,
}

impl MiniLmEmbedder {
    /// Load the model from a directory containing `model.safetensors`,
    /// `tokenizer.json`, and `config.json` (`just fetch-model` downloads
    /// them). Loading takes a few hundred milliseconds — call off the UI
    /// thread.
    pub fn load(dir: &Path) -> Result<Self> {
        // Cap the global rayon pool before candle's first use of it. If
        // the application already configured rayon this fails, which is
        // fine — we only want to prevent the *default* thread-per-core
        // pool from oversubscribing mobile hardware.
        let _ = rayon::ThreadPoolBuilder::new()
            .num_threads(EMBED_THREADS)
            .build_global();

        let device = Device::Cpu;
        let config: Config =
            serde_json::from_str(&std::fs::read_to_string(dir.join("config.json")).map_err(
                |source| Error::ModelLoad {
                    detail: format!("reading config.json in {}: {source}", dir.display()),
                },
            )?)
            .map_err(|source| Error::ModelLoad {
                detail: format!("parsing config.json: {source}"),
            })?;

        let tokenizer = Tokenizer::from_file(dir.join("tokenizer.json")).map_err(|source| {
            Error::ModelLoad {
                detail: format!("loading tokenizer.json: {source}"),
            }
        })?;

        // Buffered (owned) load rather than mmap: candle's mmap path is
        // `unsafe` and the workspace denies unsafe code. The weights are
        // resident in memory during inference either way.
        let weights =
            std::fs::read(dir.join("model.safetensors")).map_err(|source| Error::ModelLoad {
                detail: format!("reading model.safetensors in {}: {source}", dir.display()),
            })?;
        let vb =
            VarBuilder::from_buffered_safetensors(weights, DTYPE, &device).map_err(|source| {
                Error::ModelLoad {
                    detail: format!("parsing model.safetensors: {source}"),
                }
            })?;
        let model = BertModel::load(vb, &config).map_err(|source| Error::ModelLoad {
            detail: format!("building model: {source}"),
        })?;

        Ok(Self {
            model,
            tokenizer,
            device,
        })
    }

    /// Tokenize, forward pass, attention-masked mean pooling over the
    /// token axis, L2 normalization.
    fn embed_inner(&self, text: &str) -> candle_core::Result<Vec<f32>> {
        let encoding = self
            .tokenizer
            .encode(text, true)
            .map_err(candle_core::Error::wrap)?;
        let ids = Tensor::new(encoding.get_ids(), &self.device)?.unsqueeze(0)?;
        let type_ids = Tensor::new(encoding.get_type_ids(), &self.device)?.unsqueeze(0)?;
        let mask = Tensor::new(encoding.get_attention_mask(), &self.device)?.unsqueeze(0)?;

        let hidden = self.model.forward(&ids, &type_ids, Some(&mask))?;

        // Mean over real (unmasked) tokens only.
        let mask_f = mask.to_dtype(DTYPE)?.unsqueeze(2)?; // [1, seq, 1]
        let summed = hidden.broadcast_mul(&mask_f)?.sum(1)?; // [1, dim]
        let counts = mask_f.sum(1)?; // [1, 1]
        let mean = summed.broadcast_div(&counts)?;

        let norm = mean.sqr()?.sum_keepdim(1)?.sqrt()?;
        let normalized = mean.broadcast_div(&norm)?;
        normalized.squeeze(0)?.to_vec1()
    }
}

impl TextEmbedder for MiniLmEmbedder {
    fn embed(&self, text: &str) -> Result<Vec<f32>> {
        let vector = self.embed_inner(text).map_err(|source| Error::Embedding {
            detail: source.to_string(),
        })?;
        debug_assert_eq!(vector.len(), EMBEDDING_DIM);
        Ok(vector)
    }
}

/// Encode a vector as little-endian f32 bytes for BLOB storage.
pub(crate) fn vector_to_blob(vector: &[f32]) -> Vec<u8> {
    let mut blob = Vec::with_capacity(vector.len() * 4);
    for value in vector {
        blob.extend_from_slice(&value.to_le_bytes());
    }
    blob
}

/// Decode a BLOB written by [`vector_to_blob`].
pub(crate) fn blob_to_vector(blob: &[u8]) -> Result<Vec<f32>> {
    if blob.len() % 4 != 0 {
        return Err(Error::CorruptRow {
            table: "embeddings",
            detail: format!(
                "vector blob had {} bytes, expected multiple of 4",
                blob.len()
            ),
        });
    }
    Ok(blob
        .chunks_exact(4)
        .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
        .collect())
}

/// Dot product — equal to cosine similarity for L2-normalized vectors.
pub(crate) fn dot(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vector_blob_round_trips() {
        let vector = vec![0.25_f32, -1.5, 0.0, 3.0e-7];
        let blob = vector_to_blob(&vector);
        assert_eq!(blob.len(), 16);
        assert_eq!(blob_to_vector(&blob).unwrap(), vector);
    }

    #[test]
    fn truncated_blob_is_corrupt() {
        let err = blob_to_vector(&[0, 1, 2]).expect_err("should fail");
        assert!(matches!(
            err,
            Error::CorruptRow {
                table: "embeddings",
                ..
            }
        ));
    }

    #[test]
    fn dot_of_normalized_vectors_is_cosine() {
        let a = [1.0_f32, 0.0];
        let b = [0.0_f32, 1.0];
        let c = [1.0_f32, 0.0];
        assert!(dot(&a, &b).abs() < 1e-6);
        assert!((dot(&a, &c) - 1.0).abs() < 1e-6);
    }
}
