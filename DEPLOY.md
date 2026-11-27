# Hosting Bonkfish in the browser on Railway

Bonkfish online has two parts:

| Part | Where it runs | What it is |
|---|---|---|
| **Game server** | Railway service #1 | Headless Godot 4.7.1 running this project with `--server`. Listens for WebSocket connections on Railway's `$PORT`. Not a player. |
| **Web client** | Railway service #2 (or itch.io / GitHub Pages) | Godot's Web export: static files in `deploy/web/`. |

Players open the web client, press **Play Online**, and connect to the server over `wss://`.
Railway handles HTTPS/TLS, so the server itself only speaks plain `ws://`.

Desktop builds still have LAN/IP and Steam, and they can **Play Online** too.

---

## Files involved

| File | Purpose |
|---|---|
| `Net.gd` | `host_dedicated()` (WebSocket server on `$PORT`), `join_online(url)`, auto-retry while a sleeping server wakes, lobby leader logic. **`DEFAULT_SERVER_URL`** is the server the web build connects to. |
| `Dockerfile.server` | Railway build for the game server: downloads official headless Godot 4.7.1 for Linux, imports the project, runs `godot --headless --path /game -- --server`. |
| `.dockerignore` | Keeps `.godot/`, `deploy/`, Steam DLLs, etc. out of the server image. |
| `export_presets.cfg` | **Web** preset: threads off (no special COOP/COEP headers needed), Steam addon excluded, exports to `deploy/web/`. |
| `deploy/web/Dockerfile` | Railway build for the web client: Caddy static file server on `$PORT`. |
| `deploy/.gdignore` | Stops Godot importing the exported build back into the project. |

---

## Step 1 - Push the project to GitHub

Railway deploys from a GitHub repo. This project is already a git repo with a remote (`origin`).

```powershell
git add -A
git commit -m "Online play: WebSocket dedicated server + web build"
git push
```

> `deploy/web/index.wasm` is ~38 MB. That's fine for GitHub (limit is 100 MB per file).

## Step 2 - Create the Railway project

1. Sign in at <https://railway.com> and pick the **Hobby** plan ($5/month, includes $5 of usage).
2. **New Project -> Deploy from GitHub repo**, choose this repo.
   Railway creates one service from it. This becomes the **game server**.

## Step 3 - Configure the game server service

In the service's **Settings**:

1. **Variables** tab -> add `RAILWAY_DOCKERFILE_PATH` = `Dockerfile.server`
2. **Settings -> Networking -> Generate Domain.** You'll get something like `bonkfish-server-production.up.railway.app`.
   If Railway asks for a port, use **7777** (or leave it to detect `$PORT`).
3. *(Optional, saves money)* **Settings -> Serverless -> enable.** The server sleeps after ~5-10 min with no players
   and wakes when someone connects (the client retries for ~10 s while it wakes).
4. Rename the service to `server` so it's easy to tell apart.

Railway now builds and deploys. In **Deployments -> View logs** you should see:

```
Bonkfish dedicated server listening on ws://0.0.0.0:<port>
```

## Step 4 - Point the web build at your server

1. Open `Net.gd` and set your domain (keep `wss://`):

   ```gdscript
   const DEFAULT_SERVER_URL := "wss://bonkfish-server-production.up.railway.app"
   ```

2. Re-export the web build. Either:
   - In the Godot editor: **Project -> Export -> Web -> Export Project** (path is already `deploy/web/index.html`), or
   - From PowerShell in the project folder:

     ```powershell
     & "C:\Users\franc\Desktop\Godot Files\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe" --headless --path . --export-release "Web"
     ```

3. Commit and push again (`git add -A`, `git commit`, `git push`).

## Step 5 - Add the web client service

1. In the same Railway project: **New -> GitHub Repo ->** the same repo again.
2. That service's **Settings -> Root Directory** = `deploy/web`
   (it then builds with `deploy/web/Dockerfile`, a tiny Caddy file server).
3. **Networking -> Generate Domain** -> e.g. `bonkfish-production.up.railway.app`.
4. Rename the service to `web`. Enable **Serverless** here too.

Open the web domain in a browser -> type a name -> **Play Online**. Share that link with friends.
The **first player in the lobby is the leader** and gets the **Start Match** button.

### Alternative: host the client for free

Skip Step 5 and upload the contents of `deploy/web/` (zip them, **without** the `Dockerfile`) to
**itch.io** as an HTML5 game (tick *"SharedArrayBuffer support"* OFF - not needed since threads are off).
Only the server then runs on Railway.

---

## Testing locally before deploying

Run a local dedicated server and connect to it from the editor:

```powershell
$env:PORT = "7777"; & "C:\Users\franc\Desktop\Godot Files\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe" --headless --path . -- --server
```

Then run the game from the editor, put `ws://127.0.0.1:7777` in the **Online** server box, and press **Play Online**
(run 2 instances via *Debug -> Customize Run Instances* to have two players).

To try the **web build** locally, serve `deploy/web/` with any static server, e.g. `python -m http.server 8060 --directory deploy/web`,
and open <http://localhost:8060>. Note the release web build hides the server box and always uses `DEFAULT_SERVER_URL`
(debug exports show it).

---

## Updating the game later

- **Gameplay/code change:** commit + push. Railway rebuilds the **server** automatically (it runs the source).
- **Also re-export Web** (Step 4.2) and push, or browsers keep the old client. Client and server must match:
  RPC/sync changes between versions will break connections.

## Costs (Hobby plan)

- $5/month subscription, which includes $5 of usage. RAM ~$10/GB-month, CPU ~$20/vCPU-month, billed per second.
- This server is small (~0.15-0.2 GB RAM, light CPU). With Serverless sleeping on, an idle month costs ~$0 in usage,
  and 1 hour/day of play is well under $1 - so in practice you pay the **$5** fee.

## Limitations

- **One shared lobby per server.** Everyone who presses Play Online lands in the same dock. (Room codes would be a future addition.)
- **No Steam in browsers.** The Steam addon is excluded from the web build. Desktop players can still use Steam/LAN separately.
- **Players can't join mid-match**; they get "try again soon" and can rejoin after the match returns to the lobby.
- WebSockets run over TCP, so it's a little laggier than LAN/ENet. Fine for a party brawler.
- The first connection after the server has been asleep can take a few seconds; the client retries automatically.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Couldn't connect" in the browser | Check `DEFAULT_SERVER_URL` uses **`wss://`** and your server domain; re-export Web and push. |
| Server logs show `couldn't listen on port` | Make sure no custom start command overrides the Dockerfile's `CMD`. |
| Web page is blank / stuck loading | Make sure all files from `deploy/web/` were deployed (especially `index.wasm` and `index.pck`). |
| Works locally, not online | Client and server versions differ: push the latest code and re-exported web build together. |
