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
  with my_plots as (
    select distinct pp.plot_id
    from ow.plot_people pp
    where pp.profile_id = p_user_id
      and pp.is_active = true
      and pp.archived_at is null
  ),
  plot_to_group as (
    select p.id as plot_id, pgm.plot_group_id
    from ow.plots p
    left join ow.plot_group_memberships pgm
      on pgm.plot_id = p.id
     and pgm.archived_at is null
    where p.id in (select plot_id from my_plots)
      and p.archived_at is null
  ),
  participation_units as (
    -- Each participation unit is either a real plot_group_id OR an implicit singleton plot (when no group exists).
    select
      ptg.plot_id,
      ptg.plot_group_id,
      case
        when ptg.plot_group_id is null then 1::numeric
        else (select pg.voting_value::numeric from ow.plot_groups pg where pg.id = ptg.plot_group_id and pg.archived_at is null)
      end as unit_value
    from plot_to_group ptg
  ),
  eligible_people as (
    -- For grouped plots: eligible people across all plots in the group.
    -- For ungrouped plots: eligible people on that plot only.
    select
      u.plot_id,
      u.plot_group_id,
      pp.profile_id
    from participation_units u
    join ow.plot_people pp
      on (
        (u.plot_group_id is null and pp.plot_id = u.plot_id)
        or
        (u.plot_group_id is not null and pp.plot_id in (
          select pgm.plot_id
          from ow.plot_group_memberships pgm
          where pgm.plot_group_id = u.plot_group_id and pgm.archived_at is null
        ))
      )
    where pp.archived_at is null
      and pp.is_active = true
      and ow.is_active_member(pp.profile_id)
    group by u.plot_id, u.plot_group_id, pp.profile_id
  ),
  unit_counts as (
    select plot_id, plot_group_id, count(*)::numeric as cnt
    from eligible_people
    group by plot_id, plot_group_id
  )
  select
    case
      when not ow.is_active_member(p_user_id) then 0::numeric(10,6)
      else coalesce((
        select sum((u.unit_value / nullif(c.cnt, 0)))::numeric(10,6)
        from participation_units u
        join unit_counts c
          on c.plot_id = u.plot_id
         and (c.plot_group_id is not distinct from u.plot_group_id)
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

