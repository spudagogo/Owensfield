-- Owensfield Community Platform - Join Plots (UPDATED)
-- - Elected RG can create plot groups
-- - Add 2+ plots per group (no hard limit)
-- - Plot belongs to only one group (enforced by unique plot_id in memberships)
-- - Voting value = plot count (computed)
-- - No unjoin/regrouping (no updates/deletes of memberships)
-- - All actions explicit and audited (RPCs + audit_log)

begin;

-- ------------------------------------------------------------
-- Remove any old "voting_value in (1,2)" constraint
-- ------------------------------------------------------------

do $$
declare
  c record;
begin
  for c in
    select conname
    from pg_constraint
    where conrelid = 'ow.plot_groups'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%voting_value%'
      and pg_get_constraintdef(oid) ilike '%(1, 2)%'
  loop
    execute format('alter table ow.plot_groups drop constraint %I', c.conname);
  end loop;
end $$;

alter table ow.plot_groups
  alter column voting_value set default 0;

-- ------------------------------------------------------------
-- No unjoin/regrouping: prevent updates (deletes are already prevented)
-- This blocks changing plot_id/plot_group_id and also blocks "archived_at" toggles.
-- ------------------------------------------------------------

drop trigger if exists plot_group_memberships_prevent_update on ow.plot_group_memberships;
create trigger plot_group_memberships_prevent_update
before update on ow.plot_group_memberships
for each row execute function ow.prevent_update();

-- ------------------------------------------------------------
-- Voting value computed as plot count in group (server-side)
-- ------------------------------------------------------------

create or replace function ow.recompute_plot_group_voting_value(p_plot_group_id uuid)
returns void
language plpgsql
as $$
declare
  cnt int;
begin
  select count(*)::int into cnt
  from ow.plot_group_memberships
  where plot_group_id = p_plot_group_id
    and archived_at is null;

  update ow.plot_groups
  set voting_value = cnt,
      updated_at = now()
  where id = p_plot_group_id
    and archived_at is null;
end;
$$;

create or replace function ow.on_plot_group_membership_inserted()
returns trigger
language plpgsql
as $$
begin
  perform ow.recompute_plot_group_voting_value(new.plot_group_id);
  return new;
end;
$$;

drop trigger if exists plot_group_memberships_recompute_value on ow.plot_group_memberships;
create trigger plot_group_memberships_recompute_value
after insert on ow.plot_group_memberships
for each row execute function ow.on_plot_group_membership_inserted();

-- ------------------------------------------------------------
-- Explicit, audited RPCs (elected RG only)
-- ------------------------------------------------------------

create or replace function public.create_plot_group(p_note text default null)
returns uuid
language plpgsql
security definer
set search_path = ow, public
as $$
declare
  uid uuid;
  gid uuid;
begin
  uid := auth.uid();
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if not ow.has_elected_rg_role(uid) then
    raise exception 'Elected RG role required';
  end if;

  insert into ow.plot_groups (voting_value) values (0) returning id into gid;

  insert into ow.audit_log (actor_id, action, entity_type, entity_id, after_data)
  values (uid, 'plot_group_created', 'plot_group', gid, jsonb_build_object('note', p_note));

  return gid;
end;
$$;

create or replace function public.add_plot_to_group(p_plot_id uuid, p_plot_group_id uuid, p_note text default null)
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

  -- Plot may belong to only one group: if membership exists, block (no regrouping).
  if exists (
    select 1
    from ow.plot_group_memberships m
    where m.plot_id = p_plot_id
      and m.archived_at is null
  ) then
    raise exception 'Plot is already assigned to a group';
  end if;

  insert into ow.plot_group_memberships (plot_id, plot_group_id)
  values (p_plot_id, p_plot_group_id);

  insert into ow.audit_log (actor_id, action, entity_type, entity_id, after_data)
  values (
    uid,
    'plot_added_to_group',
    'plot',
    p_plot_id,
    jsonb_build_object('plot_group_id', p_plot_group_id::text, 'note', p_note)
  );
end;
$$;

-- Elected-only group summary for display
create or replace function public.plot_group_summary()
returns table (
  plot_group_id uuid,
  plot_count int,
  voting_value int
)
language plpgsql
security definer
set search_path = ow, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if not ow.has_elected_rg_role(auth.uid()) then
    raise exception 'Elected RG role required';
  end if;

  return query
  select
    pg.id,
    count(pgm.plot_id)::int as plot_count,
    count(pgm.plot_id)::int as voting_value
  from ow.plot_groups pg
  left join ow.plot_group_memberships pgm
    on pgm.plot_group_id = pg.id
   and pgm.archived_at is null
  where pg.archived_at is null
  group by pg.id
  order by count(pgm.plot_id) desc, pg.id;
end;
$$;

commit;

