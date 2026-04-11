# teru Blog Post Pipeline

Write and publish a blog post for teru.sh. Orchestrates research, drafting, SEO optimization, and cross-post generation.

## Topic

$ARGUMENTS

## Protocol

You are the blog editor. Coordinate the full pipeline. Do NOT skip phases.

### Phase 1: Research

1. Read `CHANGELOG.md` to understand what shipped
2. Read `git log --oneline` for the relevant version range
3. Read the actual source files for any feature you'll mention — verify every claim
4. Read existing blog posts at `~/prod/teru.sh/src/lib/data/blogposts/` to avoid repeating angles
5. Read `README.md` for current positioning and comparison table
6. Gather real numbers:
   - `zig build test 2>&1 | tail -3` — test count
   - `make release && ls -la zig-out/bin/teru` — binary size
   - `find src -name "*.zig" | wc -l` — source file count
   - `wc -l src/**/*.zig | tail -1` — total lines

### Phase 2: Outline

Write an outline with:
- **Hook** (1-2 sentences): the pain point or surprising fact
- **Problem** section: what exists today and why it's insufficient
- **Solution** section: what teru does differently (with code)
- **Proof** section: benchmarks, architecture, real usage
- **CTA**: install instructions + links

Show the outline to the user for approval before drafting.

### Phase 3: Draft

Using the blog-writer agent:
1. Write the full post following the voice/style rules
2. Pull real code examples from the teru source tree — never fabricate
3. Include at least one code block with actual teru commands
4. Target 1500-2200 words
5. Write the mdsvex frontmatter with proper tags and description

### Phase 4: SEO Review

Check the draft against:
- [ ] Title contains the primary search keyword
- [ ] Meta description is under 160 chars with keyword near start
- [ ] H2s map to "People Also Ask" style questions
- [ ] At least 2 internal links (teru.sh/docs/*, teru.sh/features)
- [ ] Code blocks have language tags
- [ ] No broken links or references to non-existent features
- [ ] Stats are verified against actual code/build output

### Phase 5: Cross-post

Generate a dev.to version:
- Rewrite intro for dev.to audience (more context about what teru is)
- Add canonical URL: `canonical_url: https://teru.sh/blog/{slug}`
- Add dev.to frontmatter format
- Save to `cross-posts/{slug}-devto.md`

### Phase 6: Publish Checklist

Report to the user:
- [ ] Post file location
- [ ] Preview URL: `teru.sh/blog/{slug}`
- [ ] Cross-post file location
- [ ] Suggested social post (1-2 sentences + link)
- [ ] Suggested HN title (under 80 chars, no clickbait)

## Post Types (choose based on topic)

| Type | When | Length | Example title |
|------|------|--------|---------------|
| Release | After a version ships | 1200-1500w | "teru 0.4.1: left/right margins fix tmux vertical splits" |
| Deep-dive | Bi-weekly | 1800-2500w | "How teru renders 10,000 cells in 50 microseconds" |
| Comparison | Monthly | 1500-2000w | "I replaced tmux + Alacritty with a 1.4MB binary" |
| Tutorial | Bi-weekly | 1200-1800w | "Persistent terminal sessions without tmux" |
| Show HN | Launch / major release | 800-1200w | "Show HN: teru — AI-first terminal in 1.4MB, no GPU" |
