# Support & Contact Info — Binder Builder v1.0

## App Store Connect fields

| Field | Value |
|---|---|
| **Support URL** (required) | Must be a public web page — App Store Connect will not accept a `mailto:` link here. Publish a short support page (see template below) and paste its URL. |
| **Marketing URL** (optional) | Leave blank for 1.0, or point at the same site's home page. |
| **Privacy Policy URL** (required) | The published URL of `PRIVACY.md` (repo root). This file must be reachable as a plain web page — e.g. GitHub Pages or the raw/rendered GitHub URL for `PRIVACY.md`. Paste that URL into App Information → Privacy Policy URL. Do not submit without it; a dead or placeholder privacy URL is a common rejection. |
| **Copyright** | `2026 Daniel Aja` |
| **Contact email (App Review Information)** | sand_paints0g@icloud.com |
| **Phone (App Review Information)** | Required by App Store Connect — supply a reachable number at submission time. |
| **Demo account** | Not required — the app has no login. Tick "Sign-in required: No". |

## Support contact

**sand_paints0g@icloud.com**

One-person project; this is the only support channel for 1.0. The same address
appears in the app's Settings screen, in `PRIVACY.md`, and in the v1.0 release
notes, so all three should stay in sync if it ever changes.

## Support page template

Whatever host is used, the page behind the Support URL should carry at least:

- What the app is: an unofficial, fan-made Pokémon TCG collection tracker and
  3D binder, free with no account and no ads.
- Contact: sand_paints0g@icloud.com, with a realistic response expectation.
- A short FAQ:
  - **A card scanned as the wrong card.** How to correct it manually, and to
    email the set + card number so recognition can be improved.
  - **Prices look wrong or stale.** Prices are third-party market estimates
    from TCGdex (TCGplayer market / Cardmarket trend), not offers, and can lag.
  - **How do I move my collection to a new phone?** Settings → JSON backup and
    restore, or turn on iCloud sync on both devices.
  - **Where is my data?** On the device, plus the user's own private iCloud if
    sync is enabled. Nothing goes to the developer. Link to the privacy policy.
  - **Do I need eBay API keys?** No. That feature is optional and inert unless
    the user adds their own credentials.
- A link to the privacy policy (same URL as the Privacy Policy field).
- The trademark disclaimer, matching the App Store description:
  > Binder Builder is an unofficial fan app. Pokémon and Pokémon character
  > names are trademarks of Nintendo, Creatures Inc., and GAME FREAK inc. This
  > app is not affiliated with, endorsed, sponsored, or approved by them.

## Pre-submission checklist

- [ ] Privacy Policy URL is live and renders as a page (not a 404, not a repo
      file listing that requires a login).
- [ ] Support URL is live and lists sand_paints0g@icloud.com.
- [ ] `PRIVACY.md` effective date matches what is published.
- [ ] Support email in the app's Settings screen matches this file.
