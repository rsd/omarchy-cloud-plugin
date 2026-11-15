//! Secret holders. Their Debug output is `***`, they have no Display, and
//! their memory is zeroed on drop (best effort: the OS pipe to rclone and
//! rclone's own copies are outside this process's reach).

use std::fmt;
use zeroize::Zeroize;

/// Capacity reserved up front so typing never reallocates (a reallocation
/// would leave an unzeroed copy behind).
const SECRET_CAP: usize = 512;

pub struct Secret(String);

impl Secret {
    pub fn new() -> Secret {
        Secret(String::with_capacity(SECRET_CAP))
    }

    pub fn push(&mut self, c: char) {
        if self.0.len() + c.len_utf8() <= SECRET_CAP {
            self.0.push(c);
        }
    }

    pub fn pop(&mut self) {
        self.0.pop();
    }

    pub fn clear(&mut self) {
        self.0.zeroize();
        self.0.reserve(SECRET_CAP);
    }

    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.0.chars().count()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// The only way to read the value.
    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl Default for Secret {
    fn default() -> Self {
        Secret::new()
    }
}

impl Drop for Secret {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("***")
    }
}

/// An argument vector that carries a secret. Debug masks every argument
/// that contains it; the vector is zeroed on drop.
pub struct SecretArgv {
    args: Vec<String>,
    secret_index: usize,
}

impl SecretArgv {
    pub fn new(args: Vec<String>, secret_index: usize) -> SecretArgv {
        SecretArgv { args, secret_index }
    }

    pub fn expose(&self) -> &[String] {
        &self.args
    }
}

/// Removes the secret from `text` (e.g. a command's error output).
pub fn scrub(text: &str, secret: &Secret) -> String {
    if secret.is_empty() {
        text.to_string()
    } else {
        text.replace(secret.expose(), "***")
    }
}

impl Drop for SecretArgv {
    fn drop(&mut self) {
        for a in &mut self.args {
            a.zeroize();
        }
    }
}

impl fmt::Debug for SecretArgv {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let shown: Vec<&str> = self
            .args
            .iter()
            .enumerate()
            .map(|(i, a)| {
                if i == self.secret_index {
                    "***"
                } else {
                    a.as_str()
                }
            })
            .collect();
        write!(f, "{shown:?}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secret_debug_is_masked() {
        let mut s = Secret::new();
        for c in "GOCSPX-topsecret".chars() {
            s.push(c);
        }
        assert_eq!(format!("{s:?}"), "***");
        assert_eq!(format!("{:?}", Some(&s)), "Some(***)");
        assert_eq!(s.expose(), "GOCSPX-topsecret");
        assert_eq!(s.len(), 16);
        s.pop();
        assert_eq!(s.expose(), "GOCSPX-topsecre");
        s.clear();
        assert!(s.is_empty());
    }

    #[test]
    fn secret_argv_debug_is_masked() {
        let mut s = Secret::new();
        for c in "hunter2".chars() {
            s.push(c);
        }
        let a = SecretArgv::new(vec!["rclone".into(), "client_secret=hunter2".into()], 1);
        let d = format!("{a:?}");
        assert!(!d.contains("hunter2"), "{d}");
        assert_eq!(d, r#"["rclone", "***"]"#);
        assert_eq!(scrub("error near hunter2!", &s), "error near ***!");
    }

    #[test]
    fn secret_capacity_is_bounded() {
        let mut s = Secret::new();
        for _ in 0..(SECRET_CAP + 10) {
            s.push('x');
        }
        assert_eq!(s.len(), SECRET_CAP);
    }
}
