-- Owensfield Community Platform - Remaining PERMISSIONS_AND_FAILURES alignment
-- Focus: membership DB actions + enforce elected for governance-change application.

begin;

-- ------------------------------------------------------------
-- Membership DB: elected RG can edit profiles (server-side via RLS)
-- ------------------------------------------------------------

drop policy if exists profiles_update_elected_rg on ow.profiles;
create policy profiles_update_elected_rg
on ow.profiles for update
using (ow.has_elected_rg_role(auth.uid()))
with check (ow.has_elected_rg_role(auth.uid()));

-- ------------------------------------------------------------
-- Audit helper for server actions (security definer; elected-only)
-- ------------------------------------------------------------

create or replace function public.log_audit_event(
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_after jsonb default null
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

  insert into ow.audit_log (actor_id, action, entity_type, entity_id, after_data)
  values (uid, p_action, p_entity_type, p_entity_id, coalesce(p_after, '{}'::jsonb));
end;
$$;

-- ------------------------------------------------------------
-- Governance change application must be elected-RG only (matrix: close poll is elected)
-- ------------------------------------------------------------

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
  if not ow.has_elected_rg_role(uid) then
    raise exception 'Elected RG role required to apply governance change';
  end if;

  select * into r from ow.poll_results where poll_id = p_poll_id and archived_at is null;
  if r.id is null then
    raise exception 'Poll results not computed';
  end if;
  if r.outcome <> 'passed' then
    return;
  end if;

  folder_id := ow.ensure_governance_changes_folder();

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

commit;

