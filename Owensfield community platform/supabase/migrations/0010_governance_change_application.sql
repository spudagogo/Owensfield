-- Owensfield Community Platform - Governance change application + document logging (transactional on poll close)

begin;

-- Governance settings (current values) + immutable change log.
create table if not exists ow.governance_settings (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  value jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger governance_settings_set_updated_at
before update on ow.governance_settings
for each row execute function ow.set_updated_at();

create trigger governance_settings_prevent_delete
before delete on ow.governance_settings
for each row execute function ow.prevent_delete();

create table if not exists ow.governance_changes (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references ow.polls(id),
  key text not null,
  old_value jsonb,
  new_value jsonb not null,
  effective_at timestamptz not null default now(),
  document_id uuid references ow.documents(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger governance_changes_set_updated_at
before update on ow.governance_changes
for each row execute function ow.set_updated_at();

create trigger governance_changes_prevent_delete
before delete on ow.governance_changes
for each row execute function ow.prevent_delete();

-- Poll -> governance change proposals (must exist for governance change application)
create table if not exists ow.poll_governance_proposals (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references ow.polls(id),
  key text not null,
  proposed_value jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  unique (poll_id, key)
);

create trigger poll_governance_proposals_set_updated_at
before update on ow.poll_governance_proposals
for each row execute function ow.set_updated_at();

create trigger poll_governance_proposals_prevent_delete
before delete on ow.poll_governance_proposals
for each row execute function ow.prevent_delete();

-- Documents metadata (to embed change log in archived "document" rows)
alter table ow.documents
  add column if not exists metadata jsonb not null default '{}'::jsonb;

-- Ensure folder for governance change docs exists (seed-only; required by spec).
create or replace function ow.ensure_governance_changes_folder()
returns uuid
language plpgsql
security definer
set search_path = ow, public
as $$
declare
  folder_id uuid;
begin
  select id into folder_id
  from ow.document_folders
  where parent_id is null
    and name = 'Governance Changes'
    and archived_at is null
  limit 1;

  if folder_id is null then
    insert into ow.document_folders (name, parent_id)
    values ('Governance Changes', null)
    returning id into folder_id;
  end if;

  return folder_id;
end;
$$;

-- Apply governance changes transactionally at poll close (only if passed).
create or replace function ow.apply_governance_changes_for_poll(p_poll_id uuid)
returns void
language plpgsql
security definer
set search_path = ow, public
as $$
declare
  uid uuid;
  r ow.poll_results;
  folder_id uuid;
  doc_id uuid;
  payload jsonb;
begin
  uid := auth.uid();
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if not ow.has_any_rg_role(uid) then
    raise exception 'RG role required to close poll / apply governance change';
  end if;

  select * into r from ow.poll_results where poll_id = p_poll_id and archived_at is null;
  if r.id is null then
    raise exception 'Poll results not computed';
  end if;
  if r.outcome <> 'passed' then
    return;
  end if;

  folder_id := ow.ensure_governance_changes_folder();

  -- Create an archived "document" representing this governance change record.
  payload := jsonb_build_object(
    'poll_id', p_poll_id::text,
    'effective_at', now(),
    'changes', (
      select jsonb_agg(jsonb_build_object('key', key, 'proposed_value', proposed_value))
      from ow.poll_governance_proposals
      where poll_id = p_poll_id and archived_at is null
    )
  );

  insert into ow.documents (folder_id, title, state, uploaded_by, uploaded_at, metadata)
  values (
    folder_id,
    'Governance change (Poll ' || p_poll_id::text || ')',
    'archived'::ow.lifecycle_state,
    uid,
    now(),
    payload
  )
  returning id into doc_id;

  -- Apply each proposal to governance_settings and log a governance_change row.
  insert into ow.governance_changes (poll_id, key, old_value, new_value, effective_at, document_id)
  select
    p_poll_id,
    p.key,
    (select s.value from ow.governance_settings s where s.key = p.key and s.archived_at is null),
    p.proposed_value,
    now(),
    doc_id
  from ow.poll_governance_proposals p
  where p.poll_id = p_poll_id
    and p.archived_at is null;

  -- Upsert current settings.
  insert into ow.governance_settings (key, value)
  select p.key, p.proposed_value
  from ow.poll_governance_proposals p
  where p.poll_id = p_poll_id and p.archived_at is null
  on conflict (key) do update set
    value = excluded.value,
    updated_at = now();

  insert into ow.audit_log (actor_id, action, entity_type, entity_id, after_data)
  values (
    uid,
    'governance_change_applied',
    'poll',
    p_poll_id,
    jsonb_build_object('document_id', doc_id::text)
  );
end;
$$;

-- Replace poll close handler to compute results AND apply governance changes in one transaction.
create or replace function ow.on_poll_closed()
returns trigger
language plpgsql
as $$
declare
  result_row ow.poll_results;
begin
  if old.state::text <> 'closed' and new.state::text = 'closed' then
    result_row := ow.compute_poll_result(new.id);
    -- Tie handling is handled by poll_results trigger (baseline behavior).
    perform ow.apply_governance_changes_for_poll(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists polls_on_closed_compute_result on ow.polls;
create trigger polls_on_closed_compute_result
after update on ow.polls
for each row execute function ow.on_poll_closed();

-- RLS enable + minimal policies (active members read, RG write).
alter table ow.governance_settings enable row level security;
alter table ow.governance_changes enable row level security;
alter table ow.poll_governance_proposals enable row level security;

drop policy if exists governance_settings_select_active on ow.governance_settings;
create policy governance_settings_select_active
on ow.governance_settings for select
using (ow.is_active_member(auth.uid()));

drop policy if exists governance_settings_write_rg on ow.governance_settings;
create policy governance_settings_write_rg
on ow.governance_settings for insert
with check (ow.has_any_rg_role(auth.uid()));

drop policy if exists governance_changes_select_active on ow.governance_changes;
create policy governance_changes_select_active
on ow.governance_changes for select
using (ow.is_active_member(auth.uid()));

drop policy if exists governance_changes_select_rg on ow.governance_changes;
create policy governance_changes_select_rg
on ow.governance_changes for select
using (ow.has_any_rg_role(auth.uid()));

drop policy if exists poll_governance_proposals_select_rg on ow.poll_governance_proposals;
create policy poll_governance_proposals_select_rg
on ow.poll_governance_proposals for select
using (ow.has_any_rg_role(auth.uid()));

drop policy if exists poll_governance_proposals_write_rg on ow.poll_governance_proposals;
create policy poll_governance_proposals_write_rg
on ow.poll_governance_proposals for insert
with check (ow.has_any_rg_role(auth.uid()));

commit;

