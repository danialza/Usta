//! Per-role token/cost accounting, reconstructed from the CLIs' own local
//! session logs. No network calls — this reads what claude/codex already
//! write to disk:
//!
//!   claude:  ~/.claude/projects/<escaped-cwd>/<session>.jsonl
//!            one line per message; assistant lines carry message.usage
//!   codex:   ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
//!            token_count events carry info.total_token_usage; cwd in meta
//!
//! Attribution:
//!   - worktree cwd (.usta/worktrees/<role>) → that role, exactly
//!   - shared workspace cwd → nearest role terminal launch (from our DB)
//!     whose open window contains the session start; else "(shared)"
//!
//! Prices are estimates (USD per MTok) — good enough to show where the
//! money goes, not an invoice.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Default, Clone)]
pub struct RoleUsage {
    pub vendor: &'static str,
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    pub cost_usd: f64,
    pub sessions: i32,
}

/// A role-tagged terminal window used for shared-dir attribution.
pub struct TermWindow {
    pub role: String,
    pub created_ms: i64,
    pub closed_ms: Option<i64>,
}

/// $/MTok: (input, output, cache_read, cache_write). Estimate table.
fn claude_price(model: &str) -> (f64, f64, f64, f64) {
    let m = model.to_lowercase();
    if m.contains("opus") {
        (15.0, 75.0, 1.5, 18.75)
    } else if m.contains("haiku") {
        (1.0, 5.0, 0.1, 1.25)
    } else {
        // sonnet + default
        (3.0, 15.0, 0.3, 3.75)
    }
}

/// Codex/OpenAI estimate (gpt-5-class): $/MTok (input, output, cached input).
const CODEX_PRICE: (f64, f64, f64) = (1.25, 10.0, 0.125);

/// Claude Code's project-dir escaping: every char outside [A-Za-z0-9-]
/// becomes '-'. "/a/b c" → "-a-b-c".
fn escape_cwd(p: &str) -> String {
    p.chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' })
        .collect()
}

fn parse_iso_ms(ts: &str) -> Option<i64> {
    // "2026-06-12T13:21:51.123Z" → epoch ms. Cheap manual parse (UTC only).
    let b = ts.as_bytes();
    if b.len() < 19 { return None; }
    let num = |s: &str| s.parse::<i64>().ok();
    let (y, mo, d) = (num(&ts[0..4])?, num(&ts[5..7])?, num(&ts[8..10])?);
    let (h, mi, s) = (num(&ts[11..13])?, num(&ts[14..16])?, num(&ts[17..19])?);
    // days since epoch (civil algorithm)
    let y1 = if mo <= 2 { y - 1 } else { y };
    let era = if y1 >= 0 { y1 } else { y1 - 399 } / 400;
    let yoe = y1 - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(((days * 24 + h) * 60 + mi) * 60_000 + s * 1000)
}

/// Which role does a session starting at `start_ms` belong to?
fn attribute(start_ms: i64, terms: &[TermWindow]) -> Option<String> {
    terms
        .iter()
        .filter(|t| {
            let end = t.closed_ms.unwrap_or(i64::MAX).saturating_add(15_000);
            // Session may begin a moment before our DB row lands.
            start_ms >= t.created_ms - 15_000 && start_ms <= end
        })
        .min_by_key(|t| (start_ms - t.created_ms).abs())
        .map(|t| t.role.clone())
}

fn add(map: &mut HashMap<String, RoleUsage>, role: String, u: RoleUsage) {
    let e = map.entry(role).or_insert_with(|| RoleUsage { vendor: u.vendor, ..Default::default() });
    e.vendor = u.vendor;
    e.input += u.input;
    e.output += u.output;
    e.cache_read += u.cache_read;
    e.cache_write += u.cache_write;
    e.cost_usd += u.cost_usd;
    e.sessions += u.sessions;
}

/// Sum one claude session file. Returns (usage, first_ts_ms).
fn scan_claude_session(path: &Path) -> Option<(RoleUsage, i64)> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut u = RoleUsage { vendor: "claude", sessions: 1, ..Default::default() };
    let mut first_ts: Option<i64> = None;
    for line in text.lines() {
        let v: serde_json::Value = match serde_json::from_str(line) { Ok(v) => v, Err(_) => continue };
        if first_ts.is_none() {
            if let Some(ts) = v["timestamp"].as_str().and_then(parse_iso_ms) {
                first_ts = Some(ts);
            }
        }
        let usage = &v["message"]["usage"];
        if usage.is_object() {
            let model = v["message"]["model"].as_str().unwrap_or("");
            let (pi, po, pcr, pcw) = claude_price(model);
            let inp = usage["input_tokens"].as_i64().unwrap_or(0);
            let out = usage["output_tokens"].as_i64().unwrap_or(0);
            let cr = usage["cache_read_input_tokens"].as_i64().unwrap_or(0);
            let cw = usage["cache_creation_input_tokens"].as_i64().unwrap_or(0);
            u.input += inp;
            u.output += out;
            u.cache_read += cr;
            u.cache_write += cw;
            u.cost_usd += (inp as f64 * pi + out as f64 * po + cr as f64 * pcr + cw as f64 * pcw) / 1e6;
        }
    }
    if u.input + u.output + u.cache_read + u.cache_write == 0 { return None; }
    Some((u, first_ts.unwrap_or(0)))
}

