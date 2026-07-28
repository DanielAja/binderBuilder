# Age Rating Questionnaire — Binder Builder v1.0

Answers for the current (post-2025 overhaul) App Store Connect age rating
questionnaire. Category names follow Apple's "Age ratings values and
definitions" reference. Expected resulting rating: **4+**.

App type declared: **App** (not a game). Binder Builder is a collection
utility; the 3D binder is a presentation of the user's own catalog data, not
gameplay.

---

## In-App Controls

| Question | Answer | Note |
|---|---|---|
| Parental Controls | **No** | The app has no parental-control system, and nothing to gate. |
| Age Assurance | **No** | No age verification, no account, no age-gated content. |

## Capabilities

| Question | Answer | Note |
|---|---|---|
| Unrestricted Web Access | **No** | There is no in-app browser or web view that can reach arbitrary URLs. The only network traffic is fixed-endpoint API/image fetches to TCGdex (`api.tcgdex.net`, `assets.tcgdex.net`) and, if the user supplies their own keys, eBay's API. The optional eBay sold-listings link opens a single known listing URL in the system browser (Safari), where Screen Time and parental controls apply — it does not render web content inside the app. |
| User-Generated Content | **No** | Users enter data (card notes, group names, trade entries) but it is private to their own device and there is no sharing, publishing, feed, profile, or way for one user to see another user's content. |
| Social Media | **No** | No social feed, no follow/friend graph, no redistribution, amplification, or discovery of other users' content. |
| Social Media Disabled for Users Under 13 | **N/A** | Not applicable — no social media capability. (Answer required only if the Social Media answer is Yes.) |
| Messaging and Chat | **No** | No messaging, chat, comments, or DMs of any kind. |
| Advertising | **No** | No ads, no ad SDKs, no sponsored placements, no cross-promotion. |

## Mature Themes

| Question | Answer |
|---|---|
| Profanity or Crude Humor | **None** |
| Horror/Fear Themes | **None** |
| Alcohol, Tobacco, or Drug Use or References | **None** |

## Medical or Wellness

| Question | Answer |
|---|---|
| Medical or Treatment Information | **None** |
| Health or Wellness Topics | **None** |

## Sexuality or Nudity

| Question | Answer |
|---|---|
| Mature or Suggestive Themes | **None** |
| Sexual Content or Nudity | **None** |
| Graphic Sexual Content and Nudity | **None** |

## Violence

| Question | Answer | Note |
|---|---|---|
| Cartoon or Fantasy Violence | **None** | Card artwork is displayed as published; the app depicts no violence itself and contains no combat, battling, or gameplay. |
| Realistic Violence | **None** | |
| Prolonged Graphic or Sadistic Realistic Violence | **None** | |
| Guns or Other Weapons | **None** | |

## Chance-Based Activities

| Question | Answer | Note |
|---|---|---|
| Gambling | **No** | No real-money wagering, no simulated wagering. |
| Simulated Gambling | **No** | There is no pack-opening simulator, no randomized pull mechanic, and no virtual currency. Cards are added by search or camera scan only. |
| Contests | **No** | No sweepstakes, giveaways, or prize competitions. |
| Loot Boxes | **No** | No loot boxes, no randomized purchasable items — there are no purchases at all. |

---

## Related declarations (adjacent to the questionnaire)

| Field | Answer |
|---|---|
| Made for Kids / Kids Category | **No** — general audience app, not submitted to the Kids Category. |
| In-app purchases | **None** |
| Third-party analytics / advertising | **None** |
| Data collection (App Privacy) | **Data Not Collected** — see `privacy-nutrition-label.md` |
| Encryption (ITSAppUsesNonExemptEncryption) | **No** — HTTPS only, exempt |

## Expected outcome

**4+** in all territories, with no content descriptors applied.

## Reviewer-facing note (App Review Information → Notes)

Suggested text:

> Binder Builder is an unofficial, fan-made collection tracker for Pokémon
> trading cards. It is free with no in-app purchases, no account, no ads, and
> no data collection. Card data and images are served by the free TCGdex API.
> The app self-identifies as unofficial in the description and includes the
> Nintendo / Creatures Inc. / GAME FREAK inc. trademark attribution. No
> Pokémon trademark appears in the app name or subtitle.
>
> Camera access is used only for on-device card recognition (matching against
> the bundled catalog); frames are never uploaded. The optional eBay
> sold-listings feature requires the user to supply their own eBay API
> credentials in Settings — it is inert until they do, and is not required to
> use the app.
