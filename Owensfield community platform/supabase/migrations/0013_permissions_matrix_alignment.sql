-- Owensfield Community Platform - Align DB enforcement to PERMISSIONS_AND_FAILURES.md
-- Delta only: tighten elected-role requirements and 4-approval gates where required.

begin;

-- ------------------------------------------------------------
-- Helpers: elected checks in triggers
-- ------------------------------------------------------------

create or replace function ow.require_elected_rg()
returns void
language plpgsql
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if not ow.has_elected_rg_role(auth.uid()) then
    raise exception 'Elected RG role required';
  end if;
end;
$$;

-- ------------------------------------------------------------
-- Poll activation/close require elected + >=4 approvals
-- ------------------------------------------------------------

create or replace function ow.enforce_poll_activation_approvals()
returns trigger
language plpgsql
as $$
begin
  if old.state::text <> 'active' and new.state::text = 'active' then
    perform ow.require_elected_rg();
    if not ow.approval_is_satisfied('poll'::ow.approval_subject_type, new.id, 'activate') then
      raise exception 'Poll activation requires ≥4 RG approvals';
    end if;
  end if;
  return new;
end;
$$;

create or replace function ow.enforce_poll_close_approvals()
returns trigger
language plpgsql
as $$
begin
  if old.state::text <> 'closed' and new.state::text = 'closed' then
    perform ow.require_elected_rg();
    if not ow.approval_is_satisfied('poll'::ow.approval_subject_type, new.id, 'close') then
      raise exception 'Poll close requires ≥4 RG approvals';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists polls_enforce_activation_approvals on ow.polls;
create trigger polls_enforce_activation_approvals
before update on ow.polls
for each row execute function ow.enforce_poll_activation_approvals();

drop trigger if exists polls_enforce_close_approvals on ow.polls;
create trigger polls_enforce_close_approvals
before update on ow.polls
for each row execute function ow.enforce_poll_close_approvals();

-- ------------------------------------------------------------
-- Meetings: create/edit/approve are elected-only; approval requires ≥4 RG approvals
-- ------------------------------------------------------------

create or replace function ow.enforce_meeting_agenda_approval()
returns trigger
language plpgsql
as $$
begin
  if old.state::text <> 'archived' and new.state::text = 'archived' then
    perform ow.require_elected_rg();
    if not ow.approval_is_satisfied('meeting_agenda'::ow.approval_subject_type, new.id, 'approve') then
      raise exception 'Agenda approval requires ≥4 RG approvals';
    end if;
  end if;
  return new;
end;
$$;

create or replace function ow.enforce_meeting_minutes_approval()
returns trigger
language plpgsql
as $$
begin
  if old.state::text <> 'archived' and new.state::text = 'archived' then
    perform ow.require_elected_rg();
    if not ow.approval_is_satisfied('meeting_minutes'::ow.approval_subject_type, new.id, 'approve') then
      raise exception 'Minutes approval requires ≥4 RG approvals';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists meeting_agendas_enforce_approval on ow.meeting_agendas;
create trigger meeting_agendas_enforce_approval
before update on ow.meeting_agendas
for each row execute function ow.enforce_meeting_agenda_approval();

drop trigger if exists meeting_minutes_enforce_approval on ow.meeting_minutes;
create trigger meeting_minutes_enforce_approval
before update on ow.meeting_minutes
for each row execute function ow.enforce_meeting_minutes_approval();

-- RLS policy changes to match matrix:
-- Create meeting: elected RG only
drop policy if exists meetings_write_rg on ow.meetings;
create policy meetings_insert_elected_rg
on ow.meetings for insert
with check (ow.has_elected_rg_role(auth.uid()) and created_by = auth.uid());

-- Edit draft agenda/minutes: elected RG only
drop policy if exists meeting_agendas_update_rg on ow.meeting_agendas;
create policy meeting_agendas_update_elected_rg
on ow.meeting_agendas for update
using (ow.has_elected_rg_role(auth.uid()))
with check (ow.has_elected_rg_role(auth.uid()));

