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

### Supabase Auth wiring (scaffold)

Set these env vars (see `.env.example`):

- `NEXT_PUBLIC_SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_ANON_KEY`

Notes:

- Middleware will redirect unauthenticated users to `/login`.
- Member status and RG roles are currently read from Supabase JWT `app_metadata`:
  - `ow_member_status`: `"active"` or `"inactive"` (defaults to `"inactive"` if missing)
  - `ow_rg_roles`: array of role strings (defaults to empty)
