import SwiftUI
import UstaProto

/// Session replay — scrub through the team's whole run, event by event.
/// Export produces a self-contained HTML player anyone can open (no Usta
/// needed): every replay is a shareable artifact.
struct ReplayView: View {
    let workspaceName: String
    @EnvironmentObject var bus: WorkspaceBus
    @Environment(\.dismiss) private var dismiss

    @State private var cursor: Double = 0     // index into the event list
    @State private var playing = false
    @State private var exportStatus: String?

    private var events: [Usta_V1_Event] { bus.events }
    private var shown: [Usta_V1_Event] { Array(events.prefix(Int(cursor))) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "memories").foregroundStyle(UstaTheme.accentPurple)
                Text("Session replay").font(.title3.weight(.semibold))
                Spacer()
                Button("Export HTML…") { exportHTML() }
                    .disabled(events.isEmpty)
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(UstaTheme.dim)
            }
            .padding(16)
            Divider().overlay(UstaTheme.border)

            if events.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock").font(.system(size: 28)).foregroundStyle(UstaTheme.dim)
                    Text("No events to replay yet").foregroundStyle(UstaTheme.dim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(shown, id: \.id) { e in
                                replayRow(e).id(e.id)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: shown.count) { _, _ in
                        if let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }

                Divider().overlay(UstaTheme.border)
                HStack(spacing: 12) {
                    Button {
                        if Int(cursor) >= events.count { cursor = 0 }
                        playing.toggle()
                    } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .frame(width: 24, height: 24)
                    }
                    Slider(value: $cursor, in: 0...Double(events.count))
                    Text("\(Int(cursor))/\(events.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(UstaTheme.dim)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .frame(width: 560, height: 480)
        .background(UstaTheme.panel)
        .task(id: playing) {
            guard playing else { return }
            while playing && Int(cursor) < events.count {
                try? await Task.sleep(nanoseconds: 700_000_000)
                if !playing { break }
                cursor = min(cursor + 1, Double(events.count))
            }
            playing = false
        }
        .alert("Replay export", isPresented: Binding(
            get: { exportStatus != nil }, set: { if !$0 { exportStatus = nil } }
        )) { Button("OK") { exportStatus = nil } } message: { Text(exportStatus ?? "") }
    }

    private func replayRow(_ e: Usta_V1_Event) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.time(e.createdUnixMs))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(UstaTheme.dim2)
                .frame(width: 58, alignment: .leading)
            Circle().fill(UstaTheme.roleColor(for: e.fromRole))
                .frame(width: 7, height: 7).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("@\(e.fromRole)").font(.system(size: 11, weight: .semibold))
                    Text(e.topic).font(.system(size: 10))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(UstaTheme.cell).clipShape(Capsule())
                        .foregroundStyle(UstaTheme.dim)
                }
                Text(e.summary).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func time(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    // MARK: export

    private func exportHTML() {
        let items: [[String: Any]] = events.map {
            ["t": $0.createdUnixMs, "role": $0.fromRole, "topic": $0.topic, "summary": $0.summary]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let json = String(data: data, encoding: .utf8) else { return }
        let html = Self.playerHTML(title: workspaceName, eventsJSON: json)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(workspaceName)-replay.html"
        panel.title = "Export Session Replay"
        if panel.runModal() == .OK, let url = panel.url {
            try? html.write(to: url, atomically: true, encoding: .utf8)
            exportStatus = "Replay exported → \(url.lastPathComponent)"
        }
    }

    /// Minimal self-contained dark-theme player.
    static func playerHTML(title: String, eventsJSON: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <title>\(title) — Usta replay</title>
        <style>
        body{background:#050810;color:#e8e9ef;font:14px -apple-system,system-ui,sans-serif;max-width:720px;margin:32px auto;padding:0 16px}
        h1{font-size:18px}h1 span{color:#2DD4A7}
        .row{display:flex;gap:10px;padding:8px 10px;border-left:2px solid #1f2632;margin:4px 0;opacity:0;transform:translateY(6px);transition:all .3s}
        .row.on{opacity:1;transform:none}
        .t{color:#616374;font-family:ui-monospace,monospace;font-size:11px;min-width:64px}
        .role{color:#2DD4A7;font-weight:600}
        .topic{background:#0e1320;border-radius:99px;padding:1px 8px;font-size:11px;color:#8b8d9e;margin-left:6px}
        .sum{color:#c9cbd6;font-size:12px;margin-top:2px}
        .bar{display:flex;gap:10px;align-items:center;margin:18px 0}
        button{background:#2DD4A7;color:#04211a;border:0;border-radius:8px;padding:6px 14px;font-weight:700;cursor:pointer}
        input[type=range]{flex:1}
        footer{color:#616374;font-size:11px;margin-top:24px}
        footer a{color:#2DD4A7}
        </style></head><body>
        <h1><span>Usta</span> session replay — \(title)</h1>
        <div class="bar"><button id="play">▶ Play</button><input type="range" id="seek" min="0" value="0"><span id="n" class="t"></span></div>
        <div id="feed"></div>
        <footer>Recorded with <a href="https://github.com/danialza/Usta">Usta</a> — your AI engineering team on macOS.</footer>
        <script>
        const EVENTS = \(eventsJSON);
        const feed = document.getElementById('feed'), seek = document.getElementById('seek'),
              n = document.getElementById('n'), play = document.getElementById('play');
        seek.max = EVENTS.length;
        const fmt = ms => new Date(ms).toTimeString().slice(0,8);
        EVENTS.forEach(e => {
          const d = document.createElement('div'); d.className = 'row';
          d.innerHTML = `<div class="t">${fmt(e.t)}</div><div><span class="role">@${e.role}</span><span class="topic">${e.topic}</span><div class="sum">${e.summary.replace(/</g,'&lt;')}</div></div>`;
          feed.appendChild(d);
        });
        const rows = [...feed.children];
        let cur = 0, timer = null;
        function show(k){ cur = k; rows.forEach((r,i)=>r.classList.toggle('on', i<k)); seek.value = k; n.textContent = k+'/'+EVENTS.length;
          if(k>0) rows[k-1].scrollIntoView({block:'nearest',behavior:'smooth'}); }
        seek.oninput = () => show(+seek.value);
        play.onclick = () => {
          if (timer){ clearInterval(timer); timer=null; play.textContent='▶ Play'; return; }
          if (cur >= EVENTS.length) show(0);
          play.textContent='⏸ Pause';
          timer = setInterval(()=>{ if(cur>=EVENTS.length){clearInterval(timer);timer=null;play.textContent='▶ Play';return;} show(cur+1); }, 700);
        };
        show(0);
        </script></body></html>
        """
    }
}
