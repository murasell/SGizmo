create extension if not exists pgcrypto;

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[0-9]{5}$'),
  owner_uid uuid not null references auth.users(id) on delete cascade,
  owner_name text not null,
  is_public boolean not null default true,
  status text not null default 'lobby' check (status in ('lobby','playing','finished')),
  phase text not null default 'setup' check (phase in ('setup','countdown','clue','voting','results')),
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
  host_mode text not null default 'owner' check (host_mode in ('owner','random','bot')),
  game_mode text not null default 'chat' check (game_mode in ('chat','live')),
  turn_seconds integer not null default 30 check (turn_seconds between 15 and 60),
  vote_after_rounds integer not null default 2 check (vote_after_rounds between 2 and 4)
);

create table if not exists public.room_players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  nickname text not null check (char_length(nickname) between 1 and 18),
  is_bot boolean not null default false,
  is_ready boolean not null default false,
  is_moderator boolean not null default false,
  is_eliminated boolean not null default false,
  joined_at timestamptz not null default now(),
  check ((is_bot and user_id is null) or (not is_bot and user_id is not null))
);
create unique index if not exists room_players_user_unique on public.room_players(room_id,user_id) where user_id is not null;
create unique index if not exists room_players_one_bot on public.room_players(room_id) where is_bot;
create index if not exists room_players_room_idx on public.room_players(room_id,joined_at);
alter table public.rooms drop constraint if exists rooms_current_player_fk;
alter table public.rooms add constraint rooms_current_player_fk foreign key (current_player_id) references public.room_players(id) on delete set null deferrable initially deferred;

