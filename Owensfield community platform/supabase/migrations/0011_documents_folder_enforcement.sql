-- Owensfield Community Platform - Document folder enforcement + revision history + audit

begin;

-- Folder rules: RG can upload only to allowed folders.
create table if not exists ow.document_folder_rules (
  id uuid primary key default gen_random_uuid(),
  folder_id uuid not null unique references ow.document_folders(id),
  allow_rg_upload boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger document_folder_rules_set_updated_at
before update on ow.document_folder_rules
for each row execute function ow.set_updated_at();

create trigger document_folder_rules_prevent_delete
before delete on ow.document_folder_rules
for each row execute function ow.prevent_delete();

create or replace function ow.can_rg_upload_to_folder(p_user_id uuid, p_folder_id uuid)
returns boolean
language sql
stable
as $$
  select ow.has_any_rg_role(p_user_id)
     and exists (
       select 1
       from ow.document_folder_rules r
       where r.folder_id = p_folder_id
         and r.allow_rg_upload = true
         and r.archived_at is null
     )
$$;

-- Seed rule for the required "Governance Changes" folder: allow RG uploads so poll-close logging can insert.
insert into ow.document_folder_rules (folder_id, allow_rg_upload)
select ow.ensure_governance_changes_folder(), true
on conflict (folder_id) do update set
  allow_rg_upload = true,
  updated_at = now(),
  archived_at = null;

-- Revisions for documents (preserve history on edits/deletes).
create table if not exists ow.document_revisions (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references ow.documents(id),
  revision_no integer not null,
  snapshot jsonb not null,
  created_by uuid references ow.profiles(id),
  created_at timestamptz not null default now(),
  archived_at timestamptz,
  unique (document_id, revision_no)
);

create trigger document_revisions_prevent_delete
before delete on ow.document_revisions
for each row execute function ow.prevent_delete();

-- Capture revision + audit on any document update that is permitted.
create or replace function ow.capture_document_revision_and_audit()
returns trigger
language plpgsql
as $$
declare
  next_rev int;
begin
  -- Snapshot the previous state.
  select coalesce(max(revision_no), 0) + 1 into next_rev
  from ow.document_revisions
  where document_id = old.id;

  insert into ow.document_revisions (document_id, revision_no, snapshot, created_by)
  values (old.id, next_rev, to_jsonb(old), auth.uid());

  insert into ow.audit_log (actor_id, action, entity_type, entity_id, before_data, after_data)
  values (auth.uid(), 'document_updated', 'document', old.id, to_jsonb(old), to_jsonb(new));

  return new;
end;
$$;

drop trigger if exists documents_capture_revision on ow.documents;
create trigger documents_capture_revision
before update on ow.documents
for each row execute function ow.capture_document_revision_and_audit();

-- Strengthen insert policy to enforce folder rules.
drop policy if exists documents_insert_rg on ow.documents;
create policy documents_insert_rg
on ow.documents for insert
with check (
  uploaded_by = auth.uid()
  and ow.can_rg_upload_to_folder(auth.uid(), folder_id)
);

-- RLS for rules + revisions:
alter table ow.document_folder_rules enable row level security;
alter table ow.document_revisions enable row level security;

drop policy if exists document_folder_rules_select_rg on ow.document_folder_rules;
create policy document_folder_rules_select_rg
on ow.document_folder_rules for select
using (ow.has_any_rg_role(auth.uid()));

drop policy if exists document_folder_rules_write_elected_rg on ow.document_folder_rules;
create policy document_folder_rules_write_elected_rg
on ow.document_folder_rules for all
using (ow.has_elected_rg_role(auth.uid()))
with check (ow.has_elected_rg_role(auth.uid()));

drop policy if exists document_revisions_select_active on ow.document_revisions;
create policy document_revisions_select_active
on ow.document_revisions for select
using (ow.is_active_member(auth.uid()));

drop policy if exists document_revisions_select_rg on ow.document_revisions;
create policy document_revisions_select_rg
on ow.document_revisions for select
using (ow.has_any_rg_role(auth.uid()));

commit;

