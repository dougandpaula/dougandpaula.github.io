-- Paula & Doug wedding: database setup (v2). Safe to run more than once.

-- 1. Tables ---------------------------------------------------------------
create table if not exists public.invites (
  id uuid primary key default gen_random_uuid(),
  household_name text not null,
  code text unique,
  invite_type text not null default 'garden' check (invite_type in ('ceremony','garden')),
  plus_one_allowed boolean not null default false,
  message text,
  responded_at timestamptz,
  first_opened_at timestamptz,
  last_opened_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.invites add column if not exists category text;
alter table public.invites add column if not exists priority text;
alter table public.invites add column if not exists notes text;
alter table public.invites add column if not exists sent_at timestamptz;
alter table public.invites add column if not exists list_order int;
alter table public.invites add column if not exists sent_by text;
alter table public.invites add column if not exists main_contact uuid;
alter table public.invites add column if not exists send_method text not null default 'whatsapp';
alter table public.invites add column if not exists address text;

create table if not exists public.guests (
  id uuid primary key default gen_random_uuid(),
  invite_id uuid not null references public.invites(id) on delete cascade,
  name text not null,
  is_plus_one boolean not null default false,
  attending boolean,
  dietary text,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
alter table public.guests add column if not exists age_group text not null default 'adult';
alter table public.guests add column if not exists age int;
alter table public.guests add column if not exists phone text;
alter table public.guests drop constraint if exists guests_age_group_check;
alter table public.guests add constraint guests_age_group_check check (age_group in ('adult','teen','child'));

create table if not exists public.settings (key text primary key, value text);
create table if not exists public.admins (email text primary key);

alter table public.invites enable row level security;
alter table public.guests enable row level security;
alter table public.settings enable row level security;
alter table public.admins enable row level security;
revoke all on public.invites, public.guests, public.settings, public.admins from anon, authenticated;

-- 2. Admin access (only emails in the admins table, once logged in) ---------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins
                 where email = lower(coalesce(auth.jwt()->>'email', '')))
$$;

grant select, insert, update, delete on public.invites, public.guests, public.settings to authenticated;
drop policy if exists admin_all on public.invites;
drop policy if exists admin_all on public.guests;
drop policy if exists admin_all on public.settings;
create policy admin_all on public.invites for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy admin_all on public.guests for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy admin_all on public.settings for all to authenticated using (public.is_admin()) with check (public.is_admin());

insert into public.admins (email) values ('dougandpaulawinch@gmail.com') on conflict do nothing;

-- 3. Personal link codes, e.g. "joan-winch-7k2q9" ---------------------------
create or replace function public.make_invite_code()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.code is null or new.code = '' then
    new.code := trim(both '-' from left(lower(regexp_replace(new.household_name, '[^a-zA-Z0-9]+', '-', 'g')), 20))
                || '-' || left(md5(gen_random_uuid()::text), 5);
  end if;
  new.code := lower(new.code);
  return new;
end $$;

drop trigger if exists invites_code on public.invites;
create trigger invites_code before insert on public.invites
for each row execute function public.make_invite_code();

-- 4. What the guest page is allowed to call ---------------------------------
create or replace function public.get_invite(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.invites;
begin
  update public.invites
     set first_opened_at = coalesce(first_opened_at, now()), last_opened_at = now()
   where code = lower(trim(p_code))
  returning * into v;
  if v.id is null then return null; end if;
  return jsonb_build_object(
    'household', v.household_name,
    'type', v.invite_type,
    'plus_one_allowed', v.plus_one_allowed,
    'message', v.message,
    'responded_at', v.responded_at,
    'guests', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', g.id, 'name', g.name, 'is_plus_one', g.is_plus_one,
               'attending', g.attending, 'dietary', g.dietary,
               'age_group', g.age_group, 'age', g.age)
             order by g.is_plus_one, g.sort_order, g.created_at)
      from public.guests g where g.invite_id = v.id), '[]'::jsonb),
    'gift', (select jsonb_object_agg(key, value) from public.settings where key like 'gift_%')
  );
end $$;

