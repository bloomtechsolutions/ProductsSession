-- Sessions, teams and score events for the facilitator console.
-- Anyone can read (scoreboards are shown on the projector and on table phones).
-- Every write goes through a SECURITY DEFINER function that checks the session's host key,
-- which only the facilitator's device holds.

create extension if not exists pgcrypto with schema extensions;

create table public.sessions (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null default 'Session',
  created_at timestamptz not null default now()
);

-- Kept apart from sessions so the hash is never readable through the API.
create table public.session_secrets (
  session_id uuid primary key references public.sessions(id) on delete cascade,
  host_key_hash text not null
);

create table public.teams (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sessions(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  color_idx int not null default 0,
  position int not null default 0,
  created_at timestamptz not null default now()
);
create index teams_session_idx on public.teams(session_id);

create table public.score_events (
  id bigint generated always as identity primary key,
  session_id uuid not null references public.sessions(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete cascade,
  points int not null,
  activity text not null default 'manual',
  ref text,               -- set for automatic awards so they are idempotent and can be revoked
  reason text,
  created_at timestamptz not null default now()
);
create index score_events_session_idx on public.score_events(session_id);
create index score_events_team_idx on public.score_events(team_id);
create unique index score_events_ref_uniq on public.score_events(session_id, team_id, ref) where ref is not null;

alter table public.sessions enable row level security;
alter table public.session_secrets enable row level security;
alter table public.teams enable row level security;
alter table public.score_events enable row level security;

create policy "sessions are readable" on public.sessions for select to anon, authenticated using (true);
create policy "teams are readable" on public.teams for select to anon, authenticated using (true);
create policy "score events are readable" on public.score_events for select to anon, authenticated using (true);
-- session_secrets: no policies, so the API cannot read or write it.

-- ---------- helpers ----------
create or replace function public._check_host(p_session uuid, p_key text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (
    select 1 from public.session_secrets s
    where s.session_id = p_session
      and s.host_key_hash = encode(extensions.digest(coalesce(p_key, ''), 'sha256'), 'hex')
  ) then
    raise exception 'Not the facilitator of this session' using errcode = '42501';
  end if;
end $$;
revoke all on function public._check_host(uuid, text) from public, anon, authenticated;

-- ---------- facilitator API ----------
create or replace function public.create_session(p_name text default 'Session')
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_code text;
  v_key text := encode(extensions.gen_random_bytes(24), 'hex');
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  loop
    v_code := '';
    for i in 1..6 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.sessions where code = v_code);
  end loop;
  insert into public.sessions(code, name) values (v_code, left(coalesce(nullif(trim(p_name), ''), 'Session'), 80))
    returning id into v_id;
  insert into public.session_secrets(session_id, host_key_hash)
    values (v_id, encode(extensions.digest(v_key, 'sha256'), 'hex'));
  return json_build_object('session_id', v_id, 'code', v_code, 'host_key', v_key);
end $$;

create or replace function public.add_team(p_session uuid, p_key text, p_name text)
returns public.teams language plpgsql security definer set search_path = '' as $$
declare v_row public.teams; v_n int;
begin
  perform public._check_host(p_session, p_key);
  select count(*) into v_n from public.teams where session_id = p_session;
  if v_n >= 8 then raise exception 'A session can have at most 8 teams'; end if;
  insert into public.teams(session_id, name, color_idx, position)
    values (p_session, left(trim(p_name), 60),
            coalesce((select max(color_idx) + 1 from public.teams where session_id = p_session), 0),
            coalesce((select max(position) + 1 from public.teams where session_id = p_session), 0))
    returning * into v_row;
  return v_row;
end $$;

create or replace function public.rename_team(p_session uuid, p_key text, p_team uuid, p_name text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._check_host(p_session, p_key);
  update public.teams set name = left(trim(p_name), 60) where id = p_team and session_id = p_session;
end $$;

create or replace function public.remove_team(p_session uuid, p_key text, p_team uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._check_host(p_session, p_key);
  delete from public.teams where id = p_team and session_id = p_session;
end $$;

-- Adds points. With a ref, the award is idempotent per team: calling again replaces the points.
create or replace function public.award(p_session uuid, p_key text, p_team uuid, p_points int,
                                        p_activity text default 'manual', p_ref text default null, p_reason text default null)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_id bigint;
begin
  perform public._check_host(p_session, p_key);
  if not exists (select 1 from public.teams where id = p_team and session_id = p_session) then
    raise exception 'Team is not in this session';
  end if;
  if p_ref is null then
    insert into public.score_events(session_id, team_id, points, activity, reason)
      values (p_session, p_team, p_points, left(p_activity, 40), left(p_reason, 200)) returning id into v_id;
  else
    insert into public.score_events(session_id, team_id, points, activity, ref, reason)
      values (p_session, p_team, p_points, left(p_activity, 40), left(p_ref, 120), left(p_reason, 200))
      on conflict (session_id, team_id, ref) where ref is not null
      do update set points = excluded.points, reason = excluded.reason, created_at = now()
      returning id into v_id;
  end if;
  return v_id;
end $$;

create or replace function public.revoke_award(p_session uuid, p_key text, p_team uuid, p_ref text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._check_host(p_session, p_key);
  delete from public.score_events where session_id = p_session and team_id = p_team and ref = p_ref;
end $$;

create or replace function public.undo_event(p_session uuid, p_key text, p_event bigint)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._check_host(p_session, p_key);
  delete from public.score_events where id = p_event and session_id = p_session;
end $$;

create or replace function public.reset_scores(p_session uuid, p_key text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._check_host(p_session, p_key);
  delete from public.score_events where session_id = p_session;
end $$;

revoke all on function public.create_session(text) from public;
revoke all on function public.add_team(uuid, text, text) from public;
revoke all on function public.rename_team(uuid, text, uuid, text) from public;
revoke all on function public.remove_team(uuid, text, uuid) from public;
revoke all on function public.award(uuid, text, uuid, int, text, text, text) from public;
revoke all on function public.revoke_award(uuid, text, uuid, text) from public;
revoke all on function public.undo_event(uuid, text, bigint) from public;
revoke all on function public.reset_scores(uuid, text) from public;
grant execute on function public.create_session(text) to anon, authenticated;
grant execute on function public.add_team(uuid, text, text) to anon, authenticated;
grant execute on function public.rename_team(uuid, text, uuid, text) to anon, authenticated;
grant execute on function public.remove_team(uuid, text, uuid) to anon, authenticated;
grant execute on function public.award(uuid, text, uuid, int, text, text, text) to anon, authenticated;
grant execute on function public.revoke_award(uuid, text, uuid, text) to anon, authenticated;
grant execute on function public.undo_event(uuid, text, bigint) to anon, authenticated;
grant execute on function public.reset_scores(uuid, text) to anon, authenticated;

-- Direct table writes are not allowed; only the functions above write.
revoke insert, update, delete on public.sessions, public.session_secrets, public.teams, public.score_events from anon, authenticated;

-- Live scoreboards on every device.
alter publication supabase_realtime add table public.teams, public.score_events;
