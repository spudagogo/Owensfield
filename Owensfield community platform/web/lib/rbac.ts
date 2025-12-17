/**
 * RBAC scaffolding (no auth wiring yet).
 *
 * Global spec constraints:
 * - No implicit admin powers: every action must be explicitly permitted by role.
 * - Inactive members can access ONLY Profile + Renewal/Reactivate.
 * - No discussion functionality (not modeled here).
 */

export type MemberStatus = "active" | "inactive";

export type RgRole =
  | "chair"
  | "vice_chair"
  | "treasurer"
  | "secretary"
  | "rg_member";

export type AppRole =
  | "member_active"
  | "member_inactive"
  | "rg_member"
  | "rg_elected_chair"
  | "rg_elected_vice_chair"
  | "rg_elected_treasurer"
  | "rg_elected_secretary";

export type AppArea =
  | "profile"
  | "renewal"
  | "documents"
  | "polls"
  | "meetings"
  | "actions"
  | "communications"
  | "finance"
  | "governance"
  | "notices"
  | "settings"
  | "rg";

export const INACTIVE_ALLOWED_AREAS: ReadonlySet<AppArea> = new Set([
  "profile",
  "renewal",
]);

export function canInactiveMemberAccess(area: AppArea): boolean {
  return INACTIVE_ALLOWED_AREAS.has(area);
}

export function isElectedRgRole(role: RgRole): boolean {
  return (
    role === "chair" ||
    role === "vice_chair" ||
    role === "treasurer" ||
    role === "secretary"
  );
}

/**
 * Very small "area access" helper.
 * This is intentionally conservative: if we don't know, deny.
 */
export function canAccessArea(input: {
  area: AppArea;
  memberStatus: MemberStatus;
  rgRoles?: ReadonlyArray<RgRole>;
}): boolean {
  if (input.memberStatus === "inactive") {
    return canInactiveMemberAccess(input.area);
  }

  if (input.area === "rg") {
    return (input.rgRoles ?? []).length > 0;
  }

  // Active members can access member areas (spec: documents/polls/meetings/etc.)
  return true;
}

