//! User-attached reference material (mockups, specs, clips, transcripts).
//!
//! Two jobs, and both matter:
//!
//! 1. **Persist** every attachment under `<workspace>/.usta/attachments/`.
//!    The CLI agents run *inside* the workspace, so a path is all they need —
//!    `@ui-ux` can literally open the mockup PNG, `@docs` can read the spec
//!    PDF. This is what makes attachments useful rather than decorative.
//! 2. **Forward** the visual ones to the model as vision blocks, so the PM
//!    can see a mockup while proposing the team.
//!
//! Everything is best-effort: a file that can't be written still reaches the
//! model, and a format we can't inline still shows up in the manifest so the
//! agents know it exists.

use usta_providers::{ChatMessage, ContentPart};
use usta_proto::v1::{attachment::Kind as PbKind, Attachment as PbAttachment};

/// Where attachments live, relative to the workspace root.
pub const DIR: &str = ".usta/attachments";

/// Sanitise a user-supplied filename into something safe to join onto a path:
/// basename only, no traversal, conservative charset.
fn safe_name(raw: &str) -> String {
    let base = raw.rsplit('/').next().unwrap_or(raw);
    let base = base.rsplit('\\').next().unwrap_or(base);
    let cleaned: String = base
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | ' ') { c } else { '-' }
        })
        .collect();
    let cleaned = cleaned.trim().trim_matches('.').to_string();
    if cleaned.is_empty() { "attachment".into() } else { cleaned }
}

/// Write the attachments into `<ws_path>/.usta/attachments/`, filling in each
/// one's `saved_path`. Name collisions get a `-2`, `-3`, … suffix so a second
/// drop never silently overwrites the first.
pub fn persist(ws_path: &str, atts: &mut [PbAttachment]) {
    if atts.is_empty() { return; }
    let dir = std::path::Path::new(ws_path).join(DIR);
    if let Err(e) = std::fs::create_dir_all(&dir) {
        tracing::warn!(error = %e, dir = %dir.display(), "attachments: mkdir failed");
        return;
    }
    for att in atts.iter_mut() {
        let name = safe_name(&att.filename);
        let (stem, ext) = match name.rsplit_once('.') {
            Some((s, e)) if !s.is_empty() => (s.to_string(), format!(".{e}")),
            _ => (name.clone(), String::new()),
        };
        // Find a free filename.
        let mut candidate = dir.join(&name);
        let mut n = 2;
        while candidate.exists() {
            candidate = dir.join(format!("{stem}-{n}{ext}"));
            n += 1;
        }
        // Prefer the raw bytes; fall back to writing the extracted text so
        // even a transcript-only attachment leaves something on disk.
        let wrote = if !att.data.is_empty() {
            std::fs::write(&candidate, &att.data).is_ok()
        } else if !att.extracted_text.is_empty() {
            let txt = candidate.with_extension("txt");
            let ok = std::fs::write(&txt, att.extracted_text.as_bytes()).is_ok();
            if ok { candidate = txt; }
            ok
        } else {
            false
        };
        if wrote {
            att.saved_path = format!("{DIR}/{}", candidate.file_name().unwrap().to_string_lossy());
            tracing::info!(file = %att.saved_path, "attachment saved");
        }
        // Video keyframes ride along as `<stem>-frame1.png`, … so a
        // non-vision agent can still look at what happened in the clip.
        if !att.frames.is_empty() {
            for (i, f) in att.frames.iter().enumerate() {
                let fp = dir.join(format!("{stem}-frame{}.png", i + 1));
                let _ = std::fs::write(&fp, f);
            }
        }
    }
}

