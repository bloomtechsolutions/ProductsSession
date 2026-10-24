-- One player device per team, and rounds that teams answer from their phones.
-- A team's seat is claimed by exactly one device (it holds a player key, stored only as a hash).
-- The facilitator opens a round; the answer key stays in round_keys, which the API cannot read,
-- so answers cannot be read from the player page. Closing a round marks every team's answer
-- on the server and writes the points as score_events.

alter table public.teams add column claimed boolean not null default false;

create table public.team_secrets (
  team_id uuid primary key references public.teams(id) on delete cascade,
  player_key_hash text not null
);

create table public.rounds (
  id bigint generated always as identity primary key,
  session_id uuid not null references public.sessions(id) on delete cascade,
  kind text not null check (kind in ('choice', 'multi', 'text')),
  activity text not null,
  ref text not null,
  points int not null default 0,
  payload jsonb not null default '{}',
  status text not null default 'open' check (status in ('open', 'closed', 'cancelled')),
  result jsonb,
  opened_at timestamptz not null default now(),
  closed_at timestamptz
);
create index rounds_session_idx on public.rounds(session_id, id desc);

create table public.round_keys (
  round_id bigint primary key references public.rounds(id) on delete cascade,
  answer jsonb not null
);

create table public.answers (
  id bigint generated always as identity primary key,
  round_id bigint not null references public.rounds(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete cascade,
  answer jsonb not null,
  submitted_at timestamptz not null default now(),
  unique (round_id, team_id)
);

alter table public.team_secrets enable row level security;
alter table public.rounds enable row level security;
alter table public.round_keys enable row level security;
alter table public.answers enable row level security;
create policy "rounds are readable" on public.rounds for select to anon, authenticated using (true);
-- team_secrets, round_keys and answers have no policies: only the functions below touch them.
revoke insert, update, delete on public.team_secrets, public.rounds, public.round_keys, public.answers from anon, authenticated;
revoke select on public.team_secrets, public.round_keys, public.answers from anon, authenticated;

create or replace function public._check_player(p_team uuid, p_key text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (
    select 1 from public.team_secrets s
    where s.team_id = p_team
      and s.player_key_hash = encode(extensions.digest(coalesce(p_key, ''), 'sha256'), 'hex')
  ) then
    raise exception 'This device is not the player for that team' using errcode = '42501';
  end if;
end $$;
revoke all on function public._check_player(uuid, text) from public, anon, authenticated;

-- ---------- teams: at most 6, one player each ----------
create or replace function public.add_team(p_session uuid, p_key text, p_name text)
returns public.teams language plpgsql security definer set search_path = '' as $$
declare v_row public.teams;
begin
  perform public._check_host(p_session, p_key);
  perform 1 from public.sessions where id = p_session for update;
  if (select count(*) from public.teams where session_id = p_session) >= 6 then
    raise exception 'A session can have at most 6 teams';
  end if;
  insert into public.teams(session_id, name, color_idx, position)
    values (p_session, left(trim(p_name), 60),
            coalesce((select max(color_idx) + 1 from public.teams where session_id = p_session), 0),
            coalesce((select max(position) + 1 from public.teams where session_id = p_session), 0))
    returning * into v_row;
  return v_row;
end $$;

-- A player takes a free team. Fails if another device already holds it.
create or replace function public.claim_team(p_session uuid, p_team uuid)
returns json language plpgsql security definer set search_path = '' as $$
declare v_key text := encode(extensions.gen_random_bytes(24), 'hex'); v_row public.teams;
begin
  update public.teams set claimed = true
    where id = p_team and session_id = p_session and not claimed
    returning * into v_row;
  if not found then raise exception 'That team already has a player. Ask the facilitator to release it.'; end if;
  insert into public.team_secrets(team_id, player_key_hash)
    values (p_team, encode(extensions.digest(v_key, 'sha256'), 'hex'))
    on conflict (team_id) do update set player_key_hash = excluded.player_key_hash;
  return json_build_object('team', row_to_json(v_row), 'player_key', v_key);
end $$;

-- A player creates a new team and takes it in one step.
create or replace function public.join_new_team(p_session uuid, p_name text)
returns json language plpgsql security definer set search_path = '' as $$
declare v_key text := encode(extensions.gen_random_bytes(24), 'hex'); v_row public.teams;
begin
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter a team name'; end if;
  perform 1 from public.sessions where id = p_session for update;
  if not found then raise exception 'Session not found'; end if;
  if (select count(*) from public.teams where session_id = p_session) >= 6 then
    raise exception 'This session already has 6 teams';
  end if;
  insert into public.teams(session_id, name, color_idx, position, claimed)
    values (p_session, left(trim(p_name), 60),
            coalesce((select max(color_idx) + 1 from public.teams where session_id = p_session), 0),
            coalesce((select max(position) + 1 from public.teams where session_id = p_session), 0),
            true)
    returning * into v_row;
  insert into public.team_secrets(team_id, player_key_hash)
    values (v_row.id, encode(extensions.digest(v_key, 'sha256'), 'hex'));
  return json_build_object('team', row_to_json(v_row), 'player_key', v_key);
end $$;

create or replace function public.leave_team(p_team uuid, p_player_key text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._check_player(p_team, p_player_key);
  delete from public.team_secrets where team_id = p_team;
  update public.teams set claimed = false where id = p_team;
end $$;

-- The facilitator frees a seat, for example when a phone dies.
create or replace function public.release_team(p_session uuid, p_key text, p_team uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._check_host(p_session, p_key);
  delete from public.team_secrets where team_id = p_team;
  update public.teams set claimed = false where id = p_team and session_id = p_session;
end $$;

-- ---------- rounds ----------
create or replace function public.open_round(p_session uuid, p_key text, p_kind text, p_activity text, p_ref text,
                                             p_points int, p_payload jsonb, p_answer jsonb)
returns public.rounds language plpgsql security definer set search_path = '' as $$
declare v_row public.rounds;
begin
  perform public._check_host(p_session, p_key);
  update public.rounds set status = 'cancelled', closed_at = now() where session_id = p_session and status = 'open';
  insert into public.rounds(session_id, kind, activity, ref, points, payload)
    values (p_session, p_kind, left(p_activity, 40), left(p_ref, 120), p_points, coalesce(p_payload, '{}'))
    returning * into v_row;
  insert into public.round_keys(round_id, answer) values (v_row.id, coalesce(p_answer, '{}'));
  return v_row;
end $$;

create or replace function public.cancel_round(p_session uuid, p_key text, p_round bigint)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._check_host(p_session, p_key);
  update public.rounds set status = 'cancelled', closed_at = now() where id = p_round and session_id = p_session and status = 'open';
end $$;

-- A team's player submits or changes its answer while the round is open.
create or replace function public.submit_answer(p_round bigint, p_team uuid, p_player_key text, p_answer jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_round public.rounds;
begin
  perform public._check_player(p_team, p_player_key);
  select * into v_round from public.rounds where id = p_round;
  if not found or v_round.status <> 'open' then raise exception 'This question is closed'; end if;
  if not exists (select 1 from public.teams where id = p_team and session_id = v_round.session_id) then
    raise exception 'Team is not in this session';
  end if;
  if length(p_answer::text) > 4000 then raise exception 'Answer is too long'; end if;
  insert into public.answers(round_id, team_id, answer) values (p_round, p_team, p_answer)
    on conflict (round_id, team_id) do update set answer = excluded.answer, submitted_at = now();
end $$;

-- The facilitator sees which teams have answered (and, once closed, what they answered).
create or replace function public.round_answers(p_session uuid, p_key text, p_round bigint)
returns table(team_id uuid, answer jsonb, submitted_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  perform public._check_host(p_session, p_key);
  return query select a.team_id, a.answer, a.submitted_at from public.answers a
    join public.rounds r on r.id = a.round_id where r.id = p_round and r.session_id = p_session;
end $$;

-- Close a round and mark it on the server. 'choice' rounds score the round's points for a matching choice;
-- 'multi' rounds score the points for every pick in the key; 'text' rounds are marked by the facilitator.
-- Closing an already closed round marks it again.
create or replace function public.close_round(p_session uuid, p_key text, p_round bigint)
returns json language plpgsql security definer set search_path = '' as $$
declare v_round public.rounds; v_key jsonb; v_res jsonb := '{}'; v_team record; v_ans jsonb; v_pts int;
begin
  perform public._check_host(p_session, p_key);
  select * into v_round from public.rounds where id = p_round and session_id = p_session for update;
  if not found then raise exception 'Round not found'; end if;
  select answer into v_key from public.round_keys where round_id = v_round.id;
  for v_team in select id from public.teams where session_id = p_session loop
    select answer into v_ans from public.answers where round_id = v_round.id and team_id = v_team.id;
    v_pts := null;
    if v_round.kind = 'choice' then
      v_pts := case when v_ans is not null and v_ans->'choice' = v_key->'correct' then v_round.points else 0 end;
    elsif v_round.kind = 'multi' then
      select count(distinct x.v) * v_round.points into v_pts
        from jsonb_array_elements_text(case when jsonb_typeof(v_ans->'picks') = 'array' then v_ans->'picks' else '[]'::jsonb end) as x(v)
        where coalesce(v_key->'ideal', '[]'::jsonb) ? x.v;
    end if;
    if v_pts is not null then
      if v_pts > 0 then
        insert into public.score_events(session_id, team_id, points, activity, ref, reason)
          values (p_session, v_team.id, v_pts, v_round.activity, v_round.ref, 'Answered on team device')
          on conflict (session_id, team_id, ref) where ref is not null
          do update set points = excluded.points, reason = excluded.reason, created_at = now();
      else
        delete from public.score_events where session_id = p_session and team_id = v_team.id and ref = v_round.ref;
      end if;
    end if;
    v_res := v_res || jsonb_build_object(v_team.id::text, jsonb_build_object('answer', v_ans, 'points', v_pts));
  end loop;
  update public.rounds set status = 'closed', closed_at = now(), result = jsonb_build_object('key', v_key, 'teams', v_res)
    where id = v_round.id returning * into v_round;
  return json_build_object('round', row_to_json(v_round));
end $$;

-- Lets a player's device check that it still holds its team's seat (false after a release).
create or replace function public.player_status(p_team uuid, p_player_key text)
returns boolean language sql security definer set search_path = '' as $$
  select exists (
    select 1 from public.team_secrets s
    where s.team_id = p_team
      and s.player_key_hash = encode(extensions.digest(coalesce(p_player_key, ''), 'sha256'), 'hex'));
$$;

-- Resetting scores also clears the session's rounds and answers so the game starts fresh.
create or replace function public.reset_scores(p_session uuid, p_key text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._check_host(p_session, p_key);
  delete from public.score_events where session_id = p_session;
  delete from public.rounds where session_id = p_session;
end $$;

revoke all on function public.player_status(uuid, text) from public;
grant execute on function public.player_status(uuid, text) to anon, authenticated;
revoke all on function public.claim_team(uuid, uuid) from public;
revoke all on function public.join_new_team(uuid, text) from public;
revoke all on function public.leave_team(uuid, text) from public;
revoke all on function public.release_team(uuid, text, uuid) from public;
revoke all on function public.open_round(uuid, text, text, text, text, int, jsonb, jsonb) from public;
revoke all on function public.cancel_round(uuid, text, bigint) from public;
revoke all on function public.submit_answer(bigint, uuid, text, jsonb) from public;
revoke all on function public.round_answers(uuid, text, bigint) from public;
revoke all on function public.close_round(uuid, text, bigint) from public;
grant execute on function public.claim_team(uuid, uuid) to anon, authenticated;
grant execute on function public.join_new_team(uuid, text) to anon, authenticated;
grant execute on function public.leave_team(uuid, text) to anon, authenticated;
grant execute on function public.release_team(uuid, text, uuid) to anon, authenticated;
grant execute on function public.open_round(uuid, text, text, text, text, int, jsonb, jsonb) to anon, authenticated;
grant execute on function public.cancel_round(uuid, text, bigint) to anon, authenticated;
grant execute on function public.submit_answer(bigint, uuid, text, jsonb) to anon, authenticated;
grant execute on function public.round_answers(uuid, text, bigint) to anon, authenticated;
grant execute on function public.close_round(uuid, text, bigint) to anon, authenticated;

alter publication supabase_realtime add table public.rounds;
