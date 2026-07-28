# App Privacy (Nutrition Label) — Binder Builder v1.0

**Answer to the first question in App Store Connect → App Privacy:**

> Do you or your third-party partners collect data from this app?
> **No — Data Not Collected.**

This produces the "Data Not Collected" privacy card on the App Store product
page. Every data-type category below is therefore answered **No**, but each is
walked explicitly so the answer can be defended if App Review asks.

Apple's definition of *collect*: transmitting data off the device in a way that
lets you or a third-party partner access it for longer than needed to service
the request in real time. Data processed only on device, or sent and
immediately discarded, is not "collected."

---

## Why the app's network and hardware use is not collection

| Behavior | Why it is not "collected" data |
|---|---|
| **TCGdex API + image fetches** (`api.tcgdex.net`, `assets.tcgdex.net`) | Outbound *read* requests for public catalog data and card images. Nothing about the user is sent — no identifier, no account, no collection contents, no usage events. This is a fetch, not a collection. Standard network metadata such as the IP address is inherent to any HTTP request and is not retained by us (we operate no server at all). |
| **eBay API** (optional, user-supplied keys) | Only active if the user pastes their own eBay API credentials into Settings. Requests go from the device directly to eBay; the developer has no server in the path and never receives the keys or the results. Credentials are stored in the device Keychain. eBay's own handling is governed by eBay's terms with that user. |
| **eBay sold-listings link-out** (optional) | Opens a normal listing URL in Safari. No data is passed beyond the search/listing identifiers already contained in the URL. |
| **Camera / card scanning** | Frames are processed entirely on device (matched against the bundled catalog) and are never uploaded, saved to the photo library, or written to disk. Per Apple's rules, on-device-only processing is not collection. |
| **Price-drop & new-release alerts** | Local notifications scheduled on device. No push server, no APNs token registration, no remote notification service. |
| **iCloud sync (optional, off by default)** | CloudKit **private** database in the user's own iCloud account. The developer has no access to the private database. Apple's guidance is that data stored in the user's own iCloud account is not developer-collected data. |
| **JSON backup / export** | Written to a location the user picks (Files, share sheet). Nothing is transmitted by the app. |
| **No SDKs** | No analytics, attribution, advertising, crash-reporting, or A/B SDKs are linked. No third-party partners exist, so there is nothing to disclose on their behalf. |

---

## Category-by-category answers

Every subtype below: **Not collected.**

### Contact Info
| Subtype | Collected? | Note |
|---|---|---|
| Name | **No** | No account, no sign-up, no name field. |
| Email Address | **No** | Support email is a `mailto:` link handled by Mail; the app never reads or stores an address. |
| Phone Number | **No** | |
| Physical Address | **No** | |
| Other User Contact Info | **No** | |

### Health & Fitness
| Subtype | Collected? | Note |
|---|---|---|
| Health | **No** | No HealthKit entitlement. |
| Fitness | **No** | No Motion & Fitness use. |

### Financial Info
| Subtype | Collected? | Note |
|---|---|---|
| Payment Info | **No** | No purchases, no IAP, no payment forms. |
| Credit Info | **No** | |
| Other Financial Info | **No** | Card values and trade P/L are the user's own figures, stored locally and never transmitted. |

### Location
| Subtype | Collected? | Note |
|---|---|---|
| Precise Location | **No** | No location entitlement of any kind. |
| Coarse Location | **No** | |

### Sensitive Info
| Subtype | Collected? | Note |
|---|---|---|
| Sensitive Info | **No** | None requested, inferred, or stored. |

### Contacts
| Subtype | Collected? | Note |
|---|---|---|
| Contacts | **No** | No Contacts access; trade partners are free-text names stored locally. |

### User Content
| Subtype | Collected? | Note |
|---|---|---|
| Emails or Text Messages | **No** | |
| Photos or Videos | **No** | Camera frames are on-device only; no photo library read/write for collection purposes. |
| Audio Data | **No** | No microphone use. |
| Gameplay Content | **No** | Not a game; binder layouts are local app data. |
| Customer Support | **No** | Support happens over the user's own email client, outside the app. |
| Other User Content | **No** | Collection, wishlist, groups, trades, and notes stay in the local database (or the user's private iCloud). |

### Browsing History
| Subtype | Collected? | Note |
|---|---|---|
| Browsing History | **No** | No in-app browser or web view. |
| Search History | **No** | Card searches are executed locally and are not logged or transmitted. |

### Identifiers
| Subtype | Collected? | Note |
|---|---|---|
| User ID | **No** | No accounts exist. |
| Device ID | **No** | IDFA is never requested; no ATT prompt; no device-level identifier is read or sent. |

### Purchases
| Subtype | Collected? | Note |
|---|---|---|
| Purchase History | **No** | No StoreKit, no IAP. What a user paid for a card is their own local record. |

### Usage Data
| Subtype | Collected? | Note |
|---|---|---|
| Product Interaction | **No** | No analytics of taps, launches, or screen views. |
| Advertising Data | **No** | No ads. |
| Other Usage Data | **No** | |

### Diagnostics
| Subtype | Collected? | Note |
|---|---|---|
| Crash Data | **No** | No third-party crash reporter. Apple's own opt-in crash sharing is between the user and Apple and is not developer collection. |
| Performance Data | **No** | |
| Other Diagnostic Data | **No** | |

### Surroundings
| Subtype | Collected? | Note |
|---|---|---|
| Environment Scanning | **No** | The 3D binder is rendered geometry; no ARKit scene understanding, no mesh or plane capture of the user's surroundings. |

### Body
| Subtype | Collected? | Note |
|---|---|---|
| Hands | **No** | |
| Head | **No** | Card tilt/parallax uses accelerometer and gyroscope motion, which is not a disclosable data type and is never transmitted. |

### Other Data
| Subtype | Collected? | Note |
|---|---|---|
| Other Data Types | **No** | |

### Tracking
| Question | Answer | Note |
|---|---|---|
| Is data used to track users (across apps/websites owned by other companies)? | **No** | No ATT prompt, no `NSUserTrackingUsageDescription`, no data brokers, no ad networks. |

---

## Consistency checks before submission

- `PrivacyInfo.xcprivacy` must declare `NSPrivacyTracking: false`, an empty
  `NSPrivacyCollectedDataTypes` array, and required-reason API declarations
  (e.g. `UserDefaults`, file timestamp) — confirm it matches this label.
- The App Privacy answers above must match `PRIVACY.md` (repo root), which is
  the text published at the Privacy Policy URL.
- Usage-description strings must be present and honest:
  `NSCameraUsageDescription` should say recognition happens on device and
  images are not uploaded.
