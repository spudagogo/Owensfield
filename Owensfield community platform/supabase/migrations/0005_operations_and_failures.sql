-- Owensfield Community Platform - Operational functions & failure-safe automation
-- Focus: spec-critical lifecycle automation and non-destructive admin actions.

begin;

-- ------------------------------------------------------------
-- Plots: mark unregistered on profile archival
-- ------------------------------------------------------------

alter table ow.plots
  add column if not exists is_registered boolean not null default true;

-- ------------------------------------------------------------
-- Actions: completed -> archived automatically
-- ------------------------------------------------------------

create or replace function ow.auto_archive_on_close()
returns trigger
language plpgsql
as $$
begin
  -- When an item is closed, automatically archive it (closed -> archived).
  if (to_jsonb(old) ? 'state') and old.state::text <> 'closed' and new.state::text = 'closed' then
    -- Update row to archived in-place.
    new.state := 'archived'::ow.lifecycle_state;
    new.archived_at := coalesce(new.archived_at, now());
    return new;
  end if;

  return new;
end;
$$;

-- Actions table uses lifecycle_state; auto-archive on close.
drop trigger if exists actions_auto_archive_on_close on ow.actions;
create trigger actions_auto_archive_on_close
before update on ow.actions
for each row execute function ow.auto_archive_on_close();

-- Communications: when closed, archive automatically (active -> closed -> archived is enforced elsewhere; here we map close to archived).
drop trigger if exists communication_threads_auto_archive_on_close on ow.communication_threads;
create trigger communication_threads_auto_archive_on_close
before update on ow.communication_threads
for each row execute function ow.auto_archive_on_close();

-- ------------------------------------------------------------
-- Poll tie / unresolved handling: ties become archived "unresolved"
-- ------------------------------------------------------------

create table if not exists ow.poll_unresolved (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null unique references ow.polls(id),
  reason text not null, -- e.g. "tie"
  created_at timestamptz not null default now()
);

create trigger poll_unresolved_prevent_delete
before delete on ow.poll_unresolved
for each row execute function ow.prevent_delete();

create or replace function ow.archive_poll_if_tied()
returns trigger
language plpgsql
as $$
begin
  -- When results are computed and tied, record unresolved and archive poll.
  if (new.outcome = 'tied') then
    insert into ow.poll_unresolved (poll_id, reason)
    values (new.poll_id, 'tie')
    on conflict (poll_id) do nothing;

    update ow.polls
    set state = 'archived'::ow.lifecycle_state,
        archived_at = coalesce(archived_at, now()),
        updated_at = now()
    where id = new.poll_id
      and state = 'closed'::ow.lifecycle_state;
  end if;

  return new;
end;
$$;

drop trigger if exists poll_results_on_tie_archive_poll on ow.poll_results;
create trigger poll_results_on_tie_archive_poll
after insert or update on ow.poll_results
for each row execute function ow.archive_poll_if_tied();

-- ------------------------------------------------------------
-- Annual report: regeneration-safe scaffolding
-- ------------------------------------------------------------

alter table ow.annual_reports
  add column if not exists needs_regeneration boolean not null default false;

create or replace function ow.flag_annual_report_regeneration()
returns trigger
language plpgsql
as $$
begin
  if new.meeting_type = 'agm'::ow.meeting_type and old.scheduled_for is distinct from new.scheduled_for then
    update ow.annual_reports
    set needs_regeneration = true,
        updated_at = now()
    where meeting_id = new.id
      and archived_at is null;
  end if;
  return new;
end;
$$;

drop trigger if exists meetings_flag_annual_report_regen on ow.meetings;
create trigger meetings_flag_annual_report_regen
after update on ow.meetings
for each row execute function ow.flag_annual_report_regeneration();

