# Know Your Customer, Know Your Product

Facilitator console for the BML retail refresher session (Day 1 · Session 4). It runs on a projector and holds the run of show, session timer, team scoreboard and seven activities: Myth or Fact, Product Passport, Product Challenge quiz, Listen for the Clue, Match the Customer, Spot the Opportunity, and Spin & Explain.

It is a single static page (`public/index.html`) with no build step, backed by Supabase for sessions, teams and scores.

## Sessions, teams and automatic scoring

- **Session…** in the top bar creates a session (a 6-character code) or joins one. The device that creates it is the facilitator: it holds a private host key, and only it can add teams or change scores.
- **+ Team** creates a team (up to 8). Rename teams in the bar or in the session dialog.
- The session dialog has a **scoreboard link** for tables (view only, updates live) and a private **facilitator link** to control the session from another device.
- Marking is scoring. Every activity awards points as you mark it, and unticking removes them:
  - Myth or Fact: record each table's call, then Reveal; correct tables get 10.
  - Product Passport: tap each table's 1–5 teach-back rating (10 per star).
  - Quiz: tap the answering table's answer; correct scores the tile value, a miss opens a steal for the other tables. Turns rotate automatically.
  - Listen for the Clue: tick clue, need and question per table (10 each).
  - Match the Customer: choose the presenting table and press Check (10 per recommended product found).
  - Spot the Opportunity: tick the tables that listed each opportunity.
  - Spin & Explain: tick the volunteer's table on a thumbs up (30).
  - Close: the leaderboard picks the winner and shows points by activity.

### Data model

`supabase/migrations/` holds the schema. A team's score is the sum of its `score_events`. Automatic awards carry a `ref` (for example `quiz:2-3`), so awarding again replaces the points instead of adding them. Tables are readable by anyone with the publishable key; every write goes through `SECURITY DEFINER` functions that check the session's host key (stored only as a SHA-256 hash). Teams and score events are published to Supabase Realtime so every screen updates live.

The Supabase client is vendored in `public/vendor/` so the page does not depend on a CDN on the day.

## Run locally

```sh
npm run dev
```

## Deploy

Deployed on Vercel as a static site. `vercel.json` serves `public/` as the output directory. Import the repository in Vercel (framework preset: Other) or run `npx vercel --prod`.

Product facts were taken from bankofmaldives.com.mv on 24 Oct 2026. Check rates, limits and fees against the current Schedule of Charges before each session.
