---
name: slide-deck-builder
description: Build or update a reveal.js slide deck with a dark theme, semantic accent colors, and technical density (Outfit + JetBrains Mono fonts; indigo + green/amber/red/blue accents). Operates on docs/slides/index.html if present; scaffolds a new one otherwise. Use this skill whenever the user mentions slides, the deck, a presentation, a talk, or wants to add, edit, or fix any slide-level content - even if they don't explicitly say "reveal.js".
---

# Slide deck builder (reveal.js)

Maintenance manual for a single-file reveal.js deck at `docs/slides/index.html`. Reveal.js + theme CSS load from `cdn.jsdelivr.net` (version-pinned in the URL); fonts load from Google Fonts (the wrapping MkDocs Material site already requires `fonts.googleapis.com`, so this is zero new dependency). The HTML file IS the deck - no build step, no `assets/` directory, no vendored libraries.

## When to use

- "make / build / draft a slide deck about X"
- "add a slide showing Z" / "insert a slide between intro and roadmap"
- "edit the [intro / roadmap / evidence] slide"
- "update the comparison table to add a row"
- "the deck looks cramped / colors are off / fonts are wrong - fix it"
- "scaffold a new deck for topic Y"

## Stack

| Layer        | Choice                                                                      | Why                                                                     |
| ------------ | --------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| Framework    | reveal.js from `cdn.jsdelivr.net`, pinned `@<major>.<minor>` (e.g. `@6.0`)  | small `index.html`; patch bug fixes auto-flow via SemVer                |
| Theme base   | `dist/theme/black.min.css` from same jsdelivr URL                           | dark canvas; everything else overrides via inline `<style>`             |
| Fonts        | Outfit (300 / 600 / 800) + JetBrains Mono (700) from `fonts.googleapis.com` | MkDocs Material already loads Google Fonts for the wrapping site        |
| Aspect ratio | 1280x720 logical                                                            | reveal auto-scales to viewport                                          |
| Transition   | `fade` at fast speed                                                        | technical decks; flashy transitions distract                            |
| Output       | one `index.html`, served from the wrapping MkDocs site                      | no build step; trivially diffable; presented live from the deployed URL |

The stack is load-bearing - changing a layer (build pipeline, framework, swapping reveal, adding a new CDN host) cascades into the whole visual system. Confirm with the user before any layer change.

## Theme tokens

The whole design system lives in one `:root` block at the top of the inline `<style>`. Reach for an existing token rather than inventing a color per deck.

| Token             | Value                    | Use                                            |
| ----------------- | ------------------------ | ---------------------------------------------- |
| `--primary`       | `#5C6BC0`                | brand indigo, deep                             |
| `--primary-light` | `#7986CB`                | brand indigo, h3, accents, primary emphasis    |
| `--accent-blue`   | `#42A5F5`                | neutral / info / "in progress"                 |
| `--accent-red`    | `#FF3B4F`                | negative / current pain / failure              |
| `--accent-amber`  | `#FFAB00`                | warning / partial / roadmap                    |
| `--accent-green`  | `#00C853`                | positive / shipped / target state              |
| `--bg-card`       | `rgba(255,255,255,0.04)` | subtle elevation on `.stat-card` / `.info-box` |
| `--text-main`     | `#E8ECF4`                | body text                                      |
| `--text-dim`      | `#7A8599`                | captions, attributions, secondary commentary   |
| `--text-bright`   | `#FFFFFF`                | headings, emphasized cells                     |

**Color semantics matter.** Green / amber / red / blue map to ok / warn / fail / info. A "before vs after" comparison uses red for current pain and green for target state - never inverted.

## Reusable components

The deck has seven components, all defined in the inline `<style>` block. To add a slide, copy the markup of an existing slide that uses the same component rather than reinventing it.

| Component           | Use for                                                           |
| ------------------- | ----------------------------------------------------------------- |
| Title slide         | the cover                                                         |
| Stat grid           | "by the numbers" pages, three-pillar comparisons, evidence cards  |
| Comparison table    | before-vs-after, feature matrices, ownership / RACI tables        |
| Quote block         | thesis statement + attribution that the rest of the slide unpacks |
| Code block          | shell commands, config snippets                                   |
| Info box            | callouts and asides that don't warrant a full quote               |
| Horizontal timeline | 4-stage progressions (Evaluate, Pilot, Standardize, Scale)        |

For full HTML markup of each component plus the deck's `<head>` template, **read [`references/components.md`](references/components.md)**.

## Slide structure

The recurring shape - preserve this skeleton when editing:

