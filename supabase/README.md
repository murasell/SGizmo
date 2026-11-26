# Supabase setup for SGizmo

This schema must be installed before the website can create shared rooms.

1. In Supabase, open **Authentication → Sign In / Providers** and enable **Anonymous Sign-Ins**.
2. Open **SQL Editor → New query**.
3. Copy the full contents of `setup.sql`, paste them into the editor, and click **Run**.
4. Do not use or publish a `secret` or `service_role` key in the browser app.

The `publishable` key is intended for browser clients. Row-level security in this schema keeps room settings private before a game and hides each player's word and role from other players. Compressed profile avatars are visible only to members of the room.

For a new project, run the complete `setup.sql` script as above. To update an existing project, open **SQL Editor → New query**, paste the complete current contents of `migrations/20261126_lobby_game_updates.sql`, and click **Run**. This migration is transactional and safe to rerun. It adds lobby avatars and moderator selection, allows multiple test bots, resets ready state in existing lobbies once, tracks room heartbeats, and adds leave/disconnect cleanup RPCs.

Disconnected players are removed after 90 seconds without a server heartbeat; another connected room member runs the cleanup. If too few active players remain during a game, the game ends without a winner. When the owner leaves, ownership transfers to the earliest remaining human player; if none remain, the room is deleted.

The migration keeps the existing RLS policies and does not change application keys. After it succeeds, publish the updated website files, including `pirate-cat.svg`, so its RPC calls and favicon match the new schema.
