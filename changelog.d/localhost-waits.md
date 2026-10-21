---
highlight: The page comes back when your dev server does
plain: Open a local site before its server runs, and the page loads by itself once it starts.
---
A refused local address such as `localhost:3000` now says "Nothing is listening on :3000" and reloads by itself once a server starts there, as long as its tab is on screen, for up to ten minutes; Escale reads the Mac's own list of listening ports for that and sends nothing to the port (#16).
