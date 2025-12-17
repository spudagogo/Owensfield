import type { NextRequest } from "next/server";
import { NextResponse } from "next/server";

/**
 * Middleware scaffolding (NO auth wired yet).
 *
 * This file exists so we have a single place to enforce:
 * - Inactive member lockout (Profile + Renewal only)
 * - Role-based access only (no implicit admin powers)
 * - RG area restrictions
 *
 * Once Supabase Auth is connected, this middleware should:
 * - read the session/user
 * - load member status + roles
 * - decide allow/redirect based on explicit rules
 */
export function middleware(_req: NextRequest) {
  void _req;
  return NextResponse.next();
}

export const config = {
  matcher: [
    /*
     * Keep broad for now; actual gating happens once auth exists.
     * Excludes Next internals and static assets.
     */
    "/((?!_next|.*\\..*).*)",
  ],
};

