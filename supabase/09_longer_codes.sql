-- 09: Longer, harder-to-guess link codes. Safe to run more than once.
-- Save the date: 10 random characters (about 800 million million combinations).
-- Invitation: name + 10 random characters, e.g. "joan-winch-k7m2qx9pbt".
-- Only links that haven't been sent yet are changed; test households keep their codes.

create or replace function public.rand_code(n int) returns text
language plpgsql volatile set search_path = public as $$
declare c text := ''; abc text := 'abcdefghjkmnpqrstuvwxyz23456789';
begin
  for k in 1..n loop c := c || substr(abc, 1 + floor(random() * length(abc))::int, 1); end loop;
  return c;
end $$;

create or replace function public.new_std_code() returns text
language plpgsql volatile set search_path = public as $$
declare c text;
begin
  loop
    c := public.rand_code(10);
    exit when not exists (select 1 from public.invites where std_code = c);
  end loop;
  return c;
end $$;

create or replace function public.make_invite_code()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.code is null or new.code = '' then
    new.code := trim(both '-' from left(lower(regexp_replace(new.household_name, '[^a-zA-Z0-9]+', '-', 'g')), 20))
                || '-' || public.rand_code(10);
  end if;
  new.code := lower(new.code);
  return new;
end $$;

revoke all on function public.rand_code(int), public.new_std_code(), public.make_invite_code() from public, anon, authenticated;

-- Re-issue codes for links not sent yet
update public.invites set std_code = public.new_std_code()
 where std_sent_at is null and length(std_code) < 10;
update public.invites
   set code = trim(both '-' from left(lower(regexp_replace(household_name, '[^a-zA-Z0-9]+', '-', 'g')), 20)) || '-' || public.rand_code(10)
 where sent_at is null and code not like 'test%' and code !~ '-[a-z2-9]{10}$';
