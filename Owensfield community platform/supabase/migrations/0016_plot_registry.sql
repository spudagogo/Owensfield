-- Owensfield Community Platform - Plot Registry (RG elected-role admin)
-- Implements: plot metadata, elected-only plot CRUD (no deletes), owner assignment, join two plots, registry listing.

begin;

-- ------------------------------------------------------------
-- Plot metadata (address/label + notes) and default registration status
-- ------------------------------------------------------------

alter table ow.plots
  add column if not exists label text,
  add column if not exists notes text;

-- Ensure default status is unregistered for new plots (registry seeding requirement).
alter table ow.plots
  alter column is_registered set default false;

-- ------------------------------------------------------------
-- RLS: elected-only insert/update for plots and plot_people (admin tool)
-- ------------------------------------------------------------

alter table ow.plots enable row level security;
alter table ow.plot_people enable row level security;

drop policy if exists plots_insert_elected_rg on ow.plots;
create policy plots_insert_elected_rg
on ow.plots for insert
with check (ow.has_elected_rg_role(auth.uid()));

drop policy if exists plots_update_elected_rg on ow.plots;
create policy plots_update_elected_rg
on ow.plots for update
using (ow.has_elected_rg_role(auth.uid()))
with check (ow.has_elected_rg_role(auth.uid()));

drop policy if exists plot_people_insert_elected_rg on ow.plot_people;
create policy plot_people_insert_elected_rg
on ow.plot_people for insert
with check (ow.has_elected_rg_role(auth.uid()));

drop policy if exists plot_people_update_elected_rg on ow.plot_people;
create policy plot_people_update_elected_rg
on ow.plot_people for update
using (ow.has_elected_rg_role(auth.uid()))
with check (ow.has_elected_rg_role(auth.uid()));

-- ------------------------------------------------------------
-- Admin RPCs (explicit, audited, no deletes)
-- ------------------------------------------------------------

