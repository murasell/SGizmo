begin;

alter table public.room_players add column if not exists avatar text;
alter table public.room_settings add column if not exists moderator_player_id uuid;
alter table public.room_settings alter column turn_seconds set default 60;
drop index if exists public.room_players_one_bot;
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
alter table public.room_presence enable row level security;
alter table public.room_exit_notices enable row level security;
drop policy if exists exit_notices_read on public.room_exit_notices;
create policy exit_notices_read on public.room_exit_notices for select to authenticated using (user_id=auth.uid());
revoke all on public.room_presence,public.room_exit_notices from public,anon,authenticated;
grant select on public.room_exit_notices to authenticated;
alter table public.rooms replica identity full;
alter table public.room_players replica identity full;
insert into public.room_presence(player_id,room_id,user_id,last_seen_at)
select id,room_id,user_id,now() from public.room_players where not is_bot and user_id is not null
on conflict(player_id) do nothing;
alter table public.room_settings drop constraint if exists room_settings_host_mode_check;
update public.room_settings set moderator_player_id=(
  select p.id from public.room_players p join public.rooms r on r.id=p.room_id
  where p.room_id=room_settings.room_id and p.user_id=r.owner_uid
) where host_mode='owner';
update public.room_settings set moderator_player_id=(
  select p.id from public.room_players p
  where p.room_id=room_settings.room_id and not p.is_bot
  order by p.joined_at limit 1
) where host_mode='random';
update public.room_settings set host_mode='player' where host_mode in ('owner','random');
update public.room_settings set host_mode='bot',moderator_player_id=null where host_mode not in ('player','bot');
update public.room_settings s set host_mode='player',moderator_player_id=(
  select p.id from public.room_players p join public.rooms r on r.id=p.room_id
  where p.room_id=s.room_id and p.user_id=r.owner_uid
) from public.rooms r where r.id=s.room_id and r.player_count>3 and s.host_mode='bot';
alter table public.room_settings alter column host_mode set default 'bot';
alter table public.room_settings add constraint room_settings_host_mode_check check (host_mode in ('player','bot'));
do $$ begin
  if not exists(select 1 from pg_constraint where conname='room_players_avatar_check' and conrelid='public.room_players'::regclass) then
    alter table public.room_players add constraint room_players_avatar_check check (avatar is null or (char_length(avatar)<=40000 and avatar like 'data:image/webp;base64,%'));
  end if;
end $$;
create table if not exists public.sgizmo_migrations(version text primary key);
alter table public.sgizmo_migrations enable row level security;
revoke all on table public.sgizmo_migrations from public,anon,authenticated;
do $$ begin
  if not exists(select 1 from public.sgizmo_migrations where version='20261126_lobby_game_updates') then
    update public.room_players p set is_ready=false from public.rooms r where r.id=p.room_id and r.status='lobby' and not p.is_bot;
    insert into public.sgizmo_migrations(version) values('20261126_lobby_game_updates');
  end if;
end $$;

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
    insert into public.rooms(code,owner_uid,owner_name) values(v_code,auth.uid(),v_name) on conflict(code) do nothing returning id into v_room;
    exit when v_room is not null;
  end loop;
  insert into public.room_settings(room_id,max_players,host_mode,game_mode,turn_seconds,vote_after_rounds) values(v_room,6,'bot','chat',60,3);
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
  if r.player_count+1>3 then
    update public.room_settings set host_mode='player',moderator_player_id=(
      select p.id from public.room_players p where p.room_id=r.id and p.user_id=r.owner_uid
    ) where room_id=r.id and host_mode='bot';
  end if;
  return r.id;
end $$;

