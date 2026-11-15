//! Input validation. Every name, path and value is checked here before it
//! reaches a file, a unit name or an argument vector. All functions are pure.

use std::path::{Component, Path, PathBuf};

/// Longest accepted free-text value (remote paths, patterns, prefixes).
pub const MAX_TEXT: usize = 1024;

/// Remote, pair and job names: `^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$`, nothing
/// more (`..` inside a name is allowed), the same rule as the helpers'
/// NAME_RE and the plugin's `isValidRemote`. The cases every validator is
/// tested against: tests/fixtures/names.tsv.
pub fn is_valid_name(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && b.len() <= 64
        && b[0].is_ascii_alphanumeric()
        && b[1..]
            .iter()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'.' | b'-'))
}

/// True when `s` holds an ASCII or Unicode control character.
pub fn has_control(s: &str) -> bool {
    s.chars().any(char::is_control)
}

/// Splits a leading run of ASCII digits with an optional `.digits` fraction.
/// Returns the rest, or None when `s` does not start with a number.
fn take_number(s: &str) -> Option<&str> {
    let int = s.bytes().take_while(u8::is_ascii_digit).count();
    if int == 0 {
        return None;
    }
    let rest = &s[int..];
    if let Some(frac) = rest.strip_prefix('.') {
        let n = frac.bytes().take_while(u8::is_ascii_digit).count();
        if n == 0 {
            return None;
        }
        return Some(&frac[n..]);
    }
    Some(rest)
}

/// Size values: `^[0-9]+(\.[0-9]+)?[KMGT]?$`.
pub fn is_valid_size(s: &str) -> bool {
    match take_number(s) {
        Some("") => true,
        Some(rest) => matches!(rest, "K" | "M" | "G" | "T"),
        None => false,
    }
}

/// rclone durations: `^([0-9]+(\.[0-9]+)?(ms|s|m|h|d|w|M|y))+$` or `0`.
pub fn is_valid_duration(s: &str) -> bool {
    if s == "0" {
        return true;
    }
    let mut rest = s;
    if rest.is_empty() {
        return false;
    }
    while !rest.is_empty() {
        let Some(after) = take_number(rest) else {
            return false;
        };
        let unit_len = if after.starts_with("ms") {
            2
        } else if after.starts_with(['s', 'm', 'h', 'd', 'w', 'M', 'y']) {
            1
        } else {
            return false;
        };
        rest = &after[unit_len..];
    }
    true
}

/// Shortest accepted bisync interval, in seconds.
pub const MIN_INTERVAL_S: u64 = 30;

/// systemd timespan for the bisync timer, as the helper accepts it:
/// `^[0-9]+(s|min|h|d)$`, at least 30 seconds (no `ms`, no 0).
pub fn is_valid_interval(s: &str) -> bool {
    let n = s.bytes().take_while(u8::is_ascii_digit).count();
    if n == 0 || n > 9 {
        return false;
    }
    let unit: u64 = match &s[n..] {
        "s" => 1,
        "min" => 60,
        "h" => 3600,
        "d" => 86400,
        _ => return false,
    };
    s[..n]
        .parse::<u64>()
        .is_ok_and(|v| v * unit >= MIN_INTERVAL_S)
}

/// OnCalendar value: `^[A-Za-z0-9*:,./ -]{1,64}$`.
pub fn is_valid_schedule(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 64
        && s.bytes().all(|c| {
            c.is_ascii_alphanumeric() || matches!(c, b'*' | b':' | b',' | b'.' | b'/' | b' ' | b'-')
        })
}

/// KEEP: an integer 1..=365.
pub fn parse_keep(s: &str) -> Option<u32> {
    if s.is_empty() || !s.bytes().all(|c| c.is_ascii_digit()) || s.len() > 3 {
        return None;
    }
    let n: u32 = s.parse().ok()?;
    (1..=365).contains(&n).then_some(n)
}

