-- Owensfield Community Platform - Supabase Auth bootstrap (profiles row creation)
-- This is minimal and does not implement UI flows; it ensures ow.profiles exists for authenticated users.

begin;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ow, public
as $$
begin
  insert into ow.profiles (id, email, display_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'display_name', ''))
  on conflict (id) do update set
    email = excluded.email,
    updated_at = now();

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

commit;

