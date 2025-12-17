-- Owensfield Community Platform - Governance flows (spec-critical)
-- NOTE: This migration adds DB-side safeguards for approvals, polls, elections, temporary mode.

begin;

-- ------------------------------------------------------------
-- Approvals: satisfaction checks (auditable threshold enforcement)
-- ------------------------------------------------------------

create or replace function ow.approval_yes_count(p_approval_id uuid)
returns integer
language sql
stable
as $$
  select count(*)::int
  from ow.approval_votes v
  where v.approval_id = p_approval_id
    and v.archived_at is null
    and v.approved = true
$$;

create or replace function ow.approval_is_satisfied(
  p_subject_type ow.approval_subject_type,
  p_subject_id uuid,
  p_action text
)
returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from ow.approvals a
    where a.subject_type = p_subject_type
      and a.subject_id = p_subject_id
      and a.action = p_action
      and a.archived_at is null
      and ow.approval_yes_count(a.id) >= a.required_approvals
  )
$$;

-- ------------------------------------------------------------
-- Poll lifecycle: activation requires 4 RG approvals; closing computes outcome
-- ------------------------------------------------------------

create table if not exists ow.poll_results (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null unique references ow.polls(id),
  outcome text not null check (outcome in ('passed', 'failed', 'tied', 'no_votes')),
  totals jsonb not null default '{}'::jsonb,
  computed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger poll_results_set_updated_at
before update on ow.poll_results
for each row execute function ow.set_updated_at();

create trigger poll_results_prevent_delete
before delete on ow.poll_results
for each row execute function ow.prevent_delete();

create or replace function ow.compute_poll_result(p_poll_id uuid)
returns ow.poll_results
language plpgsql
security definer
set search_path = ow, public
as $$
declare
  total_votes numeric(20,6);
  best_weight numeric(20,6);
  best_count int;
  result_row ow.poll_results;
  totals jsonb;
begin
  select coalesce(sum(weight), 0) into total_votes
  from ow.poll_votes
  where poll_id = p_poll_id and archived_at is null;

  select jsonb_object_agg(option_id::text, sum(weight)) into totals
  from ow.poll_votes
  where poll_id = p_poll_id and archived_at is null
  group by poll_id;

  -- Determine top option weight and whether tied.
  with option_totals as (
    select option_id, coalesce(sum(weight), 0) as w
    from ow.poll_votes
    where poll_id = p_poll_id and archived_at is null
    group by option_id
  )
  select max(w) into best_weight from option_totals;

  if best_weight is null then
    insert into ow.poll_results (poll_id, outcome, totals)
    values (p_poll_id, 'no_votes', coalesce(totals, '{}'::jsonb))
    on conflict (poll_id) do update set
      outcome = excluded.outcome,
      totals = excluded.totals,
      computed_at = now(),
      updated_at = now()
    returning * into result_row;
    return result_row;
  end if;

  select count(*) into best_count
  from (
    select option_id, coalesce(sum(weight), 0) as w
    from ow.poll_votes
    where poll_id = p_poll_id and archived_at is null
    group by option_id
  ) t
  where t.w = best_weight;

  insert into ow.poll_results (poll_id, outcome, totals)
  values (
    p_poll_id,
    case
      when best_count > 1 then 'tied'
      else 'passed'
    end,
    coalesce(totals, '{}'::jsonb)
  )
  on conflict (poll_id) do update set
    outcome = excluded.outcome,
    totals = excluded.totals,
    computed_at = now(),
    updated_at = now()
  returning * into result_row;

  return result_row;
end;
$$;

-- Enforce: poll cannot enter 'active' without RG approvals (default threshold = 4).
create or replace function ow.enforce_poll_activation_approvals()
returns trigger
language plpgsql
as $$
begin
  if old.state::text <> 'active' and new.state::text = 'active' then
    if not ow.approval_is_satisfied('poll'::ow.approval_subject_type, new.id, 'activate') then
      raise exception 'Poll activation requires RG approvals (subject=poll, action=activate)';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists polls_enforce_activation_approvals on ow.polls;
create trigger polls_enforce_activation_approvals
before update on ow.polls
for each row execute function ow.enforce_poll_activation_approvals();

-- When poll is closed, compute result. (Governance application is handled by downstream governance logic.)
create or replace function ow.on_poll_closed_compute_result()
returns trigger
language plpgsql
as $$
begin
  if old.state::text <> 'closed' and new.state::text = 'closed' then
    perform ow.compute_poll_result(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists polls_on_closed_compute_result on ow.polls;
create trigger polls_on_closed_compute_result
after update on ow.polls
for each row execute function ow.on_poll_closed_compute_result();

-- ------------------------------------------------------------
-- Documents: "delete" is modeled as a soft remove flag (no hard delete)
-- ------------------------------------------------------------

alter table ow.documents
  add column if not exists is_removed boolean not null default false,
  add column if not exists removed_at timestamptz;

create or replace function ow.enforce_document_change_approvals()
returns trigger
language plpgsql
as $$
begin
  -- Archived documents editable/deletable only with 4 RG approvals.
  if (old.state::text = 'archived') then
    -- Soft-remove
    if old.is_removed is distinct from new.is_removed and new.is_removed = true then
      if not ow.approval_is_satisfied('document'::ow.approval_subject_type, new.id, 'delete') then
        raise exception 'Document delete (soft remove) requires 4 RG approvals';
      end if;
      new.removed_at := coalesce(new.removed_at, now());
      return new;
    end if;

    -- Any other update requires edit approval.
    if to_jsonb(old) <> to_jsonb(new) then
      if not ow.approval_is_satisfied('document'::ow.approval_subject_type, new.id, 'edit') then
        raise exception 'Archived document edits require 4 RG approvals';
      end if;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists documents_enforce_change_approvals on ow.documents;
create trigger documents_enforce_change_approvals
before update on ow.documents
for each row execute function ow.enforce_document_change_approvals();

-- ------------------------------------------------------------
-- Temporary governance mode (RG < 4) + override logging
-- ------------------------------------------------------------

create table if not exists ow.governance_overrides (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references ow.profiles(id),
  reason text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create trigger governance_overrides_prevent_delete
before delete on ow.governance_overrides
for each row execute function ow.prevent_delete();

create trigger governance_overrides_prevent_update
before update on ow.governance_overrides
for each row execute function ow.prevent_update();

create or replace function ow.rg_member_count()
returns integer
language sql
stable
as $$
  select count(distinct profile_id)::int
  from ow.role_assignments
  where archived_at is null
    and (effective_from is null or effective_from <= now())
    and (effective_to is null or effective_to > now())
$$;

create or replace function ow.in_temporary_mode()
returns boolean
language sql
stable
as $$
  select ow.rg_member_count() < 4
$$;

create or replace function ow.has_temporary_authority(user_id uuid)
returns boolean
language sql
stable
as $$
  select ow.in_temporary_mode()
    and exists (
      select 1
      from ow.role_assignments
      where profile_id = user_id
        and archived_at is null
        and (effective_from is null or effective_from <= now())
        and (effective_to is null or effective_to > now())
        and role in ('chair'::ow.rg_role, 'vice_chair'::ow.rg_role)
    )
$$;

-- ------------------------------------------------------------
-- Elections & role changes (foundational schema; activation tied to OCG/AGM enactment)
-- ------------------------------------------------------------

do $$ begin
  create type ow.election_state as enum ('nominating', 'voting', 'closed', 'archived');
exception when duplicate_object then null;
end $$;

create table if not exists ow.elections (
  id uuid primary key default gen_random_uuid(),
  role ow.rg_role not null, -- chair/vice/treasurer/secretary/rg_member
  state ow.election_state not null default 'nominating',
  nomination_opens_at timestamptz not null default now(),
  nomination_closes_at timestamptz not null,
  voting_opens_at timestamptz,
  voting_closes_at timestamptz,
  created_by uuid not null references ow.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger elections_set_updated_at
before update on ow.elections
for each row execute function ow.set_updated_at();

create trigger elections_prevent_delete
before delete on ow.elections
for each row execute function ow.prevent_delete();

create table if not exists ow.election_nominations (
  id uuid primary key default gen_random_uuid(),
  election_id uuid not null references ow.elections(id),
  nominee_id uuid not null references ow.profiles(id),
  nominated_by uuid not null references ow.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  unique (election_id, nominee_id)
);

create trigger election_nominations_set_updated_at
before update on ow.election_nominations
for each row execute function ow.set_updated_at();

create trigger election_nominations_prevent_delete
before delete on ow.election_nominations
for each row execute function ow.prevent_delete();

create table if not exists ow.election_results (
  id uuid primary key default gen_random_uuid(),
  election_id uuid not null unique references ow.elections(id),
  winner_id uuid references ow.profiles(id),
  is_uncontested boolean not null default false,
  computed_at timestamptz not null default now(),
  enacted_at_meeting_id uuid references ow.meetings(id), -- must be OCG or AGM
  enacted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger election_results_set_updated_at
before update on ow.election_results
for each row execute function ow.set_updated_at();

create trigger election_results_prevent_delete
before delete on ow.election_results
for each row execute function ow.prevent_delete();

commit;

