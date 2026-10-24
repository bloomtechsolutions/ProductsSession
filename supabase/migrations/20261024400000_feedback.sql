-- End-of-session feedback. Every staff member scans a QR code and fills in a short form on their own phone,
-- including the 1-to-5 confidence question before and after the session. Anyone with the session code can
-- submit; only the facilitator (host key) can read the answers. One answer per device per session: sending
-- again from the same phone replaces the earlier answer.

create table public.feedback (
  id bigint generated always as identity primary key,
  session_id uuid not null references public.sessions(id) on delete cascade,
  device_id text not null,
  conf_before int not null check (conf_before between 1 and 5),
  conf_after int not null check (conf_after between 1 and 5),
  rating int not null check (rating between 1 and 5),
  useful text,
  commitment text,
  comment text,
  name text,
  unit text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (session_id, device_id)
);
alter table public.feedback enable row level security;
revoke all on public.feedback from anon, authenticated;

create or replace function public.submit_feedback(p_code text, p_device text, p_before int, p_after int, p_rating int,
                                                  p_useful text, p_commitment text, p_comment text, p_name text, p_unit text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_session uuid;
begin
  select id into v_session from public.sessions where code = upper(trim(coalesce(p_code, '')));
  if not found then raise exception 'Session not found. Check the code with the facilitator.'; end if;
  if coalesce(length(p_device), 0) not between 8 and 80 then raise exception 'Invalid device'; end if;
  if p_before not between 1 and 5 or p_after not between 1 and 5 or p_rating not between 1 and 5 then
    raise exception 'Please answer the three 1 to 5 questions';
  end if;
  if (select count(*) from public.feedback where session_id = v_session) >= 500
     and not exists (select 1 from public.feedback where session_id = v_session and device_id = p_device) then
    raise exception 'This session has reached its feedback limit';
  end if;
  insert into public.feedback(session_id, device_id, conf_before, conf_after, rating, useful, commitment, comment, name, unit)
    values (v_session, p_device, p_before, p_after, p_rating,
            nullif(left(trim(p_useful), 60), ''), nullif(left(trim(p_commitment), 600), ''), nullif(left(trim(p_comment), 1500), ''),
            nullif(left(trim(p_name), 80), ''), nullif(left(trim(p_unit), 80), ''))
    on conflict (session_id, device_id) do update set
      conf_before = excluded.conf_before, conf_after = excluded.conf_after, rating = excluded.rating,
      useful = excluded.useful, commitment = excluded.commitment, comment = excluded.comment,
      name = excluded.name, unit = excluded.unit, updated_at = now();
  return 'ok';
end $$;

create or replace function public.feedback_results(p_session uuid, p_key text)
returns table(id bigint, conf_before int, conf_after int, rating int, useful text, commitment text, comment text,
              name text, unit text, updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  perform public._check_host(p_session, p_key);
  return query select f.id, f.conf_before, f.conf_after, f.rating, f.useful, f.commitment, f.comment, f.name, f.unit, f.updated_at
    from public.feedback f where f.session_id = p_session order by f.updated_at;
end $$;

revoke all on function public.submit_feedback(text, text, int, int, int, text, text, text, text, text) from public;
revoke all on function public.feedback_results(uuid, text) from public;
grant execute on function public.submit_feedback(text, text, int, int, int, text, text, text, text, text) to anon, authenticated;
grant execute on function public.feedback_results(uuid, text) to anon, authenticated;
