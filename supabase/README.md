# Drama Shoot Supabase setup

This folder contains the initial database contract for the Drama Shorts Viewer and Creator Studio apps.

## What the migration creates

- User profiles with a one-time username claim.
- Published dramas and ordered episodes.
- Coin wallets, immutable coin transactions, episode unlock records, and rewarded-ad claim records.
- Per-user watch progress.
- Creator roles stored in the private `app_private` schema.
- Three Storage buckets:
  - `avatars` — public profile images; users may upload only under their own auth UUID folder.
  - `drama-covers` — public cover art; creators only may upload or change files.
  - `drama-videos` — private video files; viewers may read a published free episode or an episode they have unlocked. Creators may upload videos.

Every public application table has RLS enabled. Data API grants are explicit and intentionally limited. Wallet changes, coin transactions, rewarded-ad verification, and episode unlock writes are not allowed directly from the mobile clients.

## Deploy

1. Create a dedicated Supabase project named **Drama Shoot** in an organization with available project capacity.
2. Apply the migration in `migrations/20261107000000_drama_shoot_core.sql` using the Supabase CLI or SQL migration workflow.
3. Confirm that `public` is enabled under the project's Data API exposed schemas. The migration grants the minimum required table privileges; grants do not themselves add a schema to the exposed-schema list.
4. In Authentication settings, enable Email provider. Configure Google provider with a Google OAuth Web Client ID and client secret. Copy the exact callback URL shown by Supabase into the Google Cloud OAuth client's authorized redirect URIs. Add the app's actual deep-link redirect URI(s) to Supabase's allowed redirect URLs after confirming them from the mobile app configuration.
5. Register the first Creator Studio owner through the secure SQL Editor after that account has signed up:
   
   ```sql
   insert into app_private.admin_members (user_id, role)
   values ('<AUTH_USER_UUID>', 'owner');
   ```

   Replace the placeholder with the owner's auth user UUID. Never expose this role table through the Data API or let a client self-assign a role.
6. Add these GitHub Actions repository secrets:
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_PUBLISHABLE_KEY`

   Use the project's URL and publishable key only. Never put a Supabase service-role or secret key inside either APK or any `VITE_*` variable.
7. Test email/password signup, username claim, sign-in, profile photo upload, published catalogue reads, private video access, and creator uploads with separate viewer and creator accounts. Run Supabase Security Advisors after deployment.

## Important deployment notes

- This migration is committed to the repository but has **not** been applied to a live database yet.
- The current Supabase account has reached its two-active-project Free-plan limit. Do not pause or delete the existing `King` or `King2` projects just to make room; create capacity deliberately first.
- The mobile APK workflow only compiles and packages the apps. It does not create a Supabase project, configure Google OAuth, or apply migrations.
- Google OAuth client credentials must be configured in Supabase Authentication. Do not commit them to GitHub.
- Welcome coin issuance, rewarded-ad server-side verification, purchase verification, and episode unlocking need trusted server-side Edge Functions or another secure server. Do not implement these by letting the mobile app update wallet balances or unlock rows directly.
- Before wiring the mobile clients to these tables, compare the restored app's actual Supabase queries with this schema and reconcile any naming or field differences. This migration is the initial secure data contract, not proof that the client code is already connected.
