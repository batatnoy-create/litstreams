# LitStreams: demo video script (60–90 s)

A screen recording of the live site on LiteForge testnet. No voice-over needed: the captions below can be added as on-screen text.

## Before you record

- **Two wallets** with a little testnet zkLTC: the **sender** (≥ 0.02 zkLTC) and the **recipient** (≥ 0.002 zkLTC for gas). On one device, use two browser profiles; or record the sender on the computer and the recipient on the phone.
- Open the site in both: https://ubiquitous-chimera-7afb97.netlify.app/
- Prepare **stream #2 in advance** (for the cancel part): a 1-hour cancelable stream of 0.005 zkLTC to the recipient, created a few minutes before recording.
- Copy the recipient address to the clipboard.
- Recording size: 1280×720 (desktop) or a phone recording in portrait. Hide bookmarks and other tabs.

## Storyboard

| Time | Screen | Exact actions | Caption |
| --- | --- | --- | --- |
| 0:00–0:06 | Create page, sender connected | Hold on the page. | **Get paid in hard money, every second.** |
| 0:06–0:20 | Create | Paste the recipient address → type `0.01` → click **10 min · demo** → leave **Start now** and **Cancelable** on. Pause on the **Review** panel. | Lock zkLTC once. Review exactly what the recipient gets per second, hour and day. |
| 0:20–0:28 | Wallet popup | Click **Create stream** → confirm in the wallet → wait for the green toast. | One transaction on LitVM. |
| 0:28–0:34 | Success card | Click **Open stream page** → click **Copy link**. | Every stream has a public page. |
| 0:34–0:48 | Recipient: **Incoming** | Switch to the recipient window, open **Incoming**. Let the counter tick for ~8 s. | The recipient's balance grows every second. |
| 0:48–0:58 | Recipient: Incoming | Click **Withdraw** → confirm → wait for the toast. Show the counter dropping to ~0 and ticking up again. | Withdraw any time. The stream keeps going. |
| 0:58–1:12 | Sender: **Outgoing** | Switch back to the sender, open **Outgoing**. On the prepared 1-hour stream click **Cancel stream** → read the dialog ("You get back about …") → confirm in the wallet → toast. The badge turns **Canceled**. | Cancelable streams can be stopped. The unstreamed part goes back to the sender; the streamed part stays with the recipient. |
| 1:12–1:22 | Explorer | Click **View on explorer** in the toast (or the contract link in the footer). Show the transaction and the verified contract. | All on chain. Verified source. No admin, no fees. |
| 1:22–1:30 | How it works | Open **How it works**, scroll slowly over the risks. End on the logo / URL. | Testnet only. Try it: the link in the bio. |

## Tips

- If the counter looks static on a slow stream, use the 10-minute preset: 0.01 zkLTC over 10 minutes is about 0.0000167 zkLTC per second, so the digits move visibly.
- Wallet popups on mobile can cover the page; cut them out or speed them up in editing.
- Use the finished recording for X post #3 in `docs/LISTING.md`.
