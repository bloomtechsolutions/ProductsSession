-- Product Passport: each team picks 2 products to teach; a product can belong to only one team.
-- Picks are public (every phone shows which products are taken). Teams pick only while the
-- facilitator has a picking round open; the facilitator can release any pick.

create table public.product_picks (
  session_id uuid not null references public.sessions(id) on delete cascade,
  product text not null check (char_length(product) between 1 and 80),
  team_id uuid not null references public.teams(id) on delete cascade,
  picked_at timestamptz not null default now(),
  primary key (session_id, product)
);
create index product_picks_team_idx on public.product_picks(team_id);

alter table public.product_picks enable row level security;
create policy "product picks are readable" on public.product_picks for select to anon, authenticated using (true);
revoke insert, update, delete on public.product_picks from anon, authenticated;

-- A team's phone takes a product. The primary key makes it first come, first served.
create or replace function public.pick_product(p_team uuid, p_player_key text, p_product text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_session uuid;
begin
  perform public._check_player(p_team, p_player_key);
  select session_id into v_session from public.teams where id = p_team for update;
  if not exists (select 1 from public.rounds where session_id = v_session and status = 'open' and payload->>'type' = 'pick') then
    raise exception 'Product picking is closed';
  end if;
  if (select count(*) from public.product_picks where team_id = p_team) >= 2 then
    raise exception 'Your team already has 2 products. Tap one of yours to swap it.';
  end if;
  insert into public.product_picks(session_id, product, team_id) values (v_session, p_product, p_team)
    on conflict (session_id, product) do nothing;
  if not found then raise exception 'Another team just took that product'; end if;
end $$;

-- A team's phone gives back one of its own products while picking is open.
create or replace function public.unpick_product(p_team uuid, p_player_key text, p_product text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_session uuid;
begin
  perform public._check_player(p_team, p_player_key);
  select session_id into v_session from public.teams where id = p_team;
  if not exists (select 1 from public.rounds where session_id = v_session and status = 'open' and payload->>'type' = 'pick') then
    raise exception 'Product picking is closed';
  end if;
  delete from public.product_picks where team_id = p_team and product = p_product;
end $$;

-- The facilitator frees a product from whichever team holds it.
create or replace function public.release_product(p_session uuid, p_key text, p_product text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._check_host(p_session, p_key);
  delete from public.product_picks where session_id = p_session and product = p_product;
end $$;

-- Resetting scores also clears product picks.
create or replace function public.reset_scores(p_session uuid, p_key text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._check_host(p_session, p_key);
  delete from public.score_events where session_id = p_session;
  delete from public.rounds where session_id = p_session;
  delete from public.product_picks where session_id = p_session;
end $$;

revoke all on function public.pick_product(uuid, text, text) from public;
revoke all on function public.unpick_product(uuid, text, text) from public;
revoke all on function public.release_product(uuid, text, text) from public;
grant execute on function public.pick_product(uuid, text, text) to anon, authenticated;
grant execute on function public.unpick_product(uuid, text, text) to anon, authenticated;
grant execute on function public.release_product(uuid, text, text) to anon, authenticated;

alter publication supabase_realtime add table public.product_picks;
