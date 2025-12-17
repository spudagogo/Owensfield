## Owensfield Community Platform

This repository contains the starting structure for the **Owensfield Community Platform**.

The product requirements are **locked** by the provided “Cursor Master Build Prompt” (authoritative). In particular:

- **No discussion functionality**: no comments, replies, chat, forums, or debate threads.
- **Archive, never delete**: governance data must move through states and become read-only when archived.
- **Role-based access only**: every action must be explicitly permitted by role.
- **Inactive members**: can access **only** Profile + Renewal/Reactivate (no access to the rest of the app).

### Proposed v1 stack (simple, modern, scalable)

- **Web**: Next.js (App Router) + TypeScript
- **UI**: Tailwind CSS (minimal usage for structure only right now)
- **Backend**: Supabase (Auth + Postgres + Storage) — **not connected yet**
- **Security model**: Supabase Row Level Security (RLS) + explicit role permissions (no implicit admin)
- **Auditability**: append-only audit/event tables (to meet “approvals must be auditable” and “archive-only” rules)

### Project layout

The app lives here:

- `Owensfield community platform/web/`: Next.js application (App Router)
  - `app/`: route pages and layouts
  - `components/`: placeholder components used by routes
  - `lib/`: RBAC + spec helpers (no auth wiring yet)
  - `middleware.ts`: permission middleware scaffold (currently no-op until auth is connected)

The (offline) database schema scaffolding lives here:

- `Owensfield community platform/supabase/migrations/`: SQL migrations for Supabase Postgres
  - `0001_init.sql`: initial “archive-only + auditable approvals” schema foundation

Key placeholder routes (no auth/logic yet):

- `app/profile`: Profile
- `app/renewal`: Renewal / Reactivation
- `app/archives`: Read-only archives entry point
- `app/documents`: Documents archive
- `app/polls`: Polls lifecycle (Draft → Pending → Active → Closed → Archived)
- `app/meetings`: Meetings / agenda / minutes placeholders
- `app/actions`: Actions placeholders
- `app/communications`: Official communications record placeholders
- `app/finance`: Reporting placeholders
- `app/governance`: Governance dashboard placeholder
- `app/rg/*`: RG area placeholders (membership database, pending approvals, etc.)

### What is intentionally NOT implemented yet

- **No Supabase connection**
- **No auth wiring (so no enforcement yet in the running app)**
- **No Supabase project configured/applied migrations yet** (schema files exist, but nothing is connected)
- **No workflows / approvals / voting math**
- **No UI polish**

### Local development

From `Owensfield community platform/web/`:

```bash
npm install
npm run dev
```

### Supabase Auth (now wired, still minimal)

- The Next.js app includes middleware that (when Supabase env vars are set):
  - redirects logged-out users to `/login`
  - restricts **inactive** members to **Profile + Renewal** only
  - restricts **RG** areas unless explicit RG roles are present
- This is **scaffold-level**: no login UI flow is implemented yet, and Supabase is not provisioned in this repo.