drop function if exists public.update_room_settings(uuid,integer,text,text,integer,integer);
create or replace function public.update_room_settings(p_room uuid,p_max integer,p_host text,p_moderator uuid,p_mode text,p_seconds integer,p_vote_rounds integer) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_count integer; v_all_ready boolean;
begin
  perform 1 from public.rooms where id=p_room and owner_uid=auth.uid() and status='lobby' for update;
  if not found then raise exception 'Only the room owner can change settings in a lobby'; end if;
  if p_max not between 4 and 8 or p_host not in ('player','bot') or p_mode not in ('chat','live') or p_seconds not between 15 and 60 or p_vote_rounds not between 2 and 4 then raise exception 'Invalid settings'; end if;
  if (select player_count from public.rooms where id=p_room)>p_max then raise exception 'Remove players before lowering the limit'; end if;
  select player_count into v_count from public.rooms where id=p_room;
  if v_count<=3 then p_host:='bot'; p_moderator:=null;
  elsif p_host<>'player' or not exists(select 1 from public.room_players where id=p_moderator and room_id=p_room and not is_bot) then raise exception 'Choose a player to lead the game';
  end if;
  update public.room_settings set max_players=p_max,host_mode=p_host,moderator_player_id=p_moderator,game_mode=p_mode,turn_seconds=p_seconds,vote_after_rounds=p_vote_rounds where room_id=p_room;
  select not exists(select 1 from public.room_players where room_id=p_room and not is_bot and not is_ready) into v_all_ready;
  if v_all_ready and ((p_host='bot' and v_count>=3) or (p_host='player' and v_count>=4)) then
    perform public._start_game(p_room);
  end if;
end $$;

create or replace function public.set_ready(p_room uuid,p_ready boolean) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_count integer; v_all_ready boolean;
begin
  perform 1 from public.rooms where id=p_room and status='lobby' for update;
  if not found then raise exception 'Room is not accepting ready status'; end if;
  update public.room_players set is_ready=p_ready where room_id=p_room and user_id=auth.uid() and exists(select 1 from public.rooms r where r.id=p_room and r.status='lobby');
  if not found then raise exception 'Cannot update ready status'; end if;
  select player_count into v_count from public.rooms where id=p_room;
  select not exists(select 1 from public.room_players where room_id=p_room and not is_bot and not is_ready) into v_all_ready;
  if v_count>=3 and v_all_ready then perform public._start_game(p_room); end if;
end $$;

