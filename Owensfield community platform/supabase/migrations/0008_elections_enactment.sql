-- Owensfield Community Platform - RG elections: delayed enactment + step-downs (spec-critical)

begin;

do $$ begin
  create type ow.enactment_state as enum ('pending', 'enacted', 'void', 'archived');
exception when duplicate_object then null;
end $$;

alter table ow.election_results
  add column if not exists enactment_state ow.enactment_state not null default 'pending',
  add column if not exists enacted_by uuid references ow.profiles(id);

-- Role step-down requests: take effect only at OCG/AGM enactment meeting.
create table if not exists ow.role_stepdowns (
  id uuid primary key default gen_random_uuid(),
  role ow.rg_role not null,
  requested_by uuid not null references ow.profiles(id),
  requested_at timestamptz not null default now(),
  enactment_state ow.enactment_state not null default 'pending',
  enacted_at_meeting_id uuid references ow.meetings(id),
  enacted_at timestamptz,
  enacted_by uuid references ow.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger role_stepdowns_set_updated_at
before update on ow.role_stepdowns
for each row execute function ow.set_updated_at();

create trigger role_stepdowns_prevent_delete
before delete on ow.role_stepdowns
for each row execute function ow.prevent_delete();

-- Helpers
create or replace function ow.is_enactment_meeting(p_meeting_id uuid)
returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from ow.meetings m
    where m.id = p_meeting_id
      and m.meeting_type in ('ocg'::ow.meeting_type, 'agm'::ow.meeting_type)
      and m.archived_at is null
  )
$$;

create or replace function ow.meeting_effective_at(p_meeting_id uuid)
returns timestamptz
language sql
stable
as $$
  select coalesce(m.scheduled_for, now())
  from ow.meetings m
  where m.id = p_meeting_id
$$;

create or replace function ow.is_role_vacant(p_role ow.rg_role)
returns boolean
language sql
stable
as $$
  select not exists (
    select 1
    from ow.role_assignments ra
    where ra.role = p_role
      and ra.is_elected_role = true
      and ra.archived_at is null
      and (ra.effective_from is null or ra.effective_from <= now())
      and (ra.effective_to is null or ra.effective_to > now())
  )
$$;

-- Uncontested nominations auto-elect: if exactly one nomination at close, create pending result.
create or replace function public.finalize_election_uncontested(p_election_id uuid)
returns void
language plpgsql
security definer
set search_path = ow, public
as $$
declare
  uid uuid;
  e ow.elections;
  nominee uuid;
  nominee_count int;
begin
  uid := auth.uid();
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if not ow.has_any_rg_role(uid) then
    raise exception 'RG role required';
  end if;

  select * into e from ow.elections where id = p_election_id and archived_at is null;
  if e.id is null then
    raise exception 'Election not found';
  end if;

  select count(*)::int into nominee_count
  from ow.election_nominations n
  where n.election_id = e.id and n.archived_at is null;

  if nominee_count <> 1 then
    raise exception 'Election is not uncontested';
  end if;

  select n.nominee_id into nominee
  from ow.election_nominations n
  where n.election_id = e.id and n.archived_at is null
  limit 1;

  update ow.elections
  set state = 'closed'::ow.election_state,
      updated_at = now()
  where id = e.id;

  insert into ow.election_results (election_id, winner_id, is_uncontested, enactment_state)
  values (e.id, nominee, true, 'pending'::ow.enactment_state)
  on conflict (election_id) do nothing;

  insert into ow.audit_log (actor_id, action, entity_type, entity_id, after_data)
  values (uid, 'election_finalized_uncontested', 'election', e.id, jsonb_build_object('winner_id', nominee::text));
end;
$$;

-- Enactment must be deliberate, tied to an OCG/AGM meeting, and only activates if role is vacant.
create or replace function public.enact_election_result(p_election_id uuid, p_meeting_id uuid)
returns void
language plpgsql
security definer
set search_path = ow, public
as $$
declare
  uid uuid;
  e ow.elections;
  r ow.election_results;
  effective_at timestamptz;
