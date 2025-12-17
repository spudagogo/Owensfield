-- Owensfield Community Platform - Authoritative voting weight computation (DB-side)

begin;

-- Votes must be immutable after cast.
drop trigger if exists poll_votes_prevent_update on ow.poll_votes;
create trigger poll_votes_prevent_update
before update on ow.poll_votes
for each row execute function ow.prevent_update();

-- Compute voting weight:
-- - Each plot group has voting_value (1 for single plot, 2 for joined plots)
-- - Weight is split equally among active registered people (owners + tenants) for that plot group
-- - Inactive members contribute zero
create or replace function ow.voting_weight_for_user(p_user_id uuid)
returns numeric(10,6)
language sql
stable
as $$
  with user_groups as (
    select distinct pgm.plot_group_id
    from ow.plot_people pp
    join ow.plots p on p.id = pp.plot_id
    join ow.plot_group_memberships pgm on pgm.plot_id = p.id
    where pp.profile_id = p_user_id
      and pp.is_active = true
      and pp.archived_at is null
      and p.archived_at is null
      and pgm.archived_at is null
  ),
  eligible_people as (
    -- All active members associated with any plot in the plot group (owners + tenants).
    select
      pgm.plot_group_id,
      pp.profile_id
    from ow.plot_group_memberships pgm
    join ow.plots p on p.id = pgm.plot_id
    join ow.plot_people pp on pp.plot_id = p.id
    where pgm.plot_group_id in (select plot_group_id from user_groups)
      and pgm.archived_at is null
      and p.archived_at is null
      and pp.archived_at is null
      and pp.is_active = true
      and ow.is_active_member(pp.profile_id)
    group by pgm.plot_group_id, pp.profile_id
  ),
  group_counts as (
    select plot_group_id, count(*)::numeric as cnt
    from eligible_people
    group by plot_group_id
  )
  select
    case
      when not ow.is_active_member(p_user_id) then 0::numeric(10,6)
      else coalesce((
        select sum((pg.voting_value::numeric / nullif(gc.cnt, 0)))::numeric(10,6)
        from user_groups ug
        join ow.plot_groups pg on pg.id = ug.plot_group_id
        join group_counts gc on gc.plot_group_id = ug.plot_group_id
      ), 0::numeric(10,6))
    end
$$;

-- Ensure vote weights are computed server-side and cannot be provided by client.
create or replace function ow.set_poll_vote_weight()
returns trigger
language plpgsql
as $$
begin
  new.weight := ow.voting_weight_for_user(new.voter_id);
  return new;
end;
$$;

drop trigger if exists poll_votes_set_weight on ow.poll_votes;
create trigger poll_votes_set_weight
before insert on ow.poll_votes
for each row execute function ow.set_poll_vote_weight();

commit;

