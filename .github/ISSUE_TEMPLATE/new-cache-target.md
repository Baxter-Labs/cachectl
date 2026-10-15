---
name: New cache target
about: A tool leaves a big cache that cachectl doesn't know about
title: 'Add target: '
labels: new-target
---

**Tool**

<!-- e.g. Bazel, Nix, Unity -->

**Path on disk**

<!-- Say which OS. e.g. macOS: ~/Library/Caches/whatever · Linux: ~/.cache/whatever · Windows: %LOCALAPPDATA%\whatever -->

**How big is it on your machine?**

```
du -sh <path>          # macOS / Linux
cachectl top           # any OS: lists the biggest entries in your cache folder
```

**What happens if it's deleted?**

<!-- Rebuilt silently? Needs a re-download? Needs the user to re-run something? -->

**Does the tool have its own cleanup command?**

<!-- e.g. `bazel clean --expunge`. If so we should call that instead of rm. -->

**Suggested risk tier**

- [ ] safe — regenerates on its own
- [ ] review — safe to lose but expensive to rebuild
- [ ] risky — could destroy something unrecoverable
