these are insturciotns on how to read a discord conversation given in markdown format. 

### FILE FORMAT EXPLANATION:

Sample file we will walk through:
file: 001-many-to-many.md

here are key insights on how to read file: 

Managing a many-to-many relationship
> this is title of the discord thread. 


--- 


tjtuom
OP
 — Yesterday at 3:46 PM 
 > this is the author name, and time. After this - is user message. 
 
 
 
 ---- 

  — Yesterday at 3:46 PM
> this marks end of a user message.
 
 
 
###  INSTRUCTIONS FOR WORKFLOW:
 
 1. setup a new single file ash example - as elixir script (see sample_ash.exs) for example
 2. read the md file -> find if it 'answers' the original question -> distill it at top of script in this format:
    - QUESTION
    - ISSUE
    - FIX
 3. write the elixir script reproducing the problem first ("repro"), then add the fix path
 4. use the usage_rules directory for ash docs. 
 
 ### RELEVANT GOTCHAS (from this repo sessions):
 1. for many_to_many repros, prefer sqlite (AshSqlite) over ETS.
 2. keep first script minimal: exact failing call + exact fixed call.
 3. for manage_relationship on many_to_many payload, pass destination `id` (not `file_id`).
 4. if join table has extra fields (`role`, `sort_order`), pass them via `join_keys`.
 5. do writes through unfiltered relationship (example: `:files`); keep filtered relationships for reads.
 
 ### TIP:
 1. try to run the elixir script to get the output and iterate from outputs 
 2. after successfully producing the script -> reflect on mistakes and write learnings in docs/mistakes-learnings.
 
 
 
 
 
