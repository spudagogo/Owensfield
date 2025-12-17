-- Owensfield Community Platform - Annual report automation (day before AGM)
-- Uses pg_cron scheduled function. Retains old + regenerated reports.

begin;

create extension if not exists pg_cron;

alter table ow.annual_reports
  add column if not exists agm_scheduled_for timestamptz,
  add column if not exists is_current boolean not null default true;

-- Exactly one "current" report per AGM meeting schedule timestamp.
create unique index if not exists annual_reports_current_unique
on ow.annual_reports (meeting_id, agm_scheduled_for)
where is_current = true;

-- System generator (cron) - no auth.uid requirement.
create or replace function public.generate_annual_reports_due()
returns integer
language plpgsql
security definer
set search_path = ow, public
as $$
declare
  m record;
  created_count int := 0;
  payload_id uuid;
  cycle_id uuid;
begin
  cycle_id := ow.current_cycle_id();
  if cycle_id is null then
    return 0;
  end if;

  -- Generate for any AGM scheduled tomorrow (local DB date), if no current report exists for that scheduled_for.
  for m in
    select id, scheduled_for
    from ow.meetings
    where meeting_type = 'agm'::ow.meeting_type
      and archived_at is null
      and scheduled_for is not null
      and (scheduled_for::date = (current_date + 1))
  loop
    if not exists (
      select 1
      from ow.annual_reports r
      where r.meeting_id = m.id
        and r.agm_scheduled_for = m.scheduled_for
        and r.is_current = true
        and r.archived_at is null
    ) then
      -- Supersede any previous current reports for this AGM meeting.
      update ow.annual_reports
      set is_current = false,
          updated_at = now()
      where meeting_id = m.id
        and is_current = true
        and archived_at is null;

      insert into ow.annual_reports (meeting_id, cycle_id, content, needs_regeneration, agm_scheduled_for, is_current)
      values (
        m.id,
        cycle_id,
        jsonb_build_object('generated_for_meeting_id', m.id::text, 'generated_at', now()),
        false,
        m.scheduled_for,
        true
      )
      returning id into payload_id;

      insert into ow.audit_log (actor_id, action, entity_type, entity_id, after_data)
      values (null, 'annual_report_auto_generated', 'meeting', m.id, jsonb_build_object('report_id', payload_id::text));

      created_count := created_count + 1;
    end if;
  end loop;

  return created_count;
end;
$$;

-- Schedule daily run (idempotent).
do $$
declare
  existing int;
begin
  select jobid into existing
  from cron.job
  where jobname = 'ow_generate_annual_reports_due'
  limit 1;

  if existing is null then
    perform cron.schedule('ow_generate_annual_reports_due', '5 0 * * *', $$select public.generate_annual_reports_due();$$);
  end if;
end $$;

commit;

