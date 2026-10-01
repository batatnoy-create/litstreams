# Launch checklist (what the owner does by hand)

Everything below needs a human: logins, forms, posts. The copy and images are ready in this repo.

## 1. Site address
- [x] Custom domain `litstreams.site` (Namecheap, DNS → Netlify, Let's Encrypt HTTPS). `www` and the old `*.netlify.app` address keep working.
- [ ] Renewal: auto-renew is on in Namecheap (about $1.78/year). Keep a payment method there, or the address is lost.

## 2. Check the social preview
- [x] (2026-10-01: the card shows correctly on X.) Paste the site URL into an X post draft (do not send) and check that the preview card shows `og-image.png`. If it does not, try the [X Card Validator](https://cards-dev.twitter.com/validator) or wait a few minutes for the cache.

## 3. Submit to the LitVM directory
- [ ] Open https://testnet.litvm.com → **Submit Your App**.
- [ ] Fill it in from `docs/LISTING.md` → *Form copy* (name, tagline, category **Payments**, description, links, tags).
- [ ] Upload `web/assets/logo-512.png` as the logo and `web/assets/og-image.png` as the cover, if the form asks.
- [ ] Submit and note the date here: ____

## 4. X (Twitter)
- [ ] Optional project account: profile picture `web/assets/logo-512.png`, header `web/assets/x-banner-1500x500.png`, bio: *Get paid in hard money, every second. Per-second zkLTC streaming on LitVM (testnet).* + the site link.
- [ ] Record the demo video (`docs/DEMO_SCRIPT.md`).
- [ ] Post the 5 drafts from `docs/LISTING.md`, one per day or as a thread. Replace `@[LitVM handle]` and refresh the numbers in post #4 first.

## 5. GitHub polish (2 minutes)
- [ ] On https://github.com/batatnoy-create/litstreams → ⚙️ next to **About**: description *Per-second zkLTC payment streaming on LitVM (testnet)*, website = the site URL, topics `litvm`, `litecoin`, `payments`, `streaming`, `solidity`, `foundry`.

## 6. Keep in mind
- Testnet only. Do not promise mainnet: that needs an external audit first (see `docs/SECURITY.md`).
- Never post private keys, seed phrases or `.env` contents. Public addresses and transaction hashes are fine.
- Keep a little zkLTC in the demo wallets; the faucet gives about 0.06 zkLTC per day.
