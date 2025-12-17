import { createServerClient } from "@supabase/ssr";
import { createClient } from "@supabase/supabase-js";
import type { NextRequest } from "next/server";
import { NextResponse } from "next/server";

import { getSupabaseEnv } from "@/lib/supabase/env";

type Body = {
  userId: string;
};

export async function POST(req: NextRequest) {
  const { isConfigured, url, anonKey } = getSupabaseEnv();
  if (!isConfigured) {
    return NextResponse.json({ error: "Supabase is not configured." }, { status: 500 });
  }

  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!serviceKey) {
    return NextResponse.json(
      { error: "Server is missing SUPABASE_SERVICE_ROLE_KEY." },
      { status: 501 },
    );
  }

  let body: Body;
  try {
    body = (await req.json()) as Body;
  } catch {
    return NextResponse.json({ error: "Invalid JSON body." }, { status: 400 });
  }

  if (!body.userId) {
    return NextResponse.json({ error: "Missing userId." }, { status: 400 });
  }

  // Session-bound client (enforces elected-RG permission via DB RPC).
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

  const viewer = await supabase.rpc("viewer_context");
  if (viewer.error || !viewer.data) {
    return NextResponse.json({ error: "Unable to load viewer context." }, { status: 403 });
  }
  if (!viewer.data.has_elected_rg_role) {
    return NextResponse.json({ error: "Elected RG role required." }, { status: 403 });
  }

  const admin = createClient(url!, serviceKey, {
    auth: { persistSession: false },
  });

  const userRes = await admin.auth.admin.getUserById(body.userId);
  if (userRes.error || !userRes.data.user?.email) {
    return NextResponse.json({ error: "Target user not found or has no email." }, { status: 404 });
  }

  const linkRes = await admin.auth.admin.generateLink({
    type: "recovery",
    email: userRes.data.user.email,
  });

  if (linkRes.error) {
    return NextResponse.json({ error: linkRes.error.message }, { status: 500 });
  }

  // Audit (DB-side; elected-only).
  await supabase.rpc("log_audit_event", {
    p_action: "password_reset_generated",
    p_entity_type: "profile",
    p_entity_id: body.userId,
    p_after: { method: "recovery_link" },
  });

  return NextResponse.json(
    {
      recoveryLink: linkRes.data.properties?.action_link ?? null,
      email: userRes.data.user.email,
    },
    { status: 200 },
  );
}

