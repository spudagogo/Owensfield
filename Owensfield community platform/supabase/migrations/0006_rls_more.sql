-- Owensfield Community Platform - Additional RLS for new tables

begin;

alter table ow.poll_unresolved enable row level security;

drop policy if exists poll_unresolved_select_active on ow.poll_unresolved;
create policy poll_unresolved_select_active
on ow.poll_unresolved for select
using (ow.is_active_member(auth.uid()));

drop policy if exists poll_unresolved_select_rg on ow.poll_unresolved;
create policy poll_unresolved_select_rg
on ow.poll_unresolved for select
using (ow.has_any_rg_role(auth.uid()));

commit;

