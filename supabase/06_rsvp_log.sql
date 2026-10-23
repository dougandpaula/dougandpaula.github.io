-- 06: RSVP log + allergy confirmation checkbox
-- Safe to run more than once.

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