/// A remote-side path (the part after `remote:`): no control characters
/// (so it cannot break a KEY=VALUE line), bounded length. May be empty.
pub fn is_valid_remote_path(s: &str) -> bool {
    s.len() <= MAX_TEXT && !has_control(s)
}

/// `<remote>:<path>` with a valid remote name. Returns (name, path).
pub fn split_remote_spec(s: &str) -> Option<(&str, &str)> {
    let (name, path) = s.split_once(':')?;
    (is_valid_name(name) && is_valid_remote_path(path)).then_some((name, path))
}

/// A relative remote path, as the helpers' `valid_rel`: not empty, no
/// leading or trailing `/`, no empty (`//`), `.` or `..` segment, no control
/// characters, bounded length.
pub fn is_valid_rel(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= MAX_TEXT
        && !has_control(s)
        && s.split('/')
            .all(|seg| !seg.is_empty() && seg != "." && seg != "..")
}

/// A backup prefix (the part after `remote:`): empty, or a relative path.
pub fn is_valid_prefix(s: &str) -> bool {
    s.is_empty() || is_valid_rel(s)
}

/// Expands a local directory as written in a config file or a form:
/// absolute, or `~/…` relative to `home` (as the helpers: `~/x` is
/// `$HOME/x`, so `~//x` is `$HOME/x` too, never `/x`). No control
/// characters, no `.`/`..` segments. Repeated and trailing `/` are dropped.
pub fn expand_local(input: &str, home: &Path) -> Result<PathBuf, String> {
    if input.is_empty() {
        return Err("the folder is empty".into());
    }
    if input.len() > MAX_TEXT || has_control(input) {
        return Err("the folder contains control characters or is too long".into());
    }
    let path = if let Some(rest) = input.strip_prefix("~/") {
        home.join(rest.trim_start_matches('/'))
    } else if input.starts_with('/') {
        PathBuf::from(input)
    } else {
        return Err("the folder must be absolute or start with ~/".into());
    };
    let raw = path.to_string_lossy();
    if raw.split('/').any(|seg| seg == "." || seg == "..") {
        return Err("the folder must not contain . or .. segments".into());
    }
    let clean: PathBuf = path
        .components()
        .filter(|c| !matches!(c, Component::CurDir))
        .collect();
    Ok(clean)
}

/// Longest accepted mount root, in UTF-8 bytes.
pub const MAX_ROOT: usize = 255;

/// The mount root (`OMARCHY_CLOUD_ROOT` in cloud.env): absolute, not `/`,
/// every component non-empty and not `.` or `..` (so no `//` and no trailing
/// `/`), no ASCII whitespace or control byte (0x00-0x20, 0x7F), none of
/// `$`, `%`, `\`, `"`, `'` or a backtick, not `home` and not inside it (component-wise), at most
/// 255 bytes, and no U+FFFD: a `&str` is valid UTF-8 already, and banning the
/// replacement character makes a lossy decoder (the bar reads cloud.env as
/// text, a bad byte arriving as U+FFFD) reach the same verdict as a strict
/// one (envfile::parse_root rejects a non-UTF-8 value). The same rule as the helpers' and install.sh's `valid_root`
/// and the bar's `isValidRoot`; the cases every validator is tested
/// against: tests/fixtures/roots.tsv.
pub fn is_valid_root(path: &str, home: &Path) -> bool {
    let b = path.as_bytes();
    b.len() <= MAX_ROOT
        && b.first() == Some(&b'/')
        && path != "/"
        && !b.iter().any(|&c| {
            c <= 0x20 || c == 0x7f || matches!(c, b'$' | b'%' | b'\\' | b'"' | b'\'' | b'`')
        })
        && !path.contains(char::REPLACEMENT_CHARACTER)
        && path[1..]
            .split('/')
            .all(|seg| !seg.is_empty() && seg != "." && seg != "..")
        && !inside_home(path, home)
}

