# Drama Shorts offline edition

The Android Viewer and Creator Studio builds in this repository use a device-local IndexedDB data store. They do not require Supabase or another online backend.

## How to publish content to the Viewer

1. Install and open **Drama Creator Studio** on the device where the creator will manage videos.
2. Create a local creator profile using an email address and password. This profile exists only on that device.
3. Create a drama, add episodes, select the episode video clips, and publish the drama and its episodes.
4. Choose **Export published content package**. Save or share the generated `.drama` file.
5. On the device running **Drama Shorts Viewer**, choose **Import** and select the same `.drama` file.
6. The Viewer copies the drama metadata and video clips into its own local storage. Imported dramas then appear in Discover.

When content changes, export a fresh package from Creator Studio and import it again in Viewer. Re-importing replaces records with matching IDs and adds new ones.

## Offline edition limitations

- Creator Studio and Viewer are separate Android apps and therefore have separate local databases.
- The exported `.drama` file is the manual transfer mechanism. There is no automatic cross-device sync or online catalogue.
- Local email/password profiles and starter coins are device-only and are not verified by a server.
- Local coin unlocking is a demonstration feature only. It is not secure and must not be used for real-money balances.
- Ad rewards, payments, subscriptions, push notifications, and online video streaming are not enabled.
- Creator permissions are not server-enforced. Do not treat a local profile as a secure remote administrator identity.
- Large video packages can exceed device storage or available memory. The app currently rejects packages over 800 MB.

A real multi-user streaming service with secure accounts, shared video hosting, payments, ads, and cross-device synchronisation requires an online backend. AI Wisebase is a personal knowledge base, not a replacement for that service infrastructure.
