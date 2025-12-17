-- Owensfield Community Platform - Security, RLS, lifecycle hardening
-- MUST conform to Master Specification v1.0 (Locked)

begin;

-- ------------------------------------------------------------
-- Hard-delete prevention + archive read-only helpers
-- ------------------------------------------------------------

create or replace function ow.prevent_update()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Updates are not allowed for %', tg_table_name;
end;
$$;

create or replace function ow.prevent_update_when_archived()
returns trigger
language plpgsql
as $$
begin
  -- If it was already archived (by timestamp) OR state was archived, it is read-only forever.
  if (old.archived_at is not null) then
    raise exception 'Archived rows are read-only for %', tg_table_name;
  end if;

  if (to_jsonb(old) ? 'state') then
    -- If table has state column and it was archived, it is read-only.
    if (old.state::text = 'archived') then
      raise exception 'Archived rows are read-only for %', tg_table_name;
    end if;
  end if;

  -- Prevent un-archiving by blocking archived_at removal.
  if (old.archived_at is not null and new.archived_at is null) then
    raise exception 'Un-archiving is not allowed for %', tg_table_name;
  end if;

  return new;
end;
$$;

-- ------------------------------------------------------------
-- Ensure profiles are also archive-only (no hard deletes)
-- ------------------------------------------------------------

alter table ow.profiles
  add column if not exists email text,
  add column if not exists archived_at timestamptz;

drop trigger if exists profiles_prevent_delete on ow.profiles;
create trigger profiles_prevent_delete
before delete on ow.profiles
for each row execute function ow.prevent_delete();

-- ------------------------------------------------------------
-- Audit log is append-only
-- ------------------------------------------------------------

drop trigger if exists audit_log_prevent_update on ow.audit_log;
create trigger audit_log_prevent_update
before update on ow.audit_log
for each row execute function ow.prevent_update();

-- ------------------------------------------------------------
-- State machine guards (strict lifecycle transitions)
-- ------------------------------------------------------------

create or replace function ow.enforce_lifecycle_transition()
returns trigger
language plpgsql
as $$
declare
  o text;
  n text;
begin
  if not (to_jsonb(old) ? 'state') then
    return new;
  end if;

  o := old.state::text;
  n := new.state::text;

  if o = n then
    return new;
  end if;

  -- Locked lifecycle: Draft → Pending → Active → Closed → Archived
  if o = 'draft' and n = 'pending' then return new; end if;
  if o = 'pending' and n = 'active' then return new; end if;
  if o = 'active' and n = 'closed' then return new; end if;
  if o = 'closed' and n = 'archived' then return new; end if;

  raise exception 'Invalid lifecycle transition: % -> % for %', o, n, tg_table_name;
end;
$$;

-- Attach lifecycle + archive read-only guards to key governance tables.
do $$
begin
  -- Polls
  if to_regclass('ow.polls') is not null then
    drop trigger if exists polls_enforce_transition on ow.polls;
    create trigger polls_enforce_transition
    before update on ow.polls
    for each row execute function ow.enforce_lifecycle_transition();

    drop trigger if exists polls_readonly_when_archived on ow.polls;
    create trigger polls_readonly_when_archived
    before update on ow.polls
    for each row execute function ow.prevent_update_when_archived();
  end if;

  -- Approvals
  if to_regclass('ow.approvals') is not null then
    drop trigger if exists approvals_readonly_when_archived on ow.approvals;
    create trigger approvals_readonly_when_archived
    before update on ow.approvals
    for each row execute function ow.prevent_update_when_archived();
  end if;

  -- Meetings + agenda + minutes
  if to_regclass('ow.meetings') is not null then
    drop trigger if exists meetings_readonly_when_archived on ow.meetings;
    create trigger meetings_readonly_when_archived
    before update on ow.meetings
    for each row execute function ow.prevent_update_when_archived();
  end if;

  if to_regclass('ow.meeting_agendas') is not null then
    drop trigger if exists meeting_agendas_enforce_transition on ow.meeting_agendas;
    create trigger meeting_agendas_enforce_transition
    before update on ow.meeting_agendas
    for each row execute function ow.enforce_lifecycle_transition();

    drop trigger if exists meeting_agendas_readonly_when_archived on ow.meeting_agendas;
    create trigger meeting_agendas_readonly_when_archived
    before update on ow.meeting_agendas
    for each row execute function ow.prevent_update_when_archived();
  end if;

  if to_regclass('ow.meeting_minutes') is not null then
    drop trigger if exists meeting_minutes_enforce_transition on ow.meeting_minutes;
    create trigger meeting_minutes_enforce_transition
    before update on ow.meeting_minutes
    for each row execute function ow.enforce_lifecycle_transition();

    drop trigger if exists meeting_minutes_readonly_when_archived on ow.meeting_minutes;
    create trigger meeting_minutes_readonly_when_archived
    before update on ow.meeting_minutes
    for each row execute function ow.prevent_update_when_archived();
  end if;

  if to_regclass('ow.actions') is not null then
    drop trigger if exists actions_readonly_when_archived on ow.actions;
    create trigger actions_readonly_when_archived
    before update on ow.actions
    for each row execute function ow.prevent_update_when_archived();
  end if;

  if to_regclass('ow.communication_threads') is not null then
    drop trigger if exists communication_threads_readonly_when_archived on ow.communication_threads;
    create trigger communication_threads_readonly_when_archived
    before update on ow.communication_threads
    for each row execute function ow.prevent_update_when_archived();
  end if;

  if to_regclass('ow.documents') is not null then
    drop trigger if exists documents_readonly_when_archived on ow.documents;
    create trigger documents_readonly_when_archived
    before update on ow.documents
    for each row execute function ow.prevent_update_when_archived();
  end if;
