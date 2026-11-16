Linkwarden keeps the pages you bookmark, not just their links - on your NAS.

- **Archived for good**: each saved page is kept as a screenshot, a PDF and a readable copy (and optionally a full
  single-file copy), so it's still there when the site changes or disappears.
- **Organised**: collections and sub-collections, tags, highlights and notes, full-text search, and an RSS reader that
  saves new posts.
- **Shared**: collections shared with others on the NAS (each with their own account), or published by a link.
- **Everywhere**: browser extensions, phone apps (Android and iPhone) and an API - all pointed at your NAS's address.

It runs as three containers - Linkwarden (with the headless Chromium that makes its archives), PostgreSQL and
Meilisearch (its search) - in about **1.5GB of memory for Docker**. It's reached through the Nginx app, at
`https://links.<domain>`.

The install makes the admin account from the user name and password you choose here; sign-ups stay off, and the admin
adds everyone else in Linkwarden's settings (Settings -> Admin).
