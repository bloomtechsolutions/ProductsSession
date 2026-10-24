# Know Your Customer, Know Your Product

Facilitator console for the BML retail refresher session (Day 1 · Session 4). It runs on a projector and holds the run of show, session timer, team scoreboard and five activities: True or False, Product Passport, Product Challenge quiz, Listen for the Clue, and Spin & Explain.

It is a single static page (`public/index.html`) with no build step, backed by Supabase for sessions, teams and scores.

## Editing content (/admin)

All activity content lives in `public/content.js`: True or False statements, the Product Challenge quiz, the Listen for the Clue customers, the Spin & Explain wheel and its coaching notes, the product library and the audience screen's facts. Facilitators update outdated information on the admin page (`/admin`, linked from the Run of show):

- The first visit sets the admin password (at least 8 characters). After that, sign in with it. Five wrong passwords lock the admin page for 5 minutes. The password is stored only as a salted hash.
- Each section has its own tab: add, remove, reorder and edit items, with checks before saving (for example every quiz question needs four options and a ticked answer, and Listen for the Clue keeps at least four customers).
- **Save for everyone** stores the section in Supabase. Open consoles and audience screens update at once; phones get it with the next question. The Run of show says which sections were edited, when and by whom.
- **Reset to original** deletes the edited version so the built-in content is used again.

The admin tables come from `supabase/migrations/20261024300000_content_admin.sql`.

## Product Library

The **Product Library** view (last item in the menu) holds every Bank of Maldives product: 31 for individual customers (accounts, cards, financing, digital, what's new) and 25 for business customers (accounts and cards, SME financing, corporate and trade, payments and merchant services). Filter by Individual or Business and by family, or search any word, rate or customer type. Each card says who the product is for, its key facts and a one-line pitch. Facts come from bankofmaldives.com.mv; figures the bank's own pages disagree on (such as business debit card limits) are left out.

Business products also appear in the games: Product Passport teams can pick them, the Product Challenge has a Business & SME column, the Spin & Explain wheel includes four business products, and the audience screen's ticker has business facts.

## Sessions, team phones and automatic marking

- **Session…** in the top bar creates a session (a 6-character code). The device that creates it is the facilitator console: it holds a private host key and is the only device that can send questions or change scores.
- **Show on screen** puts a join QR code on the projector. Each team joins on **one phone** at `/play`: it picks a free team or creates its own. A session has **at most 6 teams**, and a team that already has a phone can't be taken by another one. If a phone dies, **Release phone** in the session dialog frees the seat.
- Teams answer on their phones. The facilitator sends each item to the phones and sees who has answered (not what) until the reveal:
  - True or False (16 statements, four on business products): Start sends statement 1 to every phone; Reveal scores every team (+10 if right); Next sends the next statement. Next waits for Reveal during a game, and Finish ends it after the last statement.
  - Product Challenge: opening a tile sends it to every phone with a countdown (15, 20 or 30 seconds, chosen above the board). Answers lock at zero, or as soon as every team phone has answered, and are scored straight away: every correct team gets the tile value, the fastest correct team +50 and the second fastest +25 (by when each team last submitted). The choosing table still rotates.
  - Listen for the Clue runs by itself: press Start and each of the 8 customers gets three timed questions on the phones (the clue, the product to lead with, the best next question), 20 seconds each. Answers lock at zero or once every phone has answered; 20 points per correct answer, fastest correct +10. The answer and the matching clue card stay up for 8 seconds, then the next question goes out. Pause, Next now and Stop are there if needed; the last answer leads into the standings.
  - Product Passport covers Accounts, Cards and Financing (20 products). **Open picking on team phones**: each team takes 2 products, first come first served; a product one team takes is closed to the others, and the facilitator can free any pick. Then pick the presenting team (its 2 products are shown) and press Start (a 3-minute timer runs). Every other team scores the teach-back on its phone, 1–5 stars for a clear explanation, accurate facts and a customer-ready pitch, plus an optional comment. The presenting team's phone can't vote. Close voting & score gives the presenter 10 points per average star (max 50) and shows the averages and comments on the projector and phones.
  - Spin & Explain: teams take turns. The team presses SPIN on its phone (or the facilitator spins for it), the wheel picks a product, and the facilitator starts the 30-second pitch timer when the volunteer is ready. The facilitator then opens voting and every other team rates Feature, Advantage and Benefit on its phone. Voting closes after 20 seconds (or once every phone has voted); the team scores 10 points per average star (max 50) and the turn passes on.
  - Finishing a game (the last Next in True or False, or **Finish game & show scores** in any other activity) puts the standings on the projector and every team phone: each team's score in that game, its total, its rank (tied teams share a rank) and its score in every finished game. **Standings** in the top bar shows the table again at any time.
  - Close: the leaderboard picks the winner and shows points by activity.
- Answer keys go to the server with each question and never reach the team phones, so answers can't be read from the phone page. The server marks True or False, quiz and match answers when the round closes.

## Audience screen (/screen)

Put `/screen?s=CODE` on the projector (the session dialog has the link) and keep the console on the facilitator's laptop. The screen has no controls: the console broadcasts what to show over the session's realtime channel on every change and every 2 seconds, and answers a new screen's "hello" straight away. The design is a split-flap departures board:

- Home: the title clatters into KNOW YOUR CUSTOMER / KNOW YOUR PRODUCT, teams check in as their phones join, with the QR code and a rotating "Did you know?" product fact.
- Join (Show on screen): big QR code and code.
- Each game opens with a round intro card, then shows only the current statement or question, its countdown and who has answered; reveals highlight the answer, show each team's result and speed bonus, and throw confetti in the scoring teams' colours.
- Spin & Explain replays the console's spin on the same wheel, then shows the product and the pitch and voting timers.
- Finishing a game shows an animated leaderboard (bars grow, teams move with ▲▼); the Close view shows the winner and a podium.
- Sound (ticks, reveal chime, applause) plays after one click on the screen; Screen sound on the console mutes it.

### Data model

`supabase/migrations/` holds the schema. A team's score is the sum of its `score_events`. `rounds` holds each question sent to the phones (readable by everyone), `round_keys` its answer key and `answers` each team's answer (neither readable through the API). `team_secrets` holds each phone's player key as a hash. Automatic awards carry a `ref` (for example `quiz:2-3`), so awarding again replaces the points instead of adding them. Tables are readable by anyone with the publishable key; every write goes through `SECURITY DEFINER` functions that check the session's host key (stored only as a SHA-256 hash). Teams and score events are published to Supabase Realtime so every screen updates live.

The Supabase client is vendored in `public/vendor/` so the page does not depend on a CDN on the day.

## Run locally

```sh
npm run dev
```

## Deploy

Deployed on Vercel as a static site. `vercel.json` serves `public/` as the output directory. Import the repository in Vercel (framework preset: Other) or run `npx vercel --prod`.

Product facts were taken from bankofmaldives.com.mv on 24 Oct 2026. Check rates, limits and fees against the current Schedule of Charges before each session.
