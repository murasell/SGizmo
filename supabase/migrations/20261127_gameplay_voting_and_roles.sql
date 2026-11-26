begin;

alter table public.room_settings add column if not exists vote_seconds integer not null default 20;
alter table public.room_settings drop constraint if exists room_settings_vote_after_rounds_check;
alter table public.room_settings add constraint room_settings_vote_after_rounds_check check (vote_after_rounds between 1 and 4);
alter table public.room_settings drop constraint if exists room_settings_vote_seconds_check;
alter table public.room_settings add constraint room_settings_vote_seconds_check check (vote_seconds between 15 and 30);

create table if not exists public.room_game_words (
  room_id uuid primary key references public.rooms(id) on delete cascade,
  player_word text not null check (char_length(player_word) between 2 and 60),
  spy_word text not null check (char_length(spy_word) between 2 and 60),
  spy_player_id uuid not null references public.room_players(id) on delete cascade,
  check (lower(trim(player_word))<>lower(trim(spy_word)))
);
alter table public.room_game_words enable row level security;

drop policy if exists settings_read on public.room_settings;
create policy settings_read on public.room_settings for select to authenticated using (
  public.is_room_owner(room_id)
  or (public.is_room_member(room_id) and exists(select 1 from public.rooms r where r.id=room_id and r.status<>'lobby'))
  or exists(select 1 from public.room_players p where p.room_id=room_settings.room_id and p.user_id=auth.uid() and p.is_moderator)
);
drop policy if exists secrets_read on public.room_secrets;
create policy secrets_read on public.room_secrets for select to authenticated using (
  exists(select 1 from public.rooms r where r.id=room_id and r.status='finished') and public.is_room_member(room_id)
);
drop policy if exists room_game_words_moderator_read on public.room_game_words;
create policy room_game_words_moderator_read on public.room_game_words for select to authenticated using (
  exists(select 1 from public.room_settings s
    join public.room_players p on p.id=s.moderator_player_id
    join public.rooms r on r.id=s.room_id
    where s.room_id=room_game_words.room_id and p.user_id=auth.uid() and r.status='lobby')
);
grant select on public.room_game_words to authenticated;

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
declare s public.room_settings%rowtype;
begin
  select * into s from public.room_settings where room_id=p_room for update;
  if not found or not exists(select 1 from public.room_players where id=s.moderator_player_id and room_id=p_room and user_id=auth.uid()) then raise exception 'Only the selected game leader can set the words'; end if;
  if (select status from public.rooms where id=p_room)<>'lobby' then raise exception 'The game has already started'; end if;
  if p_player_word is null or p_spy_word is null or char_length(trim(p_player_word)) not between 2 and 60 or char_length(trim(p_spy_word)) not between 2 and 60 or lower(trim(p_player_word))=lower(trim(p_spy_word)) then raise exception 'Enter two different words (2-60 characters)'; end if;
  if not exists(select 1 from public.room_players where id=p_spy_player and room_id=p_room and id<>s.moderator_player_id and not is_eliminated) then raise exception 'Choose a player to be the spy'; end if;
  insert into public.room_game_words(room_id,player_word,spy_word,spy_player_id)
    values(p_room,trim(p_player_word),trim(p_spy_word),p_spy_player)
    on conflict(room_id) do update set player_word=excluded.player_word,spy_word=excluded.spy_word,spy_player_id=excluded.spy_player_id;
  if not exists(select 1 from public.room_players where room_id=p_room and not is_bot and not is_ready) then perform public._start_game(p_room); end if;
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
    insert into public.room_exit_notices(room_id,user_id,reason) values(p_room,p.user_id,p_reason)
    on conflict(room_id,user_id) do update set reason=excluded.reason,created_at=now();
  end if;
  delete from public.room_players where id=p_player;
  if r.moderator_uid=p.user_id then update public.rooms set moderator_uid=null where id=p_room; end if;
  if r.owner_uid=p.user_id then
    select id,user_id,nickname into v_new_owner_player,v_new_owner,v_new_owner_name
    from public.room_players where room_id=p_room and user_id is not null and not is_bot order by joined_at,id limit 1;
    if v_new_owner is null then delete from public.rooms where id=p_room; return true; end if;
    update public.rooms set owner_uid=v_new_owner,owner_name=v_new_owner_name where id=p_room;
  else
    select owner_uid into v_new_owner from public.rooms where id=p_room;
    select id into v_new_owner_player from public.room_players where room_id=p_room and user_id=v_new_owner;
  end if;
  if r.status='lobby' then
    select count(*),count(*) filter(where not is_bot) into v_active,v_live_humans from public.room_players where room_id=p_room;
    update public.room_settings set host_mode=case when v_active>=4 and v_live_humans>=2 then 'random' else 'bot' end,moderator_player_id=null
      where room_id=p_room and moderator_player_id=p_player;
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
    delete from public.room_messages where room_id=p_room;
    insert into public.room_messages(room_id,nickname,body,kind) values(p_room,'SGizmo','Игра окончена — ведущий покинул комнату','system');
    return true;
  end if;
  select count(*) into v_active from public.room_players where room_id=p_room and not is_moderator and not is_eliminated;
  select count(*) into v_humans from public.room_players where room_id=p_room and not is_moderator and not is_eliminated and not is_bot;
  if v_active<3 or v_humans<1 then
    update public.rooms set status='finished',phase='results',winner=null,current_player_id=null,turn_ends_at=null where id=p_room;
    delete from public.room_messages where room_id=p_room;
    insert into public.room_messages(room_id,nickname,body,kind) values(p_room,'SGizmo','Игра окончена','system');
    return true;
  end if;
  if r.phase in ('countdown','clue') then
    select array_agg(id order by joined_at,id) into v_order from public.room_players where room_id=p_room and not is_moderator and not is_eliminated;
    select exists(select 1 from public.room_players where id=r.current_player_id and room_id=p_room) into v_current_exists;
    v_position:=array_position(v_order,r.current_player_id);
    if v_position is null then v_position:=1; end if;
    select turn_seconds into v_turn_seconds from public.room_settings where room_id=p_room;
    update public.rooms set turn_order=v_order,turn_pos=v_position,current_player_id=v_order[v_position],
      phase=case when v_current_exists then r.phase else 'clue' end,
      turn_ends_at=case when v_current_exists then r.turn_ends_at else now()+make_interval(secs=>v_turn_seconds) end
      where id=p_room;
  end if;
  return true;
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
  if v_total<4 or v_humans<2 or s.host_mode='bot' then s.host_mode:='bot'; s.moderator_player_id:=null; v_moderator:=null;
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
  select count(*),count(*) filter(where not is_bot) into v_active,v_active_humans from public.room_players where room_id=p_room and id is distinct from s.moderator_player_id;
  if v_active<3 or v_active_humans<1 then return; end if;
  if v_moderator_player is not null then
    select array[player_word,spy_word],spy_player_id into v_pair,v_spy from public.room_game_words
      where room_id=p_room and exists(select 1 from public.room_players where id=spy_player_id and room_id=p_room and id<>v_moderator_player and not is_eliminated);
    if v_pair is null then return; end if;
  else
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
  delete from public.room_secrets where room_id=p_room;
  for p in select id from public.room_players where id=any(v_order) loop
    insert into public.room_secrets(room_id,player_id,role,word) values(p_room,p.id,case when p.id=v_spy then 'spy' else 'player' end,case when p.id=v_spy then v_pair[2] else v_pair[1] end);
  end loop;
  delete from public.room_messages where room_id=p_room;
  insert into public.room_messages(room_id,nickname,body,kind,round_no) values(p_room,'SGizmo','Раунд 1','system',1);
  update public.rooms set status='playing',phase='countdown',current_round=1,turn_order=v_order,turn_pos=1,current_player_id=v_order[1],
    turn_ends_at=now()+interval '3 seconds',moderator_uid=v_moderator,winner=null where id=p_room;