drop policy if exists meeting_minutes_update_rg on ow.meeting_minutes;
create policy meeting_minutes_update_elected_rg
on ow.meeting_minutes for update
using (ow.has_elected_rg_role(auth.uid()))
with check (ow.has_elected_rg_role(auth.uid()));

-- ------------------------------------------------------------
-- Actions: elected RG only for create/update/complete (state updates)
-- ------------------------------------------------------------

drop policy if exists actions_write_rg on ow.actions;
create policy actions_insert_elected_rg
on ow.actions for insert
with check (ow.has_elected_rg_role(auth.uid()) and created_by = auth.uid());

drop policy if exists actions_update_rg on ow.actions;
create policy actions_update_elected_rg
on ow.actions for update
using (ow.has_elected_rg_role(auth.uid()))
with check (ow.has_elected_rg_role(auth.uid()));

-- Action updates: elected RG only
alter table ow.action_updates enable row level security;
drop policy if exists action_updates_select_active on ow.action_updates;
create policy action_updates_select_active
on ow.action_updates for select
using (ow.is_active_member(auth.uid()));

drop policy if exists action_updates_insert_elected_rg on ow.action_updates;
create policy action_updates_insert_elected_rg
on ow.action_updates for insert
with check (ow.has_elected_rg_role(auth.uid()) and created_by = auth.uid());

drop policy if exists action_updates_update_none on ow.action_updates;
create policy action_updates_update_none
on ow.action_updates for update
using (false);

-- ------------------------------------------------------------
-- Communications: elected RG only for thread create/update and updates
-- ------------------------------------------------------------

drop policy if exists communication_threads_insert_rg on ow.communication_threads;
create policy communication_threads_insert_elected_rg
on ow.communication_threads for insert
with check (ow.has_elected_rg_role(auth.uid()) and created_by = auth.uid());

drop policy if exists communication_threads_update_rg on ow.communication_threads;
create policy communication_threads_update_elected_rg
on ow.communication_threads for update
using (ow.has_elected_rg_role(auth.uid()))
with check (ow.has_elected_rg_role(auth.uid()));

drop policy if exists communication_updates_insert_rg on ow.communication_updates;
create policy communication_updates_insert_elected_rg
on ow.communication_updates for insert
with check (ow.has_elected_rg_role(auth.uid()) and created_by = auth.uid());

-- ------------------------------------------------------------
-- Poll updates: only elected RG can activate/close (and any other updates)
-- ------------------------------------------------------------

drop policy if exists polls_update_rg on ow.polls;
create policy polls_update_elected_rg
on ow.polls for update
using (ow.has_elected_rg_role(auth.uid()))
with check (ow.has_elected_rg_role(auth.uid()));

-- ------------------------------------------------------------
-- Documents: elected RG only for upload and archived edits/deletes, folder-restricted
-- ------------------------------------------------------------

create or replace function ow.can_rg_upload_to_folder(p_user_id uuid, p_folder_id uuid)
returns boolean
language sql
stable
as $$
  select ow.has_elected_rg_role(p_user_id)
     and exists (
       select 1
       from ow.document_folder_rules r
       where r.folder_id = p_folder_id
         and r.allow_rg_upload = true
         and r.archived_at is null
     )
$$;

-- Document updates: elected RG only (approval trigger enforces ≥4 approvals for archived edits/deletes)
drop policy if exists documents_update_rg on ow.documents;
create policy documents_update_elected_rg
on ow.documents for update
using (ow.has_elected_rg_role(auth.uid()))
with check (ow.has_elected_rg_role(auth.uid()));

-- ------------------------------------------------------------
-- Finance: treasurer (elected) only for uploads
-- ------------------------------------------------------------

drop policy if exists finance_entries_insert_treasurer on ow.finance_entries;
create policy finance_entries_insert_treasurer
on ow.finance_entries for insert
with check (
  ow.is_active_member(auth.uid())
  and created_by = auth.uid()
  and ow.has_elected_rg_role(auth.uid())
  and 'treasurer' = any(ow.get_rg_roles(auth.uid()))
);

commit;

