import { createBrowserClient } from "@supabase/ssr";
import { getSupabaseEnv } from "@/lib/supabase/env";

export function createSupabaseBrowserClient() {
  const { url, anonKey, isConfigured } = getSupabaseEnv();
  if (!isConfigured) return null;
  return createBrowserClient(url!, anonKey!);
}

