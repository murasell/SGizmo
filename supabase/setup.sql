create extension if not exists pgcrypto;

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[0-9]{5}$'),
  owner_uid uuid not null references auth.users(id) on delete cascade,
  owner_name text not null,
  is_public boolean not null default false,
  status text not null default 'lobby' check (status in ('lobby','playing','finished')),
  phase text not null default 'setup' check (phase in ('setup','moderator_setup','countdown','clue','voting','results')),
  player_count integer not null default 0,
  current_round integer not null default 0,
  turn_order uuid[] not null default '{}',
  turn_pos integer not null default 0,
  current_player_id uuid,
  turn_ends_at timestamptz,
  moderator_uid uuid,
  winner text check (winner in ('spy','players')),
  created_at timestamptz not null default now()
);

create table if not exists public.room_settings (
  room_id uuid primary key references public.rooms(id) on delete cascade,
  max_players integer not null default 6 check (max_players between 4 and 8),
  host_mode text not null default 'random' check (host_mode in ('player','bot','random')),
  moderator_player_id uuid,
  game_mode text not null default 'chat' check (game_mode in ('chat','live')),
  turn_seconds integer not null default 60 check (turn_seconds between 15 and 60),
  vote_after_rounds integer not null default 2 check (vote_after_rounds between 1 and 4),
  vote_seconds integer not null default 20 check (vote_seconds between 15 and 30)
);

create table if not exists public.room_players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  nickname text not null check (char_length(nickname) between 1 and 18),
  avatar text check (avatar is null or (char_length(avatar)<=40000 and avatar like 'data:image/webp;base64,%')),
  is_bot boolean not null default false,
  is_ready boolean not null default false,
  is_moderator boolean not null default false,
  is_eliminated boolean not null default false,
  joined_at timestamptz not null default now(),
  check ((is_bot and user_id is null) or (not is_bot and user_id is not null))
);
create unique index if not exists room_players_user_unique on public.room_players(room_id,user_id) where user_id is not null;
drop index if exists public.room_players_one_bot;
create index if not exists room_players_room_idx on public.room_players(room_id,joined_at);
create table if not exists public.room_presence (
  player_id uuid primary key references public.room_players(id) on delete cascade,
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  last_seen_at timestamptz not null default now()
);
create index if not exists room_presence_room_seen_idx on public.room_presence(room_id,last_seen_at);
create table if not exists public.room_exit_notices (
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  reason text not null check (reason in ('owner','offline')),
  created_at timestamptz not null default now(),
  primary key(room_id,user_id)
);
alter table public.room_players add column if not exists avatar text;
alter table public.room_settings add column if not exists moderator_player_id uuid;
alter table public.room_settings add column if not exists vote_seconds integer not null default 20;
alter table public.rooms alter column is_public set default false;
alter table public.rooms drop constraint if exists rooms_phase_check;
alter table public.rooms add constraint rooms_phase_check check (phase in ('setup','moderator_setup','countdown','clue','voting','results'));
alter table public.room_settings alter column turn_seconds set default 60;
alter table public.room_settings drop constraint if exists room_settings_vote_after_rounds_check;
alter table public.room_settings add constraint room_settings_vote_after_rounds_check check (vote_after_rounds between 1 and 4);
alter table public.room_settings drop constraint if exists room_settings_vote_seconds_check;
alter table public.room_settings add constraint room_settings_vote_seconds_check check (vote_seconds between 15 and 30);
alter table public.room_settings drop constraint if exists room_settings_host_mode_check;
update public.room_settings set moderator_player_id=(
  select p.id from public.room_players p join public.rooms r on r.id=p.room_id
  where p.room_id=room_settings.room_id and p.user_id=r.owner_uid
) where host_mode='owner';
update public.room_settings set moderator_player_id=null where host_mode='random';
update public.room_settings set host_mode='player' where host_mode='owner';
update public.room_settings set host_mode='bot',moderator_player_id=null where host_mode not in ('player','bot','random');
update public.room_settings s set host_mode='bot',moderator_player_id=null
from public.rooms r
where r.id=s.room_id and r.status='lobby'
  and ((select count(*) from public.room_players p where p.room_id=r.id)<4
    or (select count(*) from public.room_players p where p.room_id=r.id and not p.is_bot)<2);
alter table public.room_settings alter column host_mode set default 'random';
alter table public.room_settings add constraint room_settings_host_mode_check check (host_mode in ('player','bot','random'));
do $$ begin
  if not exists(select 1 from pg_constraint where conname='room_players_avatar_check' and conrelid='public.room_players'::regclass) then
    alter table public.room_players add constraint room_players_avatar_check check (avatar is null or (char_length(avatar)<=40000 and avatar like 'data:image/webp;base64,%'));
  end if;
end $$;
alter table public.rooms drop constraint if exists rooms_current_player_fk;
alter table public.rooms add constraint rooms_current_player_fk foreign key (current_player_id) references public.room_players(id) on delete set null deferrable initially deferred;

create table if not exists public.room_secrets (
  room_id uuid not null references public.rooms(id) on delete cascade,
  player_id uuid not null references public.room_players(id) on delete cascade,
  role text not null check (role in ('spy','player')),
  word text not null,
  primary key(room_id,player_id)
);
create table if not exists public.room_game_words (
  room_id uuid primary key references public.rooms(id) on delete cascade,
  player_word text not null check (char_length(player_word) between 2 and 60),
  spy_word text not null check (char_length(spy_word) between 2 and 60),
  spy_player_id uuid not null references public.room_players(id) on delete cascade,
  check (lower(trim(player_word))<>lower(trim(spy_word)))
);
create table if not exists public.room_messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  player_id uuid references public.room_players(id) on delete set null,
  user_id uuid references auth.users(id) on delete set null,
  nickname text not null,
  body text not null check (char_length(body) between 1 and 300),
  kind text not null default 'chat' check (kind in ('chat','clue','system')),
  round_no integer not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists room_messages_room_idx on public.room_messages(room_id,created_at);
