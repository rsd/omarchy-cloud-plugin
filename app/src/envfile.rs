//! The per-remote mount settings file, ~/.config/rclone-mount/<remote>.env
//! (a systemd EnvironmentFile). Parsing and rendering are pure and keep every
//! line the TUI does not manage — comments, blank lines, other keys — as is.
//! Also the mount-root setting, ~/.config/omarchy-cloud/cloud.env (parsed
//! only; install.sh is its one writer).

use crate::validate::{is_valid_duration, is_valid_root, is_valid_size};
use std::path::{Path, PathBuf};

/// The key of the mount-root setting in cloud.env.
pub const ROOT_KEY: &str = "OMARCHY_CLOUD_ROOT";
/// The root the unit uses when cloud.env sets none (its `Environment=`).
pub const DEFAULT_ROOT: &str = "/mnt/cloud";
/// cloud.env is read up to this many bytes, as every other reader does.
pub const ROOT_FILE_MAX: usize = 4096;

/// What cloud.env says about the mount root.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RootSetting {
    /// No file, or no `OMARCHY_CLOUD_ROOT=` line.
    Absent,
    /// The value, which fails `validate::is_valid_root`.
    Invalid(String),
    Valid(PathBuf),
}

/// Parses cloud.env without sourcing it: the first ROOT_FILE_MAX bytes,
/// one trailing `\r` stripped per line, empty and `#` lines skipped; the
/// value is everything after `OMARCHY_CLOUD_ROOT=` verbatim (no quotes
/// removed, nothing expanded), and the last such line wins (systemd's
/// rule). Then checked with `is_valid_root`. Pure.
pub fn parse_root(bytes: &[u8], home: &Path) -> RootSetting {
    let bytes = &bytes[..bytes.len().min(ROOT_FILE_MAX)];
    let prefix = format!("{ROOT_KEY}=");
    let mut found: Option<&[u8]> = None;
    for line in bytes.split(|&b| b == b'\n') {
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        if line.is_empty() || line[0] == b'#' {
            continue;
        }
        if let Some(v) = line.strip_prefix(prefix.as_bytes()) {
            found = Some(v);
        }
    }
    match found.map(std::str::from_utf8) {
        None => RootSetting::Absent,
        Some(Ok(v)) if is_valid_root(v, home) => RootSetting::Valid(PathBuf::from(v)),
        Some(Ok(v)) => RootSetting::Invalid(v.to_string()),
        Some(Err(_)) => {
            RootSetting::Invalid(String::from_utf8_lossy(found.unwrap_or_default()).into_owned())
        }
    }
}

/// A setting the TUI edits: env key, form label, unit default, value kind.
pub struct Managed {
    pub key: &'static str,
    pub label: &'static str,
    pub default: &'static str,
    pub is_size: bool,
}

/// The keys the TUI may write, with the defaults the unit sets.
pub const MANAGED: [Managed; 5] = [
    Managed {
        key: "RCLONE_VFS_CACHE_MAX_SIZE",
        label: "Cache max size",
        default: "10G",
        is_size: true,
    },
    Managed {
        key: "RCLONE_VFS_CACHE_MAX_AGE",
        label: "Cache max age",
        default: "72h",
        is_size: false,
    },
    Managed {
        key: "RCLONE_VFS_WRITE_BACK",
        label: "Write-back delay",
        default: "1s",
        is_size: false,
    },
    Managed {
        key: "RCLONE_DIR_CACHE_TIME",
        label: "Dir cache time",
        default: "5m",
        is_size: false,
    },
    Managed {
        key: "RCLONE_POLL_INTERVAL",
        label: "Poll interval",
        default: "1m",
        is_size: false,
    },
];

/// Checks a value for a managed key (sizes or rclone durations).
pub fn validate_value(m: &Managed, value: &str) -> Result<(), String> {
    let ok = if m.is_size {
        is_valid_size(value)
    } else {
        is_valid_duration(value)
    };
    if ok {
        Ok(())
    } else if m.is_size {
        Err(format!(
            "{}: expected a size like 10G (digits, optional K/M/G/T)",
            m.label
        ))
    } else {
        Err(format!(
            "{}: expected an rclone duration like 5m, 72h, 1m30s or 0",
            m.label
        ))
    }
}