/// Human-readable list injected into prompts, telling the model (and, via the
/// role briefs, the CLI agents) what exists and where to find it.
pub fn manifest(atts: &[PbAttachment]) -> String {
    if atts.is_empty() { return String::new(); }
    let mut out = String::from("\n## Attachments from the user\n");
    for att in atts {
        let kind = match att.kind() {
            PbKind::Image => "image",
            PbKind::Pdf => "pdf",
            PbKind::Video => "video",
            PbKind::Audio => "audio",
            PbKind::Text => "text",
            PbKind::Other => "file",
        };
        let loc = if att.saved_path.is_empty() {
            String::new()
        } else {
            format!(" — saved at `{}` (read it directly)", att.saved_path)
        };
        out.push_str(&format!("- **{}** ({kind}){}\n", att.filename, loc));
        if !att.extracted_text.is_empty() {
            let t = att.extracted_text.trim();
            let clipped: String = t.chars().take(4000).collect();
            out.push_str(&format!(
                "  Contents:\n  ```\n  {}\n  ```\n",
                clipped.replace('\n', "\n  ")
            ));
            if t.chars().count() > 4000 { out.push_str("  _(truncated — open the file for the rest)_\n"); }
        }
        if !att.frames.is_empty() {
            out.push_str(&format!("  {} keyframes extracted from the clip.\n", att.frames.len()));
        }
    }
    out.push_str(
        "Treat these as authoritative reference material — inspect them before \
         making assumptions.\n",
    );
    out
}

/// Turn attachments into the multimodal parts of a user message: images and
/// PDFs become real vision/document blocks, video becomes its keyframes.
pub fn content_parts(atts: &[PbAttachment]) -> Vec<ContentPart> {
    let mut parts = Vec::new();
    for att in atts {
        match att.kind() {
            PbKind::Image if !att.data.is_empty() => {
                parts.push(ContentPart::Image {
                    mime: if att.mime.is_empty() { "image/png".into() } else { att.mime.clone() },
                    data: att.data.to_vec(),
                });
            }
            PbKind::Pdf if !att.data.is_empty() => {
                parts.push(ContentPart::Document {
                    mime: "application/pdf".into(),
                    data: att.data.to_vec(),
                    filename: att.filename.clone(),
                });
            }
            PbKind::Video => {
                for f in &att.frames {
                    parts.push(ContentPart::Image { mime: "image/png".into(), data: f.to_vec() });
                }
            }
            _ => {} // text/audio/other travel in the manifest instead
        }
    }
    parts
}

/// Build the user turn: the typed prompt, the attachment manifest, and any
/// vision blocks — in that order, so the model reads the ask first.
pub fn user_message(prompt: &str, atts: &[PbAttachment]) -> ChatMessage {
    let mut parts = vec![ContentPart::Text(format!("{}{}", prompt, manifest(atts)))];
    parts.extend(content_parts(atts));
    ChatMessage { role: "user".into(), parts }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safe_name_strips_traversal() {
        assert_eq!(safe_name("../../etc/passwd"), "passwd");
        assert_eq!(safe_name("/tmp/a/b/mock up.png"), "mock up.png");
        assert_eq!(safe_name("weird*name?.png"), "weird-name-.png");
        assert_eq!(safe_name(""), "attachment");
        assert_eq!(safe_name("..."), "attachment");
    }

    #[test]
    fn persist_writes_and_dedupes() {
        let dir = std::env::temp_dir().join(format!("usta-att-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&dir).unwrap();
        let ws = dir.to_string_lossy().to_string();
        let mk = || PbAttachment {
            kind: PbKind::Image as i32,
            filename: "shot.png".into(),
            mime: "image/png".into(),
            data: b"fake".to_vec(),
            ..Default::default()
        };
        let mut a = vec![mk()];
        persist(&ws, &mut a);
        assert_eq!(a[0].saved_path, ".usta/attachments/shot.png");
        let mut b = vec![mk()];
        persist(&ws, &mut b);
        assert_eq!(b[0].saved_path, ".usta/attachments/shot-2.png", "collision must not overwrite");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn manifest_mentions_path_and_text() {
        let atts = vec![PbAttachment {
            kind: PbKind::Text as i32,
            filename: "spec.md".into(),
            extracted_text: "Build a login page".into(),
            saved_path: ".usta/attachments/spec.md".into(),
            ..Default::default()
        }];
        let m = manifest(&atts);
        assert!(m.contains("spec.md"));
        assert!(m.contains(".usta/attachments/spec.md"));
        assert!(m.contains("Build a login page"));
    }
}