create table if not exists public.room_secrets (
  room_id uuid not null references public.rooms(id) on delete cascade,
  player_id uuid not null references public.room_players(id) on delete cascade,
  role text not null check (role in ('spy','player')),
  word text not null,
  primary key(room_id,player_id)
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
alter table public.room_messages enable row level security;
alter table public.room_reactions enable row level security;
alter table public.room_votes enable row level security;
drop policy if exists rooms_read on public.rooms;
create policy rooms_read on public.rooms for select to authenticated using ((is_public and status='lobby') or public.is_room_member(id));
drop policy if exists settings_read on public.room_settings;
create policy settings_read on public.room_settings for select to authenticated using (public.is_room_owner(room_id) or (public.is_room_member(room_id) and exists(select 1 from public.rooms r where r.id=room_id and r.status<>'lobby')));
drop policy if exists players_read on public.room_players;
create policy players_read on public.room_players for select to authenticated using (public.is_room_member(room_id));
drop policy if exists secrets_read on public.room_secrets;
create policy secrets_read on public.room_secrets for select to authenticated using (
  exists(select 1 from public.room_players p where p.id=player_id and p.user_id=auth.uid())
  or public.is_room_owner(room_id)
  or exists(select 1 from public.rooms r where r.id=room_id and r.moderator_uid=auth.uid())
  or (exists(select 1 from public.rooms r where r.id=room_id and r.status='finished') and public.is_room_member(room_id))
);
drop policy if exists messages_read on public.room_messages;
create policy messages_read on public.room_messages for select to authenticated using (public.is_room_member(room_id));
drop policy if exists reactions_read on public.room_reactions;
create policy reactions_read on public.room_reactions for select to authenticated using (public.is_room_member(room_id));
drop policy if exists votes_read on public.room_votes;
create policy votes_read on public.room_votes for select to authenticated using (public.is_room_owner(room_id) or (public.is_room_member(room_id) and exists(select 1 from public.rooms r where r.id=room_id and r.status='finished')));
grant select on public.rooms,public.room_settings,public.room_players,public.room_secrets,public.room_messages,public.room_reactions,public.room_votes to authenticated;

create or replace function public.create_room(p_name text,p_max integer,p_host text,p_mode text,p_seconds integer,p_vote_rounds integer) returns jsonb
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_room uuid; v_code text; v_name text:=left(trim(p_name),18);
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  if char_length(v_name)<1 then raise exception 'Nickname required'; end if;
  if p_max not between 4 and 8 or p_host not in ('owner','random','bot') or p_mode not in ('chat','live') or p_seconds not between 15 and 60 or p_vote_rounds not between 2 and 4 then raise exception 'Invalid room settings'; end if;
  loop
    v_code:=lpad(floor(random()*100000)::int::text,5,'0');
    insert into public.rooms(code,owner_uid,owner_name) values(v_code,auth.uid(),v_name) on conflict(code) do nothing returning id into v_room;
    exit when v_room is not null;
  end loop;
  insert into public.room_settings(room_id,max_players,host_mode,game_mode,turn_seconds,vote_after_rounds) values(v_room,p_max,p_host,p_mode,p_seconds,p_vote_rounds);
  insert into public.room_players(room_id,user_id,nickname,is_ready) values(v_room,auth.uid(),v_name,true);
  return jsonb_build_object('id',v_room,'code',v_code);
end $$;

create or replace function public.join_room(p_code text,p_name text) returns uuid
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare r public.rooms%rowtype; s public.room_settings%rowtype; v_player uuid; v_name text:=left(trim(p_name),18);
begin
  if auth.uid() is null or p_code !~ '^[0-9]{5}$' or char_length(v_name)<1 then raise exception 'Invalid code or nickname'; end if;
  select * into r from public.rooms where code=p_code for update;
  if not found or r.status<>'lobby' then raise exception 'Room not found or already started'; end if;
  select * into s from public.room_settings where room_id=r.id;
  select id into v_player from public.room_players where room_id=r.id and user_id=auth.uid();
  if v_player is not null then update public.room_players set nickname=v_name where id=v_player; return r.id; end if;
  if r.player_count>=s.max_players then raise exception 'Room is full'; end if;
  insert into public.room_players(room_id,user_id,nickname) values(r.id,auth.uid(),v_name) returning id into v_player;
  return r.id;
end $$;

create or replace function public.update_room_settings(p_room uuid,p_max integer,p_host text,p_mode text,p_seconds integer,p_vote_rounds integer) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  if not public.is_room_owner(p_room) then raise exception 'Only the room owner can change settings'; end if;
  if (select status from public.rooms where id=p_room)<>'lobby' then raise exception 'Game already started'; end if;
  if p_max not between 4 and 8 or p_host not in ('owner','random','bot') or p_mode not in ('chat','live') or p_seconds not between 15 and 60 or p_vote_rounds not between 2 and 4 then raise exception 'Invalid settings'; end if;
  if (select player_count from public.rooms where id=p_room)>p_max then raise exception 'Remove players before lowering the limit'; end if;
  update public.room_settings set max_players=p_max,host_mode=p_host,game_mode=p_mode,turn_seconds=p_seconds,vote_after_rounds=p_vote_rounds where room_id=p_room;
end $$;

create or replace function public.set_ready(p_room uuid,p_ready boolean) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  update public.room_players set is_ready=p_ready where room_id=p_room and user_id=auth.uid() and exists(select 1 from public.rooms r where r.id=p_room and r.status='lobby');
  if not found then raise exception 'Cannot update ready status'; end if;
end $$;

create or replace function public.kick_player(p_room uuid,p_player uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  if not public.is_room_owner(p_room) then raise exception 'Only the owner can remove players'; end if;
  delete from public.room_players where id=p_player and room_id=p_room and user_id is distinct from auth.uid() and exists(select 1 from public.rooms r where r.id=p_room and r.status='lobby');
  if not found then raise exception 'Player cannot be removed'; end if;
end $$;

create or replace function public.add_test_bot(p_room uuid) returns uuid
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_id uuid;
begin
  if not public.is_room_owner(p_room) then raise exception 'Only the owner can add a bot'; end if;
  if (select status from public.rooms where id=p_room)<>'lobby' then raise exception 'Game already started'; end if;
  if exists(select 1 from public.room_players where room_id=p_room and is_bot) then raise exception 'Only one test bot is allowed'; end if;
  if (select player_count from public.rooms where id=p_room)>=(select max_players from public.room_settings where room_id=p_room) then raise exception 'Room is full'; end if;
  insert into public.room_players(room_id,nickname,is_bot,is_ready) values(p_room,'Бот',true,true) returning id into v_id; return v_id;
end $$;

create or replace function public.start_game(p_room uuid,p_player_word text,p_spy_word text) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare r public.rooms%rowtype; s public.room_settings%rowtype; v_humans integer; v_moderator uuid; v_order uuid[]; v_spy uuid; p record;
begin
  select * into r from public.rooms where id=p_room for update;
  if not found or r.owner_uid<>auth.uid() or r.status<>'lobby' then raise exception 'Only the owner can start this lobby'; end if;
  select * into s from public.room_settings where room_id=p_room;
  select count(*) into v_humans from public.room_players where room_id=p_room and not is_bot;
  if exists(select 1 from public.room_players where room_id=p_room and not is_ready) then raise exception 'Everyone must be ready'; end if;
  if (s.host_mode='bot' and v_humans<3) or (s.host_mode<>'bot' and v_humans<4) then raise exception 'Not enough players'; end if;
  if char_length(trim(p_player_word))<2 or char_length(trim(p_spy_word))<2 then raise exception 'Words are required'; end if;
  if s.host_mode='owner' then v_moderator:=r.owner_uid;
  elsif s.host_mode='random' then select user_id into v_moderator from public.room_players where room_id=p_room and not is_bot order by random() limit 1;
  else v_moderator:=null; end if;
  update public.room_players set is_moderator=coalesce(user_id=v_moderator,false),is_eliminated=false where room_id=p_room;
  select array_agg(id order by joined_at) into v_order from public.room_players where room_id=p_room and not is_moderator;
  if coalesce(array_length(v_order,1),0)<3 then raise exception 'Not enough active players'; end if;
  select id into v_spy from public.room_players where id=any(v_order) and not is_bot order by random() limit 1;
  delete from public.room_secrets where room_id=p_room;
  for p in select id,is_bot from public.room_players where id=any(v_order) loop
    insert into public.room_secrets(room_id,player_id,role,word) values(p_room,p.id,case when p.id=v_spy then 'spy' else 'player' end,case when p.id=v_spy then trim(p_spy_word) else trim(p_player_word) end);
  end loop;
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

create or replace function public._advance_turn(p_room uuid,p_timeout boolean default false) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare r public.rooms%rowtype; s public.room_settings%rowtype; v_next integer; v_len integer;
begin
  select * into r from public.rooms where id=p_room for update;
  if r.status<>'playing' or r.phase<>'clue' then return; end if;
  if not p_timeout and not public.is_room_owner(p_room) and not exists(select 1 from public.room_players where id=r.current_player_id and (user_id=auth.uid() or is_bot) and public.is_room_member(p_room)) then raise exception 'Not your turn'; end if;
  if p_timeout and r.turn_ends_at>now() then raise exception 'Turn has not ended'; end if;
  v_next:=r.turn_pos+1; v_len:=coalesce(array_length(r.turn_order,1),0);
  if v_next<=v_len then
    update public.rooms set turn_pos=v_next,current_player_id=turn_order[v_next],turn_ends_at=now()+interval '3 seconds',phase='countdown' where id=p_room;
    return;
  end if;
  select * into s from public.room_settings where room_id=p_room;
  if r.current_round>=s.vote_after_rounds then
    update public.rooms set phase='voting',current_player_id=null,turn_ends_at=null where id=p_room;
  else
    update public.rooms set current_round=current_round+1,turn_pos=1,current_player_id=turn_order[1],turn_ends_at=now()+interval '3 seconds',phase='countdown' where id=p_room;
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
declare r public.rooms%rowtype; v_voter uuid; v_required integer; v_done integer; v_target uuid; v_top integer; v_second integer; v_spy boolean; v_alive integer; v_order uuid[];
begin
  select * into r from public.rooms where id=p_room for update;
  if r.status<>'playing' or r.phase<>'voting' then raise exception 'Voting is not open'; end if;
  select id into v_voter from public.room_players where room_id=p_room and user_id=auth.uid() and not is_moderator and not is_eliminated;
  if v_voter is null then raise exception 'You cannot vote'; end if;
  if not exists(select 1 from public.room_players where id=p_target and room_id=p_room and not is_moderator and not is_eliminated) then raise exception 'Invalid target'; end if;
  insert into public.room_votes(room_id,round_no,voter_id,target_id) values(p_room,r.current_round,v_voter,p_target) on conflict(room_id,round_no,voter_id) do update set target_id=excluded.target_id;
  select count(*) into v_required from public.room_players where room_id=p_room and not is_moderator and not is_eliminated and not is_bot;
  select count(*) into v_done from public.room_votes where room_id=p_room and round_no=r.current_round;
  if v_done<v_required then return; end if;
  select target_id,count(*) into v_target,v_top from public.room_votes where room_id=p_room and round_no=r.current_round group by target_id order by count(*) desc limit 1;
  select count(*) into v_second from public.room_votes where room_id=p_room and round_no=r.current_round group by target_id order by count(*) desc offset 1 limit 1;
  if v_target is not null and coalesce(v_top,0)>coalesce(v_second,0) then update public.room_players set is_eliminated=true where id=v_target; end if;
  select exists(select 1 from public.room_secrets where room_id=p_room and player_id=v_target and role='spy') into v_spy;
  select count(*) into v_alive from public.room_players where room_id=p_room and not is_moderator and not is_eliminated and not is_bot;
  if coalesce(v_spy,false) then
    update public.rooms set status='finished',phase='results',winner='players',current_player_id=null,turn_ends_at=null where id=p_room; return;
  elsif v_alive<=2 then
    update public.rooms set status='finished',phase='results',winner='spy',current_player_id=null,turn_ends_at=null where id=p_room; return;
  end if;
  select array_agg(id order by joined_at) into v_order from public.room_players where room_id=p_room and not is_moderator and not is_eliminated;
  update public.rooms set current_round=current_round+1,turn_order=v_order,turn_pos=1,current_player_id=v_order[1],turn_ends_at=now()+interval '3 seconds',phase='countdown' where id=p_room;
end $$;

create or replace function public.restart_room(p_room uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  if not public.is_room_owner(p_room) or (select status from public.rooms where id=p_room)<>'finished' then raise exception 'Only the owner can restart a finished game'; end if;
  delete from public.room_secrets where room_id=p_room; delete from public.room_votes where room_id=p_room;
  update public.room_players set is_ready=(user_id=auth.uid() or is_bot),is_moderator=false,is_eliminated=false where room_id=p_room;
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
grant execute on function public.create_room(text,integer,text,text,integer,integer) to authenticated;
grant execute on function public.join_room(text,text) to authenticated;
grant execute on function public.update_room_settings(uuid,integer,text,text,integer,integer) to authenticated;
grant execute on function public.set_ready(uuid,boolean) to authenticated;
grant execute on function public.kick_player(uuid,uuid) to authenticated;
grant execute on function public.add_test_bot(uuid) to authenticated;
grant execute on function public.start_game(uuid,text,text) to authenticated;
grant execute on function public.begin_turn(uuid) to authenticated;
grant execute on function public.send_room_message(uuid,text) to authenticated;
grant execute on function public.send_turn_message(uuid,text) to authenticated;
grant execute on function public.complete_live_turn(uuid) to authenticated;
grant execute on function public.advance_expired_turn(uuid) to authenticated;
grant execute on function public.run_bot_turn(uuid) to authenticated;
grant execute on function public.set_room_reaction(uuid,uuid,text) to authenticated;
grant execute on function public.vote_for(uuid,uuid) to authenticated;
grant execute on function public.restart_room(uuid) to authenticated;