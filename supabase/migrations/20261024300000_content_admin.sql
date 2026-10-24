-- Editable activity content. The app ships built-in content (public/content.js); a row here replaces one section
-- of it for every console, phone and audience screen. Anyone can read the content; only someone with the admin
-- password can change it. The password is stored as a salted SHA-256 hash, and five wrong attempts lock the admin
-- functions for five minutes.

create table public.content (
  key text primary key check (key in ('mf', 'quiz', 'clues', 'wheel', 'products', 'facts')),
  data jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by text
);
alter table public.content enable row level security;
create policy "content is readable" on public.content for select to anon, authenticated using (true);
revoke insert, update, delete on public.content from anon, authenticated;

create table public.admin_secret (
  id int primary key default 1 check (id = 1),
  salt text not null,
  pass_hash text not null,
  failed int not null default 0,
  locked_until timestamptz
);
alter table public.admin_secret enable row level security;
revoke all on public.admin_secret from anon, authenticated;

-- Returns 'ok', 'bad_password', 'locked' or 'not_set'. Records failures instead of raising, so they are kept.
create or replace function public._admin_auth(p_password text)
returns text language plpgsql security definer set search_path = '' as $$
declare v public.admin_secret;
begin
  select * into v from public.admin_secret where id = 1 for update;
  if not found then return 'not_set'; end if;
  if v.locked_until is not null and v.locked_until > now() then return 'locked'; end if;
  if v.pass_hash = encode(extensions.digest(v.salt || coalesce(p_password, ''), 'sha256'), 'hex') then
    update public.admin_secret set failed = 0, locked_until = null where id = 1;
    return 'ok';
  end if;
  update public.admin_secret
    set failed = case when v.failed + 1 >= 5 then 0 else v.failed + 1 end,
        locked_until = case when v.failed + 1 >= 5 then now() + interval '5 minutes' else null end
    where id = 1;
  return 'bad_password';
end $$;
revoke all on function public._admin_auth(text) from public, anon, authenticated;

create or replace function public.admin_status()
returns json language sql security definer set search_path = '' as $$
  select json_build_object('password_set', exists (select 1 from public.admin_secret));
$$;

-- First-time setup only: sets the admin password when none exists yet.
create or replace function public.admin_setup(p_password text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_salt text := encode(extensions.gen_random_bytes(16), 'hex');
begin
  if exists (select 1 from public.admin_secret) then return 'already_set'; end if;
  if char_length(coalesce(p_password, '')) < 8 then return 'too_short'; end if;
  insert into public.admin_secret(id, salt, pass_hash) values (1, v_salt, encode(extensions.digest(v_salt || p_password, 'sha256'), 'hex'));
  return 'ok';
end $$;

create or replace function public.admin_login(p_password text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  return public._admin_auth(p_password);
end $$;

create or replace function public.admin_change_password(p_old text, p_new text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_auth text; v_salt text := encode(extensions.gen_random_bytes(16), 'hex');
begin
  v_auth := public._admin_auth(p_old);
  if v_auth <> 'ok' then return v_auth; end if;
  if char_length(coalesce(p_new, '')) < 8 then return 'too_short'; end if;
  update public.admin_secret set salt = v_salt, pass_hash = encode(extensions.digest(v_salt || p_new, 'sha256'), 'hex') where id = 1;
  return 'ok';
end $$;

create or replace function public.save_content(p_password text, p_key text, p_data jsonb, p_by text default null)
returns text language plpgsql security definer set search_path = '' as $$
declare v_auth text;
begin
  v_auth := public._admin_auth(p_password);
  if v_auth <> 'ok' then return v_auth; end if;
  if p_key not in ('mf', 'quiz', 'clues', 'wheel', 'products', 'facts') then return 'bad_key'; end if;
  if length(p_data::text) > 300000 then return 'too_large'; end if;
  insert into public.content(key, data, updated_at, updated_by) values (p_key, p_data, now(), left(p_by, 60))
    on conflict (key) do update set data = excluded.data, updated_at = now(), updated_by = excluded.updated_by;
  return 'ok';
end $$;

create or replace function public.reset_content(p_password text, p_key text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_auth text;
begin
  v_auth := public._admin_auth(p_password);
  if v_auth <> 'ok' then return v_auth; end if;
  delete from public.content where key = p_key;
  return 'ok';
end $$;

revoke all on function public.admin_status() from public;
revoke all on function public.admin_setup(text) from public;
revoke all on function public.admin_login(text) from public;
revoke all on function public.admin_change_password(text, text) from public;
revoke all on function public.save_content(text, text, jsonb, text) from public;
revoke all on function public.reset_content(text, text) from public;
grant execute on function public.admin_status() to anon, authenticated;
grant execute on function public.admin_setup(text) to anon, authenticated;
grant execute on function public.admin_login(text) to anon, authenticated;
grant execute on function public.admin_change_password(text, text) to anon, authenticated;
grant execute on function public.save_content(text, text, jsonb, text) to anon, authenticated;
grant execute on function public.reset_content(text, text) to anon, authenticated;

alter publication supabase_realtime add table public.content;
