# RecordPOV website

This static site lives in the RecordPOV repository. Its Vercel Root Directory is `apps/web`, and the site is served from `public`. The public pages cover the app, support, privacy, and account deletion.

Preview locally from this folder with:

```sh
python3 -m http.server 8765 --directory public
```

The hero and walkthrough use native screenshots of the iOS onboarding flow. Update the launch section with verified App Store and Google Play URLs when the listings go live.

The launch form posts to `/api/waitlist` on Vercel. The production project has a private Blob store connected through `BLOB_READ_WRITE_TOKEN`. Signup writes use one object per normalized address. The static preview serves the website but leaves the Vercel API unavailable.

To prepare the one-time launch email, run the export from a temporary directory linked to the Vercel project. Use private paths outside the repository. Install the website dependencies before running the export and delete the temporary environment file when finished.

```sh
umask 077
vercel env pull .env.launch-export --environment production
node --env-file=.env.launch-export /absolute/path/to/apps/web/scripts/export-waitlist.js /absolute/private/path/recordpov-launch.json
```

Send the launch announcement after the store listings are public. This project collects signups and exports the private list. Sending the announcement is a separate operation.
