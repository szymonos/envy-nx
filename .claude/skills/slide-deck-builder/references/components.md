# Components reference

Full HTML markup for the seven reusable components, plus the deck's `<head>` template. All component CSS is defined once in the inline `<style>` block of `index.html` - these snippets show the markup that consumes those classes.

## Head template

Copy verbatim when scaffolding a new deck. Bump `@6.0` to the current major.minor when needed (see [`maintenance.md`](maintenance.md) for cadence and the pin strictness ladder).

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Project Name - tagline</title>

<!-- reveal.js @6.0 (jsdelivr auto-resolves to latest 6.0.x patch) -->
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/reveal.js@6.0/dist/reveal.min.css">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/reveal.js@6.0/dist/theme/black.min.css">

<!-- Google Fonts: Outfit + JetBrains Mono -->
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;600;800&family=JetBrains+Mono:wght@700&display=swap">

<style>
  /* :root tokens + component CSS - copy from an existing deck */
</style>
</head>
<body>
<div class="reveal"><div class="slides">

  <!-- slide sections go here -->

</div></div>

<script src="https://cdn.jsdelivr.net/npm/reveal.js@6.0/dist/reveal.min.js"></script>
<script>
  Reveal.initialize({
    hash: true, slideNumber: 'c/t', showSlideNumber: 'all',
    transition: 'fade', transitionSpeed: 'fast',
    center: false, width: 1280, height: 720, margin: 0.04
  });
</script>
</body>
</html>
```

The `@6.0` appears in three places (two CSS links + one script). Keep them in sync.

## Title slide

```html
<section>
  <section class="title-slide">
    <h1>Project Name</h1>
    <p class="subtitle">One-line tagline that frames the talk</p>
    <div class="title-date">YYYY-MM-DD &nbsp;|&nbsp; Author Name &nbsp;|&nbsp; Team or Org</div>
  </section>
</section>
```

Centered (overrides default left-align). The outer wrapper section enables reveal's vertical-stack pattern in case you ever want a second title-zone slide below.

## Stat grid

Equal-width cards in 2 / 3 / 4 columns. Modifier classes: `.stat-grid` (default 3), `.stat-grid.two`, `.stat-grid.four`.

```html
<div class="stat-grid four">
  <div class="stat-card">
    <div class="big-num blue">3</div>
    <div class="big-label">platforms<br>linux &middot; macos &middot; windows</div>
  </div>
  <!-- ... -->
</div>
```

`.big-num` color modifiers: `.blue`, `.green`, `.amber`, `.red`. Cards may also contain `<ul>` at `font-size:0.42em; line-height:1.65;` for "shipped / roadmap / next" patterns.

## Comparison table

`.reveal table` with semantic `td` classes: `.ok` (green), `.fail` (red), `.warn` (amber), `.em` (bright bold), `.mono`. Headers (`th`) render mono uppercase in `--primary-light`.

```html
<table>
  <tr><th>Concern</th><th>Before</th><th>After</th></tr>
  <tr>
    <td><strong>Onboarding</strong></td>
    <td class="warn">days of manual toolchain setup</td>
    <td class="ok">&lt;1 hour to a productive baseline</td>
  </tr>
</table>
```

## Quote block

```html
<div class="quote-block">
  <div class="quote-text">Your thesis statement in one tight sentence.</div>
  <div class="quote-attribution">&mdash; Source, <em>Origin</em></div>
</div>
```

Italic body, attribution right-aligned. Use as a thesis statement that the rest of the slide unpacks.

## Code block

```html
<div class="code-block">
  <span class="prompt">$</span> your-tool <span class="flag">--scope</span> <span class="flag">--option</span>
</div>
```

`.prompt` for the dim `$`, `.flag` for amber flag tokens. For inline within prose: `<span class="code-inline">your-cli verb</span>` (amber, mono, padded).

## Info box

```html
<div class="info-box">
  <strong>Note:</strong> short callout body.
</div>
```

Left border in `--primary-light`, subtle background. Use for callouts and asides that don't warrant a full quote block.

## Horizontal timeline

```html
<div class="timeline">
  <div class="timeline-bar"></div>
  <div class="timeline-stages">
    <div class="timeline-stage" style="color: var(--accent-green);">
      <div class="timeline-dot"></div>
      <div class="timeline-label">Evaluate</div>
      <div class="timeline-detail">one machine</div>
    </div>
    <!-- ... 3 more stages -->
  </div>
</div>
```

Gradient bar runs green to blue to amber to primary-light underneath the dots. Always 4 stages. Use for adoption / maturity progressions.

## Section divider

Gradient `<hr>` in primary-light, used between the slide's main content and the closing commentary paragraph - the deck's signature rhythm:

```html
<hr>
<p style="text-align:center; font-size:0.5em;">
  Closing commentary - the meta-point.
</p>
```
