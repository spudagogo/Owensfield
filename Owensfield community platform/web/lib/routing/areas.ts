import type { AppArea } from "@/lib/rbac";

export const PUBLIC_PATH_PREFIXES: ReadonlyArray<string> = [
  "/login",
];

export function areaFromPath(pathname: string): AppArea | null {
  if (pathname === "/" || pathname === "") return null;

  const first = pathname.split("/").filter(Boolean)[0];
  if (!first) return null;

  switch (first) {
    case "profile":
      return "profile";
    case "renewal":
      return "renewal";
    case "documents":
      return "documents";
    case "polls":
      return "polls";
    case "meetings":
      return "meetings";
    case "actions":
      return "actions";
    case "communications":
      return "communications";
    case "finance":
      return "finance";
    case "governance":
      return "governance";
    case "notices":
      return "notices";
    case "settings":
      return "settings";
    case "rg":
      return "rg";
    default:
      return null;
  }
}

