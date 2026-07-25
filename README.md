# `downloads` — manifests served to Piper clients

This is an **orphan branch**. It shares no history with `main` and holds no
source code — only the release manifests that shipped clients fetch over
`raw.githubusercontent.com`.

## Why a branch

Piper is a fork of [`jacobaraujo7/remote_pi`](https://github.com/jacobaraujo7/remote_pi),
whose clients fetch their manifests from a host the upstream author operates
(`rp-s3.jacobmoura.work`). This fork has no such host, and pointing at theirs
would make Piper offer *Remote Pi* builds to its users.

A branch gives a stable URL with no server to run, no domain and no TLS to
renew. `/releases/latest/download/` was not an option: releases here split into
`app-v*` and `cockpit-v*` tags, so `latest` would resolve to whichever product
shipped most recently.

## Layout

```
app/latest.json                  → the in-app update banner (Android)
cockpit/latest.json              → the update card + Linux notify path
cockpit/appcast-windows.xml      → WinSparkle self-update (Windows)
```

Consumed at:

```
https://raw.githubusercontent.com/pungggi/remote_pi/downloads/app/latest.json
https://raw.githubusercontent.com/pungggi/remote_pi/downloads/cockpit/latest.json
https://raw.githubusercontent.com/pungggi/remote_pi/downloads/cockpit/appcast-windows.xml
```

## Publishing (the manual gate)

Building a release does **not** ship it. CI attaches `latest.json` (and the
appcast, for Cockpit) to the GitHub Release; users only start seeing the update
once the file lands here. That gap is deliberate — it is the last chance to
hold back a bad build.

```bash
gh release download app-v1.2.3 --pattern latest.json --dir /tmp
git checkout downloads
cp /tmp/latest.json app/latest.json
git commit -am "publish app 1.2.3" && git push origin downloads
```

Same for `cockpit-v*`, into `cockpit/`, together with `appcast-windows.xml`.

## A missing file is safe

Both clients treat any failure — 404, timeout, malformed JSON, wrong schema —
as "no update available" and stay silent. An absent manifest degrades to
nothing happening, never to an error in the user's face. That is why this
branch starts out holding no manifests at all: there is no published release
yet to announce.

## Never put anything else here

No signing keys, no build artifacts, no source. This branch is world-readable
and its contents are fetched automatically by every installed client.
