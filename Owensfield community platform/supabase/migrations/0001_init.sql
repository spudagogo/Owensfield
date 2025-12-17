-- Owensfield Community Platform - Initial schema (spec-first, archive-only)
-- NOTE: This file is intended for Supabase Postgres migrations.
-- NOTE: No features are implemented in the web app yet; this is schema-only scaffolding.

begin;

create schema if not exists ow;

-- ------------------------------------------------------------
-- Common helpers (archive-only + audit)
-- ------------------------------------------------------------

create or replace function ow.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function ow.prevent_delete()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Hard deletes are not allowed for %', tg_table_name;
end;
$$;

-- ------------------------------------------------------------
-- Enums / statuses (explicit state machines)
-- ------------------------------------------------------------

do $$ begin
  create type ow.lifecycle_state as enum ('draft', 'pending', 'active', 'closed', 'archived');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type ow.member_status as enum ('active', 'inactive');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type ow.plot_person_role as enum ('owner', 'tenant');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type ow.meeting_type as enum ('community_quarterly', 'agm', 'rg', 'ocg');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type ow.document_action as enum ('edit', 'delete');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type ow.approval_subject_type as enum (
    'poll',
    'document',
    'meeting_agenda',
    'meeting_minutes',
    'agenda_submission',
    'communication_thread'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type ow.rg_role as enum ('chair', 'vice_chair', 'treasurer', 'secretary', 'rg_member');
exception when duplicate_object then null;
end $$;

-- ------------------------------------------------------------
-- People & membership cycle
-- ------------------------------------------------------------

-- Profiles are keyed to Supabase auth.users.id.
create table if not exists ow.profiles (
  id uuid primary key, -- references auth.users(id) in Supabase
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger profiles_set_updated_at
before update on ow.profiles
for each row execute function ow.set_updated_at();

-- Membership runs AGM → AGM (one cycle active at a time operationally).
create table if not exists ow.membership_cycles (
  id uuid primary key default gen_random_uuid(),
  label text not null, -- e.g. "2025 AGM → 2026 AGM"
  starts_at date not null,
  ends_at date not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger membership_cycles_set_updated_at
before update on ow.membership_cycles
for each row execute function ow.set_updated_at();

create trigger membership_cycles_prevent_delete
before delete on ow.membership_cycles
for each row execute function ow.prevent_delete();

-- Per-cycle member status (inactive members are restricted to Profile + Renewal only).
create table if not exists ow.member_cycle_statuses (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references ow.profiles(id),
  cycle_id uuid not null references ow.membership_cycles(id),
  status ow.member_status not null default 'inactive',
  status_set_at timestamptz not null default now(),
  status_set_by uuid references ow.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  unique (profile_id, cycle_id)
);

create trigger member_cycle_statuses_set_updated_at
before update on ow.member_cycle_statuses
for each row execute function ow.set_updated_at();

create trigger member_cycle_statuses_prevent_delete
before delete on ow.member_cycle_statuses
for each row execute function ow.prevent_delete();

-- ------------------------------------------------------------
-- Plots & occupancy (voting value defaults to 1, joined plots = 2)
-- ------------------------------------------------------------

-- "Fixed number of plots" is enforced operationally (seeded once); records are permanent.
create table if not exists ow.plots (
  id uuid primary key default gen_random_uuid(),
  plot_code text not null unique, -- stable identifier (e.g. "P-001")
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger plots_set_updated_at
before update on ow.plots
for each row execute function ow.set_updated_at();

create trigger plots_prevent_delete
before delete on ow.plots
for each row execute function ow.prevent_delete();

-- Plot groups represent voting units (1 plot => voting_value 1; 2 joined plots => voting_value 2).
create table if not exists ow.plot_groups (
  id uuid primary key default gen_random_uuid(),
  voting_value smallint not null default 1 check (voting_value in (1, 2)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger plot_groups_set_updated_at
before update on ow.plot_groups
for each row execute function ow.set_updated_at();

create trigger plot_groups_prevent_delete
before delete on ow.plot_groups
for each row execute function ow.prevent_delete();

-- Each plot belongs to exactly one group.
create table if not exists ow.plot_group_memberships (
  id uuid primary key default gen_random_uuid(),
  plot_id uuid not null unique references ow.plots(id),
  plot_group_id uuid not null references ow.plot_groups(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger plot_group_memberships_set_updated_at
before update on ow.plot_group_memberships
for each row execute function ow.set_updated_at();

create trigger plot_group_memberships_prevent_delete
before delete on ow.plot_group_memberships
for each row execute function ow.prevent_delete();

-- Joined plots: record which elected RG user assigned the join.
create table if not exists ow.plot_joins (
  id uuid primary key default gen_random_uuid(),
  plot_group_id uuid not null unique references ow.plot_groups(id),
  assigned_by uuid not null references ow.profiles(id),
  assigned_at timestamptz not null default now(),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger plot_joins_set_updated_at
before update on ow.plot_joins
for each row execute function ow.set_updated_at();

create trigger plot_joins_prevent_delete
before delete on ow.plot_joins
for each row execute function ow.prevent_delete();

-- Plot occupancy: owners (max 2 per plot) and tenants (unlimited).
create table if not exists ow.plot_people (
  id uuid primary key default gen_random_uuid(),
  plot_id uuid not null references ow.plots(id),
  profile_id uuid not null references ow.profiles(id),
  role ow.plot_person_role not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  unique (plot_id, profile_id, role)
);

create trigger plot_people_set_updated_at
before update on ow.plot_people
for each row execute function ow.set_updated_at();

create trigger plot_people_prevent_delete
before delete on ow.plot_people
for each row execute function ow.prevent_delete();

-- Enforce max 2 active owners per plot (spec: 1–2 owners).
create or replace function ow.enforce_plot_owner_limit()
returns trigger
language plpgsql
as $$
declare
  owner_count integer;
begin
  if (new.role <> 'owner') then
    return new;
  end if;

  if (new.is_active is distinct from true) then
    return new;
  end if;

  select count(*) into owner_count
  from ow.plot_people
  where plot_id = new.plot_id
    and role = 'owner'
    and is_active = true
    and archived_at is null
    and (tg_op = 'INSERT' or id <> new.id);

  if owner_count >= 2 then
    raise exception 'A plot may have at most 2 active owners';
  end if;

  return new;
end;
$$;

drop trigger if exists plot_people_enforce_owner_limit on ow.plot_people;
create trigger plot_people_enforce_owner_limit
before insert or update on ow.plot_people
for each row execute function ow.enforce_plot_owner_limit();

-- ------------------------------------------------------------
-- RG roles, assignments, elections (foundational tables only)
-- ------------------------------------------------------------

create table if not exists ow.role_assignments (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references ow.profiles(id),
  role ow.rg_role not null,
  is_elected_role boolean not null default false,
  -- Role changes take effect only at OCG meeting or AGM; link enactment to meeting when known.
  enacted_at_meeting_id uuid,
  effective_from timestamptz,
  effective_to timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger role_assignments_set_updated_at
before update on ow.role_assignments
for each row execute function ow.set_updated_at();

create trigger role_assignments_prevent_delete
before delete on ow.role_assignments
for each row execute function ow.prevent_delete();

-- ------------------------------------------------------------
-- Approvals (auditable; default threshold = 4 RG approvals)
-- ------------------------------------------------------------

create table if not exists ow.approvals (
  id uuid primary key default gen_random_uuid(),
  subject_type ow.approval_subject_type not null,
  subject_id uuid not null,
  action text not null, -- e.g. "activate", "approve_minutes", "approve_agenda", "document_edit", "document_delete"
  required_approvals integer not null default 4 check (required_approvals > 0),
  state ow.lifecycle_state not null default 'pending',
  requested_by uuid not null references ow.profiles(id),
  requested_at timestamptz not null default now(),
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger approvals_set_updated_at
before update on ow.approvals
for each row execute function ow.set_updated_at();

create trigger approvals_prevent_delete
before delete on ow.approvals
for each row execute function ow.prevent_delete();

create table if not exists ow.approval_votes (
  id uuid primary key default gen_random_uuid(),
  approval_id uuid not null references ow.approvals(id),
  approver_id uuid not null references ow.profiles(id),
  approved boolean not null,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  unique (approval_id, approver_id)
);

create trigger approval_votes_set_updated_at
before update on ow.approval_votes
for each row execute function ow.set_updated_at();

create trigger approval_votes_prevent_delete
before delete on ow.approval_votes
for each row execute function ow.prevent_delete();

-- ------------------------------------------------------------
-- Polls (governance changes require a poll)
-- ------------------------------------------------------------

create table if not exists ow.polls (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  state ow.lifecycle_state not null default 'draft',
  default_runtime_days integer not null default 14,
  opens_at timestamptz,
  closes_at timestamptz,
  created_by uuid not null references ow.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger polls_set_updated_at
before update on ow.polls
for each row execute function ow.set_updated_at();

create trigger polls_prevent_delete
before delete on ow.polls
for each row execute function ow.prevent_delete();

create table if not exists ow.poll_options (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references ow.polls(id),
  label text not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger poll_options_set_updated_at
before update on ow.poll_options
for each row execute function ow.set_updated_at();

create trigger poll_options_prevent_delete
before delete on ow.poll_options
for each row execute function ow.prevent_delete();

-- Votes store the computed voting weight at time of vote for auditability.
create table if not exists ow.poll_votes (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references ow.polls(id),
  option_id uuid not null references ow.poll_options(id),
  voter_id uuid not null references ow.profiles(id),
  weight numeric(10,6) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  unique (poll_id, voter_id)
);

create trigger poll_votes_set_updated_at
before update on ow.poll_votes
for each row execute function ow.set_updated_at();

create trigger poll_votes_prevent_delete
before delete on ow.poll_votes
for each row execute function ow.prevent_delete();

-- ------------------------------------------------------------
-- Meetings, agendas, minutes (draft → pending approvals → approved/archived)
-- ------------------------------------------------------------

create table if not exists ow.meetings (
  id uuid primary key default gen_random_uuid(),
  meeting_type ow.meeting_type not null,
  title text not null,
  scheduled_for timestamptz,
  created_by uuid not null references ow.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger meetings_set_updated_at
before update on ow.meetings
for each row execute function ow.set_updated_at();

create trigger meetings_prevent_delete
before delete on ow.meetings
for each row execute function ow.prevent_delete();

create table if not exists ow.meeting_agendas (
  id uuid primary key default gen_random_uuid(),
  meeting_id uuid not null unique references ow.meetings(id),
  state ow.lifecycle_state not null default 'draft',
  content text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger meeting_agendas_set_updated_at
before update on ow.meeting_agendas
for each row execute function ow.set_updated_at();

create trigger meeting_agendas_prevent_delete
before delete on ow.meeting_agendas
for each row execute function ow.prevent_delete();

create table if not exists ow.meeting_minutes (
  id uuid primary key default gen_random_uuid(),
  meeting_id uuid not null unique references ow.meetings(id),
  state ow.lifecycle_state not null default 'draft',
  content text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger meeting_minutes_set_updated_at
before update on ow.meeting_minutes
for each row execute function ow.set_updated_at();

create trigger meeting_minutes_prevent_delete
before delete on ow.meeting_minutes
for each row execute function ow.prevent_delete();

create table if not exists ow.agenda_submissions (
  id uuid primary key default gen_random_uuid(),
  submitted_by uuid not null references ow.profiles(id),
  meeting_id uuid references ow.meetings(id),
  title text not null,
  description text,
  state ow.lifecycle_state not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger agenda_submissions_set_updated_at
before update on ow.agenda_submissions
for each row execute function ow.set_updated_at();

create trigger agenda_submissions_prevent_delete
before delete on ow.agenda_submissions
for each row execute function ow.prevent_delete();

-- ------------------------------------------------------------
-- Actions
-- ------------------------------------------------------------

create table if not exists ow.actions (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  state ow.lifecycle_state not null default 'active',
  created_by uuid not null references ow.profiles(id),
  source_type text, -- e.g. "poll" / "meeting" / "minutes" / "communication"
  source_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger actions_set_updated_at
before update on ow.actions
for each row execute function ow.set_updated_at();

create trigger actions_prevent_delete
before delete on ow.actions
for each row execute function ow.prevent_delete();

create table if not exists ow.action_updates (
  id uuid primary key default gen_random_uuid(),
  action_id uuid not null references ow.actions(id),
  update_text text not null,
  created_by uuid not null references ow.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger action_updates_set_updated_at
before update on ow.action_updates
for each row execute function ow.set_updated_at();

create trigger action_updates_prevent_delete
before delete on ow.action_updates
for each row execute function ow.prevent_delete();

-- ------------------------------------------------------------
-- Communications (official record only)
-- ------------------------------------------------------------

create table if not exists ow.communication_threads (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  state ow.lifecycle_state not null default 'active', -- closed → archived
  created_by uuid not null references ow.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger communication_threads_set_updated_at
before update on ow.communication_threads
for each row execute function ow.set_updated_at();

create trigger communication_threads_prevent_delete
before delete on ow.communication_threads
for each row execute function ow.prevent_delete();

create table if not exists ow.communication_updates (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references ow.communication_threads(id),
  update_text text not null,
  created_by uuid not null references ow.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger communication_updates_set_updated_at
before update on ow.communication_updates
for each row execute function ow.set_updated_at();

create trigger communication_updates_prevent_delete
before delete on ow.communication_updates
for each row execute function ow.prevent_delete();

-- ------------------------------------------------------------
-- Documents (central archive; archived by default)
-- ------------------------------------------------------------

create table if not exists ow.document_folders (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  parent_id uuid references ow.document_folders(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  unique (parent_id, name)
);

create trigger document_folders_set_updated_at
before update on ow.document_folders
for each row execute function ow.set_updated_at();

create trigger document_folders_prevent_delete
before delete on ow.document_folders
for each row execute function ow.prevent_delete();

create table if not exists ow.documents (
  id uuid primary key default gen_random_uuid(),
  folder_id uuid references ow.document_folders(id),
  title text not null,
  state ow.lifecycle_state not null default 'archived',
  storage_path text, -- supabase storage path (future)
  uploaded_by uuid not null references ow.profiles(id),
  uploaded_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger documents_set_updated_at
before update on ow.documents
for each row execute function ow.set_updated_at();

create trigger documents_prevent_delete
before delete on ow.documents
for each row execute function ow.prevent_delete();

-- ------------------------------------------------------------
-- Finance (reporting only)
-- ------------------------------------------------------------

create table if not exists ow.finance_entries (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  document_id uuid references ow.documents(id),
  created_by uuid not null references ow.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger finance_entries_set_updated_at
before update on ow.finance_entries
for each row execute function ow.set_updated_at();

create trigger finance_entries_prevent_delete
before delete on ow.finance_entries
for each row execute function ow.prevent_delete();

-- ------------------------------------------------------------
-- Notices (placeholder entity; read-only to members when implemented)
-- ------------------------------------------------------------

create table if not exists ow.notices (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text not null default '',
  state ow.lifecycle_state not null default 'active',
  created_by uuid not null references ow.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger notices_set_updated_at
before update on ow.notices
for each row execute function ow.set_updated_at();

create trigger notices_prevent_delete
before delete on ow.notices
for each row execute function ow.prevent_delete();

-- ------------------------------------------------------------
-- Annual report (auto-generated day before AGM; archived permanently)
-- ------------------------------------------------------------

create table if not exists ow.annual_reports (
  id uuid primary key default gen_random_uuid(),
  meeting_id uuid not null references ow.meetings(id), -- AGM meeting
  cycle_id uuid not null references ow.membership_cycles(id),
  generated_at timestamptz not null default now(),
  content jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger annual_reports_set_updated_at
before update on ow.annual_reports
for each row execute function ow.set_updated_at();

create trigger annual_reports_prevent_delete
before delete on ow.annual_reports
for each row execute function ow.prevent_delete();

-- ------------------------------------------------------------
-- Audit log (append-only)
-- ------------------------------------------------------------

create table if not exists ow.audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references ow.profiles(id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now()
);

create trigger audit_log_prevent_delete
before delete on ow.audit_log
for each row execute function ow.prevent_delete();

commit;

