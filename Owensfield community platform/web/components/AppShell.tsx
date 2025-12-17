import type { PropsWithChildren } from "react";
import { AppNav } from "@/components/AppNav";

export function AppShell({ children }: PropsWithChildren) {
  return (
    <div>
      <header>
        <div>
          <strong>Owensfield</strong>
        </div>
        <AppNav />
      </header>
      <main>{children}</main>
    </div>
  );
}