/// Sum one codex rollout file IF its cwd matches. Returns usage.
/// Codex logs cumulative `total_token_usage` — take the LAST occurrence.
fn scan_codex_session(path: &Path, ws_path: &str, wt_prefix: &str) -> Option<(RoleUsage, Option<String>)> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut cwd: Option<String> = None;
    let mut last: Option<serde_json::Value> = None;
    for line in text.lines() {
        // cwd appears once in session meta; token_count events repeat.
        if cwd.is_none() && line.contains("\"cwd\"") {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(line) {
                for probe in [&v["payload"]["cwd"], &v["cwd"], &v["payload"]["turn_context"]["cwd"]] {
                    if let Some(c) = probe.as_str() { cwd = Some(c.to_string()); break; }
                }
            }
        }
        if line.contains("total_token_usage") {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(line) {
                last = Some(v);
            }
        }
    }
    let cwd = cwd?;
    // Only sessions run inside this workspace (shared dir or a role worktree).
    let role: Option<String> = if cwd == ws_path {
        None
    } else if let Some(rest) = cwd.strip_prefix(wt_prefix) {
        Some(rest.trim_matches('/').split('/').next().unwrap_or("").to_string())
    } else {
        return None;
    };
    let v = last?;
    let tu = &v["payload"]["info"]["total_token_usage"];
    let tu = if tu.is_object() { tu } else { &v["payload"]["total_token_usage"] };
    if !tu.is_object() { return None; }
    let inp = tu["input_tokens"].as_i64().unwrap_or(0);
    let out = tu["output_tokens"].as_i64().unwrap_or(0);
    let cached = tu["cached_input_tokens"].as_i64().unwrap_or(0);
    let (pi, po, pc) = CODEX_PRICE;
    let fresh = (inp - cached).max(0);
    let u = RoleUsage {
        vendor: "codex",
        input: inp,
        output: out,
        cache_read: cached,
        cache_write: 0,
        cost_usd: (fresh as f64 * pi + out as f64 * po + cached as f64 * pc) / 1e6,
        sessions: 1,
    };
    Some((u, role))
}

/// Build the whole per-role cost map for a workspace.
pub fn compute(ws_path: &str, terms: &[TermWindow]) -> HashMap<String, RoleUsage> {
    let mut out: HashMap<String, RoleUsage> = HashMap::new();
    let home = match std::env::var("HOME") { Ok(h) => h, Err(_) => return out };

    // ---- claude: shared workspace dir + each role worktree dir ----
    let projects = PathBuf::from(&home).join(".claude/projects");
    let mut claude_dirs: Vec<(PathBuf, Option<String>)> =
        vec![(projects.join(escape_cwd(ws_path)), None)];
    let wt_root = PathBuf::from(ws_path).join(".usta/worktrees");
    if let Ok(rd) = std::fs::read_dir(&wt_root) {
        for e in rd.filter_map(|e| e.ok()) {
            let role = e.file_name().to_string_lossy().into_owned();
            let dir = projects.join(escape_cwd(&e.path().to_string_lossy()));
            claude_dirs.push((dir, Some(role)));
        }
    }
    for (dir, fixed_role) in claude_dirs {
        let Ok(rd) = std::fs::read_dir(&dir) else { continue };
        for e in rd.filter_map(|e| e.ok()) {
            let p = e.path();
            if p.extension().map(|x| x != "jsonl").unwrap_or(true) { continue; }
            let Some((u, first_ts)) = scan_claude_session(&p) else { continue };
            let role = fixed_role.clone()
                .or_else(|| attribute(first_ts, terms))
                .unwrap_or_else(|| "(shared)".into());
            add(&mut out, role, u);
        }
    }

    // ---- codex: walk ~/.codex/sessions (bounded), match by cwd ----
    let wt_prefix = format!("{ws_path}/.usta/worktrees");
    let sessions = PathBuf::from(&home).join(".codex/sessions");
    let mut stack = vec![sessions];
    let mut visited = 0usize;
    while let Some(d) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else { continue };
        for e in rd.filter_map(|e| e.ok()) {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else if p.extension().map(|x| x == "jsonl").unwrap_or(false) {
                visited += 1;
                if visited > 3000 { return out; } // hard cap: pathological dirs
                // Cheap pre-filter: skip files that never mention the ws path.
                if let Ok(txt) = std::fs::read_to_string(&p) {
                    if !txt.contains(ws_path) { continue; }
                }
                if let Some((u, role)) = scan_codex_session(&p, ws_path, &wt_prefix) {
                    // Shared-dir codex sessions: attribute via terminal windows
                    // is unreliable (codex logs no first-ts uniformly) → use
                    // file mtime as the session-start proxy.
                    let role = role.or_else(|| {
                        let mt = std::fs::metadata(&p).ok()
                            .and_then(|m| m.modified().ok())
                            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                            .map(|d| d.as_millis() as i64)?;
                        attribute(mt, terms)
                    }).unwrap_or_else(|| "(shared)".into());
                    add(&mut out, role, u);
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_parse_roundtrip() {
        // 2026-06-12T13:21:51Z
        let ms = parse_iso_ms("2026-06-12T13:21:51.123Z").unwrap();
        assert_eq!(ms % 60_000, 51_000); // seconds land intact
        assert!(ms > 1_700_000_000_000); // after 2023
    }

    #[test]
    fn escape_matches_claude_convention() {
        assert_eq!(
            escape_cwd("/Users/danial/Usta /calculator-test/calc-hub"),
            "-Users-danial-Usta--calculator-test-calc-hub"
        );
    }

    #[test]
    fn attribution_picks_nearest_open_window() {
        let terms = vec![
            TermWindow { role: "frontend".into(), created_ms: 1_000, closed_ms: Some(50_000) },
            TermWindow { role: "backend".into(), created_ms: 30_000, closed_ms: None },
        ];
        assert_eq!(attribute(2_000, &terms).unwrap(), "frontend");
        assert_eq!(attribute(31_000, &terms).unwrap(), "backend");
        assert_eq!(attribute(500_000, &terms).unwrap(), "backend"); // only open window
    }
}