#[derive(Debug, Clone, PartialEq)]
enum Line {
    /// Kept verbatim: comments, blank lines, anything unparsable.
    Raw(String),
    Kv {
        key: String,
        value: String,
    },
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct EnvFile {
    lines: Vec<Line>,
}

fn is_env_key(k: &str) -> bool {
    let b = k.as_bytes();
    !b.is_empty()
        && (b[0].is_ascii_alphabetic() || b[0] == b'_')
        && b.iter().all(|c| c.is_ascii_alphanumeric() || *c == b'_')
}

impl EnvFile {
    pub fn parse(text: &str) -> EnvFile {
        let lines = text
            .lines()
            .map(|l| {
                let t = l.trim_start();
                if t.is_empty() || t.starts_with('#') || t.starts_with(';') {
                    return Line::Raw(l.to_string());
                }
                match l.split_once('=') {
                    Some((k, v)) if is_env_key(k) => Line::Kv {
                        key: k.to_string(),
                        value: v.to_string(),
                    },
                    _ => Line::Raw(l.to_string()),
                }
            })
            .collect();
        EnvFile { lines }
    }

    /// The value of the last assignment of `key` (systemd's rule), with one
    /// layer of matching quotes removed.
    pub fn get(&self, key: &str) -> Option<String> {
        self.lines.iter().rev().find_map(|l| match l {
            Line::Kv { key: k, value } if k == key => {
                let v = value.trim();
                let unq = v
                    .strip_prefix('"')
                    .and_then(|x| x.strip_suffix('"'))
                    .or_else(|| v.strip_prefix('\'').and_then(|x| x.strip_suffix('\'')))
                    .unwrap_or(v);
                Some(unq.to_string())
            }
            _ => None,
        })
    }

    /// Sets `key` (in place of its first assignment; later duplicates are
    /// dropped) or removes it with `None`. New keys are appended.
    pub fn set(&mut self, key: &str, value: Option<&str>) {
        let mut placed = false;
        let mut out = Vec::with_capacity(self.lines.len() + 1);
        for l in self.lines.drain(..) {
            match l {
                Line::Kv { key: k, .. } if k == key => {
                    if let (false, Some(v)) = (placed, value) {
                        out.push(Line::Kv {
                            key: k,
                            value: v.to_string(),
                        });
                        placed = true;
                    }
                }
                other => out.push(other),
            }
        }
        if let (false, Some(v)) = (placed, value) {
            out.push(Line::Kv {
                key: key.to_string(),
                value: v.to_string(),
            });
        }
        self.lines = out;
    }

