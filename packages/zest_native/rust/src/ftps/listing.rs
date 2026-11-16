//! Folder listings: MLSD (RFC 3659, machine-readable) where the server has it, else LIST in the
//! Unix `ls -l` or the DOS (IIS) form. LIST has no standard form, so a line neither parser knows is
//! left out rather than guessed at.

use std::time::UNIX_EPOCH;

use serde::Serialize;
use suppaftp::list::{ListParser, PosixPexQuery};

/// One entry of a folder, as the app gets it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Entry {
    pub name: String,
    pub dir: bool,
    pub link: bool,
    pub size: u64,
    /// Seconds since 1970 (UTC for MLSD; LIST gives the server's local time, often without a year).
    pub mtime: Option<i64>,
    /// The Unix permission bits, where the server said them.
    pub mode: Option<u32>,
    /// Where a link leads, where LIST said it.
    pub target: Option<String>,
}

/// One MLSD line (`fact=value;fact=value; name`), or None for the folder itself and its parent
/// (`type=cdir`, `type=pdir`) and for a line that is not one.
pub fn parse_mlsd(line: &str) -> Option<Entry> {
    let (facts, name) = if let Some(name) = line.strip_prefix(' ') {
        ("", name)
    } else {
        let end = line.find("; ")?;
        (&line[..end], &line[end + 2..])
    };
    if name.is_empty() || name == "." || name == ".." {
        return None;
    }
    let mut entry = Entry {
        name: name.to_string(),
        dir: false,
        link: false,
        size: 0,
        mtime: None,
        mode: None,
        target: None,
    };
    for fact in facts.split(';') {
        let Some((key, value)) = fact.split_once('=') else { continue };
        match key.to_ascii_lowercase().as_str() {
            "type" => {
                let v = value.to_ascii_lowercase();
                match v.as_str() {
                    "cdir" | "pdir" => return None,
                    "dir" => entry.dir = true,
                    "file" => {}
                    // vsftpd has no MLSD; ProFTPD and Pure-FTPd say a link like this.
                    _ if v.starts_with("os.unix=slink") || v.starts_with("os.unix=symlink") || v == "link" => {
                        entry.link = true;
                        if let Some((_, to)) = value.split_once(':') {
                            if !to.is_empty() {
                                entry.target = Some(to.to_string());
                            }
                        }
                    }
                    // Anything else (a device, a pipe): shown as a file, never descended into.
                    _ => {}
                }
            }
            "size" | "sizd" => entry.size = value.parse().unwrap_or(0),
            "modify" => entry.mtime = parse_mlsx_time(value),
            "unix.mode" if !value.is_empty() && value.len() <= 6 && value.bytes().all(|b| (b'0'..=b'7').contains(&b)) => {
                entry.mode = u32::from_str_radix(value, 8).ok().map(|m| m & 0o7777);
            }
            _ => {}
        }
    }
    if entry.dir {
        entry.size = 0;
    }
    Some(entry)
}

