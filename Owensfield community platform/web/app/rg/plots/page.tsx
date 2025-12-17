import { createClient } from "@supabase/supabase-js";
import { redirect } from "next/navigation";

import { PlaceholderPage } from "@/components/PlaceholderPage";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { getSupabaseEnv } from "@/lib/supabase/env";

type RegistryRow = {
  plot_id: string;
  plot_code: string;
  label: string | null;
  notes: string | null;
  is_registered: boolean;
  plot_group_id: string | null;
  group_plot_count: number;
  computed_voting_value: number;
  owners: Array<{ profile_id: string; name: string | null; member_status: "active" | "inactive" }>;
  tenants: Array<{ profile_id: string; name: string | null; member_status: "active" | "inactive" }>;
  updated_at: string;
};

type PageProps = { searchParams?: Record<string, string | string[] | undefined> };

export default async function PlotRegistryPage(props: PageProps) {
  const supabase = await createSupabaseServerClient();
  if (!supabase) {
    return (
      <PlaceholderPage
        title="RG Admin: Plot Registry"
        note="Supabase is not configured. Set env vars to use Plot Registry."
      />
    );
  }

  const searchParams = props.searchParams ?? {};
  const message = typeof searchParams.message === "string" ? searchParams.message : null;
  const error = typeof searchParams.error === "string" ? searchParams.error : null;

  const { data, error: listError } = await supabase.rpc("plot_registry");
  if (listError) {
    return (
      <PlaceholderPage
        title="RG Admin: Plot Registry"
        note={`Unable to load registry: ${listError.message}`}
      />
    );
  }

  const rows = (data ?? []) as unknown as RegistryRow[];

  const { data: groupsData } = await supabase.rpc("plot_group_summary");
  const plotGroups =
    (groupsData ?? []) as Array<{ plot_group_id: string; plot_count: number; voting_value: number }>;

  async function addPlot(formData: FormData) {
    "use server";
    const supabase = await createSupabaseServerClient();
    if (!supabase) return;

    const plotCode = String(formData.get("plot_code") ?? "").trim();
    const label = String(formData.get("label") ?? "").trim();
    const notes = String(formData.get("notes") ?? "").trim();

    const res = await supabase.rpc("create_plot", {
      p_plot_code: plotCode,
      p_label: label || null,
      p_notes: notes || null,
    });

    if (res.error) {
      return redirectWithError(res.error.message);
    }
    return redirectWithMessage("Plot created.");
  }

  async function updatePlot(formData: FormData) {
    "use server";
    const supabase = await createSupabaseServerClient();
    if (!supabase) return;

    const plotId = String(formData.get("plot_id") ?? "");
    const label = String(formData.get("label") ?? "").trim();
    const notes = String(formData.get("notes") ?? "").trim();

    const res = await supabase.rpc("update_plot_metadata", {
      p_plot_id: plotId,
      p_label: label || null,
      p_notes: notes || null,
    });

    if (res.error) return redirectWithError(res.error.message);
    return redirectWithMessage("Plot updated.");
  }

  async function addOwner(formData: FormData) {
    "use server";
    const supabase = await createSupabaseServerClient();
    if (!supabase) return;

    const plotId = String(formData.get("plot_id") ?? "");
    const ownerProfileId = String(formData.get("owner_profile_id") ?? "");
    const confirmed = String(formData.get("confirm") ?? "") === "on";
    if (!confirmed) return redirectWithError("Confirmation is required.");

    const res = await supabase.rpc("add_plot_owner", {
      p_plot_id: plotId,
      p_owner_profile_id: ownerProfileId,
      p_note: null,
    });

    if (res.error) return redirectWithError(res.error.message);
    return redirectWithMessage("Owner assigned.");
  }

  async function changeOwner(formData: FormData) {
    "use server";
    const supabase = await createSupabaseServerClient();
    if (!supabase) return;

    const plotId = String(formData.get("plot_id") ?? "");
    const oldOwnerId = String(formData.get("old_owner_profile_id") ?? "");
    const newOwnerId = String(formData.get("new_owner_profile_id") ?? "");
    const confirmed = String(formData.get("confirm") ?? "") === "on";
    if (!confirmed) return redirectWithError("Confirmation is required.");

    const res = await supabase.rpc("reassign_plot_owner", {
      p_plot_id: plotId,
      p_old_owner_id: oldOwnerId,
      p_new_owner_id: newOwnerId,
      p_reason: "plot_owner_reassigned",
    });

    if (res.error) return redirectWithError(res.error.message);
    return redirectWithMessage("Owner changed.");
  }

  async function joinPlots(formData: FormData) {
    "use server";
    const supabase = await createSupabaseServerClient();
    if (!supabase) return;

    const plotCodeA = String(formData.get("plot_code_a") ?? "").trim();
    const plotCodeB = String(formData.get("plot_code_b") ?? "").trim();
    const confirmed = String(formData.get("confirm") ?? "") === "on";
    if (!confirmed) return redirectWithError("Confirmation is required.");

    const a = await supabase
      .schema("ow")
      .from("plots")
      .select("id")
      .eq("plot_code", plotCodeA)
      .maybeSingle();
    if (a.error || !a.data?.id) return redirectWithError("Plot A not found.");

    const b = await supabase
      .schema("ow")
      .from("plots")
      .select("id")
      .eq("plot_code", plotCodeB)
      .maybeSingle();
    if (b.error || !b.data?.id) return redirectWithError("Plot B not found.");

    // UPDATED Join Plots: create a plot group explicitly, then add 2 plots to it.
    const groupRes = await supabase.rpc("create_plot_group", { p_note: null });
    if (groupRes.error || !groupRes.data) {
      return redirectWithError(groupRes.error?.message ?? "Unable to create plot group.");
    }

    const addA = await supabase.rpc("add_plot_to_group", {
      p_plot_id: a.data.id,
      p_plot_group_id: groupRes.data,
      p_note: null,
    });
    if (addA.error) return redirectWithError(addA.error.message);

    const addB = await supabase.rpc("add_plot_to_group", {
      p_plot_id: b.data.id,
      p_plot_group_id: groupRes.data,
      p_note: null,
    });
    if (addB.error) return redirectWithError(addB.error.message);

    return redirectWithMessage(`Plots grouped: ${groupRes.data}`);
  }

  async function addPlotToGroup(formData: FormData) {
    "use server";
    const supabase = await createSupabaseServerClient();
    if (!supabase) return;

    const plotCode = String(formData.get("plot_code") ?? "").trim();
    const groupId = String(formData.get("plot_group_id") ?? "").trim();
    const confirmed = String(formData.get("confirm") ?? "") === "on";
    if (!confirmed) return redirectWithError("Confirmation is required.");

    const plot = await supabase
      .schema("ow")
      .from("plots")
      .select("id")
      .eq("plot_code", plotCode)
      .maybeSingle();
    if (plot.error || !plot.data?.id) return redirectWithError("Plot not found.");

    const res = await supabase.rpc("add_plot_to_group", {
      p_plot_id: plot.data.id,
      p_plot_group_id: groupId,
      p_note: null,
    });
    if (res.error) return redirectWithError(res.error.message);
    return redirectWithMessage("Plot added to group.");
  }

  async function createUser(formData: FormData) {
    "use server";

    const { isConfigured, url } = getSupabaseEnv();
    const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!isConfigured || !url) return redirectWithError("Supabase is not configured.");
    if (!serviceKey) return redirectWithError("Server is missing SUPABASE_SERVICE_ROLE_KEY.");

    const supabase = await createSupabaseServerClient();
    if (!supabase) return redirectWithError("Supabase server client unavailable.");

    const viewer = await supabase.rpc("viewer_context");
    if (viewer.error || !viewer.data?.has_elected_rg_role) {
      return redirectWithError("Elected RG role required.");
    }

    const email = String(formData.get("email") ?? "").trim();
    const displayName = String(formData.get("display_name") ?? "").trim();
    const confirmed = String(formData.get("confirm") ?? "") === "on";
    if (!confirmed) return redirectWithError("Confirmation is required.");
    if (!email) return redirectWithError("Email is required.");

    const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
    const created = await admin.auth.admin.createUser({
      email,
      email_confirm: true,
      user_metadata: { display_name: displayName || null },
    });
    if (created.error || !created.data.user) {
      return redirectWithError(created.error?.message ?? "Unable to create user.");
    }

    await supabase.rpc("log_audit_event", {
      p_action: "plot_registry_user_created",
      p_entity_type: "profile",
      p_entity_id: created.data.user.id,
      p_after: { email, display_name: displayName || null },
    });

    return redirectWithMessage(`User created: ${created.data.user.id}`);
  }

  return (
    <section>
      <h1>RG Admin: Plot Registry</h1>
      <p>This admin screen is for RG elected-role members only.</p>

      {message ? <p><strong>{message}</strong></p> : null}
      {error ? <p><strong>Error:</strong> {error}</p> : null}

      <h2>Add Plot</h2>
      <form action={addPlot}>
        <div>
          <label>
            Plot ID (unique)
            <input name="plot_code" required />
          </label>
        </div>
        <div>
          <label>
            Address / Label
            <input name="label" />
          </label>
        </div>
        <div>
          <label>
            Notes
            <input name="notes" />
          </label>
        </div>
        <button type="submit">Add Plot</button>
      </form>

      <h2>Create Owner/User (deliberate)</h2>
      <form action={createUser}>
        <div>
          <label>
            Email
            <input name="email" type="email" required />
          </label>
        </div>
        <div>
          <label>
            Display name
            <input name="display_name" />
          </label>
        </div>
        <label>
          <input name="confirm" type="checkbox" required /> Confirm create user
        </label>
        <button type="submit">Create User</button>
      </form>

      <h2>Plot List</h2>
      <table>
        <thead>
          <tr>
            <th>Plot ID</th>
            <th>Address / Label</th>
            <th>Status</th>
            <th>Joined group</th>
            <th>Owners</th>
            <th>Tenants</th>
            <th>Computed voting weight</th>
            <th>Last updated</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.plot_id}>
              <td>{r.plot_code}</td>
              <td>
                <form action={updatePlot}>
                  <input type="hidden" name="plot_id" value={r.plot_id} />
                  <div>
                    <input name="label" defaultValue={r.label ?? ""} />
                  </div>
                  <div>
                    <input name="notes" defaultValue={r.notes ?? ""} placeholder="Notes" />
                  </div>
                  <button type="submit">Save</button>
                </form>
              </td>
              <td>{r.is_registered ? "registered" : "unregistered"}</td>
              <td>
                {r.plot_group_id && r.group_plot_count >= 2
                  ? `grouped (${r.plot_group_id})`
                  : "—"}
              </td>
              <td>
                <ul>
                  {r.owners.map((o) => (
                    <li key={o.profile_id}>
                      {o.name ?? o.profile_id} ({o.member_status})
                    </li>
                  ))}
                </ul>
              </td>
              <td>
                <ul>
                  {r.tenants.map((t) => (
                    <li key={t.profile_id}>
                      {t.name ?? t.profile_id} ({t.member_status})
                    </li>
                  ))}
                </ul>
              </td>
              <td>{r.computed_voting_value}</td>
              <td>{r.updated_at}</td>
              <td>
                <details>
                  <summary>Owners</summary>
                  <form action={addOwner}>
                    <input type="hidden" name="plot_id" value={r.plot_id} />
                    <label>
                      Owner profile ID
                      <input name="owner_profile_id" required />
                    </label>
                    <label>
                      <input name="confirm" type="checkbox" required /> Confirm assign owner
                    </label>
                    <button type="submit">Add Owner</button>
                  </form>
                  <hr />
                  <form action={changeOwner}>
                    <input type="hidden" name="plot_id" value={r.plot_id} />
                    <label>
                      Old owner profile ID
                      <input name="old_owner_profile_id" required />
                    </label>
                    <label>
                      New owner profile ID
                      <input name="new_owner_profile_id" required />
                    </label>
                    <label>
                      <input name="confirm" type="checkbox" required /> Confirm change owner
                    </label>
                    <button type="submit">Change Owner</button>
                  </form>
                </details>
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      <h2>Join Plots (exactly two)</h2>
      <form action={joinPlots}>
        <div>
          <label>
            Plot A (Plot ID)
            <input name="plot_code_a" required />
          </label>
        </div>
        <div>
          <label>
            Plot B (Plot ID)
            <input name="plot_code_b" required />
          </label>
        </div>
        <label>
          <input name="confirm" type="checkbox" required /> Confirm join plots
        </label>
        <button type="submit">Join Plots</button>
      </form>

      <h2>Plot Groups</h2>
      <p>Group voting value equals number of plots in the group.</p>
      <table>
        <thead>
          <tr>
            <th>Group identifier</th>
            <th>Number of plots in group</th>
            <th>Computed voting value</th>
          </tr>
        </thead>
        <tbody>
          {plotGroups.map((g) => (
            <tr key={g.plot_group_id}>
              <td>{g.plot_group_id}</td>
              <td>{g.plot_count}</td>
              <td>{g.voting_value}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <h3>Add plot to existing group (2+)</h3>
      <form action={addPlotToGroup}>
        <div>
          <label>
            Plot ID
            <input name="plot_code" required />
          </label>
        </div>
        <div>
          <label>
            Group identifier (UUID)
            <input name="plot_group_id" required />
          </label>
        </div>
        <label>
          <input name="confirm" type="checkbox" required /> Confirm add plot to group
        </label>
        <button type="submit">Add to Group</button>
      </form>
    </section>
  );
}

function redirectWithMessage(message: string): never {
  redirect(`/rg/plots?message=${encodeURIComponent(message)}`);
}

function redirectWithError(error: string): never {
  redirect(`/rg/plots?error=${encodeURIComponent(error)}`);
}

