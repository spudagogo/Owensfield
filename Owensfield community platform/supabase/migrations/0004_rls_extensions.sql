-- Owensfield Community Platform - RLS extensions for added governance tables

begin;

-- Ensure new tables have RLS enabled
alter table ow.poll_results enable row level security;
alter table ow.governance_overrides enable row level security;
alter table ow.elections enable row level security;
alter table ow.election_nominations enable row level security;
alter table ow.election_results enable row level security;

-- Poll results: active members can read once poll is closed/archived; RG can read anytime.
drop policy if exists poll_results_select_active on ow.poll_results;
create policy poll_results_select_active
on ow.poll_results for select
using (
  ow.is_active_member(auth.uid())
  and exists (
    select 1 from ow.polls p
    where p.id = poll_id
      and p.state in ('closed'::ow.lifecycle_state, 'archived'::ow.lifecycle_state)
  )
);

drop policy if exists poll_results_select_rg on ow.poll_results;
create policy poll_results_select_rg
on ow.poll_results for select
using (ow.has_any_rg_role(auth.uid()));

-- Governance overrides: RG can read; only chair/vice in temporary mode can insert.
drop policy if exists governance_overrides_select_rg on ow.governance_overrides;
create policy governance_overrides_select_rg
on ow.governance_overrides for select
using (ow.has_any_rg_role(auth.uid()));

drop policy if exists governance_overrides_insert_temp_authority on ow.governance_overrides;
create policy governance_overrides_insert_temp_authority
on ow.governance_overrides for insert
with check (
  actor_id = auth.uid()
  and ow.has_temporary_authority(auth.uid())
);

-- Documents: allow RG updates; trigger enforces 4-approval requirement for archived docs.
drop policy if exists documents_update_rg on ow.documents;
create policy documents_update_rg
on ow.documents for update
using (ow.has_any_rg_role(auth.uid()))
with check (ow.has_any_rg_role(auth.uid()));

-- Elections:
-- - Active members can view elections and nominations (for participation)
-- - Active members can nominate during nominating phase
-- - RG members can create/close elections and set results (enactment handled elsewhere)

drop policy if exists elections_select_active on ow.elections;
create policy elections_select_active
on ow.elections for select
using (ow.is_active_member(auth.uid()));

drop policy if exists elections_insert_rg on ow.elections;
create policy elections_insert_rg
on ow.elections for insert
with check (ow.has_any_rg_role(auth.uid()) and created_by = auth.uid());

drop policy if exists elections_update_rg on ow.elections;
create policy elections_update_rg
on ow.elections for update
using (ow.has_any_rg_role(auth.uid()))
with check (ow.has_any_rg_role(auth.uid()));

drop policy if exists election_nominations_select_active on ow.election_nominations;
create policy election_nominations_select_active
on ow.election_nominations for select
using (ow.is_active_member(auth.uid()));

drop policy if exists election_nominations_insert_active on ow.election_nominations;
create policy election_nominations_insert_active
on ow.election_nominations for insert
with check (
  ow.is_active_member(auth.uid())
  and nominated_by = auth.uid()
  and exists (
    select 1 from ow.elections e
    where e.id = election_id
      and e.state = 'nominating'::ow.election_state
      and now() >= e.nomination_opens_at
      and now() <= e.nomination_closes_at
  )
);

drop policy if exists election_results_select_active on ow.election_results;
create policy election_results_select_active
on ow.election_results for select
using (ow.is_active_member(auth.uid()));

drop policy if exists election_results_write_rg on ow.election_results;
create policy election_results_write_rg
on ow.election_results for insert
with check (ow.has_any_rg_role(auth.uid()));

drop policy if exists election_results_update_rg on ow.election_results;
create policy election_results_update_rg
on ow.election_results for update
using (ow.has_any_rg_role(auth.uid()))
with check (ow.has_any_rg_role(auth.uid()));

commit;