create or replace function public.generate_annual_report(p_agm_meeting_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ow, public
as $$
declare
  uid uuid;
  m ow.meetings;
  cycle_id uuid;
  payload jsonb;
  report_id uuid;
begin
  uid := auth.uid();
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if not ow.has_any_rg_role(uid) then
    raise exception 'RG role required';
  end if;

  select * into m from ow.meetings where id = p_agm_meeting_id;
  if m.id is null then
    raise exception 'AGM meeting not found';
  end if;
  if m.meeting_type <> 'agm'::ow.meeting_type then
    raise exception 'Meeting is not AGM';
  end if;

  cycle_id := ow.current_cycle_id();
  if cycle_id is null then
    raise exception 'No current membership cycle configured';
  end if;

  payload := jsonb_build_object(
    'generated_for_meeting_id', m.id::text,
    'cycle_id', cycle_id::text,
    'generated_at', now(),
    'polls', jsonb_build_object(
      'total', (select count(*) from ow.polls where archived_at is null),
      'closed', (select count(*) from ow.polls where state = 'closed'::ow.lifecycle_state and archived_at is null),
      'archived', (select count(*) from ow.polls where state = 'archived'::ow.lifecycle_state and archived_at is null)
    ),
    'actions', jsonb_build_object(
      'total', (select count(*) from ow.actions where archived_at is null),
      'archived', (select count(*) from ow.actions where archived_at is not null or state = 'archived'::ow.lifecycle_state)
    ),
    'finance', jsonb_build_object(
      'entries', (select count(*) from ow.finance_entries where archived_at is null)
    ),
    'membership', jsonb_build_object(
      'active_members', (select count(*) from ow.member_cycle_statuses where cycle_id = cycle_id and status = 'active'::ow.member_status and archived_at is null),
      'inactive_members', (select count(*) from ow.member_cycle_statuses where cycle_id = cycle_id and status = 'inactive'::ow.member_status and archived_at is null)
    )
  );

  insert into ow.annual_reports (meeting_id, cycle_id, content, needs_regeneration)
  values (m.id, cycle_id, payload, false)
  returning id into report_id;

  return report_id;
end;
$$;

-- ------------------------------------------------------------
-- Membership database admin actions (archive user, reassign owners)
-- ------------------------------------------------------------

create or replace function public.archive_user_profile(p_profile_id uuid, p_reason text default 'archive_user')
returns void
language plpgsql
security definer
set search_path = ow, public
as $$
declare
  uid uuid;
begin
  uid := auth.uid();
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if not ow.has_elected_rg_role(uid) then
    raise exception 'Elected RG role required';
  end if;

  update ow.profiles
  set archived_at = coalesce(archived_at, now()),
      updated_at = now()
  where id = p_profile_id;

  update ow.member_cycle_statuses
  set status = 'inactive'::ow.member_status,
      status_set_at = now(),
      status_set_by = uid,
      updated_at = now()
  where profile_id = p_profile_id
    and archived_at is null;

  -- Mark plots "unregistered" where this profile is an active owner.
  update ow.plots p
  set is_registered = false,
      updated_at = now()
  where exists (
    select 1
    from ow.plot_people pp
    where pp.plot_id = p.id
      and pp.profile_id = p_profile_id
      and pp.role = 'owner'::ow.plot_person_role
      and pp.is_active = true
      and pp.archived_at is null
  );

  insert into ow.audit_log (actor_id, action, entity_type, entity_id, after_data)
  values (uid, p_reason, 'profile', p_profile_id, jsonb_build_object('archived_at', now()));
end;
$$;

create or replace function public.reassign_plot_owner(p_plot_id uuid, p_old_owner_id uuid, p_new_owner_id uuid, p_reason text default 'reassign_plot_owner')
returns void
language plpgsql
security definer
set search_path = ow, public
as $$
declare
  uid uuid;
begin
  uid := auth.uid();
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if not ow.has_elected_rg_role(uid) then
    raise exception 'Elected RG role required';
  end if;

  -- Deactivate old owner record (soft).
  update ow.plot_people
  set is_active = false,
      updated_at = now()
  where plot_id = p_plot_id
    and profile_id = p_old_owner_id
    and role = 'owner'::ow.plot_person_role
    and archived_at is null;

  -- Upsert new owner record as active.
  insert into ow.plot_people (plot_id, profile_id, role, is_active)
  values (p_plot_id, p_new_owner_id, 'owner'::ow.plot_person_role, true)
  on conflict (plot_id, profile_id, role) do update set
    is_active = true,
    updated_at = now(),
    archived_at = null;

  update ow.plots set is_registered = true, updated_at = now() where id = p_plot_id;

  insert into ow.audit_log (actor_id, action, entity_type, entity_id, after_data)
  values (
    uid,
    p_reason,
    'plot',
    p_plot_id,
    jsonb_build_object('old_owner_id', p_old_owner_id::text, 'new_owner_id', p_new_owner_id::text)
  );
end;
$$;

commit;

