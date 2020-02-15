# NotePlan Reviewer
Ruby script to help a user review their project in NotePlan, along the lines of David Allen's Getting Things Done "weekly review" methodology.

It assumes that some of the note files (not calendar files) are projects with some additional structure that it can find and process.

To add the project functionality in a note file use this structure:
- the first line of a NP project file is just a markdown-formatted title
- and second line contains metadata items:
  - any #hashtags, particularly #active, #archive, #goal and/or #project
  - any @start(), @due(), @complete(), @reviewed() dates, of form YYYY-MM-DD,
  - a @reviewInterval() field, using terms like '2m', '1w'

## Possible actions
It shows a summary of the **projects ready for review**, grouped by active and then not active (archived or on-hold) projects. It then waits for user typed input to select one of the following options:

- **a**: list all notes -- this also re-reads all notes from storage
- **c**: run clean up script (if present)
- **e**: open a note in NotePlan, using fuzzy match to the remaining characters typed after the 'e'
- **l**: list people @tags in open todos
- **p**: list all projects
- **r**: review next item in the ready to review list -- i.e. open in NotePlan. When you have finished editing, return to the command line and press any key. This then automatically updates the @reviewed(...) date
- **s**: save summary to a file with today's date in the summaries/ subdirectory
- **v**: view those to review,
- **q**: quit the script 
- **w**: list all #waiting tasks

## Configuration
Before running some gems need installing:
- `gem install fuzzy_match`
- `gem install colorize`

Set the following Constants at the top of the file:
- Username: set machine username manually, as automated methods don't seek to work.
- StorageType: select whether you're using iCloud for storage (the default) or Drobpox
- TagsToFind: list of @tags to list when found in open tasks
- NPCleanScriptPath: full path and filename of optional npClean script which can be run
- the various constants under the **Colours** section, using the palette given in the 'colorize' gem

## TODO
[ ] order 'other active' by due date [done] then title
[ ] in file read operations in initialize, cope with EOF errors
[ ] Make cancelled part of archive not active
