# Docs Directory (docs/)

## Overview
Project documentation: architecture, setup, configuration and testing
guides, an architecture diagram, and the findings index with its
per-investigation write-ups in findings/.

## Key Files & Directories
- architecture.md: build-time and runtime architecture, snap parts,
  apps, lifecycle hooks, and the agent startup sequence.
- cilium-snap-architecture.svg: diagram embedded in architecture.md.
- cilium-snap-architecture.excalidraw: editable source for the diagram,
  open at excalidraw.com.
- setup.md: build and install walkthrough.
- configuration.md: full `snap set` key reference and the multi-agent
  setup recipe.
- testing.md: smoke test suite usage, structure, and CI workflows.
- findings.md: index of agent-summarised investigation write-ups kept
  in findings/. Add new findings there and list them here, don't inline
  them.
- findings/: individual findings documents referenced from findings.md.