create or replace function public.create_plot(
  p_plot_code text,
  p_label text default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = ow, public
as $$
declare
  uid uuid;
  pid uuid;
begin
  uid := auth.uid();
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if not ow.has_elected_rg_role(uid) then
    raise exception 'Elected RG role required';
  end if;

  if p_plot_code is null or length(trim(p_plot_code)) = 0 then
    raise exception 'Plot ID is required';
  end if;

  insert into ow.plots (plot_code, label, notes, is_registered)
  values (trim(p_plot_code), p_label, p_notes, false)
  returning id into pid;

  insert into ow.audit_log (actor_id, action, entity_type, entity_id, after_data)
  values (uid, 'plot_created', 'plot', pid, jsonb_build_object('plot_code', trim(p_plot_code)));

  return pid;
end;
$$;

create or replace function public.update_plot_metadata(
  p_plot_id uuid,
  p_label text,
  p_notes text
)
returns void
language plpgsql
security definer
set search_path = ow, public
as $$
declare
  uid uuid;
  before_row jsonb;
  after_row jsonb;
begin
  uid := auth.uid();
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if not ow.has_elected_rg_role(uid) then
    raise exception 'Elected RG role required';
  end if;

  select to_jsonb(p) into before_row
  from ow.plots p
  where p.id = p_plot_id;

  update ow.plots
  set label = p_label,
      notes = p_notes,
      updated_at = now()
  where id = p_plot_id;

  select to_jsonb(p) into after_row
  from ow.plots p
  where p.id = p_plot_id;

  insert into ow.audit_log (actor_id, action, entity_type, entity_id, before_data, after_data)
  values (uid, 'plot_updated', 'plot', p_plot_id, before_row, after_row);
end;
$$;

create or replace function public.add_plot_owner(
  p_plot_id uuid,
  p_owner_profile_id uuid,
  p_note text default null
)
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

  insert into ow.plot_people (plot_id, profile_id, role, is_active)
  values (p_plot_id, p_owner_profile_id, 'owner'::ow.plot_person_role, true)
  on conflict (plot_id, profile_id, role) do update set
    is_active = true,
    updated_at = now(),
    archived_at = null;

  insert into ow.audit_log (actor_id, action, entity_type, entity_id, after_data)
  values (
    uid,
    'plot_owner_added',
    'plot',
    p_plot_id,
    jsonb_build_object('owner_profile_id', p_owner_profile_id::text, 'note', p_note)
  );
end;
$$;

-- Join exactly two plots: creates a new group and assigns both plots.
-- This is explicit and does not unassign existing group memberships.
create or replace function public.join_two_plots(
  p_plot_id_a uuid,
  p_plot_id_b uuid,
  p_note text default null
)
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

  if p_plot_id_a = p_plot_id_b then
    raise exception 'Plots must be different';
  end if;

  -- Must not already belong to any group (prevents regrouping/unjoining automation).
  if exists (select 1 from ow.plot_group_memberships where plot_id in (p_plot_id_a, p_plot_id_b) and archived_at is null) then
    raise exception 'One or both plots are already assigned to a group';
  end if;

  insert into ow.plot_groups (voting_value) values (2) returning id into gid;
  insert into ow.plot_group_memberships (plot_id, plot_group_id) values (p_plot_id_a, gid);
  insert into ow.plot_group_memberships (plot_id, plot_group_id) values (p_plot_id_b, gid);

  -- Record join assignment (explicit, by elected RG).
  insert into ow.plot_joins (plot_group_id, assigned_by, assigned_at, note)
  values (gid, uid, now(), p_note);

  insert into ow.audit_log (actor_id, action, entity_type, entity_id, after_data)
  values (
    uid,
    'plots_joined',
    'plot_group',
    gid,
    jsonb_build_object('plot_id_a', p_plot_id_a::text, 'plot_id_b', p_plot_id_b::text, 'note', p_note)
  );

  return gid;
end;
$$;

-- ------------------------------------------------------------
-- Registry listing RPC: elected-only, returns required display fields
-- ------------------------------------------------------------

create or replace function public.plot_registry()
returns table (
  plot_id uuid,
  plot_code text,
  label text,
  notes text,
  is_registered boolean,
  plot_group_id uuid,
  group_plot_count integer,
  computed_voting_value integer,
  owners jsonb,
  tenants jsonb,
  updated_at timestamptz
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
  with plot_group as (
    select pgm.plot_id, pgm.plot_group_id
    from ow.plot_group_memberships pgm
    where pgm.archived_at is null
  ),
  group_counts as (
    select pgm.plot_group_id, count(*)::int as plot_count
    from ow.plot_group_memberships pgm
    where pgm.archived_at is null
    group by pgm.plot_group_id
  ),
  people as (
    select
      pp.plot_id,
      pp.role::text as role,
      pr.id as profile_id,
      pr.display_name,
      ow.get_member_status(pr.id)::text as member_status
    from ow.plot_people pp
    join ow.profiles pr on pr.id = pp.profile_id
    where pp.archived_at is null
      and pp.is_active = true
  ),
  owners_agg as (
    select
      plot_id,
      jsonb_agg(jsonb_build_object('profile_id', profile_id, 'name', display_name, 'member_status', member_status)
        order by display_name) as owners
    from people
    where role = 'owner'
    group by plot_id
  ),
  tenants_agg as (
    select
      plot_id,
      jsonb_agg(jsonb_build_object('profile_id', profile_id, 'name', display_name, 'member_status', member_status)
        order by display_name) as tenants
    from people
    where role = 'tenant'
    group by plot_id
  )
  select
    p.id as plot_id,
    p.plot_code,
    p.label,
    p.notes,
    p.is_registered,
    pg.plot_group_id,
    coalesce(gc.plot_count, 0) as group_plot_count,
    case when pg.plot_group_id is null then 1 else coalesce(gc.plot_count, 1) end as computed_voting_value,
    coalesce(oa.owners, '[]'::jsonb) as owners,
    coalesce(ta.tenants, '[]'::jsonb) as tenants,
    p.updated_at
  from ow.plots p
  left join plot_group pg on pg.plot_id = p.id
  left join group_counts gc on gc.plot_group_id = pg.plot_group_id
  left join owners_agg oa on oa.plot_id = p.id
  left join tenants_agg ta on ta.plot_id = p.id
  where p.archived_at is null
  order by p.plot_code;
end;
$$;

commit;

