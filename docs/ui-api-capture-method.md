# How the dashboard's API was captured (30 Oct 2026)

The question was what the Docker Sandboxes web dashboard (agentic-platform.docker.com) can read about a sandbox: its
state, its size, its use, its cost. The answer decides which asks in [sbx-command-proposal.md](sbx-command-proposal.md)
are new and which only need exposing in the CLI or the public API. The evidence is
[bench/cli/sbx-ui-rpc-surface-2026-10-30.log](../bench/cli/sbx-ui-rpc-surface-2026-10-30.log); the scripts are in
[bench/cli/ui-capture/](../bench/cli/ui-capture/).

This is observation of our own traffic, not an attack. The purpose is interoperability: to write a feature request
that matches what Docker already has.

## Limits we kept

- **Our own account, our own data, our own browser session.** We logged in normally. Nothing was bypassed: no token
  was reused outside the browser, no request was forged or replayed, no other account was touched.
- **Only actions a user can take.** One sandbox was created with `sbx`, and was paused and deleted from the dashboard's
  own buttons. It was the smallest size, lived a few minutes, and the owner approved the spend first.
- **Shapes, not values.** Every value is reduced to its type in the browser before it reaches the terminal. A
  value was printed only after a check proved it was not personal or secret (e.g. the literal `proxy-managed`).
  Fields holding API-key names were checked by length and form first, without printing them.
- **The raw capture stays local.** The HAR holds session cookies and bearer tokens. It lives in a scratch directory,
  is never committed, and is deleted when the work is done.
- **Internal is internal.** This API is not published. Nothing here builds on it; the proposal asks Docker to
  expose what it shows, through the CLI or the public API. Check Docker's terms before publishing anything derived from
  it, and prefer telling Docker over relying on it.

## Steps

1. **A browser with its own persistent profile**, headed, so the person logs in by hand once:
   `agent-browser --profile <dir> --headed open https://agentic-platform.docker.com/sandboxes`. Using the everyday
   Chrome profile hung, because Chrome already had it open. Later runs reuse the profile headless.
2. **Record a HAR** (`agent-browser network har start`, visit each page, `network har stop <file>`). It gives every
   method name, status, request headers and request bodies. It did **not** give response bodies here.
3. **Request shapes from the HAR**: [har_shape.py](../bench/cli/ui-capture/har_shape.py) prints, per method, the
   status, content type, which auth headers are present and the request body as types. Run it with `python -I`.
4. **Response bodies from inside the page.** Wrapping `window.fetch` caught nothing: the app keeps its own reference.
   Patching `Response.prototype.json/text/arrayBuffer` works for every call made after the patch
   ([capture-responses.js](../bench/cli/ui-capture/capture-responses.js), via `agent-browser eval`). The patch dies on
   a reload, so navigate client-side: click the app's own links. A full page load re-fetches before the patch exists.
5. **Reduce to shapes in the page** ([shape.js](../bench/cli/ui-capture/shape.js)): types for values, enum
   constants kept, list lengths, and sensitive methods (accounts, payment method, current user) left out.
6. **The method catalogue** ([rpc-methods.js](../bench/cli/ui-capture/rpc-methods.js)): the Connect client embeds
   protobuf file descriptors as base64 strings in the JavaScript chunks; decoding them lists services and methods.
   Only chunks already loaded are read, so the list is incomplete. Cross-check it against methods seen on the wire.
7. **A live object.** An empty account returns `{}` (the protobuf JSON mapping omits empty lists), so the sandbox
   shapes needed one real sandbox: create with `sbx`, open its page, then use the dashboard's Pause and Delete to
   capture those calls too, and confirm deletion in both the dashboard and `sbx ls --cloud`.

## Mistakes worth avoiding

- `agent-browser network requests --filter` returned nothing; filter the plain listing with `grep` instead.
- Request ids from one browser session are not valid in the next.
- A HAR without response bodies looks complete; check one body before trusting it.
- An empty list is not a missing field; it is an omitted one.
