import type { User } from "@supabase/supabase-js";
import type { MemberStatus, RgRole } from "@/lib/rbac";

/**
 * Authoritative identity should come from server-trusted sources.
 * For now, we read from Supabase JWT `app_metadata` (server-controlled).
 *
 * Expected keys (can be set later via admin tooling / seed scripts):
 * - app_metadata.ow_member_status: "active" | "inactive"
 * - app_metadata.ow_rg_roles: string[] of RgRole
 */

export type Viewer = {
  userId: string;
  memberStatus: MemberStatus;
  rgRoles: RgRole[];
};

export function isRgRole(value: unknown): value is RgRole {
  return (
    value === "chair" ||
    value === "vice_chair" ||
    value === "treasurer" ||
    value === "secretary" ||
    value === "rg_member"
  );
}

export function parseRgRoles(value: unknown): RgRole[] {
  return Array.isArray(value) ? value.filter(isRgRole) : [];
}

export function viewerFromSupabaseUser(user: User): Viewer {
  const appMetadata = (user.app_metadata ?? {}) as Record<string, unknown>;

  const rawStatus = appMetadata["ow_member_status"];
  const memberStatus: MemberStatus =
    rawStatus === "active" || rawStatus === "inactive" ? rawStatus : "inactive";

  const rawRgRoles = appMetadata["ow_rg_roles"];
  const rgRoles = parseRgRoles(rawRgRoles);

  return { userId: user.id, memberStatus, rgRoles };
}

