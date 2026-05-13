//! Vault encryption: AES-256-GCM with Argon2id / PBKDF2 key derivation.
//!
//! Port of vault.py + vault_crypto.py. Backward-compatible with Python-created
//! vaults: identical KDF parameters, salt format (hex in project table),
//! verifier JSON structure, and AES-GCM ciphertext/tag split.
//!
//! R1 scope: derive_key_*, encrypt_bytes, decrypt_bytes, set_password,
//! verify_password, check_vault_has_password.
//! Document-level encrypt/decrypt/remove_password are deferred to T6.

use crate::db;
use crate::types::{VaultError, VaultResult};

use aes_gcm::aead::Aead;
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
use argon2::{Algorithm, Argon2, Params, Version};
use rand::Rng;

// ---------------------------------------------------------------------------
// Constants (must match Python exactly)
// ---------------------------------------------------------------------------

const SALT_SIZE: usize = 32;
const KEY_SIZE: usize = 32;
const IV_SIZE: usize = 12;
const TAG_SIZE: usize = 16;

// Argon2id params
const ARGON2_TIME_COST: u32 = 3;
const ARGON2_MEMORY_COST: u32 = 65536; // 64 MB
const ARGON2_PARALLELISM: u32 = 4;

// PBKDF2 params
const PBKDF2_ITERATIONS: u32 = 600_000;

/// Known plaintext used to create/verify the password verifier.
const VERIFY_PLAINTEXT: &[u8] = b"SCANSORT_VAULT_VERIFY";

// ---------------------------------------------------------------------------
// Key derivation
// ---------------------------------------------------------------------------

/// Derive a 32-byte key using Argon2id (matches Python argon2-cffi params).
fn derive_key_argon2id(password: &str, salt: &[u8]) -> VaultResult<[u8; KEY_SIZE]> {
    let params = Params::new(
        ARGON2_MEMORY_COST,
        ARGON2_TIME_COST,
        ARGON2_PARALLELISM,
        Some(KEY_SIZE),
    )
    .map_err(|e| VaultError::new(format!("Argon2 params error: {e}")))?;

    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);

    let mut key = [0u8; KEY_SIZE];
    argon2
        .hash_password_into(password.as_bytes(), salt, &mut key)
        .map_err(|e| VaultError::new(format!("Argon2 hash error: {e}")))?;

    Ok(key)
}

/// Derive a 32-byte key using PBKDF2-SHA256 (matches Python hashlib params).
fn derive_key_pbkdf2(password: &str, salt: &[u8]) -> [u8; KEY_SIZE] {
    use hmac::Hmac;
    use sha2::Sha256;

    let mut key = [0u8; KEY_SIZE];
    pbkdf2::pbkdf2::<Hmac<Sha256>>(
        password.as_bytes(),
        salt,
        PBKDF2_ITERATIONS,
        &mut key,
    )
    .expect("PBKDF2 output length is valid");
    key
}

/// Derive key using the specified KDF. Defaults to pbkdf2 for old vaults.
fn derive_key(password: &str, salt: &[u8], kdf: &str) -> VaultResult<[u8; KEY_SIZE]> {
    match kdf {
        "argon2id" => derive_key_argon2id(password, salt),
        _ => Ok(derive_key_pbkdf2(password, salt)),
    }
}

// ---------------------------------------------------------------------------
// Low-level encrypt / decrypt
// ---------------------------------------------------------------------------

/// Encrypt raw bytes with AES-256-GCM. Returns (ciphertext, iv, tag).
///
/// The iv is 12 random bytes. The tag is the last 16 bytes of GCM output,
/// matching Python's AESGCM split: `ct[:-16], ct[-16:]`.
pub fn encrypt_bytes(
    key: &[u8; KEY_SIZE],
    data: &[u8],
) -> VaultResult<(Vec<u8>, Vec<u8>, Vec<u8>)> {
    let cipher = Aes256Gcm::new_from_slice(key)
        .map_err(|e| VaultError::new(format!("AES key error: {e}")))?;

    let mut iv_bytes = [0u8; IV_SIZE];
    rand::rng().fill(&mut iv_bytes);
    let nonce = Nonce::from_slice(&iv_bytes);

    // aes-gcm appends the 16-byte tag to the ciphertext, same as Python AESGCM
    let ct_with_tag = cipher
        .encrypt(nonce, data)
        .map_err(|e| VaultError::new(format!("Encryption failed: {e}")))?;

    let ct_len = ct_with_tag.len() - TAG_SIZE;
    let ct = ct_with_tag[..ct_len].to_vec();
    let tag = ct_with_tag[ct_len..].to_vec();

    Ok((ct, iv_bytes.to_vec(), tag))
}

/// Decrypt AES-256-GCM data. Expects separate ciphertext, iv, and tag.
pub fn decrypt_bytes(
    key: &[u8; KEY_SIZE],
    ciphertext: &[u8],
    iv: &[u8],
    tag: &[u8],
) -> VaultResult<Vec<u8>> {
    if iv.len() != IV_SIZE {
        return Err(VaultError::new(format!(
            "Invalid IV length: expected {IV_SIZE}, got {}",
            iv.len()
        )));
    }
    if tag.len() != TAG_SIZE {
        return Err(VaultError::new(format!(
            "Invalid tag length: expected {TAG_SIZE}, got {}",
            tag.len()
        )));
    }

    let cipher = Aes256Gcm::new_from_slice(key)
        .map_err(|e| VaultError::new(format!("AES key error: {e}")))?;

    let nonce = Nonce::from_slice(iv);

    // Reassemble ct+tag as expected by aes-gcm
    let mut ct_with_tag = Vec::with_capacity(ciphertext.len() + TAG_SIZE);
    ct_with_tag.extend_from_slice(ciphertext);
    ct_with_tag.extend_from_slice(tag);

    cipher
        .decrypt(nonce, ct_with_tag.as_slice())
        .map_err(|e| VaultError::new(format!("Decryption failed (wrong password?): {e}")))
}

