# Linkwarden

[Linkwarden](https://linkwarden.app/) keeps the pages you bookmark, not just their links: each saved page is archived as a screenshot, a PDF and a readable copy *(and optionally a single-file HTML copy)*, so it's still there when the site changes or disappears. Collections and sub-collections, tags, highlights and notes, full-text search, an RSS reader that saves new posts, sharing with others on the NAS or by a public link - with browser extensions, phone apps *(Android and iPhone)* and an API. AGPL-3.0.

It's a Docker recipe *(through the [Docker app](../../apps/docker/README.md); Intel models)* rather than a native app because of how it archives pages: with the headless Chromium in its image. For a lighter bookmark manager without page archives, there's the native [linkding app](../../apps/linkding/README.md).

## What it runs

| Container | What it is |
|-----------|------------|
| `linkwarden` | Linkwarden (`ghcr.io/linkwarden/linkwarden`, its version pinned in `.env`): its web interface, API and the worker that archives pages - published on the NAS itself only, `127.0.0.1:3003` *(port 3000 is the Grafana app's)* |
| `linkwarden_postgres` | PostgreSQL 16 *(its own, not the PostgreSQL app's)* |
| `linkwarden_meilisearch` | Meilisearch, its search *(its anonymous usage statistics off)* |

About **1.5GB of memory for Docker** *(the Docker app's memory share)*, and a few GB of disk for the images. Everything is kept in `Nas_Prog/_linkwarden`: `data/` *(the archives and uploads)*, `pgdata/`, `meili_data/`, `.env` *(root's only)*.

## Installing

With the [Store app](../../apps/store/README.md): its wizard asks for the admin's user name and password. The [Nginx app](../../apps/nginx/README.md) is required: Linkwarden is reached at `https://links.<domain>` *(added by the Store)* - HTTPS, which its browser extensions and phone apps expect.

**Nobody else can claim it.** Linkwarden's first account is its admin, and with sign-ups off only the admin may add accounts - so the install's `post_install` step makes that account itself: it makes Linkwarden's container again with sign-ups on for a moment *(while Linkwarden is only reachable on the NAS itself, and before the Store adds its Nginx site)*, signs the admin up through Linkwarden's API, and makes the container again with them off. The admin then adds everyone else in Linkwarden *(Settings → Admin)*.

**Its address** *(for its sign-in's secure cookies, and the links it makes)* is the Nginx app's site for it, written to `site.env` by its hooks *(after installing, updating or changing settings in the Store - also the way to bring it up to date if the Nginx app's domain changes)*.

By hand, without the Store: copy this folder to the NAS and run `sh setup.sh` *(it asks for the admin password, generates the secrets, starts it and adds the Nginx site)*.

## Changes from Linkwarden's own compose file

- Each container gets only the settings it needs, not a shared `.env` *(which also holds the admin's password)*.
- Published on `127.0.0.1` only *(through the Nginx app)*, on port 3003.
- Sign-ups off *(`NEXT_PUBLIC_DISABLE_REGISTRATION`)*.
- Its address from `site.env` *(written by the hooks)*.
- Meilisearch's usage statistics off; container logs capped.

Linkwarden sends no analytics from a self-hosted install *(they need a PostHog key, which the recipe doesn't set)*.

## Updating

The Store updates the recipe *(and so `LINKWARDEN_VERSION`)* with new Linkwarden releases. By hand: change `LINKWARDEN_VERSION` in `.env`, then `docker compose pull && docker compose up -d` in `Nas_Prog/_linkwarden`. Linkwarden updates its database itself when it starts.
