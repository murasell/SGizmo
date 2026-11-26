# Supabase setup for SGizmo

This schema must be installed before the website can create shared rooms.

1. In Supabase, open **Authentication → Sign In / Providers** and enable **Anonymous Sign-Ins**.
2. Open **SQL Editor → New query**.
3. Copy the full contents of `setup.sql`, paste them into the editor, and click **Run**.
4. Do not use or publish a `secret` or `service_role` key in the browser app.

The `publishable` key is intended for browser clients. Row-level security in this schema keeps room settings private before a game and hides each player's word and role from other players. Compressed profile avatars are visible only to members of the room.

For a new project, run the complete `setup.sql` script as above. For an existing project, run migrations in order from **SQL Editor → New query**, pasting the full contents of each file and clicking **Run**:

1. `migrations/20261126_lobby_game_updates.sql` (only if the project has not already applied it).
2. `migrations/20261126_room_visibility_and_host_selection.sql` (only if the project has not already applied it).
3. `migrations/20261127_gameplay_voting_and_roles.sql` (only if the project has not already applied it).
4. `migrations/20261128_gizmo_gameplay_and_narration.sql`.

The gameplay migrations are transactional and safe to rerun. The newest migration adds the in-game moderator setup phase, timeout fallback, retained round chat, timeout silence messages, all-player confession, and the seven-second inter-round break. Apply it after the earlier gameplay migration and before publishing the updated `app.js`.

Disconnected players are removed after 90 seconds without a server heartbeat; another connected room member runs the cleanup. If too few active players remain during a game, the game ends without a winner. When the owner leaves, ownership transfers to the earliest remaining human player; if none remain, the room is deleted.

The earlier visibility migration preserves existing room visibility values (only the default for new rooms changes). The gameplay migrations do not change application keys. Deploy the updated `app.js` alongside the existing `index.html` and assets after the SQL migration succeeds.
