# Charter - `ci`

The GitHub workflows, their scripts, and the release build (`.assets/tools/build_release.sh`). They decide what a PR must pass, what gets tested on real macOS and Linux, and what a release publishes and signs.

## What good looks like

- **Least privilege.** Each workflow and job declares the `permissions` it needs and no more; no secret reaches a step that runs PR-controlled code.
- **No script injection** - `${{ github.event.* }}` values reach `run:` through `env:`, never inline.
- **Third-party actions are pinned** and the pins are current.
- **Gates match their docs** - the label-gated integration matrix, the weekly upgrade walk, the release checks described in `docs/standards.md` and `docs/releasing.md` are what the YAML does.
- **The release build is reproducible** and the SBOM and signatures it produces are the ones the docs tell users to verify.
- **Jobs have timeouts** and fail rather than hang.

## What NOT to flag

- **Integration tests gated on the `test:integration` label** rather than every PR - they take 10-25 minutes an axis.
- **`runs-on: ubuntu-slim`** - a valid runner, used for light jobs (`REVIEW.md` Author decisions).
- **What CodeQL already reports.**

## References

- `docs/standards.md` - CI pipelines
- `docs/releasing.md`
