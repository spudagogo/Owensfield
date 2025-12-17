import { PlaceholderPage } from "@/components/PlaceholderPage";

export default function Home() {
  return (
    <main className="bg-background text-foreground font-sans">
      <div className="[&_h1]:font-serif [&_h1]:bg-primary [&_h1]:text-primary-fg [&_h1]:inline-block [&_h1]:px-3 [&_h1]:py-2">
        <PlaceholderPage
          title="Owensfield Community Platform"
          note="This project follows the locked Owensfield spec (no discussion features; archive-only governance records; role-based access; inactive members restricted to Profile + Renewal)."
        />
      </div>
    </main>
  );
}
