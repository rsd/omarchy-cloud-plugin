//! Setting a Drive remote's OAuth client in rclone.conf in-process, so the
//! client secret never travels on an argument vector (`rclone config update
//! … client_secret=…` is readable by every local user in /proc/<pid>/cmdline
//! while it runs). Drive keeps `client_secret` as plain text (its option is
//! not IsPassword, so rclone does not obscure it). Everything here is pure;
//! the file I/O is `app::write_client`.

use std::path::PathBuf;

/// The config file path from `rclone config file`: its last non-empty line,
/// when absolute ("Configuration file is stored at:\n<path>\n", or "…doesn't
/// exist, but rclone will use this path:\n<path>\n").
pub fn config_path(stdout: &str) -> Option<PathBuf> {
    let last = stdout
        .lines()
        .rev()
        .map(str::trim)
        .find(|l| !l.is_empty())?;
    let p = PathBuf::from(last);
    p.is_absolute().then_some(p)
}

/// True when rclone.conf is encrypted: its first line that is neither blank
/// nor a comment starts with `RCLONE_ENCRYPT_`.
pub fn is_encrypted(text: &str) -> bool {
    text.lines()
        .map(str::trim)
        .find(|t| !t.is_empty() && !t.starts_with('#') && !t.starts_with(';'))
        .is_some_and(|t| t.starts_with("RCLONE_ENCRYPT_"))
}

/// The section a line opens (`[name]`, surrounding spaces ignored), if any.
fn section_of(line: &str) -> Option<&str> {
    let t = line.trim();
    (t.len() >= 2 && t.starts_with('[') && t.ends_with(']')).then(|| t[1..t.len() - 1].trim())
}

/// The key of a `key = value` line (rclone's parser splits at the first `=`
/// or `:`); None for blank lines, comments and anything else.
fn key_of(line: &str) -> Option<&str> {
    let t = line.trim();
    if t.is_empty() || t.starts_with('#') || t.starts_with(';') {
        return None;
    }
    let i = t.find(['=', ':'])?;
    Some(t[..i].trim())
}

/// The line terminator a line carries (`\r\n`, `\n`, or none at the end).
fn ending(line: &str) -> &'static str {
    if line.ends_with("\r\n") {
        "\r\n"
    } else if line.ends_with('\n') {
        "\n"
    } else {
        ""
    }
}

/// `text` with `client_id` and `client_secret` set in the `[remote]` section
/// only: every line that assigns one of them is replaced (with its own line
/// ending), a missing one is added after the section's last key line (or
/// its header), and every other byte is kept. The secret is written straight into one
/// buffer sized up front (no reallocation leaves a copy behind); the caller
/// zeroizes it. Errors never contain the values.
pub fn set_client(text: &str, remote: &str, id: &str, secret: &str) -> Result<String, String> {
    edit_client(text, remote, id, secret).map(|(out, _)| out)
}

