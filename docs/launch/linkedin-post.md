# LinkedIn launch post

## English

I've been building something for the last few months and today I'm shipping it.

**Usta** — a native macOS IDE where you don't talk to one AI assistant. You talk to a team.

A PM agent reads your idea, drafts a plan, spawns specialist roles (frontend, backend, database, QA, designer, security, devops…), and they coordinate through a shared event bus. When one finishes a piece, the next one knows automatically.

Each role runs in its own real terminal — Claude, Gemini, or local Ollama, your pick. Pluggable. No lock-in.

Why I built it: Cursor / Copilot / Claude Code are great, but they're single-agent. Real engineering is a team handing off work. I wanted the IDE to model that.

Tech: SwiftUI on top, Rust daemon underneath (tokio + gRPC over a Unix socket), real PTYs, SQLite event store, MCP for external tools.

Open source. MIT. Repo + binary:
👉 github.com/danialza/atelier

If you find it interesting, a ⭐ helps a lot. Feedback even more.

#AI #DeveloperTools #OpenSource #Swift #Rust #LLM #macOS

---

## فارسی

چند ماه روی این کار کردم، امروز منتشرش می‌کنم.

**Usta** — یک IDE نِیتیو برای مک. ولی به جای اینکه با یک دستیار هوش مصنوعی حرف بزنی، با یک **تیم** حرف می‌زنی.

یه ایجنت PM ایده‌ت رو می‌خونه، نقش‌های متخصص رو پیشنهاد می‌ده (فرانت، بک، دیتابیس، QA، طراح، سکیوریتی، دواپس…)، و بین خودشون از طریق یه event bus مشترک هماهنگ می‌شن. وقتی یکی کارش تموم شه، نفر بعدی خودش می‌فهمه.

هر نقش توی ترمینال خودش اجرا می‌شه — Claude، Gemini، یا Ollama لوکال. هر کدوم رو خواستی.

چرا ساختمش: ابزارهای فعلی تک‌ایجنته‌ن. ولی مهندسی واقعی یعنی تیمی که کار رو دست به دست می‌ده. خواستم IDE هم همین شکلی باشه.

استک: SwiftUI + Rust + tokio + gRPC + SQLite + MCP.

اوپن‌سورس. MIT.
👉 github.com/danialza/atelier

اگه جالب بود یه ⭐ خیلی کمک می‌کنه. فیدبک از اون هم بیشتر.

#هوش_مصنوعی #اوپن_سورس
