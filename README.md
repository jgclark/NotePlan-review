# NotePlan Review
Ruby script to help a user review their projects held in [NotePlan app](https://noteplan.co/), along the lines of [David Allen](https://gettingthingsdone.com/resources)'s *Getting Things Done* "weekly review" methodology.

<img src="https://preview.redd.it/f3fz0ssis6w41.png?width=992&format=png&auto=webp&s=980924da69ecd9ec22485e780e4e5be556f23ae1">

It assumes that some of the note files (not calendar files) are projects with some additional structure that it can find and process.

To add the project functionality in a note file use this structure:
- the first line of a NP project file is just a markdown-formatted title
- the second line contains metadata items:
  - any #hashtags, particularly #active, #archive, #goal and/or #project
  - any @start(), @due(), @complete(), @reviewed() dates, of form YYYY-MM-DD,
  - a @review() field, using terms like '2m', '1w'

From NP v2.5? this reads notes in sub-folders too (excluding those beginning with an '@' symbol, including the built-in '@Archive' and '@Trash' sub-folders.

## Possible actions
It shows a summary of the **projects ready for review**, grouped by active and then not active (archived or on-hold) projects. It then waits for user typed input to select one of the following options:

- **a**: list all notes -- this also re-reads all notes from storage
- **c**: run clean up script (this runs the separate **npClean** script available from the related [NotePlan-cleaner GitHub project](https://github.com/jgclark/NotePlan-cleaner/))
- **e**: open a note in NotePlan app, using fuzzy match to the remaining characters typed after the 'e'
- **l**: list people @mentions in open todos
- **p**: list all projects
- **r**: review next note in the ready to review list in NotePlan. When you have finished editing, return to the command line and press any key. This then automatically updates the @reviewed(...) date in the note
- **s**: save summary to a file with today's date in the summaries/ subdirectory (it creates it on the first run of this summary)
- **t**: show summary of stats for tasks (this runs the separate **npStats** script available from my [NotePlan-stats GitHub project](https://github.com/jgclark/NotePlan-stats/))
- **v**: view those to review
- **q**: quit the script
- **w**: list all #waiting tasks

## Configuration
Before running some gems need installing: `gem install fuzzy_match colorize` and perhaps others.

Set the following Constants at the top of the file:
- <code>USERNAME</code></code>: set machine username manually, as automated methods don't seek to work.
- <code>STORAGE_TYPE</code>: select whether you're using iCloud for storage (the default) or Drobpox
- <code>MENTIONS_TO_FIND</code>: list of @tags to list when found in open tasks
- <code>CLEAN_SCRIPT_PATH</code>: full path and filename of optional <code>npClean</code> script which can be run
- <code>STATS_SCRIPT_PATH</code>: full path and filename of optional <code>npStats</code> script which can be run by 
- the various constants under the **Colours** section, using the palette given in the 'colorize' gem

## Problems? Suggestions?
If you have any reports of problems, or suggestions for improvement, please [open an issue in the GitHub project](https://github.com/jgclark/NotePlan-review/issues).