create or replace function public.submit_rsvp(p_code text, p_guests jsonb, p_plus_one jsonb, p_message text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.invites; r jsonb; pname text; a int;
begin
  select * into v from public.invites where code = lower(trim(p_code));
  if v.id is null then raise exception 'Invite not found'; end if;

  for r in select * from jsonb_array_elements(coalesce(p_guests, '[]'::jsonb)) loop
    a := case when coalesce(r->>'age', '') ~ '^[0-9]{1,2}$' then (r->>'age')::int end;
    update public.guests
       set attending = (r->>'attending')::boolean,
           dietary = left(nullif(trim(r->>'dietary'), ''), 300),
           age = case when age_group = 'adult' then age else coalesce(a, age) end
     where id = (r->>'id')::uuid and invite_id = v.id and not is_plus_one;
  end loop;

  if v.plus_one_allowed then
    pname := left(nullif(trim(p_plus_one->>'name'), ''), 80);
    if pname is null then
      delete from public.guests where invite_id = v.id and is_plus_one;
    elsif exists (select 1 from public.guests where invite_id = v.id and is_plus_one) then
      update public.guests set name = pname, attending = true,
             dietary = left(nullif(trim(p_plus_one->>'dietary'), ''), 300)
       where invite_id = v.id and is_plus_one;
    else
      insert into public.guests (invite_id, name, is_plus_one, attending, dietary, sort_order)
      values (v.id, pname, true, true, left(nullif(trim(p_plus_one->>'dietary'), ''), 300), 99);
    end if;
  end if;

  update public.invites set message = left(nullif(trim(p_message), ''), 1000), responded_at = now()
   where id = v.id;
  return public.get_invite(p_code);
end $$;

create or replace function public.ping() returns text language sql as $$ select 'ok' $$;

revoke all on function public.get_invite(text), public.submit_rsvp(text, jsonb, jsonb, text),
  public.ping(), public.make_invite_code(), public.is_admin() from public, anon, authenticated;
grant execute on function public.get_invite(text), public.submit_rsvp(text, jsonb, jsonb, text),
  public.ping() to anon, authenticated;
grant execute on function public.is_admin() to authenticated;

-- 5. Overviews for you (admins only) ----------------------------------------
drop view if exists public.rsvp_overview;
drop view if exists public.invite_links;

create view public.rsvp_overview with (security_invoker = true) as
select i.priority, i.household_name, i.invite_type, i.category, g.name, g.age_group, g.age,
       case when g.is_plus_one then 'Yes' else '' end as plus_one,
       case g.attending when true then 'Coming' when false then 'Not coming' else 'No reply' end as status,
       g.dietary, i.message, i.responded_at, i.first_opened_at,
       'https://dougandpaula.github.io/?g=' || i.code as link
from public.invites i left join public.guests g on g.invite_id = i.id
order by i.priority, i.household_name, g.is_plus_one, g.sort_order;

create view public.invite_links with (security_invoker = true) as
select i.priority, i.household_name, i.invite_type, i.plus_one_allowed,
       (select count(*) from public.guests g where g.invite_id = i.id and not g.is_plus_one) as people,
       case when i.responded_at is not null then 'Replied'
            when i.first_opened_at is not null then 'Opened, no reply'
            else 'Not opened' end as progress,
       'https://dougandpaula.github.io/?g=' || i.code as link
from public.invites i order by i.priority, i.household_name;

revoke all on public.rsvp_overview, public.invite_links from anon;
grant select on public.rsvp_overview, public.invite_links to authenticated;

-- 6. Admin page functions (refuse anyone not in the admins table) ------------
create or replace function public.admin_check() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not authorised' using errcode = '42501'; end if;
end $$;

create or replace function public.admin_invite_json(p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(i) || jsonb_build_object('guests', coalesce((
           select jsonb_agg(to_jsonb(g) order by g.is_plus_one, g.sort_order, g.created_at)
           from public.guests g where g.invite_id = i.id), '[]'::jsonb))
  from public.invites i where i.id = p_id
$$;

create or replace function public.admin_data() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  return jsonb_build_object(
    'invites', coalesce((select jsonb_agg(public.admin_invite_json(id)
                 order by case when priority ~ '^[0-9.]+$' then priority::numeric else 999 end, household_name)
               from public.invites), '[]'::jsonb),
    'settings', coalesce((select jsonb_object_agg(key, value) from public.settings), '{}'::jsonb));
end $$;

create or replace function public.admin_save_invite(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare iid uuid := nullif(p->>'id', '')::uuid; g jsonb; keep uuid[] := '{}'; gid uuid; n int := 0;
begin
  perform public.admin_check();
  if iid is null then
    insert into public.invites (household_name, priority, invite_type, category, plus_one_allowed, notes, sent_by, send_method, address, list_order)
    values (p->>'household_name', nullif(p->>'priority', ''), coalesce(p->>'invite_type', 'garden'),
            nullif(p->>'category', ''), coalesce((p->>'plus_one_allowed')::boolean, false), nullif(p->>'notes', ''),
            nullif(p->>'sent_by', ''), coalesce(nullif(p->>'send_method', ''), 'whatsapp'), nullif(p->>'address', ''),
            (select coalesce(max(list_order), 0) + 1 from public.invites))
    returning id into iid;
  else
    update public.invites set household_name = p->>'household_name', priority = nullif(p->>'priority', ''),
           invite_type = p->>'invite_type', category = nullif(p->>'category', ''),
           plus_one_allowed = (p->>'plus_one_allowed')::boolean, notes = nullif(p->>'notes', ''),
           sent_by = nullif(p->>'sent_by', ''),
           main_contact = case when p ? 'main_contact' then nullif(p->>'main_contact', '')::uuid else main_contact end,
           send_method = coalesce(nullif(p->>'send_method', ''), send_method),
           address = case when p ? 'address' then nullif(p->>'address', '') else address end
     where id = iid;
  end if;
  for g in select * from jsonb_array_elements(coalesce(p->'guests', '[]'::jsonb)) loop
    n := n + 1;
    gid := nullif(g->>'id', '')::uuid;
    if gid is null then
      insert into public.guests (invite_id, name, is_plus_one, age_group, age, attending, dietary, phone, sort_order)
      values (iid, g->>'name', coalesce((g->>'is_plus_one')::boolean, false), coalesce(g->>'age_group', 'adult'),
              nullif(g->>'age', '')::int, (g->>'attending')::boolean, nullif(g->>'dietary', ''), nullif(g->>'phone', ''),
              case when (g->>'is_plus_one')::boolean then 99 else n end)
      returning id into gid;
    else
      update public.guests set name = g->>'name', age_group = coalesce(g->>'age_group', 'adult'),
             age = nullif(g->>'age', '')::int, attending = (g->>'attending')::boolean,
             dietary = nullif(g->>'dietary', ''), phone = nullif(g->>'phone', ''),
             sort_order = case when is_plus_one then 99 else n end
       where id = gid and invite_id = iid;
    end if;
    keep := keep || gid;
  end loop;
  delete from public.guests where invite_id = iid and not (id = any(keep));
  return public.admin_invite_json(iid);
end $$;

create or replace function public.admin_delete_invite(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  delete from public.invites where id = p_id;
end $$;

create or replace function public.admin_mark_sent(p_id uuid, p_sent boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  update public.invites set sent_at = case when p_sent then coalesce(sent_at, now()) end where id = p_id;
  return public.admin_invite_json(p_id);
end $$;

create or replace function public.admin_save_settings(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare k text;
begin
  perform public.admin_check();
  for k in select jsonb_object_keys(p) loop
    insert into public.settings (key, value) values (k, p->>k)
    on conflict (key) do update set value = excluded.value;
  end loop;
end $$;

create or replace function public.admin_reorder(p_ids uuid[], p_id uuid, p_priority text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  update public.invites i set list_order = x.ord from unnest(p_ids) with ordinality as x(id, ord) where i.id = x.id;
  update public.invites set priority = nullif(p_priority, '') where id = p_id;
end $$;

revoke all on function public.admin_reorder(uuid[], uuid, text) from public, anon, authenticated;
grant execute on function public.admin_reorder(uuid[], uuid, text) to authenticated;

revoke all on function public.admin_check(), public.admin_invite_json(uuid), public.admin_data(),
  public.admin_save_invite(jsonb), public.admin_delete_invite(uuid), public.admin_mark_sent(uuid, boolean),
  public.admin_save_settings(jsonb) from public, anon, authenticated;
grant execute on function public.admin_data(), public.admin_save_invite(jsonb), public.admin_delete_invite(uuid),
  public.admin_mark_sent(uuid, boolean), public.admin_save_settings(jsonb) to authenticated;

-- 7. Gift details (edit later on the admin page) ----------------------------
insert into public.settings (key, value) values
  ('gift_account_name', '[ACCOUNT NAME]'),
  ('gift_sort_code', '[00-00-00]'),
  ('gift_account_number', '[00000000]')
on conflict (key) do nothing;


-- 8. RSVP log + allergy checkbox (same as 06_rsvp_log.sql) -----------------

-- 1. Log table: one row per RSVP submission, never overwritten -------------
create table if not exists public.rsvp_log (
  id uuid primary key default gen_random_uuid(),
  invite_id uuid references public.invites(id) on delete set null,
  household text,
  submitted_at timestamptz not null default now(),
  confirmed boolean not null default false,
  confirm_text text,
  answers jsonb not null
);
create index if not exists rsvp_log_invite on public.rsvp_log (invite_id, submitted_at desc);
alter table public.rsvp_log enable row level security;
revoke all on public.rsvp_log from anon, authenticated;
grant select on public.rsvp_log to authenticated;
drop policy if exists admin_read on public.rsvp_log;
create policy admin_read on public.rsvp_log for select to authenticated using (public.is_admin());

-- 2. Placeholder wording (edit on the admin page) ---------------------------
insert into public.settings (key, value) values
  ('rsvp_allergy_text', 'We have told you about any allergies or dietary needs for everyone in our party, including any plus one.')
on conflict (key) do nothing;

-- 3. Guest page gets the wording --------------------------------------------
create or replace function public.get_invite(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.invites;
begin
  update public.invites
     set first_opened_at = coalesce(first_opened_at, now()), last_opened_at = now()
   where code = lower(trim(p_code))
  returning * into v;
  if v.id is null then return null; end if;
  return jsonb_build_object(
    'household', v.household_name,
    'type', v.invite_type,
    'plus_one_allowed', v.plus_one_allowed,
    'message', v.message,
    'responded_at', v.responded_at,
    'guests', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', g.id, 'name', g.name, 'is_plus_one', g.is_plus_one,
               'attending', g.attending, 'dietary', g.dietary,
               'age_group', g.age_group, 'age', g.age)
             order by g.is_plus_one, g.sort_order, g.created_at)
      from public.guests g where g.invite_id = v.id), '[]'::jsonb),
    'gift', (select jsonb_object_agg(key, value) from public.settings where key like 'gift_%'),
    'allergy_text', (select value from public.settings where key = 'rsvp_allergy_text')
  );
end $$;

-- 4. Submit: requires the box when anyone is coming, and logs every submission
drop function if exists public.submit_rsvp(text, jsonb, jsonb, text);
create or replace function public.submit_rsvp(p_code text, p_guests jsonb, p_plus_one jsonb, p_message text, p_confirmed boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.invites; r jsonb; pname text; a int; anyone boolean;
begin
  select * into v from public.invites where code = lower(trim(p_code));
  if v.id is null then raise exception 'Invite not found'; end if;

  select coalesce(bool_or((x->>'attending')::boolean), false) into anyone
    from jsonb_array_elements(coalesce(p_guests, '[]'::jsonb)) x;
  if anyone and not coalesce(p_confirmed, false) then
    raise exception 'Please tick the allergies box';
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_guests, '[]'::jsonb)) loop
    a := case when coalesce(r->>'age', '') ~ '^[0-9]{1,2}$' then (r->>'age')::int end;
    update public.guests
       set attending = (r->>'attending')::boolean,
           dietary = left(nullif(trim(r->>'dietary'), ''), 300),
           age = case when age_group = 'adult' then age else coalesce(a, age) end
     where id = (r->>'id')::uuid and invite_id = v.id and not is_plus_one;
  end loop;

  if v.plus_one_allowed then
    pname := left(nullif(trim(p_plus_one->>'name'), ''), 80);
    if pname is null then
      delete from public.guests where invite_id = v.id and is_plus_one;
    elsif exists (select 1 from public.guests where invite_id = v.id and is_plus_one) then
      update public.guests set name = pname, attending = true,
             dietary = left(nullif(trim(p_plus_one->>'dietary'), ''), 300)
       where invite_id = v.id and is_plus_one;
    else
      insert into public.guests (invite_id, name, is_plus_one, attending, dietary, sort_order)
      values (v.id, pname, true, true, left(nullif(trim(p_plus_one->>'dietary'), ''), 300), 99);
    end if;
  end if;

  update public.invites set message = left(nullif(trim(p_message), ''), 1000), responded_at = now()
   where id = v.id;

  insert into public.rsvp_log (invite_id, household, confirmed, confirm_text, answers)
  values (v.id, v.household_name, coalesce(p_confirmed, false),
          case when anyone then (select value from public.settings where key = 'rsvp_allergy_text') end,
          jsonb_build_object(
            'message', left(nullif(trim(p_message), ''), 1000),
            'guests', coalesce((select jsonb_agg(jsonb_build_object(
                         'name', g.name, 'plus_one', g.is_plus_one, 'attending', g.attending, 'dietary', g.dietary)
                       order by g.is_plus_one, g.sort_order, g.created_at)
                       from public.guests g where g.invite_id = v.id), '[]'::jsonb)));

  return public.get_invite(p_code);
end $$;

revoke all on function public.get_invite(text), public.submit_rsvp(text, jsonb, jsonb, text, boolean) from public, anon, authenticated;
grant execute on function public.get_invite(text), public.submit_rsvp(text, jsonb, jsonb, text, boolean) to anon, authenticated;

-- 5. Admin: read the log (all, or one household) ----------------------------
create or replace function public.admin_rsvp_log(p_invite uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  return coalesce((select jsonb_agg(jsonb_build_object(
            'invite_id', l.invite_id, 'household', l.household, 'submitted_at', l.submitted_at,
            'confirmed', l.confirmed, 'confirm_text', l.confirm_text, 'answers', l.answers)
          order by l.submitted_at desc)
          from public.rsvp_log l where p_invite is null or l.invite_id = p_invite), '[]'::jsonb);
end $$;
revoke all on function public.admin_rsvp_log(uuid) from public, anon, authenticated;
grant execute on function public.admin_rsvp_log(uuid) to authenticated;
