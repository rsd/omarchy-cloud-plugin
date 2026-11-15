//! Secret holders. Their Debug output is `***`, they have no Display, and
//! their memory is zeroed on drop (best effort: rclone's own copies, once
//! it reads rclone.conf, are outside this process's reach). A secret never
//! goes on an argument vector: it is written into rclone.conf in-process
//! (`app::set_client`).

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

/// Removes the secret from `text` (e.g. a command's error output).
pub fn scrub(text: &str, secret: &Secret) -> String {
    if secret.is_empty() {
        text.to_string()
    } else {
        text.replace(secret.expose(), "***")
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
    fn scrub_masks_the_secret() {
        let mut s = Secret::new();
        for c in "hunter2".chars() {
            s.push(c);
        }
        assert_eq!(scrub("error near hunter2!", &s), "error near ***!");
        assert_eq!(scrub("nothing", &Secret::new()), "nothing");
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
