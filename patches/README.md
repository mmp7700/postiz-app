# Bind-mounted compiled-JS patches

These files are bind-mounted by `docker-compose.prod.override.yaml` over the
matching paths inside the `ghcr.io/mmp7700/postiz-app:borderline` image. They
implement runtime behavior that is not yet present in the fork's TS source.

The image build will eventually subsume these — once the equivalent TS changes
are committed and the image is rebuilt, these patches become redundant and can
be deleted (along with the bind-mount entries in the override).

## What each patch does

### `linkedin.page.provider.js` (backend + orchestrator)

Implements the second LinkedIn app for company-page posting. Differs from
upstream in five ways:

1. Reads `LINKEDIN_PAGE_CLIENT_ID` and `LINKEDIN_PAGE_CLIENT_SECRET` env vars
   instead of `LINKEDIN_CLIENT_ID` and `LINKEDIN_CLIENT_SECRET`, so the
   personal-profile app and the page app can coexist.
2. Drops `openid` and `profile` scopes (the page app uses LinkedIn's Marketing
   Developer Platform / Community Management API, which doesn't grant OIDC
   scopes).
3. Calls `/v2/me?projection=(id,localizedFirstName,localizedLastName)` instead
   of the OIDC `/v2/userinfo` endpoint.
4. Parses the legacy response shape (`localizedFirstName` + `localizedLastName`
   instead of OIDC's `name`; no `picture` field).
5. Removes `&prompt=none` from the authorization URL (an OIDC-only directive).

### `linkedin.provider.js` (backend + orchestrator)

Minor compile-output differences from upstream. Reads the same env vars as
upstream (`LINKEDIN_CLIENT_*`) and provides the same behavior. Kept here as a
matched pair with the page patch to ensure both providers stay in sync should
upstream change.

## Backend vs orchestrator

The patches are byte-identical between `backend/` and `orchestrator/` —
they're the same compiled TS source emitted to two different `dist/` paths
during the multi-app build. Edit them together.

## Replacing these with a proper image rebuild

When the time is right:

1. Modify `libraries/nestjs-libraries/src/integrations/social/linkedin.page.provider.ts`
   to incorporate the five changes above.
2. Rebuild the image (`pnpm build:backend && pnpm build:orchestrator`, then a
   `docker build`) and push to `ghcr.io/mmp7700/postiz-app:borderline`.
3. Run `./scripts/deploy-image.sh` on the droplet.
4. Once verified, remove the `linkedin.*` bind-mount entries from
   `docker-compose.prod.override.yaml` and delete this directory.