begin
  uid := auth.uid();
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if not ow.has_any_rg_role(uid) then
    raise exception 'RG role required';
  end if;
  if not ow.is_enactment_meeting(p_meeting_id) then
    raise exception 'Role enactment must occur at an OCG meeting or the AGM';
  end if;

  select * into e from ow.elections where id = p_election_id and archived_at is null;
  if e.id is null then
    raise exception 'Election not found';
  end if;
  if e.state <> 'closed'::ow.election_state then
    raise exception 'Election must be closed before enactment';
  end if;

  select * into r from ow.election_results where election_id = e.id and archived_at is null;
  if r.id is null or r.winner_id is null then
    raise exception 'Election result missing or has no winner';
  end if;
  if r.enactment_state <> 'pending'::ow.enactment_state then
    raise exception 'Election result is not pending enactment';
  end if;

  -- Results activate only when position is vacant.
  if not ow.is_role_vacant(e.role) then
    raise exception 'Role is not vacant; election result cannot activate';
  end if;

  effective_at := ow.meeting_effective_at(p_meeting_id);

  insert into ow.role_assignments (
    profile_id,
    role,
    is_elected_role,
    enacted_at_meeting_id,
    effective_from
  )
  values (r.winner_id, e.role, true, p_meeting_id, effective_at);

  update ow.election_results
  set enactment_state = 'enacted'::ow.enactment_state,
      enacted_at_meeting_id = p_meeting_id,
      enacted_at = now(),
      enacted_by = uid,
      updated_at = now()
  where id = r.id;

  insert into ow.audit_log (actor_id, action, entity_type, entity_id, after_data)
  values (
    uid,
    'election_result_enacted',
    'election',
    e.id,
    jsonb_build_object('meeting_id', p_meeting_id::text, 'winner_id', r.winner_id::text, 'role', e.role::text)
  );
end;
$$;

-- Step-down request (does not take effect immediately).
create or replace function public.request_role_step_down(p_role ow.rg_role)
returns uuid
language plpgsql
security definer
set search_path = ow, public
as $$
declare
  uid uuid;
  id_out uuid;
begin
  uid := auth.uid();
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if not ow.has_any_rg_role(uid) then
    raise exception 'RG role required';
  end if;

  -- Must currently hold that role (effective now).
  if not exists (
    select 1 from ow.role_assignments ra
    where ra.profile_id = uid
      and ra.role = p_role
      and ra.archived_at is null
      and (ra.effective_from is null or ra.effective_from <= now())
      and (ra.effective_to is null or ra.effective_to > now())
  ) then
    raise exception 'You do not currently hold this role';
  end if;

  insert into ow.role_stepdowns (role, requested_by)
  values (p_role, uid)
  returning id into id_out;

  insert into ow.audit_log (actor_id, action, entity_type, entity_id, after_data)
  values (uid, 'role_stepdown_requested', 'role', id_out, jsonb_build_object('role', p_role::text));

  return id_out;
end;
$$;

-- Enact step-down at OCG/AGM meeting (deliberate + logged).
create or replace function public.enact_role_step_down(p_stepdown_id uuid, p_meeting_id uuid)
returns void
language plpgsql
security definer
set search_path = ow, public
as $$
declare
  uid uuid;
  s ow.role_stepdowns;
  effective_at timestamptz;
begin
  uid := auth.uid();
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if not ow.has_any_rg_role(uid) then
    raise exception 'RG role required';
  end if;
  if not ow.is_enactment_meeting(p_meeting_id) then
    raise exception 'Step-down enactment must occur at an OCG meeting or the AGM';
  end if;

  select * into s from ow.role_stepdowns where id = p_stepdown_id and archived_at is null;
  if s.id is null then
    raise exception 'Step-down request not found';
  end if;
  if s.enactment_state <> 'pending'::ow.enactment_state then
    raise exception 'Step-down request is not pending';
  end if;

  effective_at := ow.meeting_effective_at(p_meeting_id);

  update ow.role_assignments
  set effective_to = effective_at,
      updated_at = now()
  where role = s.role
    and profile_id = s.requested_by
    and archived_at is null
    and (effective_from is null or effective_from <= now())
    and (effective_to is null or effective_to > now());

  update ow.role_stepdowns
  set enactment_state = 'enacted'::ow.enactment_state,
      enacted_at_meeting_id = p_meeting_id,
      enacted_at = now(),
      enacted_by = uid,
      updated_at = now()
  where id = s.id;

  insert into ow.audit_log (actor_id, action, entity_type, entity_id, after_data)
  values (
    uid,
    'role_stepdown_enacted',
    'role',
    s.id,
    jsonb_build_object('meeting_id', p_meeting_id::text, 'role', s.role::text, 'requester', s.requested_by::text)
  );
end;
$$;

-- RLS for role_stepdowns: RG can read; RG can insert for self; RG can enact (update).
alter table ow.role_stepdowns enable row level security;

drop policy if exists role_stepdowns_select_rg on ow.role_stepdowns;
create policy role_stepdowns_select_rg
on ow.role_stepdowns for select
using (ow.has_any_rg_role(auth.uid()));

drop policy if exists role_stepdowns_insert_rg_self on ow.role_stepdowns;
create policy role_stepdowns_insert_rg_self
on ow.role_stepdowns for insert
with check (ow.has_any_rg_role(auth.uid()) and requested_by = auth.uid());

drop policy if exists role_stepdowns_update_rg on ow.role_stepdowns;
create policy role_stepdowns_update_rg
on ow.role_stepdowns for update
using (ow.has_any_rg_role(auth.uid()))
with check (ow.has_any_rg_role(auth.uid()));

commit;