/// `set_client`, also returning the capacity the output buffer was created
/// with (a test compares it with the final one: equal means no growth).
fn edit_client(
    text: &str,
    remote: &str,
    id: &str,
    secret: &str,
) -> Result<(String, usize), String> {
    let lines: Vec<&str> = text.split_inclusive('\n').collect();
    let heads: Vec<usize> = (0..lines.len())
        .filter(|&i| section_of(lines[i]) == Some(remote))
        .collect();
    let start = match heads[..] {
        [i] => i,
        [] => return Err(format!("rclone.conf has no [{remote}] section")),
        _ => {
            return Err(format!(
                "rclone.conf has more than one [{remote}] section; fix it with rclone config"
            ));
        }
    };
    let end = (start + 1..lines.len())
        .find(|&i| section_of(lines[i]).is_some())
        .unwrap_or(lines.len());
    let last = (start + 1..end)
        .rev()
        .find(|&i| key_of(lines[i]).is_some())
        .unwrap_or(start);
    let eol = match ending(lines[start]) {
        "" => "\n",
        e => e,
    };
    let has = |k: &str| (start + 1..end).any(|i| key_of(lines[i]) == Some(k));
    let (has_id, has_secret) = (has("client_id"), has("client_secret"));

    // An upper bound of what is written beyond `text`: every assigning line
    // (duplicates included) or, when absent, one added line, each with its
    // key, value and a line ending of up to two bytes, plus one `eol` for
    // a last line that lacks it. Replaced lines only shrink the real total.
    let count = |k: &str| {
        (start + 1..end)
            .filter(|&i| key_of(lines[i]) == Some(k))
            .count()
    };
    let extra = count("client_id").max(1) * ("client_id = ".len() + id.len() + 2)
        + count("client_secret").max(1) * ("client_secret = ".len() + secret.len() + 2)
        + 2;
    let cap = text.len() + extra;
    let mut out = String::with_capacity(cap);
    for (i, line) in lines.iter().enumerate() {
        let in_section = i > start && i < end;
        match key_of(line) {
            Some("client_id") if in_section => {
                out.push_str("client_id = ");
                out.push_str(id);
                out.push_str(ending(line));
            }
            Some("client_secret") if in_section => {
                out.push_str("client_secret = ");
                out.push_str(secret);
                out.push_str(ending(line));
            }
            _ => out.push_str(line),
        }
        if i == last && !(has_id && has_secret) {
            if ending(line).is_empty() {
                out.push_str(eol);
            }
            if !has_id {
                out.push_str("client_id = ");
                out.push_str(id);
                out.push_str(eol);
            }
            if !has_secret {
                out.push_str("client_secret = ");
                out.push_str(secret);
                out.push_str(eol);
            }
        }
    }
    Ok((out, cap))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Three remotes, comments (both styles), CRLF in the middle one, a
    /// token line with `:` and `=` inside, a key using `:` as separator.
    const CONF: &str = "# rclone.conf, edited by hand once\n\
[work]\n\
type = drive\n\
client_id = work-id\n\
client_secret = work-secret\n\
token = {\"access_token\":\"ya29.x=y\",\"expiry\":\"2026-01-01T00:00:00Z\"}\n\
\n\
[gdrive]\r\n\
type = drive\r\n\
; the old client\r\n\
client_id = old-id.apps.googleusercontent.com\r\n\
scope = drive\r\n\
client_secret: OLD-secret\r\n\
token = {\"access_token\":\"ya29.g\",\"refresh_token\":\"1//r\"}\r\n\
\r\n\
# s3 below\n\
[media]\n\
type = s3\n\
client_id = not-touched\n";

    #[test]
    fn replaces_only_the_target_section() {
        let out = set_client(CONF, "gdrive", "new-id", "GOCSPX-n3w").unwrap();
        let want = CONF
            .replace(
                "client_id = old-id.apps.googleusercontent.com\r\n",
                "client_id = new-id\r\n",
            )
            .replace(
                "client_secret: OLD-secret\r\n",
                "client_secret = GOCSPX-n3w\r\n",
            );
        assert_eq!(out, want);
        // Every line outside the two replaced ones is byte-identical.
        let (a, b): (Vec<&str>, Vec<&str>) = (
            CONF.split_inclusive('\n').collect(),
            out.split_inclusive('\n').collect(),
        );
        assert_eq!(a.len(), b.len());
        let changed: Vec<usize> = (0..a.len()).filter(|&i| a[i] != b[i]).collect();
        assert_eq!(changed, [10, 12], "{changed:?}");
        assert!(out.contains("client_id = work-id\n") && out.contains("client_id = not-touched\n"));
    }

    #[test]
    fn adds_missing_keys_at_the_section_end() {
        let out = set_client(CONF, "media", "m-id", "m-sec").unwrap();
        assert_eq!(
            out,
            CONF.replace("client_id = not-touched\n", "client_id = m-id\n")
                + "client_secret = m-sec\n"
        );
        // Both absent, CRLF section, blank line kept after the new keys.
        let crlf = "[a]\r\ntype = drive\r\n\r\n[b]\r\ntype = s3\r\n";
        assert_eq!(
            set_client(crlf, "a", "i", "s").unwrap(),
            "[a]\r\ntype = drive\r\nclient_id = i\r\nclient_secret = s\r\n\r\n[b]\r\ntype = s3\r\n"
        );
        // Last line without a newline.
        assert_eq!(
            set_client("[a]\ntype = drive", "a", "i", "s").unwrap(),
            "[a]\ntype = drive\nclient_id = i\nclient_secret = s\n"
        );
        // After the last key, not after a comment that heads the next section.
        assert_eq!(
            set_client("[a]\ntype = drive\n# about b\n[b]\n", "a", "i", "s").unwrap(),
            "[a]\ntype = drive\nclient_id = i\nclient_secret = s\n# about b\n[b]\n"
        );
        // An empty section, a header with spaces.
        assert_eq!(
            set_client(" [ a ] \n[b]\n", "a", "i", "s").unwrap(),
            " [ a ] \nclient_id = i\nclient_secret = s\n[b]\n"
        );
    }

    #[test]
    fn the_output_buffer_never_grows() {
        // Several duplicate secret (and id) lines, a long secret: the output
        // is far larger than the input, and still built in one allocation.
        let secret = "S".repeat(256);
        let id = "i".repeat(100);
        let dup = "[a]\r\ntype = drive\r\nclient_secret = x\r\nclient_id = y\r\n\
client_secret = x\nclient_secret: x\nclient_id = y\nclient_secret = x\n[b]\n";
        for text in [dup, "[a]\n", "[a]\ntype = drive", "[a]\nclient_id = y"] {
            let (out, cap) = edit_client(text, "a", &id, &secret).unwrap();
            assert_eq!(out.capacity(), cap, "{text:?}");
            assert!(out.len() <= cap && out.len() > text.len());
        }
    }

    #[test]
    fn refuses_what_it_cannot_edit_safely() {
        let e = set_client(CONF, "nope", "i", "GOCSPX-x").unwrap_err();
        assert!(e.contains("no [nope] section"), "{e}");
        let e = set_client("[a]\n[a]\n", "a", "i", "GOCSPX-x").unwrap_err();
        assert!(e.contains("more than one"), "{e}");
        assert!(!e.contains("GOCSPX"));
        // A section name is matched whole, not as a prefix.
        assert!(set_client("[gdrive2]\n", "gdrive", "i", "s").is_err());
    }

    #[test]
    fn encrypted_configs_are_detected() {
        let enc = "# Encrypted rclone configuration File\n\nRCLONE_ENCRYPT_V0:\nXXXX\n";
        assert!(is_encrypted(enc));
        assert!(is_encrypted("RCLONE_ENCRYPT_V0:\n"));
        assert!(!is_encrypted(CONF));
        assert!(!is_encrypted(""));
        assert!(!is_encrypted("[x]\nRCLONE_ENCRYPT_V0 = y\n"));
    }

    #[test]
    fn config_file_output() {
        assert_eq!(
            config_path("Configuration file is stored at:\n/home/u/.config/rclone/rclone.conf\n"),
            Some(PathBuf::from("/home/u/.config/rclone/rclone.conf"))
        );
        assert_eq!(
            config_path(
                "Configuration file doesn't exist, but rclone will use this path:\n/x/rclone.conf\n\n"
            ),
            Some(PathBuf::from("/x/rclone.conf"))
        );
        assert_eq!(config_path(""), None);
        assert_eq!(config_path("relative.conf\n"), None);
    }
}
