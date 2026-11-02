# unlose-app

Build runner and website for **Photos Recovery** (`com.unlose.app`), a photo and file recovery app for Android.

This repository holds workflows and the public website only. A build run checks out the private
app repository with a read-only deploy key, analyses and tests it, builds the signed release APKs
and the Play bundle, drives the app on an Android emulator seeded with "deleted" files, and uploads
everything it made as **one sealed file** (AES-256, key held by the owner). No source, build or log
leaves the runner readable.

```sh
gh workflow run build.yml -R Mulhimfy/unlose-app -f ref=main -f smoke=true
```

Website (GitHub Pages, `docs/`): https://mulhimfy.github.io/unlose-app/ (privacy policy: `privacy.html`).
