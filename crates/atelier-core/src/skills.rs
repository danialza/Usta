//! Claude skill catalogue. Maps a skill id to a one-line capability hint.
//! Used to inject "you have these skills" context into a role's system
//! prompt. Real skill execution lands with the plugin layer later.

pub fn describe(skill: &str) -> Option<&'static str> {
    Some(match skill {
        "pdf"                => "read/extract/fill/create PDF files",
        "xlsx"               => "read, edit, and create Excel/CSV spreadsheets",
        "docx"               => "create and edit Word documents",
        "pptx"               => "create and edit PowerPoint decks",
        "skill-creator"      => "author and refine new Claude skills",
        "consolidate-memory" => "merge and prune long-term memory files",
        "setup-cowork"       => "guided Cowork environment setup",
        _ => return None,
    })
}

/// Render a system-prompt block listing the skills this role can use.
pub fn render_block(skills: &[String]) -> String {
    if skills.is_empty() {
        return String::new();
    }
    let mut out = String::from("\n\n## Your Claude skills\nYou have these skills available; use them when relevant:\n");
    for s in skills {
        let desc = describe(s).unwrap_or("(custom skill)");
        out.push_str(&format!("- {s}: {desc}\n"));
    }
    out
}
