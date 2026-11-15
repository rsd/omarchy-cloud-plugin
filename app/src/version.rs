//! The "installed parts vs. plugin" notice: install.sh records the plugin
//! version and checkout it ran from as `#version=` / `#repo=` header lines of
//! the installed-files manifest; when the checkout's manifest.json says
//! something else, the TUI shows one persistent line. Nothing here can fail
//! startup: every problem means "no notice".

use crate::cmd::Paths;
use std::io::Read;
use std::path::{Path, PathBuf};

const HEADER_MAX: u64 = 4096;
const MANIFEST_MAX: u64 = 64 * 1024;

fn read_head(p: &Path, max: u64) -> Option<String> {
    let mut buf = Vec::new();
    // metadata follows symlinks; a FIFO or device would block File::open
    if !std::fs::metadata(p).ok()?.is_file() {
        return None;
    }
    std::fs::File::open(p)
        .ok()?
        .take(max)
        .read_to_end(&mut buf)
        .ok()?;
    Some(String::from_utf8_lossy(&buf).into_owned())
}

/// `N.N.N` (digits only).
fn is_version(s: &str) -> bool {
    let parts: Vec<&str> = s.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
}

/// `(version, repo)` from the header lines at the top of the installed-files
/// manifest; the first appearance of each key wins, valid or not, and every
/// line is scanned (same as the JS reader).
pub fn parse_header(text: &str) -> (Option<String>, Option<PathBuf>) {
    let (mut version, mut repo) = (None, None);
    let (mut seen_v, mut seen_r) = (false, false);
    for line in text.lines() {
        if let Some(v) = line.strip_prefix("#version=") {
            if !seen_v {
                seen_v = true;
                if is_version(v) {
                    version = Some(v.to_string());
                }
            }
        } else if let Some(r) = line.strip_prefix("#repo=")
            && !seen_r
        {
            seen_r = true;
            if r.starts_with('/') && !r.chars().any(char::is_control) {
                repo = Some(PathBuf::from(r));
            }
        }
    }
    (version, repo)
}

/// The `"version"` string of manifest.json, when it is `N.N.N`.
pub fn parse_manifest_version(json: &str) -> Option<String> {
    let rest = &json[json.find("\"version\"")? + 9..];
    let rest = rest.trim_start().strip_prefix(':')?.trim_start();
    let rest = rest.strip_prefix('"')?;
    let v = &rest[..rest.find('"')?];
    is_version(v).then(|| v.to_string())
}

/// The notice text, or None when nothing is known or nothing is off.
pub fn notice_text(recorded: Option<&str>, plugin: Option<&str>) -> Option<String> {
    let (x, y) = (recorded?, plugin?);
    (x != y).then(|| format!("Installed parts are {x}, plugin is {y} — run install.sh"))
}

/// Reads the record and the plugin manifest; None on any problem.
pub fn check(paths: &Paths) -> Option<String> {
    let head = read_head(
        &paths.state_home.join("omarchy-cloud/installed-files"),
        HEADER_MAX,
    )?;
    let (version, repo) = parse_header(&head);
    let manifest = read_head(&repo?.join("manifest.json"), MANIFEST_MAX)?;
    notice_text(
        version.as_deref(),
        parse_manifest_version(&manifest).as_deref(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::text::Span;

    #[test]
    fn header_parsed() {
        let t = "#version=0.3.3\n#repo=/src/x\nabc  /f\n";
        assert_eq!(
            parse_header(t),
            (Some("0.3.3".into()), Some(PathBuf::from("/src/x")))
        );
    }

    #[test]
    fn header_first_wins_even_if_invalid() {
        let t = "#version=bad\n#version=1.2.3\n#repo=rel\n#repo=/a\n";
        assert_eq!(parse_header(t), (None, None));
        let t = "#version=4.5.6\n#version=1.2.3\n#repo=/a\n#repo=/b\n";
        assert_eq!(
            parse_header(t),
            (Some("4.5.6".into()), Some(PathBuf::from("/a")))
        );
        assert_eq!(parse_header("#repo=/a\u{1}b\n").1, None);
    }

    #[test]
    fn header_after_sha_line_is_read() {
        let t = format!("{}  /f\n#version=1.2.3\n#repo=/a\n", "a".repeat(64));
        assert_eq!(
            parse_header(&t),
            (Some("1.2.3".into()), Some(PathBuf::from("/a")))
        );
    }

    #[test]
    fn fifo_is_skipped_not_opened() {
        use std::os::unix::ffi::OsStrExt;
        let dir = std::env::temp_dir().join(format!("oc-version-fifo-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let fifo = dir.join("f");
        let c = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        assert_eq!(read_head(&fifo, 16), None);
        let reg = dir.join("r");
        std::fs::write(&reg, "hello").unwrap();
        assert_eq!(read_head(&reg, 16).as_deref(), Some("hello"));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn no_header_is_unknown() {
        assert_eq!(
            parse_header(&format!("{}  /f\n", "a".repeat(64))),
            (None, None)
        );
        assert_eq!(parse_header(""), (None, None));
    }

    #[test]
    fn manifest_version() {
        assert_eq!(
            parse_manifest_version("{\n  \"name\": \"x\",\n  \"version\": \"0.3.3\"\n}"),
            Some("0.3.3".into())
        );
        assert_eq!(parse_manifest_version("{\"version\": \"1.x\"}"), None);
        assert_eq!(parse_manifest_version("{}"), None);
    }

    #[test]
    fn notice() {
        assert_eq!(notice_text(Some("0.3.3"), Some("0.3.3")), None);
        assert_eq!(notice_text(None, Some("0.3.3")), None);
        assert_eq!(notice_text(Some("0.3.2"), None), None);
        let n = notice_text(Some("0.3.2"), Some("0.3.3")).unwrap();
        assert_eq!(
            n,
            "Installed parts are 0.3.2, plugin is 0.3.3 — run install.sh"
        );
        assert!(Span::raw(n).width() <= 82);
    }
}