end $$;

-- ------------------------------------------------------------
-- Meeting draft agenda + draft minutes auto-generation
-- ------------------------------------------------------------

create or replace function ow.create_meeting_drafts()
returns trigger
language plpgsql
as $$
begin
  insert into ow.meeting_agendas (meeting_id, state, content)
  values (new.id, 'draft', '')
  on conflict (meeting_id) do nothing;

  insert into ow.meeting_minutes (meeting_id, state, content)
  values (new.id, 'draft', '')
  on conflict (meeting_id) do nothing;

  return new;
end;
$$;

drop trigger if exists meetings_create_drafts on ow.meetings;
create trigger meetings_create_drafts
after insert on ow.meetings
for each row execute function ow.create_meeting_drafts();

-- ------------------------------------------------------------
-- Community agenda submissions: only while agenda is "open" (draft)
-- ------------------------------------------------------------

create or replace function ow.enforce_agenda_submission_window()
returns trigger
language plpgsql
as $$
declare
  agenda_state text;
begin
  if new.meeting_id is null then
    raise exception 'Agenda submissions must target a meeting';
  end if;

  select state::text into agenda_state
  from ow.meeting_agendas
  where meeting_id = new.meeting_id;

  if agenda_state is null then
    raise exception 'Meeting agenda does not exist';
  end if;

  if agenda_state <> 'draft' then
    raise exception 'Agenda submissions are closed for this meeting';
  end if;

  return new;
end;
$$;

drop trigger if exists agenda_submissions_enforce_window on ow.agenda_submissions;
create trigger agenda_submissions_enforce_window
before insert on ow.agenda_submissions
for each row execute function ow.enforce_agenda_submission_window();

-- ------------------------------------------------------------
-- Viewer context helpers (DB-trusted; consumed by Next middleware)
-- ------------------------------------------------------------

create or replace function ow.current_cycle_id()
returns uuid
language sql
stable
as $$
  select id
  from ow.membership_cycles
  where archived_at is null
    and starts_at <= current_date
    and ends_at >= current_date
  order by starts_at desc
  limit 1
$$;

create or replace function ow.get_member_status(user_id uuid)
returns ow.member_status
language sql
stable
as $$
  select coalesce((
    select m.status
    from ow.member_cycle_statuses m
    where m.profile_id = user_id
      and m.cycle_id = ow.current_cycle_id()
      and m.archived_at is null
    limit 1
  ), 'inactive'::ow.member_status)
$$;

create or replace function ow.is_active_member(user_id uuid)
returns boolean
language sql
stable
as $$
  select ow.get_member_status(user_id) = 'active'::ow.member_status
$$;

create or replace function ow.get_rg_roles(user_id uuid)
returns text[]
language sql
stable
as $$
  select coalesce(array_agg(distinct role::text), '{}'::text[])
  from ow.role_assignments
  where profile_id = user_id
    and archived_at is null
    and (effective_from is null or effective_from <= now())
    and (effective_to is null or effective_to > now())
$$;

create or replace function ow.has_any_rg_role(user_id uuid)
returns boolean
language sql
stable
as $$
  select cardinality(ow.get_rg_roles(user_id)) > 0
$$;

