# CLAUDE.md — internet-sehat

## Use CONTEXT.md first
**[CONTEXT.md](./CONTEXT.md) is the source of truth.** To save tokens, look up there before scanning files:
1. Open CONTEXT.md → **§Feature Index** to map task → exact file.
2. Read only that file.
3. Explore further only if CONTEXT.md lacks detail.

Code wins over CONTEXT.md on conflict → then update it. On adding files/features, update CONTEXT.md's Directory Map + Feature Index.

## Rules
- **Dashboard (Next.js 16):** read `dashboard/node_modules/next/dist/docs/` before coding — NJS16 breaks vs training data (see CONTEXT.md §Dashboard).
- Comments/CLI output/UI in Indonesian.
- `installer/*` must be POSIX sh (Alpine/busybox), no bashisms.
- Don't read artifacts: `*.iso`, `*.zip`, `*.cdb`, `node_modules/`, `.next/`.
