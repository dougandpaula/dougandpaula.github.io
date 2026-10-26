-- 13: Running order (one ranked list of households). Safe to run more than once.
alter table public.invites add column if not exists run_order int;

create or replace function public.admin_run_order(p_list jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  update public.invites i set run_order = x.n
    from (select value::uuid as id, ordinality as n from jsonb_array_elements_text(p_list) with ordinality) x
   where i.id = x.id;
end $$;
revoke all on function public.admin_run_order(jsonb) from public, anon, authenticated;
grant execute on function public.admin_run_order(jsonb) to authenticated;
