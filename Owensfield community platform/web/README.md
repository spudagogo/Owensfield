## Owensfield web app

This folder is the Next.js (App Router) web application.

For the overall project structure and the locked product rules, see the repository root `README.md`.

### What’s in here

- `app/`: placeholder routes for each spec module (no feature UI yet)
- `components/`: minimal placeholders (`AppShell`, `AppNav`, etc.)
- `lib/rbac.ts`: RBAC helpers (types + allow/deny helpers; **no auth wiring**)
- `middleware.ts`: middleware scaffold for gating once auth exists (currently no-op)

### Run locally

```bash
npm install
npm run dev
```