/// True when `path` is inside `home`. A home of "/" or "" (after trimming
/// trailing `/`) is no home: the rule is skipped, like the helpers'
/// `valid_root` (every trailing `/` of HOME stripped; `[[ -n $home && ... ]]`).
fn inside_home(path: &str, home: &Path) -> bool {
    let h = home.to_string_lossy();
    let h = h.trim_end_matches('/');
    !h.is_empty() && Path::new(path).starts_with(h)
}

/// True when `p` is `root` or inside it. Both should be canonical. Pure.
pub fn is_within(p: &Path, root: &Path) -> bool {
    p.starts_with(root)
}

/// True when `a` and `b` are the same directory or one is inside the other,
/// by path components (/a/b and /a/bc do not overlap; trailing and repeated
/// `/` are ignored). Pure. The cloud guard (`app::cloud_loop`) and the
/// helpers' `guard_cloud` use the same rule in both directions.
pub fn overlaps(a: &Path, b: &Path) -> bool {
    is_within(a, b) || is_within(b, a)
}

/// A line of a backup files list: a relative path (`is_valid_rel`).
pub fn is_valid_files_line(s: &str) -> bool {
    is_valid_rel(s)
}

/// Splits on the commas outside `{…}` brace globs (`{a,b}.kdbx` is one
/// pattern); a backslash escapes the next character, as in rclone's globs.
fn split_top_commas(s: &str) -> Vec<&str> {
    let (mut out, mut start, mut depth, mut esc) = (Vec::new(), 0, 0usize, false);
    for (i, c) in s.char_indices() {
        match c {
            _ if esc => esc = false,
            '\\' => esc = true,
            '{' => depth += 1,
            '}' => depth = depth.saturating_sub(1),
            ',' if depth == 0 => {
                out.push(&s[start..i]);
                start = i + 1;
            }
            _ => {}
        }
    }
    out.push(&s[start..]);
    out
}

/// Include patterns from a form: comma separated (not inside `{…}`), each
/// item trimmed; spaces inside a pattern are kept (`My Vault.kdbx` is one
/// pattern). Empty input means "the whole folder" (an empty list).
pub fn parse_patterns(s: &str) -> Result<Vec<String>, String> {
    if has_control(s) {
        return Err("patterns must not contain control characters".into());
    }
    let mut out: Vec<String> = Vec::new();
    for p in split_top_commas(s).into_iter().map(str::trim) {
        if p.is_empty() {
            continue;
        }
        if p.len() > MAX_TEXT {
            return Err("a pattern is too long".into());
        }
        if !out.iter().any(|q| q == p) {
            out.push(p.to_string());
        }
    }
    Ok(out)
}

/// A Google OAuth client id: `[A-Za-z0-9._-]`, 1..=256 characters.
pub fn is_valid_client_id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 256
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-'))
}

