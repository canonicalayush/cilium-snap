# Findings Directory (docs/findings/)

## Overview
Individual investigation write-ups, one file per finding, referenced
from ../findings.md. These are agent-summarised research documents,
written by an AI coding assistant tracing through this repo and
upstream Cilium source, not independently verified line by line by a
human reviewer.

## Conventions
- One self-contained finding per file, grounded in repo and upstream
  source, with file and line references a reader can check directly.
- Add new findings here, then add a one-line summary and a link to
  ../findings.md. Never inline a finding's content into that index.
- Mark significant claims that are inference rather than directly
  observed fact, especially in any "open gaps" or "recommendations"
  section.
- Start every finding with a provenance note, the same blockquote style
  as crd-replacement.md: state it is an agent-generated research
  summary and that claims should be checked against the cited source.

## Writing style
Match crd-replacement.md. Every finding file must follow this style:
- Concise. Cut repetition and filler. Say a thing once.
- No em dashes. Use a period, comma, or colon instead.
- Light backtick use. Reserve backticks for real commands, flags, file
  paths, and file:line references. Do not wrap ordinary words, CRD
  names, or component names in backticks just because they are
  technical terms.
- Plain prose over heavy bold/italic emphasis. Use bold sparingly, for
  example table cells like Yes/No.
- Short paragraphs and short sentences. Prefer a numbered or bulleted
  list over a dense paragraph when listing more than two items.
- Keep the evidence: file:line citations and a summary table (when the
  finding compares several items) are the point of a findings doc.
  Trim prose around them, not the citations themselves.

## Key Files
- crd-replacement.md: which of upstream Cilium's Kubernetes CRDs this
  snap's standalone packaging replaces, avoids, or still has no
  mechanism for.
