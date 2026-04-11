---
name: content-strategy
description: Content calendar and promotion strategy for teru. Suggests what to write and where to publish based on release cycles, feature gaps, and audience reach.
---

# teru Content Strategy

## Release-to-Content Pipeline

Every teru release should generate content. Map releases to post types:

| Release type | Content to produce |
|---|---|
| Patch (0.x.Y) | Short release post + changelog update on teru.sh |
| Minor (0.X.0) | Feature deep-dive + comparison update + Show HN consideration |
| Major subsystem | Architecture deep-dive (renders, parser, daemon) |
| New platform support | Tutorial for that platform's users |
| Distribution channel added | Install guide + announcement |

## Content Calendar Pattern

Week 1: Release announcement (if shipped)
Week 2: Tutorial solving a real problem
Week 3: Deep-dive into architecture
Week 4: Comparison or "why I built it this way"

## Distribution Channels (priority order)

1. **teru.sh/blog** — canonical, always publish here first
2. **Hacker News** — for launches and architecture posts. Title: factual, no hype. Best times: Tuesday-Thursday 8-10am EST
3. **dev.to** — cross-post with canonical URL. Tag: #terminal #zig #ai #opensource
4. **r/commandline** — direct link to blog post, short intro in comment
5. **r/zig** — for architecture posts about Zig-specific patterns
6. **Lobsters** — invite-only, high signal, tag: zig, terminal
7. **Twitter/X** — thread format: hook + 3 key points + link. Use @ziglang @AnthropicAI mentions
8. **Changelog.com** — submit notable releases

## SEO Keyword Targets

### High intent (people looking for a solution)
- "tmux alternative"
- "terminal multiplexer"
- "ai terminal emulator"
- "persistent terminal sessions"
- "terminal emulator no gpu"

### Comparison queries (decision stage)
- "alacritty vs wezterm vs kitty"
- "tmux vs zellij vs teru"
- "best terminal emulator 2026"
- "terminal emulator for ai coding"

### Long-tail technical (backlink magnets)
- "simd terminal rendering"
- "cpu vs gpu terminal rendering"
- "vt100 parser implementation"
- "zig terminal emulator"
- "mcp server terminal"

## Competitive Positioning

| Competitor | Their strength | teru's angle |
|---|---|---|
| Ghostty | Zig + GPU, large community | No GPU needed, built-in multiplexer |
| Alacritty | Fast, minimal | teru is minimal too (1.4MB) but includes multiplexer |
| WezTerm | Feature-rich, Lua config | teru: simpler config, native AI protocol |
| Zellij | Modern multiplexer | teru: emulator+multiplexer in one, AI-native |
| Warp | AI features | teru: local AI orchestration vs cloud suggestions |
| tmux | Universal | teru replaces tmux entirely, one less tool |

## Stats to Keep Current

Before any content, verify these haven't changed:
```bash
zig build test 2>&1 | grep -c "test" || echo "check manually"
ls -la zig-out/bin/teru | awk '{print $5}'  # binary size bytes
find src -name "*.zig" | wc -l              # source files
wc -l src/**/*.zig 2>/dev/null | tail -1    # total lines
git tag | wc -l                              # release count
```

## What NOT to Write

- Feature announcements for unfinished work
- Comparisons that trash competitors — acknowledge their strengths
- Posts that promise "the future" — write about what ships today
- Generic "top 10 terminal tips" content farm posts
- Anything with hallucinated benchmarks — measure or don't claim
