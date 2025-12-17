import Link from "next/link";

const links: Array<{ href: string; label: string }> = [
  { href: "/", label: "Home" },
  { href: "/archives", label: "Archives" },
  { href: "/documents", label: "Documents" },
  { href: "/polls", label: "Polls" },
  { href: "/meetings", label: "Meetings" },
  { href: "/actions", label: "Actions" },
  { href: "/communications", label: "Communications" },
  { href: "/finance", label: "Finance" },
  { href: "/governance", label: "Governance" },
  { href: "/notices", label: "Notices" },
  { href: "/profile", label: "Profile" },
  { href: "/renewal", label: "Renewal" },
  { href: "/settings", label: "Settings" },
  { href: "/rg", label: "RG" },
];

export function AppNav() {
  return (
    <nav aria-label="Primary">
      <ul>
        {links.map((l) => (
          <li key={l.href}>
            <Link href={l.href}>{l.label}</Link>
          </li>
        ))}
      </ul>
    </nav>
  );
}