    pub fn render(&self) -> String {
        let mut s = String::new();
        for l in &self.lines {
            match l {
                Line::Raw(r) => s.push_str(r),
                Line::Kv { key, value } => {
                    s.push_str(key);
                    s.push('=');
                    s.push_str(value);
                }
            }
            s.push('\n');
        }
        s
    }
}

/// The settings file written for a newly added remote. Drive and OneDrive
/// support change polling, so they get the same long listing cache as the
/// live remotes; the others keep the unit defaults.
pub fn initial_env(remote_type: &str) -> String {
    if matches!(remote_type, "drive" | "onedrive") {
        "# Drive/OneDrive support change polling: cache listings for a long time, poll for changes.\n\
         RCLONE_DIR_CACHE_TIME=1000h\n\
         RCLONE_POLL_INTERVAL=1m\n"
            .to_string()
    } else {
        "# rclone mount settings (RCLONE_* variables); a missing key keeps the unit default.\n"
            .to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIVE: &str = "# Drive/OneDrive support change polling: cache listings for a long time, poll for changes.\n\
RCLONE_DIR_CACHE_TIME=1000h\n\
RCLONE_POLL_INTERVAL=1m\n";

    #[test]
    fn roundtrip_is_identical() {
        let text = "# head\n\nFOO=bar baz\nRCLONE_DIR_CACHE_TIME=1000h\n  # indented\nnot a kv line\nX=\"q\"\n";
        assert_eq!(EnvFile::parse(text).render(), text);
        assert_eq!(EnvFile::parse(LIVE).render(), LIVE);
    }

    #[test]
    fn set_preserves_comments_and_unknown_keys() {
        let mut e = EnvFile::parse("# c1\nOTHER=1\nRCLONE_POLL_INTERVAL=1m\n# c2\n");
        e.set("RCLONE_POLL_INTERVAL", Some("0"));
        e.set("RCLONE_VFS_CACHE_MAX_SIZE", Some("20G"));
        assert_eq!(
            e.render(),
            "# c1\nOTHER=1\nRCLONE_POLL_INTERVAL=0\n# c2\nRCLONE_VFS_CACHE_MAX_SIZE=20G\n"
        );
        e.set("RCLONE_POLL_INTERVAL", None);
        assert_eq!(
            e.render(),
            "# c1\nOTHER=1\n# c2\nRCLONE_VFS_CACHE_MAX_SIZE=20G\n"
        );
        assert_eq!(e.get("OTHER").as_deref(), Some("1"));
    }

    #[test]
    fn duplicates_collapse_and_get_reads_last() {
        let mut e = EnvFile::parse("A=1\nA=2\n");
        assert_eq!(e.get("A").as_deref(), Some("2"));
        e.set("A", Some("3"));
        assert_eq!(e.render(), "A=3\n");
        assert_eq!(EnvFile::parse("B=\"5m\"\n").get("B").as_deref(), Some("5m"));
        assert_eq!(EnvFile::parse("").get("B"), None);
    }

    #[test]
    fn root_setting_is_parsed_not_sourced() {
        let h = Path::new("/home/tester");
        let valid = |p: &str| RootSetting::Valid(PathBuf::from(p));
        assert_eq!(parse_root(b"", h), RootSetting::Absent);
        assert_eq!(
            parse_root(b"# OMARCHY_CLOUD_ROOT=/srv/x\nOTHER=1\n", h),
            RootSetting::Absent
        );
        assert_eq!(
            parse_root(b"OMARCHY_CLOUD_ROOT=/srv/cloud\n", h),
            valid("/srv/cloud")
        );
        // No trailing newline; CRLF; last line wins; blank lines skipped.
        assert_eq!(parse_root(b"OMARCHY_CLOUD_ROOT=/srv/c", h), valid("/srv/c"));
        assert_eq!(
            parse_root(b"OMARCHY_CLOUD_ROOT=/srv/c\r\n", h),
            valid("/srv/c")
        );
        assert_eq!(
            parse_root(b"OMARCHY_CLOUD_ROOT=/a\n\nOMARCHY_CLOUD_ROOT=/b\n", h),
            valid("/b")
        );
        // Verbatim: no quote removal, no expansion, no trimming, no export.
        for (text, v) in [
            (&b"OMARCHY_CLOUD_ROOT=\"/srv/c\"\n"[..], "\"/srv/c\""),
            (b"OMARCHY_CLOUD_ROOT=$HOME/c\n", "$HOME/c"),
            (b"OMARCHY_CLOUD_ROOT= /srv/c\n", " /srv/c"),
            (b"OMARCHY_CLOUD_ROOT=/srv/c\r\r\n", "/srv/c\r"),
            (
                b"OMARCHY_CLOUD_ROOT=/home/tester/Cloud\n",
                "/home/tester/Cloud",
            ),
            (b"OMARCHY_CLOUD_ROOT=\n", ""),
        ] {
            assert_eq!(parse_root(text, h), RootSetting::Invalid(v.into()), "{v:?}");
        }
        assert_eq!(
            parse_root(b"export OMARCHY_CLOUD_ROOT=/srv/c\n", h),
            RootSetting::Absent
        );
        assert_eq!(
            parse_root(b" OMARCHY_CLOUD_ROOT=/srv/c\n", h),
            RootSetting::Absent
        );
        assert!(matches!(
            parse_root(b"OMARCHY_CLOUD_ROOT=/srv/\xff\n", h),
            RootSetting::Invalid(_)
        ));
        // Only the first 4096 bytes count.
        let mut big = vec![b'#'; ROOT_FILE_MAX];
        big.extend_from_slice(b"\nOMARCHY_CLOUD_ROOT=/srv/c\n");
        assert_eq!(parse_root(&big, h), RootSetting::Absent);
        let mut fits = b"OMARCHY_CLOUD_ROOT=/srv/c\n".to_vec();
        fits.resize(ROOT_FILE_MAX, b'#');
        assert_eq!(parse_root(&fits, h), valid("/srv/c"));
    }

    #[test]
    fn managed_validation_and_initial_files() {
        assert!(validate_value(&MANAGED[0], "10G").is_ok());
        assert!(validate_value(&MANAGED[0], "10h").is_err());
        assert!(validate_value(&MANAGED[4], "0").is_ok());
        assert!(validate_value(&MANAGED[4], "10G").is_err());
        assert_eq!(initial_env("drive"), LIVE);
        assert_eq!(initial_env("onedrive"), LIVE);
        let s3 = EnvFile::parse(&initial_env("s3"));
        assert_eq!(s3.get("RCLONE_DIR_CACHE_TIME"), None);
    }
}