// ---------------------------------------------------------------------------
// Vault-level password operations
// ---------------------------------------------------------------------------

/// Set the encryption password for a vault.
///
/// Generates a random salt (or reuses existing), derives a key via Argon2id,
/// and stores a verifier ciphertext in the project table. The password
/// itself is never stored.
pub fn set_password(path: &str, password: &str) -> VaultResult<()> {
    if password.is_empty() {
        return Err(VaultError::new("Password must not be empty"));
    }

    let conn = db::connect(path)?;

    // Get or create salt
    let salt = match db::get_project_key(&conn, "encryption_salt")? {
        Some(hex_str) if !hex_str.is_empty() => {
            hex::decode(&hex_str)
                .map_err(|e| VaultError::new(format!("Invalid salt hex: {e}")))?
        }
        _ => {
            let mut salt = vec![0u8; SALT_SIZE];
            rand::rng().fill(&mut salt[..]);
            db::set_project_key(&conn, "encryption_salt", &hex::encode(&salt))?;
            salt
        }
    };

    // Derive key using Argon2id (preferred KDF)
    let kdf = "argon2id";
    let key = derive_key(password, &salt, kdf)?;

    // Create verifier: encrypt known plaintext
    let (ct, iv, tag) = encrypt_bytes(&key, VERIFY_PLAINTEXT)?;

    let verifier = serde_json::json!({
        "ciphertext": hex::encode(&ct),
        "iv": hex::encode(&iv),
        "tag": hex::encode(&tag),
        "kdf": kdf,
    });
    db::set_project_key(&conn, "password_verifier", &verifier.to_string())?;

    Ok(())
}

/// Verify a password against the stored verifier. Returns true if correct.
pub fn verify_password(path: &str, password: &str) -> VaultResult<bool> {
    let conn = db::connect(path)?;

    let salt_hex = db::get_project_key(&conn, "encryption_salt")?
        .ok_or_else(|| VaultError::new("No password has been set on this vault"))?;
    if salt_hex.is_empty() {
        return Err(VaultError::new("No password has been set on this vault"));
    }

    let verifier_json = db::get_project_key(&conn, "password_verifier")?
        .ok_or_else(|| VaultError::new("No password verifier found in vault"))?;

    let salt = hex::decode(&salt_hex)
        .map_err(|e| VaultError::new(format!("Invalid salt hex: {e}")))?;

    let verifier: serde_json::Value = serde_json::from_str(&verifier_json)?;
    let ct = hex::decode(verifier["ciphertext"].as_str().unwrap_or(""))
        .map_err(|e| VaultError::new(format!("Invalid verifier ciphertext hex: {e}")))?;
    let iv = hex::decode(verifier["iv"].as_str().unwrap_or(""))
        .map_err(|e| VaultError::new(format!("Invalid verifier iv hex: {e}")))?;
    let tag = hex::decode(verifier["tag"].as_str().unwrap_or(""))
        .map_err(|e| VaultError::new(format!("Invalid verifier tag hex: {e}")))?;

    // KDF detection: if absent, default to "pbkdf2" (old vaults)
    let kdf = verifier["kdf"].as_str().unwrap_or("pbkdf2");

    let key = derive_key(password, &salt, kdf)?;

    match decrypt_bytes(&key, &ct, &iv, &tag) {
        Ok(plaintext) => Ok(plaintext == VERIFY_PLAINTEXT),
        Err(_) => Ok(false),
    }
}

/// Check whether a vault has a password set.
///
/// Returns (has_password, hint).
pub fn check_vault_has_password(path: &str) -> VaultResult<(bool, String)> {
    let conn = db::connect_readonly(path)?;

    let salt = db::get_project_key(&conn, "encryption_salt")?;
    let has_password = salt
        .as_ref()
        .map(|s| !s.is_empty())
        .unwrap_or(false);

    let hint = db::get_project_key(&conn, "password_hint")?
        .unwrap_or_default();

    Ok((has_password, hint))
}

/// Derive the encryption key for a vault (reads salt + verifier, derives key).
#[allow(dead_code)]
fn vault_key(path: &str, password: &str) -> VaultResult<[u8; KEY_SIZE]> {
    let conn = db::connect(path)?;

    let salt_hex = db::get_project_key(&conn, "encryption_salt")?
        .ok_or_else(|| VaultError::new("No password set on vault"))?;
    let salt = hex::decode(&salt_hex)
        .map_err(|e| VaultError::new(format!("Invalid salt hex: {e}")))?;

    let verifier_json = db::get_project_key(&conn, "password_verifier")?
        .ok_or_else(|| VaultError::new("No password verifier found"))?;
    let verifier: serde_json::Value = serde_json::from_str(&verifier_json)?;
    let kdf = verifier["kdf"].as_str().unwrap_or("pbkdf2");

    derive_key(password, &salt, kdf)
}