end $$;

create or replace function public._advance_turn(p_room uuid,p_timeout boolean default false) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare r public.rooms%rowtype; s public.room_settings%rowtype; v_next integer; v_len integer;
begin
  select * into r from public.rooms where id=p_room for update;
  if r.status<>'playing' or r.phase<>'clue' then return; end if;
  select * into s from public.room_settings where room_id=p_room;
  if not p_timeout and not public.is_room_owner(p_room) and not exists(select 1 from public.room_players where id=r.current_player_id and (user_id=auth.uid() or is_bot) and public.is_room_member(p_room)) then raise exception 'Not your turn'; end if;
  if p_timeout and r.turn_ends_at>now() then raise exception 'Turn has not ended'; end if;
  v_next:=r.turn_pos+1; v_len:=coalesce(array_length(r.turn_order,1),0);
  if v_next<=v_len then update public.rooms set turn_pos=v_next,current_player_id=turn_order[v_next],turn_ends_at=now()+make_interval(secs=>s.turn_seconds),phase='clue' where id=p_room; return; end if;
  if r.current_round>=s.vote_after_rounds then update public.rooms set phase='voting',current_player_id=null,turn_ends_at=now()+make_interval(secs=>s.vote_seconds) where id=p_room;
  else
    delete from public.room_messages where room_id=p_room;
    insert into public.room_messages(room_id,nickname,body,kind,round_no) values(p_room,'SGizmo','Раунд '||(r.current_round+1)::text,'system',r.current_round+1);
    update public.rooms set current_round=current_round+1,turn_pos=1,current_player_id=turn_order[1],turn_ends_at=now()+make_interval(secs=>s.turn_seconds),phase='clue' where id=p_room;
  end if;
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
  insert into public.room_votes(room_id,round_no,voter_id,target_id) values(p_room,r.current_round,v_voter,p_target)
    on conflict(room_id,round_no,voter_id) do update set target_id=excluded.target_id;
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
    insert into public.room_messages(room_id,nickname,body,kind) values(p_room,'SGizmo','Игра окончена','system'); return;
  end if;
  select * into s from public.room_settings where room_id=p_room;
  select array_agg(id order by joined_at) into v_order from public.room_players where room_id=p_room and not is_moderator and not is_eliminated;
  delete from public.room_messages where room_id=p_room;
  insert into public.room_messages(room_id,nickname,body,kind,round_no) values(p_room,'SGizmo','Раунд '||(r.current_round+1)::text,'system',r.current_round+1);
  update public.rooms set current_round=current_round+1,turn_order=v_order,turn_pos=1,current_player_id=v_order[1],
    turn_ends_at=now()+make_interval(secs=>s.turn_seconds),phase='clue' where id=p_room;
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
  select exists(select 1 from public.room_secrets s join public.room_players p on p.id=s.player_id join public.rooms r on r.id=s.room_id
    where s.room_id=p_room and p.user_id=auth.uid() and s.role='spy' and not p.is_moderator and not p.is_eliminated and r.status='playing' and r.phase='voting' and r.turn_ends_at>now())
