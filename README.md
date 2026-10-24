# Know Your Customer, Know Your Product

Facilitator console for the BML retail refresher session (Day 1 · Session 4). It runs on a projector and holds the run of show, session timer, team scoreboard and seven activities: Myth or Fact, Product Passport, Product Challenge quiz, Listen for the Clue, Match the Customer, Spot the Opportunity, and Spin & Explain.

It is a single static page (`public/index.html`) with no build step. Scores, used quiz tiles and the current view are saved in the browser's `localStorage`, so they belong to the device running the session.

## Run locally

```sh
npm run dev
```

## Deploy

Deployed on Vercel as a static site. `vercel.json` serves `public/` as the output directory. Import the repository in Vercel (framework preset: Other) or run `npx vercel --prod`.

Product facts were taken from bankofmaldives.com.mv on 24 Oct 2026. Check rates, limits and fees against the current Schedule of Charges before each session.