create or replace function public._remove_room_player(p_room uuid,p_player uuid,p_reason text) returns boolean
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare r public.rooms%rowtype; p public.room_players%rowtype; v_new_owner uuid; v_new_owner_name text; v_new_owner_player uuid;
  v_order uuid[]; v_position integer; v_active integer; v_humans integer; v_current_exists boolean;
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

  update public.room_settings s set
    host_mode=case when (select player_count from public.rooms where id=p_room)<=3 then 'bot' else 'player' end,
    moderator_player_id=case when (select player_count from public.rooms where id=p_room)<=3 then null else v_new_owner_player end
  where s.room_id=p_room and s.moderator_player_id=p_player;

  if r.status<>'playing' then return true; end if;
  select count(*) into v_active from public.room_players
  where room_id=p_room and not is_moderator and not is_eliminated;
  select count(*) into v_humans from public.room_players
  where room_id=p_room and not is_moderator and not is_eliminated and not is_bot;
  if v_active<3 or v_humans<2 then
    update public.rooms set status='finished',phase='results',winner=null,current_player_id=null,turn_ends_at=null
    where id=p_room;
    return true;
  end if;

  if r.phase in ('countdown','clue') then
    select array_agg(id order by joined_at,id) into v_order from public.room_players
    where room_id=p_room and not is_moderator and not is_eliminated;
    select exists(select 1 from public.room_players where id=r.current_player_id and room_id=p_room) into v_current_exists;
    v_position:=array_position(v_order,r.current_player_id);
    if v_position is null then v_position:=1; end if;
    update public.rooms set
      turn_order=v_order,
      turn_pos=v_position,
      current_player_id=v_order[v_position],
      phase=case when v_current_exists then r.phase else 'countdown' end,
      turn_ends_at=case when v_current_exists then r.turn_ends_at else now()+interval '3 seconds' end
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
  if (select player_count from public.rooms where id=p_room)>3 then
    update public.room_settings set host_mode='player',moderator_player_id=(
      select p.id from public.room_players p join public.rooms r on r.id=p.room_id
      where p.room_id=p_room and p.user_id=r.owner_uid
    ) where room_id=p_room and host_mode='bot';
  end if;
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
declare r public.rooms%rowtype; s public.room_settings%rowtype; v_count integer; v_moderator uuid; v_order uuid[]; v_spy uuid; v_pair text[]; p record;
begin
  select * into r from public.rooms where id=p_room for update;
  if not found or r.status<>'lobby' then return; end if;
  select * into s from public.room_settings where room_id=p_room;
  select count(*) into v_count from public.room_players where room_id=p_room;
  if exists(select 1 from public.room_players where room_id=p_room and not is_bot and not is_ready) then return; end if;
  if v_count<=3 then v_moderator:=null; s.moderator_player_id:=null;
  else
    if s.host_mode<>'player' or s.moderator_player_id is null or not exists(select 1 from public.room_players where id=s.moderator_player_id and room_id=p_room and not is_bot) then return; end if;
    select user_id into v_moderator from public.room_players where id=s.moderator_player_id;
  end if;
  if v_count-coalesce((select count(*) from public.room_players where id=s.moderator_player_id),0)<3 or
    (select count(*) from public.room_players where room_id=p_room and not is_bot and id is distinct from s.moderator_player_id)<2 then return; end if;
  select pair into v_pair from (values
    (array['кофе','чай']::text[]),(array['кинотеатр','театр']::text[]),(array['самолёт','вертолёт']::text[]),
    (array['пицца','пирог']::text[]),(array['море','бассейн']::text[]),(array['лифт','эскалатор']::text[]),
    (array['зубная щётка','расчёска']::text[]),(array['поезд','метро']::text[]),(array['арбуз','дыня']::text[]),
    (array['библиотека','книжный магазин']::text[]),(array['снеговик','снежная баба']::text[]),(array['пингвин','тюлень']::text[])
  ) as word_pairs(pair) order by random() limit 1;
  update public.room_players set is_moderator=coalesce(id=s.moderator_player_id,false),is_eliminated=false where room_id=p_room;
  select array_agg(id order by joined_at) into v_order from public.room_players where room_id=p_room and not is_moderator;
  if coalesce(array_length(v_order,1),0)<3 then return; end if;
  select id into v_spy from public.room_players where id=any(v_order) and not is_bot order by random() limit 1;
  delete from public.room_secrets where room_id=p_room;
  for p in select id from public.room_players where id=any(v_order) loop
    insert into public.room_secrets(room_id,player_id,role,word) values(p_room,p.id,case when p.id=v_spy then 'spy' else 'player' end,case when p.id=v_spy then v_pair[2] else v_pair[1] end);
  end loop;
  update public.rooms set status='playing',phase='countdown',current_round=1,turn_order=v_order,turn_pos=1,current_player_id=v_order[1],turn_ends_at=now()+interval '3 seconds',moderator_uid=v_moderator,winner=null where id=p_room;
end $$;

create or replace function public.restart_room(p_room uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  if not public.is_room_owner(p_room) or (select status from public.rooms where id=p_room)<>'finished' then raise exception 'Only the owner can restart a finished game'; end if;
  delete from public.room_secrets where room_id=p_room; delete from public.room_votes where room_id=p_room;
  update public.room_players set is_ready=is_bot,is_moderator=false,is_eliminated=false where room_id=p_room;
  update public.rooms set status='lobby',phase='setup',current_round=0,turn_order='{}',turn_pos=0,current_player_id=null,turn_ends_at=null,moderator_uid=null,winner=null where id=p_room;
end $$;

revoke all on function public.create_room(text,text),public.join_room(text,text,text),public.update_room_settings(uuid,integer,text,uuid,text,integer,integer),public.set_ready(uuid,boolean),public.kick_player(uuid,uuid),public.add_test_bot(uuid),public.update_room_profile(uuid,text,text),public.leave_room(uuid),public.room_heartbeat(uuid),public.expire_disconnected_players(uuid),public.consume_room_removal_notice(uuid) from public,anon;
revoke all on function public._unique_room_nickname(uuid,text,uuid),public._start_game(uuid),public._remove_room_player(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.create_room(text,text),public.join_room(text,text,text),public.update_room_settings(uuid,integer,text,uuid,text,integer,integer),public.set_ready(uuid,boolean),public.kick_player(uuid,uuid),public.add_test_bot(uuid),public.update_room_profile(uuid,text,text),public.leave_room(uuid),public.room_heartbeat(uuid),public.expire_disconnected_players(uuid),public.consume_room_removal_notice(uuid) to authenticated;

commit;
