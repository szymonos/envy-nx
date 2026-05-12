# Maintenance reference

The reveal.js version pin lives in three places in `index.html` (two `<link>` + one `<script>`). The default pin is `@<major>.<minor>` (e.g. `@6.0`), so jsdelivr auto-resolves to the latest patch within that line. Bug fixes flow in without intervention; you only act for minor or major bumps.

## Pin strictness ladder

| Pin       | Auto-pulls            | Use when                                                               |
| --------- | --------------------- | ---------------------------------------------------------------------- |
| `@latest` | major + minor + patch | never - guaranteed to break sooner or later                            |
| `@6`      | minor + patch         | rarely - new features can subtly shift behavior                        |
| `@6.0`    | patch only            | **default for live decks** - SemVer guarantees patches are bugfix-only |
| `@6.0.1`  | nothing               | regulated / audited contexts requiring byte-identical renders          |

## Bumping minor or major

- **Source:** <https://github.com/hakimel/reveal.js/releases>
- **Cadence:** before each major presentation, or quarterly otherwise
- **Procedure:** edit the `@<ver>` string in all three places in `index.html`, open the file (or `mkdocs serve` and visit `/slides/`) in a browser, click through every slide. If anything visually regresses, revert.
- **Don't automate this in CI.** A silent CSS regression mid-presentation is worse than being a release behind.

## Optional Makefile target

Drop this into the host repo's `Makefile` to surface the pinned-vs-upstream gap on demand. Informational only - never gates a build:

```makefile
.PHONY: slides-update-check
slides-update-check:  ## Compare pinned reveal.js version against the latest upstream release
	@local_pin=$$(grep -oE 'reveal\.js@[^/"]+' docs/slides/index.html 2>/dev/null \
		| head -1 | sed 's/^reveal\.js@//' || echo unknown); \
	set --; \
	if command -v gh >/dev/null 2>&1 && token=$$(gh auth token 2>/dev/null) && [ -n "$$token" ]; then \
		set -- -H "Authorization: Bearer $$token"; \
	fi; \
	upstream_ver=$$(curl -sS "$$@" https://api.github.com/repos/hakimel/reveal.js/releases/latest \
		| grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'); \
	printf '  pinned:   @%s\n  upstream: %s\n' "$$local_pin" "$$upstream_ver"; \
	if [ "$$local_pin" = "$$upstream_ver" ]; then \
		echo '  status:   pinned to latest exact version'; \
	else \
		echo "  release:  https://github.com/hakimel/reveal.js/releases/tag/$$upstream_ver"; \
	fi
```

Run `make slides-update-check` ad-hoc. The pin extractor handles any pin style (`@latest`, `@6`, `@6.0`, `@6.0.1`) - it prints whatever appears after `@` in the URL alongside the upstream latest. The literal "up to date" status only fires when the pin is an exact match (e.g., `@6.0.1` vs upstream `6.0.1`); for policy pins like `@6.0`, just read pin + upstream and decide whether a minor/major bump is warranted.

If `gh` is installed and authenticated, the API call uses your token (5000 req/hour) via positional params (`set -- -H "Authorization: Bearer $token"`) so the token stays out of `ps` output and shell history; otherwise it falls back to anonymous (60 req/hour - plenty for manual use).