/// A client secret: printable ASCII without spaces, `=`, quotes or
/// backticks (it is written as a `client_secret = <value>` line of
/// rclone.conf, whose parser reads a leading quote or backtick as quoting),
/// 1..=256 characters.
pub fn is_valid_client_secret(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 256
        && s.bytes()
            .all(|c| c.is_ascii_graphic() && !matches!(c, b'=' | b'"' | b'\'' | b'`'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        for ok in [
            "a",
            "gdrive",
            "work_drive",
            "media-s3",
            "vault-A",
            "x.y",
            "A9",
        ] {
            assert!(is_valid_name(ok), "{ok}");
        }
        let long = "a".repeat(65);
        for bad in [
            "", "-a", "_a", ".a", "a b", "a/b", "a:", "á", "a\n", &long, "a;rm", "$HOME",
        ] {
            assert!(!is_valid_name(bad), "{bad:?}");
        }
        assert!(is_valid_name(&"a".repeat(64)));
        assert!(is_valid_name("a..b"), "\"..\" inside a name is allowed");
    }

    /// The one list of name cases shared with the helpers and the bar.
    #[test]
    fn names_fixture() {
        let text = include_str!("../../tests/fixtures/names.tsv");
        let mut n = 0;
        for line in text.split('\n') {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let (want, name) = line.split_once('\t').expect("<valid|invalid><TAB><name>");
            let expect = match want {
                "valid" => true,
                "invalid" => false,
                other => panic!("bad fixture verdict {other:?}"),
            };
            assert_eq!(is_valid_name(name), expect, "{want} {name:?}");
            n += 1;
        }
        assert!(n >= 20, "only {n} cases read");
    }

    /// The one list of mount-root cases shared with the helpers, install.sh
    /// and the bar, all run with HOME=/home/tester. Read as BYTES (some
    /// cases are not UTF-8): every line goes through the real cloud.env
    /// reader, and every UTF-8 line through `is_valid_root` too.
    #[test]
    fn roots_fixture() {
        use crate::envfile::{RootSetting, parse_root};
        let bytes: &[u8] = include_bytes!("../../tests/fixtures/roots.tsv");
        let home = Path::new("/home/tester");
        let (mut n, mut valid, mut invalid, mut non_utf8) = (0, 0, 0, 0);
        for line in bytes.split(|&b| b == b'\n') {
            if line.is_empty() || line[0] == b'#' {
                continue;
            }
            let tab = line.iter().position(|&b| b == b'\t');
            let tab = tab.expect("<valid|invalid><TAB><path>");
            let (want, path) = (&line[..tab], &line[tab + 1..]);
            let expect = match want {
                b"valid" => true,
                b"invalid" => false,
                other => panic!("bad fixture verdict {other:?}"),
            };
            let shown = String::from_utf8_lossy(path);
            match std::str::from_utf8(path) {
                Ok(p) => assert_eq!(is_valid_root(p, home), expect, "{shown:?}"),
                Err(_) => {
                    assert!(!expect, "a non-UTF-8 case must be invalid: {shown:?}");
                    non_utf8 += 1;
                }
            }
            let mut env = b"OMARCHY_CLOUD_ROOT=".to_vec();
            env.extend_from_slice(path);
            env.push(b'\n');
            let got = parse_root(&env, home);
            assert_eq!(
                matches!(got, RootSetting::Valid(_)),
                expect,
                "cloud.env {shown:?}: {got:?}"
            );
            if expect {
                valid += 1;
            } else {
                invalid += 1;
            }
            n += 1;
        }
        assert!(
            n >= 49 && valid >= 13 && invalid >= 36 && non_utf8 >= 5,
            "only {n} cases read ({valid} valid, {invalid} invalid, {non_utf8} non-UTF-8)"
        );
    }

    #[test]
    fn roots_beyond_the_fixture() {
        let home = Path::new("/home/tester");
        // Control bytes, DEL and tabs; non-ASCII is allowed; 255 is BYTES.
        for bad in ["/mnt/a\tb", "/mnt/a\nb", "/mnt/a\u{7f}b", "/mnt/a\u{1}b"] {
            assert!(!is_valid_root(bad, home), "{bad:?}");
        }
        assert!(is_valid_root("/mnt/caf\u{e9}", home));
        // U+FFFD is what a lossy decoder makes of a bad byte: refused.
        assert!(!is_valid_root("/mnt/a\u{fffd}b", home));
        assert!(!is_valid_root("/\u{fffd}", home));
        let e255 = format!("/{}", "\u{e9}".repeat(127)); // 255 bytes
        assert!(is_valid_root(&e255, home));
        let e256 = format!("/{}a", "\u{e9}".repeat(127));
        assert!(!is_valid_root(&e256, home), "256 bytes");
        // A home with a trailing slash is the same home.
        assert!(!is_valid_root("/home/tester/x", Path::new("/home/tester/")));
        // No usable home ("/" or empty): the home rule is skipped.
        for home in ["/", "", "//"] {
            assert!(is_valid_root("/mnt/x", Path::new(home)), "home {home:?}");
        }
    }

    #[test]
    fn sizes() {
        for ok in ["10G", "1", "1.5T", "512M", "100K"] {
            assert!(is_valid_size(ok), "{ok}");
        }
        for bad in ["", "G", "10GB", "1.G", ".5G", "10g", "-1", "1 G"] {
            assert!(!is_valid_size(bad), "{bad:?}");
        }
    }

    #[test]
    fn durations() {
        for ok in [
            "0", "1s", "72h", "1000h", "5m", "1m30s", "100ms", "1.5h", "2w", "1M", "1y",
        ] {
            assert!(is_valid_duration(ok), "{ok}");
        }
        for bad in ["", "1", "h", "1x", "1min", "1.h", "-1s", "1 s", "00", "1s "] {
            assert!(!is_valid_duration(bad), "{bad:?}");
        }
    }

    #[test]
    fn intervals_and_schedules() {
        for ok in ["2min", "30s", "1h", "1d", "1min", "030s", "45s"] {
            assert!(is_valid_interval(ok), "{ok}");
        }
        for bad in [
            "",
            "2m",
            "min",
            "1.5h",
            "2 min",
            "500ms",
            "29s",
            "0s",
            "0min",
            "0",
            "1000000000s",
        ] {
            assert!(!is_valid_interval(bad), "{bad:?}");
        }
        for ok in ["daily", "*-*-* 03:00:00", "Mon,Fri 10:00", "weekly"] {
            assert!(is_valid_schedule(ok), "{ok}");
        }
        for bad in ["", "daily;x", "a\nb", &"d".repeat(65)] {
            assert!(!is_valid_schedule(bad), "{bad:?}");
        }
    }

    #[test]
    fn keep() {
        assert_eq!(parse_keep("14"), Some(14));
        assert_eq!(parse_keep("1"), Some(1));
        assert_eq!(parse_keep("365"), Some(365));
        for bad in ["0", "366", "", "-1", "1.5", "abc", "0014"] {
            assert_eq!(parse_keep(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn remote_specs() {
        assert_eq!(
            split_remote_spec("onedrive:Backup/Vaults"),
            Some(("onedrive", "Backup/Vaults"))
        );
        assert_eq!(split_remote_spec("work_drive:"), Some(("work_drive", "")));
        assert_eq!(split_remote_spec("a:b:c"), Some(("a", "b:c")));
        assert_eq!(split_remote_spec("noColon"), None);
        assert_eq!(split_remote_spec("-x:path"), None);
        assert_eq!(split_remote_spec("x:pa\nth"), None);
        assert!(is_valid_prefix("acme"));
        assert!(is_valid_prefix(""));
        assert!(is_valid_prefix("a/b"));
        for bad in ["acme/", "/a", "a//b", "./a", "a/./b", "a/..", ".."] {
            assert!(!is_valid_prefix(bad), "{bad:?}");
        }
    }

    #[test]
    fn local_dirs() {
        let home = Path::new("/home/u");
        assert_eq!(
            expand_local("~/Vaults", home).unwrap(),
            PathBuf::from("/home/u/Vaults")
        );
        assert_eq!(expand_local("~/", home).unwrap(), PathBuf::from("/home/u"));
        assert_eq!(
            expand_local("~//x", home).unwrap(),
            PathBuf::from("/home/u/x")
        );
        assert_eq!(expand_local("/a//b/", home).unwrap(), PathBuf::from("/a/b"));
        assert_eq!(
            expand_local("/srv/x/", home).unwrap(),
            PathBuf::from("/srv/x")
        );
        for bad in [
            "", "~", "rel/dir", "~user/x", "/a/../b", "/a/./b", "~/x\n", "-rf", "~//../x",
        ] {
            assert!(expand_local(bad, home).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn overlapping_dirs() {
        let p = Path::new;
        // The cloud guard's cases (C4): equal, inside, containing, and a
        // sibling that only shares a prefix.
        let mnt = p("/mnt/cloud");
        assert!(overlaps(p("/mnt/cloud"), mnt), "equal");
        assert!(overlaps(p("/mnt/cloud/"), mnt), "equal, trailing /");
        assert!(overlaps(p("/mnt/cloud/od/x"), mnt), "inside");
        assert!(overlaps(p("/mnt"), mnt), "contains");
        assert!(overlaps(mnt, p("/mnt")), "contains, either order");
        assert!(!overlaps(p("/mnt/cloudy"), mnt), "sibling prefix");
        assert!(
            !overlaps(mnt, p("/mnt/cloudy")),
            "sibling prefix, either order"
        );
        assert!(!overlaps(p("/mnt/cloudy/x"), mnt));
        assert!(overlaps(p("/home/u/Vaults"), p("/home/u/Vaults")));
        assert!(overlaps(p("/home/u/Vaults/bk"), p("/home/u/Vaults")));
        assert!(overlaps(p("/home/u/Vaults"), p("/home/u/Vaults/bk")));
        assert!(overlaps(p("/home/u"), p("/home/u/Vaults/a/b")));
        assert!(overlaps(p("/"), p("/home/u")));
        assert!(!overlaps(p("/home/u/Vaults"), p("/home/u/Vaults2")));
        assert!(!overlaps(p("/home/u/Vaults2/bk"), p("/home/u/Vaults")));
        assert!(!overlaps(p("/home/u/Backups/vaults"), p("/home/u/Vaults")));
    }

    #[test]
    fn files_lines() {
        assert!(is_valid_files_line("acme/admin.kdbx"));
        assert!(is_valid_files_line("a.kdbx"));
        for bad in [
            "",
            "/etc/passwd",
            "a/../b",
            "..",
            "a\tb",
            "./a",
            "a//b",
            "a/",
            ".",
            "a/./b",
        ] {
            assert!(!is_valid_files_line(bad), "{bad:?}");
        }
        assert!(is_within(
            Path::new("/mnt/cloud/x"),
            Path::new("/mnt/cloud")
        ));
        assert!(is_within(Path::new("/mnt/cloud"), Path::new("/mnt/cloud")));
        assert!(!is_within(
            Path::new("/mnt/cloudy"),
            Path::new("/mnt/cloud")
        ));
    }

    #[test]
    fn patterns() {
        assert_eq!(parse_patterns("").unwrap(), Vec::<String>::new());
        assert_eq!(
            parse_patterns("a.kdbx, b.key ,c/**").unwrap(),
            vec!["a.kdbx", "b.key", "c/**"]
        );
        // Spaces inside a pattern are kept; only commas separate.
        assert_eq!(
            parse_patterns(" My Vault.kdbx , Docs/,,").unwrap(),
            vec!["My Vault.kdbx", "Docs/"]
        );
        assert_eq!(parse_patterns("a b").unwrap(), vec!["a b"]);
        assert_eq!(parse_patterns(" , ").unwrap(), Vec::<String>::new());
        assert_eq!(parse_patterns("a, a").unwrap(), vec!["a"]);
        assert!(parse_patterns("a\u{7}b").is_err());
        // A comma inside a brace glob does not separate.
        assert_eq!(
            parse_patterns("{a,b}.kdbx, c.key").unwrap(),
            vec!["{a,b}.kdbx", "c.key"]
        );
        assert_eq!(
            parse_patterns("x/{a,{b,c}}/*.kdbx,y").unwrap(),
            vec!["x/{a,{b,c}}/*.kdbx", "y"]
        );
        // An escaped brace does not open a group; a stray } is harmless.
        assert_eq!(parse_patterns(r"\{a,b}").unwrap(), vec![r"\{a", "b}"]);
        assert_eq!(parse_patterns("a},b").unwrap(), vec!["a}", "b"]);
    }

    #[test]
    fn client_credentials() {
        assert!(is_valid_client_id("123-abc.apps.googleusercontent.com"));
        assert!(!is_valid_client_id("a b"));
        assert!(is_valid_client_secret("GOCSPX-abc_DEF123"));
        assert!(!is_valid_client_secret("has space"));
        assert!(!is_valid_client_secret("a=b"));
        for q in ["`x", "x\"y", "'x'"] {
            assert!(!is_valid_client_secret(q), "{q}");
        }
        assert!(!is_valid_client_secret(""));
    }
}