create or replace function ow.has_elected_rg_role(user_id uuid)
returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from ow.role_assignments
    where profile_id = user_id
      and is_elected_role = true
      and archived_at is null
      and (effective_from is null or effective_from <= now())
      and (effective_to is null or effective_to > now())
      and role in ('chair'::ow.rg_role, 'vice_chair'::ow.rg_role, 'treasurer'::ow.rg_role, 'secretary'::ow.rg_role)
  )
$$;

create or replace function public.viewer_context()
returns jsonb
language plpgsql
security definer
stable
set search_path = ow, public
as $$
declare
  uid uuid;
  status ow.member_status;
  roles text[];
begin
  uid := auth.uid();
  if uid is null then
    return null;
  end if;

  status := ow.get_member_status(uid);
  roles := ow.get_rg_roles(uid);

  return jsonb_build_object(
    'user_id', uid::text,
    'member_status', status::text,
    'rg_roles', roles,
    'has_elected_rg_role', ow.has_elected_rg_role(uid)
  );
end;
$$;

-- ------------------------------------------------------------
-- Row Level Security (RLS) - explicit, conservative allow rules
-- ------------------------------------------------------------

-- Enable RLS on all ow tables
do $$
declare
  r record;
begin
  for r in
    select schemaname, tablename
    from pg_tables
    where schemaname = 'ow'
  loop
    execute format('alter table %I.%I enable row level security', r.schemaname, r.tablename);
  end loop;
end $$;

-- Profiles: users can read/update self; elected RG can read for membership DB.
drop policy if exists profiles_select_self on ow.profiles;
create policy profiles_select_self
on ow.profiles for select
using (id = auth.uid());

drop policy if exists profiles_update_self on ow.profiles;
create policy profiles_update_self
on ow.profiles for update
using (id = auth.uid())
with check (id = auth.uid());

drop policy if exists profiles_select_elected_rg on ow.profiles;
create policy profiles_select_elected_rg
on ow.profiles for select
using (ow.has_elected_rg_role(auth.uid()));

-- Membership status: self can read; elected RG can read/update.
drop policy if exists member_cycle_statuses_select_self on ow.member_cycle_statuses;
create policy member_cycle_statuses_select_self
on ow.member_cycle_statuses for select
using (profile_id = auth.uid());

drop policy if exists member_cycle_statuses_select_elected_rg on ow.member_cycle_statuses;
create policy member_cycle_statuses_select_elected_rg
on ow.member_cycle_statuses for select
using (ow.has_elected_rg_role(auth.uid()));

drop policy if exists member_cycle_statuses_update_elected_rg on ow.member_cycle_statuses;
create policy member_cycle_statuses_update_elected_rg
on ow.member_cycle_statuses for update
using (ow.has_elected_rg_role(auth.uid()))
with check (ow.has_elected_rg_role(auth.uid()));

-- Membership cycles: elected RG only (admin domain).
drop policy if exists membership_cycles_all_elected_rg on ow.membership_cycles;
create policy membership_cycles_all_elected_rg
on ow.membership_cycles for all
using (ow.has_elected_rg_role(auth.uid()))
with check (ow.has_elected_rg_role(auth.uid()));

-- Plots/occupancy: membership database is restricted to elected RG.
drop policy if exists plots_select_elected_rg on ow.plots;
create policy plots_select_elected_rg
on ow.plots for select
using (ow.has_elected_rg_role(auth.uid()));

drop policy if exists plot_people_select_elected_rg on ow.plot_people;
create policy plot_people_select_elected_rg
on ow.plot_people for select
using (ow.has_elected_rg_role(auth.uid()));

drop policy if exists plot_groups_select_elected_rg on ow.plot_groups;
create policy plot_groups_select_elected_rg
on ow.plot_groups for select
using (ow.has_elected_rg_role(auth.uid()));

drop policy if exists plot_group_memberships_select_elected_rg on ow.plot_group_memberships;
create policy plot_group_memberships_select_elected_rg
on ow.plot_group_memberships for select
using (ow.has_elected_rg_role(auth.uid()));

drop policy if exists plot_joins_select_elected_rg on ow.plot_joins;
create policy plot_joins_select_elected_rg
on ow.plot_joins for select
using (ow.has_elected_rg_role(auth.uid()));

-- Role assignments: RG-only read; elected RG can write.
drop policy if exists role_assignments_select_rg on ow.role_assignments;
create policy role_assignments_select_rg
on ow.role_assignments for select
using (ow.has_any_rg_role(auth.uid()));

