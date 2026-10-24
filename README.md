# Know Your Customer, Know Your Product

Facilitator console for the BML retail refresher session (Day 1 · Session 4). It runs on a projector and holds the run of show, session timer, team scoreboard and seven activities: True or False, Product Passport, Product Challenge quiz, Listen for the Clue, Match the Customer, Spot the Opportunity, and Spin & Explain.

It is a single static page (`public/index.html`) with no build step, backed by Supabase for sessions, teams and scores.

## Sessions, team phones and automatic marking

- **Session…** in the top bar creates a session (a 6-character code). The device that creates it is the facilitator console: it holds a private host key and is the only device that can send questions or change scores.
- **Show on screen** puts a join QR code on the projector. Each team joins on **one phone** at `/play`: it picks a free team or creates its own. A session has **at most 6 teams**, and a team that already has a phone can't be taken by another one. If a phone dies, **Release phone** in the session dialog frees the seat.
- Teams answer on their phones. The facilitator sends each item to the phones and sees who has answered (not what) until the reveal:
  - True or False: Start sends statement 1 to every phone; Reveal scores every team (+10 if right); Next sends the next statement. Next waits for Reveal during a game, and Finish ends it after the last statement.
  - Product Challenge: opening a tile sends it to every phone; Reveal gives the tile value to every correct team. The choosing table still rotates.
  - Match the Customer: teams pick products for the persona; Reveal & score gives 10 per recommended product each team picked.
  - Listen for the Clue and Spot the Opportunity: teams type their answers; the facilitator shows them on screen and ticks what is right.
  - Teach-back ratings and Spin & Explain are judged by the room and ticked by the facilitator.
  - Close: the leaderboard picks the winner and shows points by activity.
- Answer keys go to the server with each question and never reach the team phones, so answers can't be read from the phone page. The server marks True or False, quiz and match answers when the round closes.

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
