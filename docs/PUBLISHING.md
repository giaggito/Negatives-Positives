# Publishing Negatives & Positives (GitHub + Buy Me a Coffee)

A step-by-step plan for giving both apps away for free and accepting support. Steps marked **(you)** need
your accounts or decisions; steps marked **(Claude)** I can do for you in a session once you are ready.

## 1. What people will need

- A Mac with Apple silicon (M1 or newer) and macOS 14 Sonoma or newer. The apps are built for Apple silicon
  only and use its GPU features (Intel Macs are not supported).
- Nothing else to install: LibRaw, OpenMP and libjpeg-turbo are built into the apps.

## 2. Licence (done)

Both apps are licensed under **GPL-3.0** (`LICENSE`): anyone may use, study and improve them, but a modified
version must stay open source — nobody can repackage your work and sell it as a closed app. Donations are
completely fine. Every third-party part is listed in `THIRD_PARTY_NOTICES.md`.

What the bundled third-party parts require (handled in both apps' Help → Credits & Licences window, in
`THIRD_PARTY_NOTICES.md` and in the bundled `*_LICENSE.txt` files):

| Part | Licence | What it asks |
|---|---|---|
| Film look tables (RawTherapee collection) and CineStill data (spektrafilm) | CC BY-SA 4.0 | credit the authors; the adapted data files stay CC BY-SA |
| t3mujinpack looks, sky model | MIT | keep the notice |
| LibRaw | LGPL-2.1 (dual LGPL-2.1 / CDDL-1.0) | ship its source (it is in `Packages/DarkroomKit/Vendor/LibRaw`) |
| libjpeg-turbo, OpenMP runtime | BSD-style / Apache-2.0 with LLVM exception | keep the notices |

Film and brand names are used only to say which film a look approximates (with the disclaimer already in the
app). Do not use Kodak, Fujifilm or Ilford logos or packaging images anywhere — on GitHub, the icon or social posts.

## 3. Make the apps open without warnings (you + Claude)

macOS blocks apps from unknown developers. Without signing, people must go to System Settings → Privacy &
Security → "Open Anyway" after the first try — many will give up there.

1. **(you)** Join the Apple Developer Program (99 USD / year): https://developer.apple.com/programs/
2. **(you)** In Xcode → Settings → Accounts, sign in with that Apple ID. Then create an app-specific password at
   https://account.apple.com (Sign-In and Security → App-Specific Passwords) for notarisation.
3. **(Claude)** Sign both apps with your "Developer ID Application" certificate (hardened runtime), send them to
   Apple's notary service, staple the ticket, and package each app as a drag-to-Applications `.dmg`.
   I can add a `release.sh` script so every future release is one command.

Without the developer account you can still publish (step 4) and tell people about "Open Anyway" in the README.

## 4. Put it on GitHub (you + Claude)

1. **(you)** Create an account at https://github.com and a new **public** repository, e.g. `darkroom`
   (both apps live in this one repository).
2. **(Claude)** Before the first push: a friendly README with screenshots and a download
   section, `.github/FUNDING.yml` (step 5), and check nothing private is included.
3. **(Claude)** Push the code, create version tags (e.g. `negatives-1.0`, `positives-1.0`) and a **GitHub Release**
   for each app with the `.dmg` attached and short release notes. People download from the Releases page.
4. **(you)** Use Issues for bug reports and feature ideas; Discussions for questions.

## 5. Buy Me a Coffee (you + Claude)

1. **(you)** Create a page at https://www.buymeacoffee.com, connect payouts (Stripe or PayPal), add a cover image
   and a short text: what the apps are, that they are free, what support pays for (developer account, time).
2. **(Claude)** With your page name:
   - `.github/FUNDING.yml` → `buy_me_a_coffee: yourname` — GitHub then shows a "Sponsor" button on the repository.
   - A "Buy me a coffee" badge and link at the top of the README and in each release's notes.
   - A Help → "Support Negatives / Positives ☕" menu item in both apps, and a small line on the start screen.
     (A gentle link converts best; never nag inside the app.)
3. Optional: GitHub Sponsors (no fees on personal sponsorships) next to Buy Me a Coffee.

## 6. Money and taxes (you)

Donations are income. Fees: Buy Me a Coffee keeps 5 %, plus payment processing. In Italy, occasional income may
fall under "redditi diversi", but regular income can require a partita IVA — ask a commercialista before the
amounts grow. (General information, not tax advice.)

## 7. Other ways to earn later (optional)

- **Pay what you want** for the signed, ready-to-use download on Gumroad or Lemon Squeezy (minimum 0 €), while
  the source stays free on GitHub — common and well accepted.
- **Recipe / preset packs** for Positives (your own film recipes) as a small paid extra.
- **Mac App Store**: possible later, but the apps would need sandboxing changes (file access) and Apple takes 15 %.

## 8. Telling people

- Reddit: r/AnalogCommunity, r/AnalogCommunity's scanning threads, r/fujifilm (Fuji recipes!), r/postprocessing.
- discuss.pixls.us (open-source photo community), Hacker News "Show HN", Product Hunt.
- Instagram / TikTok: before/after of a negative conversion, or a Fuji recipe recreated in Positives.
- Ask the first users for feedback in GitHub Issues — and thank supporters in the release notes.

## 9. Checklist

- [x] Licence: GPL-3.0, with third-party notices in both apps
- [ ] Apple Developer Program (optional but strongly recommended)
- [ ] GitHub account + empty public repository
- [ ] Buy Me a Coffee page + payouts
- [ ] Tell Claude the repository URL and the Buy Me a Coffee page name → README, FUNDING.yml, in-app support
      link, signed DMGs, first releases