drop policy if exists role_assignments_write_elected_rg on ow.role_assignments;
create policy role_assignments_write_elected_rg
on ow.role_assignments for insert
with check (ow.has_elected_rg_role(auth.uid()));

-- Approvals: RG-only read/write (approvals are RG process).
drop policy if exists approvals_all_rg on ow.approvals;
create policy approvals_all_rg
on ow.approvals for all
using (ow.has_any_rg_role(auth.uid()))
with check (ow.has_any_rg_role(auth.uid()));

drop policy if exists approval_votes_all_rg on ow.approval_votes;
create policy approval_votes_all_rg
on ow.approval_votes for all
using (ow.has_any_rg_role(auth.uid()))
with check (ow.has_any_rg_role(auth.uid()));

-- Polls: active members can suggest (create draft) and view active/closed/archived; RG can view all.
drop policy if exists polls_select_active_member on ow.polls;
create policy polls_select_active_member
on ow.polls for select
using (
  ow.is_active_member(auth.uid())
  and (
    state in ('active'::ow.lifecycle_state, 'closed'::ow.lifecycle_state, 'archived'::ow.lifecycle_state)
    or created_by = auth.uid()
  )
);

drop policy if exists polls_select_rg on ow.polls;
create policy polls_select_rg
on ow.polls for select
using (ow.has_any_rg_role(auth.uid()));

drop policy if exists polls_insert_active_member on ow.polls;
create policy polls_insert_active_member
on ow.polls for insert
with check (ow.is_active_member(auth.uid()) and created_by = auth.uid() and state = 'draft'::ow.lifecycle_state);

drop policy if exists polls_update_rg on ow.polls;
create policy polls_update_rg
on ow.polls for update
using (ow.has_any_rg_role(auth.uid()))
with check (ow.has_any_rg_role(auth.uid()));

-- Poll votes: active members only; one per poll; (weight calculation enforced elsewhere).
drop policy if exists poll_votes_insert_active on ow.poll_votes;
create policy poll_votes_insert_active
on ow.poll_votes for insert
with check (ow.is_active_member(auth.uid()) and voter_id = auth.uid());

drop policy if exists poll_votes_select_rg_or_self on ow.poll_votes;
create policy poll_votes_select_rg_or_self
on ow.poll_votes for select
using (ow.has_any_rg_role(auth.uid()) or voter_id = auth.uid());

-- Meetings: visible to active members, but drafts (agenda/minutes) only to RG.
drop policy if exists meetings_select_active on ow.meetings;
create policy meetings_select_active
on ow.meetings for select
using (ow.is_active_member(auth.uid()));

drop policy if exists meetings_write_rg on ow.meetings;
create policy meetings_write_rg
on ow.meetings for insert
with check (ow.has_any_rg_role(auth.uid()) and created_by = auth.uid());

drop policy if exists meeting_agendas_select_rg_or_archived on ow.meeting_agendas;
create policy meeting_agendas_select_rg_or_archived
on ow.meeting_agendas for select
using (ow.has_any_rg_role(auth.uid()) or (ow.is_active_member(auth.uid()) and state = 'archived'::ow.lifecycle_state));

drop policy if exists meeting_minutes_select_rg_or_archived on ow.meeting_minutes;
create policy meeting_minutes_select_rg_or_archived
on ow.meeting_minutes for select
using (ow.has_any_rg_role(auth.uid()) or (ow.is_active_member(auth.uid()) and state = 'archived'::ow.lifecycle_state));

drop policy if exists meeting_agendas_update_rg on ow.meeting_agendas;
create policy meeting_agendas_update_rg
on ow.meeting_agendas for update
using (ow.has_any_rg_role(auth.uid()))
with check (ow.has_any_rg_role(auth.uid()));

drop policy if exists meeting_minutes_update_rg on ow.meeting_minutes;
create policy meeting_minutes_update_rg
on ow.meeting_minutes for update
using (ow.has_any_rg_role(auth.uid()))
with check (ow.has_any_rg_role(auth.uid()));

-- Agenda submissions: active members can insert; RG can view/approve/update.
drop policy if exists agenda_submissions_insert_active on ow.agenda_submissions;
create policy agenda_submissions_insert_active
on ow.agenda_submissions for insert
with check (ow.is_active_member(auth.uid()) and submitted_by = auth.uid());

drop policy if exists agenda_submissions_select_rg_or_self on ow.agenda_submissions;
create policy agenda_submissions_select_rg_or_self
on ow.agenda_submissions for select
using (ow.has_any_rg_role(auth.uid()) or submitted_by = auth.uid());