$$;
create or replace function public.confess_spy(p_room uuid,p_guess text) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare r public.rooms%rowtype; v_spy uuid; v_player_word text; v_correct boolean;
begin
  select * into r from public.rooms where id=p_room for update;
  if r.status<>'playing' or r.phase<>'voting' then raise exception 'Confession is only available during voting'; end if;
  if r.turn_ends_at is null or r.turn_ends_at<=now() then raise exception 'Voting time has ended'; end if;
  select s.player_id into v_spy from public.room_secrets s join public.room_players p on p.id=s.player_id where s.room_id=p_room and p.user_id=auth.uid() and s.role='spy' and not p.is_eliminated;
  if v_spy is null or p_guess is null or char_length(trim(p_guess)) not between 2 and 60 then raise exception 'Only the active spy can make a guess'; end if;
  select word into v_player_word from public.room_secrets where room_id=p_room and role='player' limit 1;
  v_correct:=lower(trim(p_guess))=lower(trim(v_player_word));
  update public.rooms set status='finished',phase='results',winner=case when v_correct then 'spy' else 'players' end,current_player_id=null,turn_ends_at=null where id=p_room;
  insert into public.room_messages(room_id,nickname,body,kind) values(p_room,'SGizmo',case when v_correct then 'Игра окончена — шпион угадал слово' else 'Игра окончена — шпион не угадал слово' end,'system');
end $$;

create or replace function public.restart_room(p_room uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  if not public.is_room_owner(p_room) or (select status from public.rooms where id=p_room)<>'finished' then raise exception 'Only the owner can restart a finished game'; end if;
  delete from public.room_secrets where room_id=p_room;
  delete from public.room_votes where room_id=p_room;
  delete from public.room_game_words where room_id=p_room;
  update public.room_players set is_ready=is_bot,is_moderator=(id=(select moderator_player_id from public.room_settings where room_id=p_room)),is_eliminated=false where room_id=p_room;
  update public.rooms set status='lobby',phase='setup',current_round=0,turn_order='{}',turn_pos=0,current_player_id=null,turn_ends_at=null,moderator_uid=null,winner=null where id=p_room;
  delete from public.room_messages where room_id=p_room;
end $$;

revoke all on function public.update_room_settings(uuid,integer,text,uuid,text,integer,integer,integer),public.save_moderator_game(uuid,text,text,uuid),
  public.get_my_game_word(uuid),public.can_spy_confess(uuid),public.confess_spy(uuid,text),public.resolve_expired_vote(uuid) from public,anon;
grant execute on function public.update_room_settings(uuid,integer,text,uuid,text,integer,integer,integer),public.save_moderator_game(uuid,text,text,uuid),
  public.get_my_game_word(uuid),public.can_spy_confess(uuid),public.confess_spy(uuid,text),public.resolve_expired_vote(uuid) to authenticated;
revoke all on function public._resolve_vote(uuid,boolean) from public,anon,authenticated;

commit;
