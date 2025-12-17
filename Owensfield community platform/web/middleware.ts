import type { NextRequest } from "next/server";
import { NextResponse } from "next/server";
import { createServerClient } from "@supabase/ssr";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { areaFromPath, PUBLIC_PATH_PREFIXES } from "@/lib/routing/areas";
import { canAccessArea } from "@/lib/rbac";
import { parseRgRoles, viewerFromSupabaseUser } from "@/lib/auth/viewer";

/**
 * Middleware (minimal auth wiring).
 *
 * Enforces:
 * - logged-out users -> /login (except public areas)
 * - inactive members -> Profile + Renewal only
 * - RG access -> only if explicit RG roles exist (no implicit admin)
 */
export async function middleware(req: NextRequest) {
  const { isConfigured, url, anonKey } = getSupabaseEnv();
  if (!isConfigured) return NextResponse.next();

  const { pathname } = req.nextUrl;

  // Allow public access to login/profile/renewal (spec: inactive members must still access profile + renewal).
  if (PUBLIC_PATH_PREFIXES.some((p) => pathname === p || pathname.startsWith(`${p}/`))) {
    return NextResponse.next();
  }

  const res = NextResponse.next();
  const supabase = createServerClient(url!, anonKey!, {
    cookies: {
      getAll() {
        return req.cookies.getAll();
      },
      setAll(cookiesToSet) {
        cookiesToSet.forEach(({ name, value, options }) => {
          res.cookies.set(name, value, options);
        });
      },
    },
  });

  const { data, error } = await supabase.auth.getUser();
  if (error || !data.user) {
    const loginUrl = req.nextUrl.clone();
    loginUrl.pathname = "/login";
    return NextResponse.redirect(loginUrl);
  }

  // Prefer DB-trusted viewer context (RLS-backed) when available.
  // If RPC fails (e.g. migrations not applied yet), fall back to JWT app_metadata.
  const rpc = await supabase.rpc("viewer_context");
  const viewer = rpc.error || !rpc.data
    ? viewerFromSupabaseUser(data.user)
    : {
        userId: String(rpc.data.user_id),
        memberStatus:
          rpc.data.member_status === "active" || rpc.data.member_status === "inactive"
            ? rpc.data.member_status
            : "inactive",
        rgRoles: parseRgRoles(rpc.data.rg_roles),
      };
  const hasElectedRgRole =
    !rpc.error && rpc.data ? Boolean((rpc.data as { has_elected_rg_role?: unknown }).has_elected_rg_role) : false;
  const area = areaFromPath(pathname);

  // Home is always accessible once logged in.
  if (!area) return res;

  if (!canAccessArea({ area, memberStatus: viewer.memberStatus, rgRoles: viewer.rgRoles })) {
    // Inactive members are redirected to renewal; others are sent home.
    const target = req.nextUrl.clone();
    target.pathname = viewer.memberStatus === "inactive" ? "/renewal" : "/";
    return NextResponse.redirect(target);
  }

  // Extra guard: membership database is elected-RG only (Chair/Vice/Secretary/Treasurer).
  if (pathname === "/rg/membership-database" || pathname.startsWith("/rg/membership-database/")) {
    if (!hasElectedRgRole) {
      const target = req.nextUrl.clone();
      target.pathname = "/";
      return NextResponse.redirect(target);
    }
  }

  return res;
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