```html
<!-- ============================================================ -->
<!-- SECTION-NAME - one-line intent -->
<!-- ============================================================ -->
<section>
  <h2>Slide title - the claim</h2>
  <h3>Subtitle - the framing</h3>

  <p>Optional setup paragraph.</p>

  <!-- main visual: stat-grid / table / code-block / quote-block / timeline -->

  <hr>

  <p style="text-align:center; font-size:0.5em;">
    Closing commentary - the meta-point. Often italicized or with
    <strong style="color:var(--primary-light);">colored emphasis</strong>.
  </p>
</section>
```

The `<hr>` + small-font commentary lets the H2 make a sharper claim than the body could defend on its own. It's the deck's signature rhythm.

## Density

This is a technical deck for a technical audience - the generic "30 words per slide" rule does not apply.

- Paragraphs are allowed (60-150 words across multiple paragraphs is fine).
- Tables can be 4-7 rows. Don't split a coherent comparison just to satisfy a word count.
- Stat cards can hold bullet lists at `font-size:0.42em` for "shipped / roadmap / next" patterns.
- Use HTML entities for typography: `&mdash;`, `&middot;`, `&hellip;`, `&rarr;`, `&lt;` / `&gt;`.
- Set numbers in JetBrains Mono via `.big-num` or `.code-inline`, never in Outfit.
- Bold + colored emphasis is canonical: `<strong style="color:var(--primary-light);">key noun</strong>`.

## Editing workflow

- **Modify a slide.** Grep for the `<!-- SECTION-NAME -->` divider, edit in place, preserve the H2 / H3 / visual / `<hr>` / commentary skeleton. If content overflows the 1280x720 frame, trim copy or drop a font size by 0.04em rather than disabling scrolling.
- **Add a slide.** Copy a similar slide's `<!-- ===== --> + <section>` block, paste at the right narrative position, update the comment divider so the next editor can find it.
- **Update the theme.** Edit only the `:root` block. Verify text contrast against any new background (WCAG AA = 4.5:1 for `--text-dim`) and re-check the four semantic accents still telegraph their meanings.
- **Scaffold a new deck.** Copy the head template from [`references/components.md`](references/components.md), add the inline `<style>` block (copy from an existing deck), then add slide sections following the structure above. Open in a browser to verify - no build step.

## MkDocs integration (optional)

When the deck lives inside a MkDocs site, hide it from the nav while preserving livereload during local previews:

```yaml
not_in_nav: |
  /slides/

watch:
  - docs/slides
```

`not_in_nav` (Material for MkDocs) keeps the deck out of the auto-generated sidebar; `watch` makes the dev server hot-reload on edits inside `docs/slides/`.

## Maintenance

The reveal.js version pin lives in three places in `index.html` (two `<link>` + one `<script>`). The default `@<major>.<minor>` policy lets jsdelivr auto-resolve to the latest patch within that line - bug fixes flow in automatically; you only intervene for minor or major bumps.

For the pin strictness ladder, the bump procedure, and an optional `make slides-update-check` target, **read [`references/maintenance.md`](references/maintenance.md)**.

## Anti-patterns

These come up because they sound reasonable - here's why they're not:

- **"Max 30 words per slide."** That's corporate-sales-deck wisdom. The audience here is technical; density is the point.
- **Inventing a new accent color per deck.** If you think you need a fifth accent, the design isn't done - the slide probably wants two slides.
- **Adding a new CDN host.** Beyond jsdelivr (reveal) + `fonts.googleapis.com` (already loaded by the wrapping site), each new host is a corporate-proxy ask and a runtime dependency. Confirm with the proxy first.
- **Using `@latest` or a bare-major pin like `@6`.** Auto-flow at major or minor level lets in behavior shifts that surprise you mid-presentation. `@6.0` (auto-patch) is the right default.
- **Replacing reveal.js** with another framework "for cleaner code." The pinned reveal is load-bearing for the visual system - swapping means rewriting every slide.
- **Splitting a coherent comparison across two slides** to fit a word count. Keep it together; trim font size by 0.04em if needed.
- **Removing the `<!-- ===== -->` comment dividers.** They're how editors (and this skill) navigate. They cost nothing.
- **Reaching for Chart.js / D3** for a number that fits in `.big-num`. The stat-grid is the chart.
- **Writing new component CSS without checking** whether `stat-grid` / table / quote-block / info-box already covers it.

## Example invocations

- "Update the comparison table to add a 'CI/CD setup' row showing before vs after"
- "Add a slide between intro and benefits explaining the three-tier package model"
- "The roadmap slide is too cramped - split the bullet lists into two columns"
- "Change the brand color from indigo to emerald - propose the new tokens before applying"
- "Bump the reveal.js minor pin from `@6.0` to `@6.1`, click through every slide to verify"
- "Scaffold a new deck for topic X using the head template"