/// `YYYYMMDDHHMMSS[.sss]`, UTC, as seconds since 1970.
pub fn parse_mlsx_time(value: &str) -> Option<i64> {
    let digits = value.split('.').next()?;
    if digits.len() != 14 || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let n = |a: usize, b: usize| digits[a..b].parse::<i64>().ok();
    let (y, mo, d, h, mi, s) = (n(0, 4)?, n(4, 6)?, n(6, 8)?, n(8, 10)?, n(10, 12)?, n(12, 14)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || s > 60 {
        return None;
    }
    Some(days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s)
}

/// Days since 1970-01-01 of a date in the proleptic Gregorian calendar (Howard Hinnant's method).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// One LIST line, in the Unix or the DOS form, or None (a `total` line, `.`, `..`, or a form
/// neither parser knows).
pub fn parse_list(line: &str) -> Option<Entry> {
    let file = ListParser::parse_posix(line)
        .map(|f| (f, true))
        .or_else(|_| ListParser::parse_dos(line).map(|f| (f, false)))
        .ok()?;
    let (file, posix) = file;
    let name = file.name().to_string();
    if name.is_empty() || name == "." || name == ".." {
        return None;
    }
    let mode = posix.then(|| {
        let mut m = 0u32;
        for (shift, who) in [(6, PosixPexQuery::Owner), (3, PosixPexQuery::Group), (0, PosixPexQuery::Others)] {
            let bits = (file.can_read(who) as u32) << 2 | (file.can_write(who) as u32) << 1 | file.can_execute(who) as u32;
            m |= bits << shift;
        }
        m
    });
    let mtime = file.modified().duration_since(UNIX_EPOCH).ok().map(|d| d.as_secs() as i64);
    Some(Entry {
        name,
        dir: file.is_directory(),
        link: file.is_symlink(),
        size: if file.is_directory() { 0 } else { file.size() as u64 },
        mtime,
        mode,
        target: file.symlink().map(|p| p.to_string_lossy().into_owned()),
    })
}

/// The SHA-256 in a reply to `HASH` (draft-bryan-ftpext-hash: `213 SHA-256 0-49 <hex> name`) or
/// to `XSHA256` (`213 <hex>`): the first word of 64 hexadecimal digits, in lower case.
pub fn sha256_in_reply(reply: &str) -> Option<String> {
    reply
        .split_whitespace()
        .find(|w| w.len() == 64 && w.bytes().all(|b| b.is_ascii_hexdigit()))
        .map(|w| w.to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mlsd_file_dir_and_link() {
        let f = parse_mlsd("type=file;size=1024;modify=20201019151930;UNIX.mode=0644; data.bin").unwrap();
        assert_eq!(f.name, "data.bin");
        assert!(!f.dir && !f.link);
        assert_eq!(f.size, 1024);
        assert_eq!(f.mtime, Some(1603120770));
        assert_eq!(f.mode, Some(0o644));

        let d = parse_mlsd("type=dir;sizd=4096;modify=20201019151930; my folder").unwrap();
        assert!(d.dir);
        assert_eq!(d.name, "my folder");
        assert_eq!(d.size, 0);
        assert_eq!(d.mode, None);

        let l = parse_mlsd("type=OS.unix=slink:/etc/hosts;modify=20201019151930; hosts").unwrap();
        assert!(l.link && !l.dir);
        assert_eq!(l.target.as_deref(), Some("/etc/hosts"));
    }

    #[test]
    fn mlsd_skips_the_folder_and_its_parent() {
        assert!(parse_mlsd("type=cdir;modify=20201019151930; /home/x").is_none());
        assert!(parse_mlsd("type=pdir;modify=20201019151930; ..").is_none());
        assert!(parse_mlsd("no facts and no name").is_none());
    }

    #[test]
    fn mlsd_name_may_hold_semicolons_and_spaces() {
        let f = parse_mlsd("type=file;size=3; a;b  c.txt").unwrap();
        assert_eq!(f.name, "a;b  c.txt");
    }

    #[test]
    fn mlsx_time_is_utc() {
        assert_eq!(parse_mlsx_time("19700101000000"), Some(0));
        assert_eq!(parse_mlsx_time("20000301000000.123"), Some(951868800));
        assert_eq!(parse_mlsx_time("2020"), None);
        assert_eq!(parse_mlsx_time("20201319000000"), None);
    }

    #[test]
    fn list_unix_lines() {
        let f = parse_list("-rw-r--r--    1 1000     1000         5120 Nov 06 10:00 notes.txt").unwrap();
        assert_eq!(f.name, "notes.txt");
        assert_eq!(f.size, 5120);
        assert_eq!(f.mode, Some(0o644));
        assert!(!f.dir);

        let d = parse_list("drwxr-x---    2 1000     1000         4096 Jan 01  2025 backups").unwrap();
        assert!(d.dir);
        assert_eq!(d.mode, Some(0o750));

        let l = parse_list("lrwxrwxrwx    1 0        0              11 Nov 06 10:00 latest -> backups/x").unwrap();
        assert!(l.link);
        assert_eq!(l.name, "latest");
        assert_eq!(l.target.as_deref(), Some("backups/x"));

        assert!(parse_list("total 12").is_none());
        assert!(parse_list("drwxr-xr-x    2 0        0            4096 Jan 01  2025 .").is_none());
    }

    #[test]
    fn list_dos_lines() {
        let f = parse_list("10-19-20  03:19PM                 1024 report.pdf").unwrap();
        assert_eq!(f.name, "report.pdf");
        assert_eq!(f.size, 1024);
        assert_eq!(f.mode, None);
        let d = parse_list("10-19-20  03:19PM       <DIR>          Shared Docs").unwrap();
        assert!(d.dir);
        assert_eq!(d.name, "Shared Docs");
    }

    #[test]
    fn hash_replies() {
        let hex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
        assert_eq!(sha256_in_reply(&format!("213 SHA-256 0-2 {hex} abc.txt")).as_deref(), Some(hex));
        assert_eq!(sha256_in_reply(&format!("213 {}", hex.to_uppercase())).as_deref(), Some(hex));
        assert_eq!(sha256_in_reply("213 SHA-1 0-2 a9993e364706816aba3e25717850c26c9cd0d89d abc"), None);
    }
}
