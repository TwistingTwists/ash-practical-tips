# 001 Many-to-Many Session Learnings

## 1) Instructions You Had To Give To Steer Me Correctly

- You had to explicitly push me to use the `wojtekmach-mix_install_examples-7859d26/` folder as style/reference context.
- You had to repeatedly steer me toward a strict repro-first goal (`reproduce/repro exactly`) instead of a broader exploratory script.
- You had to explicitly insist on SQLite for this many-to-many case (which was correct for realistic behavior).
- You had to remind me to stay anchored to `001-many-to-many.md` as the source of truth for both issue and fix.
- You had to ask for the exact documentation format you wanted at the top of the script (`question/answer`, `issue/fix`).

## 2) Mistakes I Made While Working With Ash

- I started with ETS data layer, which masked/changed behavior and added confusion for this relationship case.
- I initially introduced two update actions marked `primary? true`, which is invalid Ash DSL.
- I spent cycles trying to make filtered relationship loading work in the repro path, instead of minimizing to the exact failure from the thread.
- I used/assumed incorrect join filter reference names while experimenting (`product_files.role`, `thumbnails_join_assoc.role`) in this context.
- I delayed converging on the core repro: `file_id` in payload causes not-found; `id` fixes it on the unfiltered write relationship.

## What I Should Have Done Earlier

- Start with SQLite immediately.
- Build a minimal script that only shows: failing payload (`file_id`) and successful payload (`id`).
- Keep filtered relationships and form-shape concerns out of the first repro script.
