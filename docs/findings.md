# Findings

Index of investigation write-ups kept in findings/, one file per finding.

These are agent-summarised findings: an AI coding assistant wrote them
after reading this repo and upstream Cilium source. Treat them as a
useful starting point, not a substitute for review. Verify a claim
against the cited source before relying on it, especially anything
flagged as a gap or recommendation.

Add a new finding under findings/ and list it below. Do not inline
findings into this file.

## Index

- [How cilium-snap replaces Cilium's Kubernetes CRDs](findings/crd-replacement.md).
  Which of upstream Cilium's 25 CRDs this snap's standalone packaging
  replaces, which it avoids needing, and which gaps remain. Notably: no
  network policy or load-balancer state delivery mechanism is wired up
  yet.
