//! Claude skill catalogue. Maps a skill id to a one-line capability hint.
//! Used to inject "you have these skills" context into a role's system
//! prompt. Real skill execution lands with the plugin layer later.

pub fn describe(skill: &str) -> Option<&'static str> {
    Some(match skill {
        // Anthropic built-ins
        "pdf"                => "read/extract/fill/create PDF files",
        "xlsx"               => "read, edit, and create Excel/CSV spreadsheets",
        "docx"               => "create and edit Word documents",
        "pptx"               => "create and edit PowerPoint decks",
        "skill-creator"      => "author and refine new Claude skills",
        "consolidate-memory" => "merge and prune long-term memory files",
        "setup-cowork"       => "guided Cowork environment setup",
        // mattpocock/skills — clone to ~/.claude/commands/ to activate
        "grill-me"           => "interview user with precise questions before writing code; build shared understanding first",
        "grill-with-docs"    => "like grill-me but also reads project docs to ground its questions",
        "tdd"                => "force Test-Driven Development cycle (Red → Green → Refactor) step by step",
        "improve-codebase-architecture" => "find tangled code and refactor into deep, clean modules",
        "diagnose"           => "structured debug loop for hard bugs — reproduce, isolate, fix, verify",
        "to-prd"             => "convert chat + planning into a Product Requirements Document",
        "to-issues"          => "split a PRD into discrete GitHub issues, each independently deliverable",
        _ => return None,
    })
}

const MAX_SKILL_BYTES: usize = 6 * 1024;

/// Candidate SKILL.md locations for a skill id.
fn skill_paths(name: &str) -> Vec<std::path::PathBuf> {
    use std::path::PathBuf;
    let mut out = Vec::new();
    if let Ok(dir) = std::env::var("ATELIER_SKILLS_DIR") {
        out.push(PathBuf::from(dir).join(name).join("SKILL.md"));
    }
    if let Ok(home) = std::env::var("HOME") {
        let home = PathBuf::from(home);
        out.push(home.join(".claude/skills").join(name).join("SKILL.md"));
        // mattpocock/skills slash-command layout
        out.push(home.join(".claude/commands").join(format!("{name}.md")));
        // one-level glob over the plugin cache: ~/.claude/plugins/cache/*/.../skills/<name>/SKILL.md
        let cache = home.join(".claude/plugins/cache");
        if let Ok(rd) = std::fs::read_dir(&cache) {
            for plugin in rd.flatten() {
                // plugins may nest: <plugin>/<inner>/skills/<name> or <plugin>/skills/<name>
                let base = plugin.path();
                out.push(base.join("skills").join(name).join("SKILL.md"));
                if let Ok(inner) = std::fs::read_dir(&base) {
                    for sub in inner.flatten() {
                        out.push(sub.path().join("skills").join(name).join("SKILL.md"));
                    }
                }
            }
        }
    }
    out
}

/// Load the real SKILL.md body for a skill, capped. None if not found.
pub fn load_skill_md(name: &str) -> Option<String> {
    for p in skill_paths(name) {
        if let Ok(body) = std::fs::read_to_string(&p) {
            let take = body.len().min(MAX_SKILL_BYTES);
            let mut s = body[..take].to_string();
            if body.len() > take { s.push_str("\n…(truncated)"); }
            return Some(s);
        }
    }
    None
}

/// Render a system-prompt block. Injects the full SKILL.md when found on
/// disk, else falls back to the one-line capability hint.
pub fn render_block(skills: &[String]) -> String {
    if skills.is_empty() {
        return String::new();
    }
    let mut out = String::from("\n\n## Your Claude skills\n");
    for s in skills {
        if let Some(md) = load_skill_md(s) {
            out.push_str(&format!("\n### Skill: {s}\n{md}\n"));
        } else {
            let desc = describe(s).unwrap_or("(custom skill)");
            out.push_str(&format!("- {s}: {desc}\n"));
        }
    }
    out
}
