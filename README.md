# get-theia

The landing page and installers of theia, published to
https://dokimelabs.github.io/get-theia/ from `distribution/get-theia` of
the theia source (one orphan commit per publish — this repository carries
no history of its own).

    curl -fsSL https://dokimelabs.github.io/get-theia/install.sh | sh     # macOS, Linux
    irm https://dokimelabs.github.io/get-theia/install.ps1 | iex          # Windows

The installers sign in through the release gate (a Cloudflare worker, see
`deploy/cloudflare/get-theia`); `@THEIA_AUTH_URL@` is replaced with the
gate's URL when the page is published. A sign-in leaves an install
credential in the installation's `.credentials.json`, so later installs
and `theia update` need no browser.

`version.json` names the newest release (`{"version":"x.y.z"}`, written at
publish from the gate's `releases/latest.json`); theia's update check
reads it here, so checking costs the gate nothing.
