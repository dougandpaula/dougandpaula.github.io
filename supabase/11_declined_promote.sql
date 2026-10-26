-- 11: Declined households, promote to ceremony, ceremony places limit. Safe to run more than once.
alter table public.invites add column if not exists declined_at timestamptz;
alter table public.invites add column if not exists promoted_at timestamptz;
insert into public.settings (key, value) values ('ceremony_max', '110') on conflict (key) do nothing;

create or replace function public.admin_set_declined(p_id uuid, p_declined boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  update public.invites set declined_at = case when p_declined then coalesce(declined_at, now()) end where id = p_id;
  return public.admin_invite_json(p_id);
end $$;

create or replace function public.admin_promote(p_id uuid, p_promote boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  if p_promote then
    update public.invites set invite_type = 'ceremony', promoted_at = coalesce(promoted_at, now())
     where id = p_id and invite_type = 'garden';
  else
    update public.invites set invite_type = 'garden', promoted_at = null where id = p_id and promoted_at is not null;
  end if;
  return public.admin_invite_json(p_id);
end $$;

revoke all on function public.admin_set_declined(uuid, boolean), public.admin_promote(uuid, boolean) from public, anon, authenticated;
grant execute on function public.admin_set_declined(uuid, boolean), public.admin_promote(uuid, boolean) to authenticated;

-- RSVP form: anyone who said on the save the date that they can't come starts as "can't come"
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
               'attending', coalesce(g.attending, case when g.std_cant then false end), 'dietary', g.dietary,
               'age_group', g.age_group, 'age', g.age)
             order by g.is_plus_one, g.sort_order, g.created_at)
      from public.guests g where g.invite_id = v.id), '[]'::jsonb),
    'gift', (select jsonb_object_agg(key, value) from public.settings where key like 'gift_%'),
    'allergy_text', (select value from public.settings where key = 'rsvp_allergy_text')
  );
end $$;
revoke all on function public.get_invite(text) from public, anon, authenticated;
grant execute on function public.get_invite(text) to anon, authenticated;

-- Reset test also clears declined / promoted
create or replace function public.admin_reset_test(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c text;
begin
  perform public.admin_check();
  select code into c from public.invites where id = p_id;
  if c is null or c not like 'test%' then
    raise exception 'Only test invites can be reset';
  end if;
  delete from public.guests where invite_id = p_id and is_plus_one;
  update public.guests set attending = null, dietary = null, std_cant = false where invite_id = p_id;
  update public.invites set responded_at = null, message = null,
         first_opened_at = null, last_opened_at = null, declined_at = null,
         invite_type = case when promoted_at is not null then 'garden' else invite_type end, promoted_at = null,
         std_sent_at = null, std_opened_at = null, std_answer = null, std_answered_at = null where id = p_id;
  delete from public.rsvp_log where invite_id = p_id;
  return public.admin_invite_json(p_id);
end $$;
revoke all on function public.admin_reset_test(uuid) from public, anon, authenticated;
grant execute on function public.admin_reset_test(uuid) to authenticated;
