# Supabase setup for SGizmo

This schema must be installed before the website can create shared rooms.

1. In Supabase, open **Authentication → Sign In / Providers** and enable **Anonymous Sign-Ins**.
2. Open **SQL Editor → New query**.
3. Copy the full contents of `setup.sql`, paste them into the editor, and click **Run**.
4. Do not use or publish a `secret` or `service_role` key in the browser app.

The `publishable` key is intended for browser clients. Row-level security in this schema keeps room settings private before a game and hides each player's word and role from other players.