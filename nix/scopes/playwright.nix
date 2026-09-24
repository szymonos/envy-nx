# Playwright browsers (Linux only). nix/configure/playwright.sh installs the
# matching playwright CLI as a uv tool; projects still pin their own library.
# Upstream `playwright install` downloads generic binaries that need host
# libraries (`install-deps` is apt-only and needs root). nixpkgs' browsers are
# linked against the nix store, so they run on any distro without root.
# PLAYWRIGHT_BROWSERS_PATH (rendered into the shell profile) points at them.
# The project's playwright version must match these browsers: each release
# looks for one exact browser revision (chromium-NNNN). The version file holds
# nixpkgs' python playwright version, not playwright-driver's - PyPI skips patch
# releases (driver 1.61.1, PyPI 1.61.0), and nixpkgs pairs the two.
# Public interface: `$PLAYWRIGHT_BROWSERS_PATH.version` lets any script match
# its playwright to these browsers - keep the path and the PyPI content stable.
# Chromium only - Firefox and WebKit would more than double the ~1 GB closure.
# macOS: empty - the configure hook runs `playwright install chromium` there.
# bins: (external-installer)
{ pkgs }: with pkgs;
let
  playwright-browsers = linkFarm "playwright-browsers" {
    "share/playwright-browsers" = playwright-driver.browsers.override { withFirefox = false; withWebkit = false; };
    "share/playwright-browsers.version" = writeText "playwright-version" python3Packages.playwright.version;
  };
in
lib.optionals stdenv.hostPlatform.isLinux
[
  playwright-browsers
]