create table if not exists public.room_reactions (
  message_id uuid not null references public.room_messages(id) on delete cascade,
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  reaction text not null check (reaction in ('+','-','=')),
  primary key(message_id,user_id)
);
create table if not exists public.room_votes (
  room_id uuid not null references public.rooms(id) on delete cascade,
  round_no integer not null,
  voter_id uuid not null references public.room_players(id) on delete cascade,
  target_id uuid not null references public.room_players(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(room_id,round_no,voter_id),
  check (voter_id <> target_id)
);

create or replace function public.is_room_member(p_room uuid) returns boolean
language sql stable security definer set search_path=public,auth,pg_temp as $$
  select exists(select 1 from public.room_players p where p.room_id=p_room and p.user_id=auth.uid())
$$;
create or replace function public.is_room_owner(p_room uuid) returns boolean
language sql stable security definer set search_path=public,auth,pg_temp as $$
  select exists(select 1 from public.rooms r where r.id=p_room and r.owner_uid=auth.uid())
$$;

create or replace function public.update_room_player_count() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if tg_op='INSERT' then update public.rooms set player_count=player_count+1 where id=new.room_id; return new; end if;
  update public.rooms set player_count=greatest(0,player_count-1) where id=old.room_id; return old;
end $$;
drop trigger if exists room_player_count_insert on public.room_players;
create trigger room_player_count_insert after insert on public.room_players for each row execute function public.update_room_player_count();
drop trigger if exists room_player_count_delete on public.room_players;
create trigger room_player_count_delete after delete on public.room_players for each row execute function public.update_room_player_count();

alter table public.rooms enable row level security;
alter table public.room_settings enable row level security;
alter table public.room_players enable row level security;
alter table public.room_secrets enable row level security;
alter table public.room_game_words enable row level security;
alter table public.room_messages enable row level security;
alter table public.room_reactions enable row level security;
alter table public.room_votes enable row level security;
alter table public.room_presence enable row level security;
alter table public.room_exit_notices enable row level security;
drop policy if exists rooms_read on public.rooms;
create policy rooms_read on public.rooms for select to authenticated using ((is_public and status='lobby') or public.is_room_member(id));
drop policy if exists settings_read on public.room_settings;
create policy settings_read on public.room_settings for select to authenticated using (public.is_room_owner(room_id) or (public.is_room_member(room_id) and exists(select 1 from public.rooms r where r.id=room_id and r.status<>'lobby')) or exists(select 1 from public.room_players p where p.room_id=room_settings.room_id and p.user_id=auth.uid() and p.is_moderator));
drop policy if exists players_read on public.room_players;
create policy players_read on public.room_players for select to authenticated using (public.is_room_member(room_id));
drop policy if exists secrets_read on public.room_secrets;
create policy secrets_read on public.room_secrets for select to authenticated using (exists(select 1 from public.rooms r where r.id=room_id and r.status='finished') and public.is_room_member(room_id));
drop policy if exists room_game_words_moderator_read on public.room_game_words;
create policy room_game_words_moderator_read on public.room_game_words for select to authenticated using (
  exists(select 1 from public.room_settings s join public.room_players p on p.id=s.moderator_player_id
    join public.rooms r on r.id=s.room_id
    where s.room_id=room_game_words.room_id and p.user_id=auth.uid() and r.status in ('lobby','playing'))
);
drop policy if exists messages_read on public.room_messages;
create policy messages_read on public.room_messages for select to authenticated using (public.is_room_member(room_id));
drop policy if exists reactions_read on public.room_reactions;
create policy reactions_read on public.room_reactions for select to authenticated using (public.is_room_member(room_id));
drop policy if exists votes_read on public.room_votes;
create policy votes_read on public.room_votes for select to authenticated using (public.is_room_owner(room_id) or (public.is_room_member(room_id) and exists(select 1 from public.rooms r where r.id=room_id and r.status='finished')));
drop policy if exists exit_notices_read on public.room_exit_notices;
create policy exit_notices_read on public.room_exit_notices for select to authenticated using (user_id=auth.uid());
grant select on public.rooms,public.room_settings,public.room_players,public.room_secrets,public.room_game_words,public.room_messages,public.room_reactions,public.room_votes to authenticated;
revoke all on public.room_presence,public.room_exit_notices from public,anon,authenticated;
grant select on public.room_exit_notices to authenticated;

create or replace function public._unique_room_nickname(p_room uuid,p_name text,p_except uuid default null) returns text
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_base text:=left(trim(p_name),18); v_candidate text; v_suffix text; n integer:=1;
begin
  if char_length(v_base)<1 then raise exception 'Nickname required'; end if;
  v_candidate:=v_base;
  while exists(select 1 from public.room_players where room_id=p_room and id is distinct from p_except and lower(nickname)=lower(v_candidate)) loop
    n:=n+1; v_suffix:=' ('||n::text||')';
    v_candidate:=left(v_base,greatest(1,18-char_length(v_suffix)))||v_suffix;
  end loop;
  return v_candidate;
end $$;
do $$ declare p record; v_name text;
begin
  for p in select id,room_id,nickname,user_id from public.room_players order by joined_at loop
    v_name:=public._unique_room_nickname(p.room_id,p.nickname,p.id);
    if v_name<>p.nickname then
      update public.room_players set nickname=v_name where id=p.id;
      update public.rooms set owner_name=v_name where id=p.room_id and owner_uid=p.user_id;
    end if;
  end loop;
end $$;

drop function if exists public.create_room(text,integer,text,text,integer,integer);
create or replace function public.create_room(p_name text,p_avatar text default null) returns jsonb
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_room uuid; v_code text; v_player uuid; v_name text:=left(trim(p_name),18);
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  if char_length(v_name)<1 then raise exception 'Nickname required'; end if;
  if p_avatar is not null and (char_length(p_avatar)>40000 or p_avatar not like 'data:image/webp;base64,%') then raise exception 'Invalid avatar'; end if;
  loop
    v_code:=lpad(floor(random()*100000)::int::text,5,'0');
    insert into public.rooms(code,owner_uid,owner_name,is_public) values(v_code,auth.uid(),v_name,false) on conflict(code) do nothing returning id into v_room;
    exit when v_room is not null;
  end loop;
  insert into public.room_settings(room_id,max_players,host_mode,game_mode,turn_seconds,vote_after_rounds) values(v_room,6,'random','chat',60,3);
  insert into public.room_players(room_id,user_id,nickname,avatar,is_ready) values(v_room,auth.uid(),v_name,p_avatar,false) returning id into v_player;
  insert into public.room_presence(player_id,room_id,user_id,last_seen_at) values(v_player,v_room,auth.uid(),now());
  return jsonb_build_object('id',v_room,'code',v_code);
end $$;

drop function if exists public.join_room(text,text);
create or replace function public.join_room(p_code text,p_name text,p_avatar text default null) returns uuid
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare r public.rooms%rowtype; s public.room_settings%rowtype; v_player uuid; v_name text:=left(trim(p_name),18);
begin
  if auth.uid() is null or p_code !~ '^[0-9]{5}$' or char_length(v_name)<1 then raise exception 'Invalid code or nickname'; end if;
  if p_avatar is not null and (char_length(p_avatar)>40000 or p_avatar not like 'data:image/webp;base64,%') then raise exception 'Invalid avatar'; end if;
  select * into r from public.rooms where code=p_code for update;
  if not found or r.status<>'lobby' then raise exception 'Room not found or already started'; end if;
  select * into s from public.room_settings where room_id=r.id;
  select id into v_player from public.room_players where room_id=r.id and user_id=auth.uid();
  if v_player is not null then
    v_name:=public._unique_room_nickname(r.id,v_name,v_player);
    update public.room_players set nickname=v_name,avatar=p_avatar where id=v_player;
    insert into public.room_presence(player_id,room_id,user_id,last_seen_at) values(v_player,r.id,auth.uid(),now())
    on conflict(player_id) do update set room_id=excluded.room_id,user_id=excluded.user_id,last_seen_at=excluded.last_seen_at;
    delete from public.room_exit_notices where room_id=r.id and user_id=auth.uid();
    if r.owner_uid=auth.uid() then update public.rooms set owner_name=v_name where id=r.id; end if;
    return r.id;
  end if;
  if r.player_count>=s.max_players then raise exception 'Room is full'; end if;
  v_name:=public._unique_room_nickname(r.id,v_name);
  insert into public.room_players(room_id,user_id,nickname,avatar) values(r.id,auth.uid(),v_name,p_avatar) returning id into v_player;
  insert into public.room_presence(player_id,room_id,user_id,last_seen_at) values(v_player,r.id,auth.uid(),now());
  delete from public.room_exit_notices where room_id=r.id and user_id=auth.uid();
  return r.id;
end $$;

drop function if exists public.update_room_settings(uuid,integer,text,text,integer,integer);
drop function if exists public.update_room_settings(uuid,integer,text,uuid,text,integer,integer);
create or replace function public.update_room_settings(p_room uuid,p_max integer,p_host text,p_moderator uuid,p_mode text,p_seconds integer,p_vote_rounds integer,p_vote_seconds integer) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_humans integer; v_total integer; v_all_ready boolean; v_old_moderator uuid;
begin
  perform 1 from public.rooms where id=p_room and owner_uid=auth.uid() and status='lobby' for update;
  if not found then raise exception 'Only the room owner can change settings in a lobby'; end if;
  if p_max not between 4 and 8 or p_host not in ('player','bot','random') or p_mode not in ('chat','live') or p_seconds not between 15 and 60 or p_vote_rounds not between 1 and 4 or p_vote_seconds not between 15 and 30 then raise exception 'Invalid settings'; end if;
  if (select player_count from public.rooms where id=p_room)>p_max then raise exception 'Remove players before lowering the limit'; end if;
  select count(*),count(*) filter(where not is_bot) into v_total,v_humans from public.room_players where room_id=p_room;
  select moderator_player_id into v_old_moderator from public.room_settings where room_id=p_room;
  if v_total<4 or v_humans<2 then p_host:='bot'; p_moderator:=null;
  elsif p_host='player' and not exists(select 1 from public.room_players where id=p_moderator and room_id=p_room and not is_bot) then raise exception 'Choose a player to lead the game';
  elsif p_host='random' then
    if not exists(select 1 from public.room_players where id=v_old_moderator and room_id=p_room and not is_bot) or (select host_mode from public.room_settings where room_id=p_room)<>'random' then
      select id into p_moderator from public.room_players where room_id=p_room and not is_bot order by random() limit 1;
    else p_moderator:=v_old_moderator; end if;
  elsif p_host='bot' then p_moderator:=null;
  end if;
  update public.room_settings set max_players=p_max,host_mode=p_host,moderator_player_id=p_moderator,game_mode=p_mode,turn_seconds=p_seconds,vote_after_rounds=p_vote_rounds,vote_seconds=p_vote_seconds where room_id=p_room;
  update public.room_players set is_moderator=(id=p_moderator) where room_id=p_room;
  if v_old_moderator is distinct from p_moderator then delete from public.room_game_words where room_id=p_room; end if;
  select not exists(select 1 from public.room_players where room_id=p_room and not is_bot and not is_ready) into v_all_ready;
  if v_all_ready then perform public._start_game(p_room); end if;
end $$;

create or replace function public.save_moderator_game(p_room uuid,p_player_word text,p_spy_word text,p_spy_player uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare r public.rooms%rowtype; s public.room_settings%rowtype; p record;
begin
  select * into r from public.rooms where id=p_room for update;
  if not found or r.status<>'playing' or r.phase<>'moderator_setup' then raise exception 'The game is not waiting for the leader'; end if;
  if r.turn_ends_at is null or r.turn_ends_at<=now() then raise exception 'The leader setup time has ended'; end if;
  select * into s from public.room_settings where room_id=p_room for update;
  if not found or not exists(select 1 from public.room_players where id=s.moderator_player_id and room_id=p_room and user_id=auth.uid()) then raise exception 'Only the selected game leader can set the words'; end if;
  if p_player_word is null or p_spy_word is null or char_length(trim(p_player_word)) not between 2 and 60 or char_length(trim(p_spy_word)) not between 2 and 60 or lower(trim(p_player_word))=lower(trim(p_spy_word)) then raise exception 'Enter two different words (2-60 characters)'; end if;
  if not exists(select 1 from public.room_players where id=p_spy_player and room_id=p_room and id<>s.moderator_player_id and not is_eliminated) then raise exception 'Choose a player to be the spy'; end if;
  insert into public.room_game_words(room_id,player_word,spy_word,spy_player_id)
    values(p_room,trim(p_player_word),trim(p_spy_word),p_spy_player)
    on conflict(room_id) do update set player_word=excluded.player_word,spy_word=excluded.spy_word,spy_player_id=excluded.spy_player_id;
  delete from public.room_secrets where room_id=p_room;
  for p in select id from public.room_players where id=any(r.turn_order) loop
    insert into public.room_secrets(room_id,player_id,role,word)
    values(p_room,p.id,case when p.id=p_spy_player then 'spy' else 'player' end,
      case when p.id=p_spy_player then trim(p_spy_word) else trim(p_player_word) end);
  end loop;
  insert into public.room_messages(room_id,nickname,body,kind,round_no)
  values(p_room,'Gizmo','Раунд 1', 'system',1);
  update public.rooms set phase='countdown',current_round=1,turn_pos=1,current_player_id=turn_order[1],
    turn_ends_at=now()+interval '3 seconds' where id=p_room;
end $$;

create or replace function public.set_room_visibility(p_room uuid,p_is_public boolean) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  update public.rooms set is_public=p_is_public
  where id=p_room and owner_uid=auth.uid() and status='lobby';
  if not found then raise exception 'Only the room owner can change visibility in a lobby'; end if;
end $$;

create or replace function public.set_ready(p_room uuid,p_ready boolean) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_all_ready boolean;
begin
  perform 1 from public.rooms where id=p_room and status='lobby' for update;
  if not found then raise exception 'Room is not accepting ready status'; end if;
  update public.room_players set is_ready=p_ready where room_id=p_room and user_id=auth.uid() and exists(select 1 from public.rooms r where r.id=p_room and r.status='lobby');
  if not found then raise exception 'Cannot update ready status'; end if;
  select not exists(select 1 from public.room_players where room_id=p_room and not is_bot and not is_ready) into v_all_ready;
  if v_all_ready then perform public._start_game(p_room); end if;
end $$;

create or replace function public._remove_room_player(p_room uuid,p_player uuid,p_reason text) returns boolean
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare r public.rooms%rowtype; p public.room_players%rowtype; v_new_owner uuid; v_new_owner_name text; v_new_owner_player uuid;
  v_order uuid[]; v_position integer; v_active integer; v_humans integer; v_live_humans integer; v_current_exists boolean; v_new_moderator uuid; v_turn_seconds integer;
begin
  if p_reason not in ('owner','offline','leave') then raise exception 'Invalid removal reason'; end if;
  select * into r from public.rooms where id=p_room for update;
  if not found then return false; end if;
  select * into p from public.room_players where id=p_player and room_id=p_room for update;
  if not found then return false; end if;

  if p_reason in ('owner','offline') and p.user_id is not null then
    insert into public.room_exit_notices(room_id,user_id,reason)
    values(p_room,p.user_id,p_reason)
    on conflict(room_id,user_id) do update set reason=excluded.reason,created_at=now();
  end if;
  if r.status='playing' and r.phase='clue' and r.current_player_id=p_player and not p.is_bot then
    insert into public.room_messages(room_id,player_id,user_id,nickname,body,kind,round_no)
    values(p_room,p.id,p.user_id,p.nickname,'Я пожалуй промолчу','clue',r.current_round);
  end if;
  delete from public.room_players where id=p_player;
  if r.moderator_uid=p.user_id then update public.rooms set moderator_uid=null where id=p_room; end if;

  if r.owner_uid=p.user_id then
    select id,user_id,nickname into v_new_owner_player,v_new_owner,v_new_owner_name
    from public.room_players where room_id=p_room and user_id is not null and not is_bot
    order by joined_at,id limit 1;
    if v_new_owner is null then
      delete from public.rooms where id=p_room;
      return true;
    end if;
    update public.rooms set owner_uid=v_new_owner,owner_name=v_new_owner_name where id=p_room;
  else
    select owner_uid into v_new_owner from public.rooms where id=p_room;
    select id into v_new_owner_player from public.room_players where room_id=p_room and user_id=v_new_owner;
  end if;

  if r.status='lobby' then
    select count(*),count(*) filter(where not is_bot) into v_active,v_live_humans from public.room_players where room_id=p_room;
    update public.room_settings s set
      host_mode=case when v_active>=4 and v_live_humans>=2 then 'random' else 'bot' end,
      moderator_player_id=null
    where s.room_id=p_room and s.moderator_player_id=p_player;
    if found then
      if v_active>=4 and v_live_humans>=2 then
        select id into v_new_moderator from public.room_players where room_id=p_room and not is_bot order by random() limit 1;
        update public.room_settings set moderator_player_id=v_new_moderator where room_id=p_room;
      end if;
      update public.room_players set is_moderator=(id=v_new_moderator) where room_id=p_room;
      delete from public.room_game_words where room_id=p_room;
    end if;
  end if;

  if r.status<>'playing' then return true; end if;
  if r.moderator_uid=p.user_id then
    update public.rooms set status='finished',phase='results',winner=null,current_player_id=null,turn_ends_at=null where id=p_room;
    insert into public.room_messages(room_id,nickname,body,kind) values(p_room,'Gizmo','Игра окончена — ведущий покинул комнату','system');
    return true;
  end if;
  select count(*) into v_active from public.room_players
  where room_id=p_room and not is_moderator and not is_eliminated;
  select count(*) into v_humans from public.room_players
  where room_id=p_room and not is_moderator and not is_eliminated and not is_bot;
  if v_active<3 or v_humans<1 then
    update public.rooms set status='finished',phase='results',winner=null,current_player_id=null,turn_ends_at=null
    where id=p_room;
    insert into public.room_messages(room_id,nickname,body,kind) values(p_room,'Gizmo','Игра окончена — не хватает игроков','system');
    return true;
  end if;

  if r.phase='moderator_setup' then
    select array_agg(id order by joined_at,id) into v_order from public.room_players
    where room_id=p_room and not is_moderator and not is_eliminated;
    update public.rooms set turn_order=v_order,current_player_id=null,turn_pos=0 where id=p_room;
    return true;
  end if;

  if r.phase in ('countdown','clue') then
    select array_agg(id order by joined_at,id) into v_order from public.room_players
    where room_id=p_room and not is_moderator and not is_eliminated;
    select exists(select 1 from public.room_players where id=r.current_player_id and room_id=p_room) into v_current_exists;
    v_position:=array_position(v_order,r.current_player_id);
    if v_position is null then v_position:=least(greatest(r.turn_pos,1),coalesce(array_length(v_order,1),1)); end if;
    select turn_seconds into v_turn_seconds from public.room_settings where room_id=p_room;
    update public.rooms set
      turn_order=v_order,
      turn_pos=v_position,
      current_player_id=v_order[v_position],
      phase=case when r.phase='countdown' or v_current_exists then r.phase else 'clue' end,
      turn_ends_at=case when r.phase='countdown' or v_current_exists then r.turn_ends_at else now()+make_interval(secs=>v_turn_seconds) end
    where id=p_room;
  end if;
  return true;
end $$;

create or replace function public.kick_player(p_room uuid,p_player uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  if not public.is_room_owner(p_room) then raise exception 'Only the room owner can remove players'; end if;
  perform 1 from public.rooms where id=p_room and status='lobby' for update;
  if not found then raise exception 'Game already started'; end if;
  if not exists(select 1 from public.room_players where id=p_player and room_id=p_room and user_id is distinct from auth.uid()) then
    raise exception 'Player cannot be removed';
  end if;
  perform public._remove_room_player(p_room,p_player,'owner');
end $$;

create or replace function public.leave_room(p_room uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_player uuid;
begin
  select id into v_player from public.room_players where room_id=p_room and user_id=auth.uid();
  if v_player is null then raise exception 'Join the room first'; end if;
  perform public._remove_room_player(p_room,v_player,'leave');
end $$;

create or replace function public.room_heartbeat(p_room uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare p public.room_players%rowtype;
begin
  select * into p from public.room_players where room_id=p_room and user_id=auth.uid() for update;
  if not found then raise exception 'Join the room first'; end if;
  insert into public.room_presence(player_id,room_id,user_id,last_seen_at)
  values(p.id,p.room_id,p.user_id,now())
  on conflict(player_id) do update set room_id=excluded.room_id,user_id=excluded.user_id,last_seen_at=excluded.last_seen_at;
end $$;

create or replace function public.expire_disconnected_players(p_room uuid) returns integer
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare p record; v_removed integer:=0;
begin
  perform 1 from public.rooms where id=p_room for update;
  if not found or not public.is_room_member(p_room) then raise exception 'Join the room first'; end if;
  for p in
    select rp.id from public.room_players rp
    left join public.room_presence presence on presence.player_id=rp.id
    where rp.room_id=p_room and not rp.is_bot and rp.user_id is not null
      and (presence.last_seen_at is null or presence.last_seen_at<now()-interval '90 seconds')
    order by rp.joined_at
    for update of rp
  loop
    if public._remove_room_player(p_room,p.id,'offline') then v_removed:=v_removed+1; end if;
  end loop;
  return v_removed;
end $$;

create or replace function public.consume_room_removal_notice(p_room uuid) returns text
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_reason text;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  select reason into v_reason from public.room_exit_notices where room_id=p_room and user_id=auth.uid();
  if v_reason is not null then delete from public.room_exit_notices where room_id=p_room and user_id=auth.uid(); end if;
  return v_reason;
end $$;

create or replace function public.add_test_bot(p_room uuid) returns uuid
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_id uuid; v_number integer; v_name text;
begin
  if not public.is_room_owner(p_room) then raise exception 'Only the owner can add a bot'; end if;
  perform 1 from public.rooms where id=p_room and status='lobby' for update;
  if not found then raise exception 'Game already started'; end if;
  if (select player_count from public.rooms where id=p_room)>=(select max_players from public.room_settings where room_id=p_room) then raise exception 'Room is full'; end if;
  select count(*)+1 into v_number from public.room_players where room_id=p_room and is_bot;
  v_name:=public._unique_room_nickname(p_room,'Бот '||v_number);
  insert into public.room_players(room_id,nickname,is_bot,is_ready) values(p_room,v_name,true,true) returning id into v_id;
  if (select player_count from public.rooms where id=p_room)>=3 and not exists(select 1 from public.room_players where room_id=p_room and not is_bot and not is_ready) then perform public._start_game(p_room); end if;
  return v_id;
end $$;

drop function if exists public.start_game(uuid,text,text);
create or replace function public.update_room_profile(p_room uuid,p_name text,p_avatar text) returns text
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_player public.room_players%rowtype; v_name text:=left(trim(p_name),18);
begin
  if auth.uid() is null or char_length(v_name)<1 then raise exception 'Nickname required'; end if;
  if p_avatar is not null and (char_length(p_avatar)>40000 or p_avatar not like 'data:image/webp;base64,%') then raise exception 'Invalid avatar'; end if;
  perform 1 from public.rooms where id=p_room for update;
  select * into v_player from public.room_players where room_id=p_room and user_id=auth.uid() for update;
  if not found then raise exception 'Join the room first'; end if;
  v_name:=public._unique_room_nickname(p_room,v_name,v_player.id);
  update public.room_players set nickname=v_name,avatar=p_avatar where id=v_player.id;
  update public.rooms set owner_name=v_name where id=p_room and owner_uid=auth.uid();
  return v_name;
end $$;

create or replace function public._start_game(p_room uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare r public.rooms%rowtype; s public.room_settings%rowtype; v_humans integer; v_total integer; v_active integer; v_active_humans integer; v_moderator_player uuid; v_moderator uuid; v_order uuid[]; v_spy uuid; v_pair text[]; p record;
begin
  select * into r from public.rooms where id=p_room for update;
  if not found or r.status<>'lobby' then return; end if;
  select * into s from public.room_settings where room_id=p_room;
  select count(*),count(*) filter(where not is_bot) into v_total,v_humans from public.room_players where room_id=p_room;
  if exists(select 1 from public.room_players where room_id=p_room and not is_bot and not is_ready) then return; end if;
  if v_total<4 or v_humans<2 or s.host_mode='bot' then
    s.host_mode:='bot';
    s.moderator_player_id:=null;
    v_moderator:=null;
  elsif s.host_mode='random' then
    if exists(select 1 from public.room_players where id=s.moderator_player_id and room_id=p_room and not is_bot) then
      select id,user_id into v_moderator_player,v_moderator from public.room_players where id=s.moderator_player_id;
    else
      select id,user_id into v_moderator_player,v_moderator from public.room_players where room_id=p_room and not is_bot order by random() limit 1;
    end if;
    s.moderator_player_id:=v_moderator_player;
  else
    if s.host_mode<>'player' or s.moderator_player_id is null or not exists(select 1 from public.room_players where id=s.moderator_player_id and room_id=p_room and not is_bot) then return; end if;
    select user_id into v_moderator from public.room_players where id=s.moderator_player_id;
  end if;
  v_moderator_player:=s.moderator_player_id;
  update public.room_settings set host_mode=s.host_mode,moderator_player_id=v_moderator_player where room_id=p_room;
  update public.room_players set is_moderator=coalesce(id=v_moderator_player,false),is_eliminated=false where room_id=p_room;
  select count(*),count(*) filter (where not is_bot) into v_active,v_active_humans
  from public.room_players where room_id=p_room and id is distinct from s.moderator_player_id;
  if v_active<3 or v_active_humans<1 then return; end if;
  if v_moderator_player is null then
    select pair into v_pair from (values
      (array['кофе','чай']::text[]),(array['кинотеатр','театр']::text[]),(array['самолёт','вертолёт']::text[]),
      (array['пицца','пирог']::text[]),(array['море','бассейн']::text[]),(array['лифт','эскалатор']::text[]),
      (array['зубная щётка','расчёска']::text[]),(array['поезд','метро']::text[]),(array['арбуз','дыня']::text[]),
      (array['библиотека','книжный магазин']::text[]),(array['снеговик','снежная баба']::text[]),(array['пингвин','тюлень']::text[])
    ) as word_pairs(pair) order by random() limit 1;
    select id into v_spy from public.room_players where room_id=p_room and id is distinct from v_moderator_player order by random() limit 1;
  end if;
  select array_agg(id order by joined_at) into v_order from public.room_players where room_id=p_room and not is_moderator;
  if coalesce(array_length(v_order,1),0)<3 then return; end if;
  delete from public.room_messages where room_id=p_room;
  if v_moderator_player is not null then
    delete from public.room_game_words where room_id=p_room;
    insert into public.room_messages(room_id,nickname,body,kind)
    values(p_room,'Gizmo','Игра началась — ведущий выбирает слова и шпиона','system');
    update public.rooms set status='playing',phase='moderator_setup',current_round=0,turn_order=v_order,turn_pos=0,
      current_player_id=null,turn_ends_at=now()+interval '60 seconds',moderator_uid=v_moderator,winner=null where id=p_room;
    return;
  end if;
  delete from public.room_secrets where room_id=p_room;
  for p in select id,is_bot from public.room_players where id=any(v_order) loop
    insert into public.room_secrets(room_id,player_id,role,word) values(p_room,p.id,case when p.id=v_spy then 'spy' else 'player' end,case when p.id=v_spy then v_pair[2] else v_pair[1] end);
  end loop;
  insert into public.room_messages(room_id,nickname,body,kind,round_no) values(p_room,'Gizmo','Раунд 1','system',1);
  update public.rooms set status='playing',phase='countdown',current_round=1,turn_order=v_order,turn_pos=1,current_player_id=v_order[1],turn_ends_at=now()+interval '3 seconds',moderator_uid=v_moderator,winner=null where id=p_room;
end $$;

create or replace function public.begin_turn(p_room uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare r public.rooms%rowtype; s public.room_settings%rowtype;
begin
  select * into r from public.rooms where id=p_room for update;
  if r.phase<>'countdown' or r.turn_ends_at>now() then return; end if;
  select * into s from public.room_settings where room_id=p_room;
  update public.rooms set phase='clue',turn_ends_at=now()+make_interval(secs=>s.turn_seconds) where id=p_room;
end $$;

create or replace function public.resolve_expired_moderator_setup(p_room uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare r public.rooms%rowtype; v_pair text[]; v_spy uuid; p record;
begin
  if not public.is_room_member(p_room) then raise exception 'Join the room first'; end if;
  select * into r from public.rooms where id=p_room for update;
  if r.status<>'playing' or r.phase<>'moderator_setup' or r.turn_ends_at>now() then return; end if;
  select pair into v_pair from (values
    (array['кофе','чай']::text[]),(array['кинотеатр','театр']::text[]),(array['самолёт','вертолёт']::text[]),
    (array['пицца','пирог']::text[]),(array['море','бассейн']::text[]),(array['лифт','эскалатор']::text[]),
    (array['зубная щётка','расчёска']::text[]),(array['поезд','метро']::text[]),(array['арбуз','дыня']::text[]),
    (array['библиотека','книжный магазин']::text[]),(array['снеговик','снежная баба']::text[]),(array['пингвин','тюлень']::text[])
  ) as word_pairs(pair) order by random() limit 1;
  select id into v_spy from public.room_players where room_id=p_room and not is_moderator and not is_eliminated order by random() limit 1;
  insert into public.room_game_words(room_id,player_word,spy_word,spy_player_id)
  values(p_room,v_pair[1],v_pair[2],v_spy)
  on conflict(room_id) do update set player_word=excluded.player_word,spy_word=excluded.spy_word,spy_player_id=excluded.spy_player_id;
  delete from public.room_secrets where room_id=p_room;
  for p in select id from public.room_players where id=any(r.turn_order) loop
    insert into public.room_secrets(room_id,player_id,role,word)
    values(p_room,p.id,case when p.id=v_spy then 'spy' else 'player' end,case when p.id=v_spy then v_pair[2] else v_pair[1] end);
  end loop;
  insert into public.room_messages(room_id,nickname,body,kind)
  values(p_room,'Gizmo','Ведущий не успел — Gizmo выбрал слова и шпиона','system');
  insert into public.room_messages(room_id,nickname,body,kind,round_no)
  values(p_room,'Gizmo','Раунд 1','system',1);
  update public.rooms set phase='countdown',current_round=1,turn_pos=1,current_player_id=turn_order[1],
    turn_ends_at=now()+interval '3 seconds' where id=p_room;
end $$;

create or replace function public._advance_turn(p_room uuid,p_timeout boolean default false) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare r public.rooms%rowtype; s public.room_settings%rowtype; p public.room_players%rowtype; v_next integer; v_len integer;
begin
  select * into r from public.rooms where id=p_room for update;
  if r.status<>'playing' or r.phase<>'clue' then return; end if;
  select * into s from public.room_settings where room_id=p_room;
  if not p_timeout and not public.is_room_owner(p_room) and not exists(select 1 from public.room_players where id=r.current_player_id and (user_id=auth.uid() or is_bot) and public.is_room_member(p_room)) then raise exception 'Not your turn'; end if;
  if p_timeout and r.turn_ends_at>now() then raise exception 'Turn has not ended'; end if;
  if p_timeout then
    select * into p from public.room_players where id=r.current_player_id and room_id=p_room;
    if found and not p.is_bot then
      insert into public.room_messages(room_id,player_id,user_id,nickname,body,kind,round_no)
      values(p_room,p.id,p.user_id,p.nickname,'Я пожалуй промолчу','clue',r.current_round);
    end if;
  end if;
  v_next:=r.turn_pos+1; v_len:=coalesce(array_length(r.turn_order,1),0);
  if v_next<=v_len then
    update public.rooms set turn_pos=v_next,current_player_id=turn_order[v_next],turn_ends_at=now()+make_interval(secs=>s.turn_seconds),phase='clue' where id=p_room;
    return;
  end if;
  if r.current_round>=s.vote_after_rounds then
    update public.rooms set phase='voting',current_player_id=null,turn_ends_at=now()+make_interval(secs=>s.vote_seconds) where id=p_room;
  else
    insert into public.room_messages(room_id,nickname,body,kind,round_no) values(p_room,'Gizmo','Раунд '||(r.current_round+1)::text,'system',r.current_round+1);
    update public.rooms set current_round=current_round+1,turn_pos=1,current_player_id=turn_order[1],
      turn_ends_at=now()+interval '7 seconds',phase='countdown' where id=p_room;
  end if;
end $$;

create or replace function public.send_room_message(p_room uuid,p_body text) returns uuid
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_player public.room_players%rowtype; v_status text; v_id uuid; v_count integer;
begin
  select * into v_player from public.room_players where room_id=p_room and user_id=auth.uid();
  if not found then raise exception 'Join the room first'; end if;
  if char_length(trim(p_body)) not between 1 and 300 then raise exception 'Message must be 1-300 characters'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_room::text||':'||auth.uid()::text,0));
  select count(*) into v_count from public.room_messages where room_id=p_room and user_id=auth.uid() and created_at>now()-interval '10 seconds';
  if v_count>=3 then raise exception 'Slow down: maximum 3 messages per 10 seconds'; end if;
  select status into v_status from public.rooms where id=p_room;
  if v_status not in ('lobby','finished') then raise exception 'Chat is closed during this phase'; end if;
  insert into public.room_messages(room_id,player_id,user_id,nickname,body,kind) values(p_room,v_player.id,auth.uid(),v_player.nickname,trim(p_body),'chat') returning id into v_id; return v_id;
end $$;

create or replace function public.send_turn_message(p_room uuid,p_body text) returns uuid
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare r public.rooms%rowtype; s public.room_settings%rowtype; p public.room_players%rowtype; v_id uuid; v_count integer;
begin
  select * into r from public.rooms where id=p_room;
  select * into s from public.room_settings where room_id=p_room;
  select * into p from public.room_players where id=r.current_player_id and user_id=auth.uid();
  if not found or r.phase<>'clue' or s.game_mode<>'chat' then raise exception 'It is not your chat turn'; end if;
  if char_length(trim(p_body)) not between 1 and 300 then raise exception 'Message must be 1-300 characters'; end if;
  if exists(select 1 from public.room_secrets x where x.room_id=p_room and char_length(x.word)>=2
    and strpos(lower(regexp_replace(p_body,'[^[:alnum:]]','','g')),lower(regexp_replace(x.word,'[^[:alnum:]]','','g')))>0) then raise exception 'Do not reveal the secret word in chat'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_room::text||':'||auth.uid()::text,0));
  select count(*) into v_count from public.room_messages where room_id=p_room and user_id=auth.uid() and created_at>now()-interval '10 seconds';
  if v_count>=3 then raise exception 'Slow down: maximum 3 messages per 10 seconds'; end if;
  insert into public.room_messages(room_id,player_id,user_id,nickname,body,kind,round_no) values(p_room,p.id,auth.uid(),p.nickname,trim(p_body),'clue',r.current_round) returning id into v_id;
  perform public._advance_turn(p_room,false); return v_id;
end $$;

create or replace function public.complete_live_turn(p_room uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  if not exists(select 1 from public.rooms r join public.room_settings s on s.room_id=r.id where r.id=p_room and r.phase='clue' and s.game_mode='live' and exists(select 1 from public.room_players p where p.id=r.current_player_id and p.user_id=auth.uid())) then raise exception 'It is not your live turn'; end if;
  perform public._advance_turn(p_room,false);
end $$;

create or replace function public.advance_expired_turn(p_room uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin perform public._advance_turn(p_room,true); end $$;

create or replace function public.run_bot_turn(p_room uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare r public.rooms%rowtype; p public.room_players%rowtype; s public.room_settings%rowtype; v_text text;
begin
  if not public.is_room_member(p_room) then raise exception 'Join the room first'; end if;
  select * into r from public.rooms where id=p_room for update;
  select * into p from public.room_players where id=r.current_player_id and is_bot;
  if not found or r.phase<>'clue' then raise exception 'Bot is not up'; end if;
  select * into s from public.room_settings where room_id=p_room;
  v_text:=(array['Слишком очевидно, я бы так не сказал.','Подозрительная штука, но ладно.','У меня есть версия, пока молчу.','Кажется, кто-то тут хитрит.'])[floor(random()*4+1)::int];
  if s.game_mode='chat' then insert into public.room_messages(room_id,player_id,nickname,body,kind,round_no) values(p_room,p.id,p.nickname,v_text,'clue',r.current_round); end if;
  perform public._advance_turn(p_room,false);
end $$;

create or replace function public.set_room_reaction(p_room uuid,p_message uuid,p_reaction text) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_user uuid:=auth.uid();
begin
  if p_reaction not in ('+','-','=') or not public.is_room_member(p_room) then raise exception 'Invalid reaction'; end if;
  if not exists(select 1 from public.room_messages where id=p_message and room_id=p_room) then raise exception 'Message not found'; end if;
  insert into public.room_reactions(message_id,room_id,user_id,reaction) values(p_message,p_room,v_user,p_reaction)
  on conflict(message_id,user_id) do update set reaction=excluded.reaction;
end $$;

create or replace function public.vote_for(p_room uuid,p_target uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare r public.rooms%rowtype; v_voter uuid;
begin
  select * into r from public.rooms where id=p_room for update;
  if r.status<>'playing' or r.phase<>'voting' then raise exception 'Voting is not open'; end if;
  if r.turn_ends_at is null or r.turn_ends_at<=now() then raise exception 'Voting time has ended'; end if;
  if r.moderator_uid=auth.uid() then raise exception 'The game leader cannot vote'; end if;
  select id into v_voter from public.room_players where room_id=p_room and user_id=auth.uid() and not is_moderator and not is_eliminated and not is_bot;
  if v_voter is null then raise exception 'You cannot vote'; end if;
  if p_target=v_voter or not exists(select 1 from public.room_players where id=p_target and room_id=p_room and not is_moderator and not is_eliminated) then raise exception 'Invalid target'; end if;
  insert into public.room_votes(room_id,round_no,voter_id,target_id) values(p_room,r.current_round,v_voter,p_target) on conflict(room_id,round_no,voter_id) do update set target_id=excluded.target_id;
  perform public._resolve_vote(p_room,false);
end $$;

create or replace function public._resolve_vote(p_room uuid,p_timeout boolean default false) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare r public.rooms%rowtype; s public.room_settings%rowtype; v_required integer; v_done integer; v_target uuid; v_top integer; v_second integer; v_spy boolean:=false; v_alive integer; v_order uuid[];
begin
  select * into r from public.rooms where id=p_room for update;
  if r.status<>'playing' or r.phase<>'voting' then return; end if;
  if p_timeout and (r.turn_ends_at is null or r.turn_ends_at>now()) then return; end if;
  select count(*) into v_required from public.room_players where room_id=p_room and not is_moderator and not is_eliminated and not is_bot;
  select count(*) into v_done from public.room_votes where room_id=p_room and round_no=r.current_round;
  if v_done<v_required and not p_timeout then return; end if;
  select target_id,count(*) into v_target,v_top from public.room_votes where room_id=p_room and round_no=r.current_round group by target_id order by count(*) desc limit 1;
  select count(*) into v_second from public.room_votes where room_id=p_room and round_no=r.current_round group by target_id order by count(*) desc offset 1 limit 1;
  if v_target is not null and coalesce(v_top,0)>coalesce(v_second,0) then
    update public.room_players set is_eliminated=true where id=v_target;
    select exists(select 1 from public.room_secrets where room_id=p_room and player_id=v_target and role='spy') into v_spy;
  end if;
  select count(*) into v_alive from public.room_players where room_id=p_room and not is_moderator and not is_eliminated;
  if coalesce(v_spy,false) or v_alive<=2 then
    update public.rooms set status='finished',phase='results',winner=case when v_spy then 'players' else 'spy' end,current_player_id=null,turn_ends_at=null where id=p_room;
    insert into public.room_messages(room_id,nickname,body,kind) values(p_room,'Gizmo','Игра окончена','system');
    return;
  end if;
  select * into s from public.room_settings where room_id=p_room;
  select array_agg(id order by joined_at) into v_order from public.room_players where room_id=p_room and not is_moderator and not is_eliminated;
  insert into public.room_messages(room_id,nickname,body,kind,round_no) values(p_room,'Gizmo','Раунд '||(r.current_round+1)::text,'system',r.current_round+1);
  update public.rooms set current_round=current_round+1,turn_order=v_order,turn_pos=1,current_player_id=v_order[1],
    turn_ends_at=now()+interval '7 seconds',phase='countdown' where id=p_room;
end $$;

create or replace function public.resolve_expired_vote(p_room uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  if not public.is_room_member(p_room) then raise exception 'Join the room first'; end if;
  perform public._resolve_vote(p_room,true);
end $$;

create or replace function public.get_my_game_word(p_room uuid) returns text
language sql stable security definer set search_path=public,auth,pg_temp as $$
  select s.word from public.room_secrets s
  join public.room_players p on p.id=s.player_id and p.user_id=auth.uid() and not p.is_moderator
  join public.rooms r on r.id=s.room_id and r.status='playing'
  where s.room_id=p_room limit 1
$$;

create or replace function public.can_spy_confess(p_room uuid) returns boolean
language sql stable security definer set search_path=public,auth,pg_temp as $$
  select exists(select 1 from public.room_players p join public.rooms r on r.id=p.room_id
    where p.room_id=p_room and p.user_id=auth.uid() and not p.is_bot and not p.is_moderator and not p.is_eliminated
      and r.status='playing' and r.phase='voting' and r.turn_ends_at>now())
$$;

create or replace function public.confess_spy(p_room uuid,p_guess text) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare r public.rooms%rowtype; v_spy uuid; v_role text; v_nickname text; v_player_word text; v_correct boolean; v_winner text; v_result text;
begin
  select * into r from public.rooms where id=p_room for update;
  if r.status<>'playing' or r.phase<>'voting' then raise exception 'Confession is only available during voting'; end if;
  if r.turn_ends_at is null or r.turn_ends_at<=now() then raise exception 'Voting time has ended'; end if;
  select s.player_id,s.role,p.nickname into v_spy,v_role,v_nickname
  from public.room_secrets s join public.room_players p on p.id=s.player_id
  where s.room_id=p_room and p.user_id=auth.uid() and not p.is_bot and not p.is_moderator and not p.is_eliminated;
  if v_spy is null or p_guess is null or char_length(trim(p_guess)) not between 2 and 60 then raise exception 'Only an active player can guess'; end if;
  select word into v_player_word from public.room_secrets where room_id=p_room and role='player' limit 1;
  v_correct:=lower(trim(p_guess))=lower(trim(v_player_word));
  v_winner:=case when v_role<>'spy' or v_correct then 'spy' else 'players' end;
  v_result:=case when v_role<>'spy' then 'Мирный игрок '||v_nickname||' признался — шпион победил'
    when v_correct then 'Шпион угадал слово — шпион победил'
    else 'Шпион не угадал слово — победа мирных' end;
  update public.rooms set status='finished',phase='results',winner=v_winner,current_player_id=null,turn_ends_at=null where id=p_room;
  insert into public.room_messages(room_id,nickname,body,kind) values(p_room,'Gizmo',v_result,'system');
end $$;

create or replace function public.restart_room(p_room uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  if not public.is_room_owner(p_room) or (select status from public.rooms where id=p_room)<>'finished' then raise exception 'Only the owner can restart a finished game'; end if;
  delete from public.room_secrets where room_id=p_room; delete from public.room_votes where room_id=p_room; delete from public.room_game_words where room_id=p_room;
  update public.room_players set is_ready=is_bot,is_moderator=(id=(select moderator_player_id from public.room_settings where room_id=p_room)),is_eliminated=false where room_id=p_room;
  update public.rooms set status='lobby',phase='setup',current_round=0,turn_order='{}',turn_pos=0,current_player_id=null,turn_ends_at=null,moderator_uid=null,winner=null where id=p_room;
end $$;

create or replace function public.check_room_rate(p_room uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare n integer;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_room::text||':'||auth.uid()::text,0));
  select count(*) into n from public.room_messages where room_id=p_room and user_id=auth.uid() and created_at>now()-interval '10 seconds';
  if n>=3 then raise exception 'Maximum 3 messages per 10 seconds'; end if;
end $$;

alter table public.rooms replica identity full;
alter table public.room_players replica identity full;
alter table public.room_settings replica identity full;
alter table public.room_messages replica identity full;
alter table public.room_reactions replica identity full;
alter table public.room_secrets replica identity full;
do $$ begin
  execute 'alter publication supabase_realtime add table public.rooms, public.room_players, public.room_settings, public.room_messages, public.room_reactions, public.room_secrets';
exception when duplicate_object then null; when undefined_object then null;
end $$;

grant execute on function public.is_room_member(uuid),public.is_room_owner(uuid) to authenticated;
revoke all on function public.create_room(text,text),public.join_room(text,text,text),public.update_room_settings(uuid,integer,text,uuid,text,integer,integer,integer),public.save_moderator_game(uuid,text,text,uuid),public.set_room_visibility(uuid,boolean),public.set_ready(uuid,boolean),public.kick_player(uuid,uuid),public.add_test_bot(uuid),public.update_room_profile(uuid,text,text),public.leave_room(uuid),public.room_heartbeat(uuid),public.expire_disconnected_players(uuid),public.consume_room_removal_notice(uuid),public.get_my_game_word(uuid),public.can_spy_confess(uuid),public.confess_spy(uuid,text),public.resolve_expired_vote(uuid),public.resolve_expired_moderator_setup(uuid) from public,anon;
grant execute on function public.create_room(text,text) to authenticated;
grant execute on function public.join_room(text,text,text) to authenticated;
grant execute on function public.update_room_settings(uuid,integer,text,uuid,text,integer,integer,integer) to authenticated;
grant execute on function public.save_moderator_game(uuid,text,text,uuid),public.get_my_game_word(uuid),public.can_spy_confess(uuid),public.confess_spy(uuid,text),public.resolve_expired_vote(uuid),public.resolve_expired_moderator_setup(uuid) to authenticated;
grant execute on function public.set_room_visibility(uuid,boolean) to authenticated;
grant execute on function public.set_ready(uuid,boolean) to authenticated;
grant execute on function public.kick_player(uuid,uuid) to authenticated;
grant execute on function public.add_test_bot(uuid) to authenticated;
grant execute on function public.update_room_profile(uuid,text,text) to authenticated;
grant execute on function public.leave_room(uuid),public.room_heartbeat(uuid),public.expire_disconnected_players(uuid),public.consume_room_removal_notice(uuid) to authenticated;
revoke all on function public._unique_room_nickname(uuid,text,uuid),public._start_game(uuid),public._remove_room_player(uuid,uuid,text),public._resolve_vote(uuid,boolean) from public,anon,authenticated;
grant execute on function public.begin_turn(uuid) to authenticated;
grant execute on function public.send_room_message(uuid,text) to authenticated;
grant execute on function public.send_turn_message(uuid,text) to authenticated;
grant execute on function public.complete_live_turn(uuid) to authenticated;
grant execute on function public.advance_expired_turn(uuid) to authenticated;
grant execute on function public.run_bot_turn(uuid) to authenticated;
grant execute on function public.set_room_reaction(uuid,uuid,text) to authenticated;
grant execute on function public.vote_for(uuid,uuid) to authenticated;
grant execute on function public.restart_room(uuid) to authenticated;