drop policy if exists agenda_submissions_update_rg on ow.agenda_submissions;
create policy agenda_submissions_update_rg
on ow.agenda_submissions for update
using (ow.has_any_rg_role(auth.uid()))
with check (ow.has_any_rg_role(auth.uid()));

-- Actions: members view-only; RG creates/updates; completion should archive (enforced by app/DB logic later).
drop policy if exists actions_select_active on ow.actions;
create policy actions_select_active
on ow.actions for select
using (ow.is_active_member(auth.uid()));

drop policy if exists actions_write_rg on ow.actions;
create policy actions_write_rg
on ow.actions for insert
with check (ow.has_any_rg_role(auth.uid()) and created_by = auth.uid());

drop policy if exists actions_update_rg on ow.actions;
create policy actions_update_rg
on ow.actions for update
using (ow.has_any_rg_role(auth.uid()))
with check (ow.has_any_rg_role(auth.uid()));

-- Communications: active members read-only; RG writes; closing should archive (enforced by app/DB logic later).
drop policy if exists communication_threads_select_active on ow.communication_threads;
create policy communication_threads_select_active
on ow.communication_threads for select
using (ow.is_active_member(auth.uid()));

drop policy if exists communication_threads_insert_rg on ow.communication_threads;
create policy communication_threads_insert_rg
on ow.communication_threads for insert
with check (ow.has_any_rg_role(auth.uid()) and created_by = auth.uid());

drop policy if exists communication_threads_update_rg on ow.communication_threads;
create policy communication_threads_update_rg
on ow.communication_threads for update
using (ow.has_any_rg_role(auth.uid()))
with check (ow.has_any_rg_role(auth.uid()));

drop policy if exists communication_updates_select_active on ow.communication_updates;
create policy communication_updates_select_active
on ow.communication_updates for select
using (ow.is_active_member(auth.uid()));

drop policy if exists communication_updates_insert_rg on ow.communication_updates;
create policy communication_updates_insert_rg
on ow.communication_updates for insert
with check (ow.has_any_rg_role(auth.uid()) and created_by = auth.uid());

-- Documents: active members can read archived docs/folders; RG can upload; edits/deletes require approvals (implemented later).
drop policy if exists document_folders_select_active on ow.document_folders;
create policy document_folders_select_active
on ow.document_folders for select
using (ow.is_active_member(auth.uid()));

drop policy if exists documents_select_active on ow.documents;
create policy documents_select_active
on ow.documents for select
using (ow.is_active_member(auth.uid()) and state = 'archived'::ow.lifecycle_state);

drop policy if exists documents_insert_rg on ow.documents;
create policy documents_insert_rg
on ow.documents for insert
with check (ow.has_any_rg_role(auth.uid()) and uploaded_by = auth.uid());

-- Finance: active members can read; treasurer uploads (enforced by role assignments).
drop policy if exists finance_entries_select_active on ow.finance_entries;
create policy finance_entries_select_active
on ow.finance_entries for select
using (ow.is_active_member(auth.uid()));

drop policy if exists finance_entries_insert_treasurer on ow.finance_entries;
create policy finance_entries_insert_treasurer
on ow.finance_entries for insert
with check (
  ow.is_active_member(auth.uid())
  and created_by = auth.uid()
  and 'treasurer' = any(ow.get_rg_roles(auth.uid()))
);

-- Notices: active members read; RG writes.
drop policy if exists notices_select_active on ow.notices;
create policy notices_select_active
on ow.notices for select
using (ow.is_active_member(auth.uid()));

drop policy if exists notices_write_rg on ow.notices;
create policy notices_write_rg
on ow.notices for insert
with check (ow.has_any_rg_role(auth.uid()) and created_by = auth.uid());

-- Annual report: active members read; only RG can create (generation job).
drop policy if exists annual_reports_select_active on ow.annual_reports;
create policy annual_reports_select_active
on ow.annual_reports for select
using (ow.is_active_member(auth.uid()));

drop policy if exists annual_reports_write_rg on ow.annual_reports;
create policy annual_reports_write_rg
on ow.annual_reports for insert
with check (ow.has_any_rg_role(auth.uid()));

-- Audit log: RG read-only (append-only inserts via security definer functions later).
drop policy if exists audit_log_select_rg on ow.audit_log;
create policy audit_log_select_rg
on ow.audit_log for select
using (ow.has_any_rg_role(auth.uid()));

commit;

