# get-theia — the theia installer and docs site (generated artifact)

```sh
curl -fsSL https://dokimelabs.github.io/get-theia/install.sh | sh
```

The published site also carries the documentation:
[user guide](https://dokimelabs.github.io/get-theia/docs/en/) (en/ru) and
the [platform reference](https://dokimelabs.github.io/get-theia/reference/)
— both built with Diplodoc from `docs/sources/` in theia-dev at publish
time.

This repository is a **build artifact with no history**: its entire content
is replicated from `dokimelabs/theia-dev` (`distribution/get-theia/`, plus
the docs built in CI) by the
publish workflow on every change — a single orphan commit each time. Do not
open pull requests or push here; changes land in theia-dev and flow out.
Issues and wiki are disabled; pull requests are closed automatically.

`THEIA_VERSION=<x.y.z>` pins an exact release (also the recovery lever —
re-running the installer replaces an existing install wholesale and verifies
the binary runs before the PATH symlink flips). The latest never resolves a
pre-release; `-pre.N` builds install only when the exact suffixed version is
typed.
