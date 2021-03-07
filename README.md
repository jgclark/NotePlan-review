# NotePlan Review
`npReview.rb` is a command-line script to help a user review their projects held in [NotePlan app](https://noteplan.co/), along the lines of [David Allen](https://gettingthingsdone.com/resources)'s *Getting Things Done* "weekly review" methodology.

<img src="npReview-20210210.jpg">

It assumes that some of the note files (not calendar files) are used for tasks and/or projects with some additional structure that it can find and process.

To add the project functionality in a note file use this structure:
- the first line of a NP project file is the usual markdown-formatted title
- the second line contains **metadata** items:
  - any #hashtags, particularly `#active`, `#archive`, `#goal`, `#project` and/or `#area`
  - any `@start(date)`, `@due(date)`, `@completed(date)`, `@reviewed(date)` dates, of form YYYY-MM-DD,
  - a `@review(interval)` field, using terms like '2m', '1w'

Valid **review date intervals** are specified as `[+][0-9][bdwmqy]`. This allows for `b`usiness days,  `d`ays, `w`eeks, `m`onths, `q`uarters or `y`ears. (Business days skip weekends. If the existing date happens to be on a weekend, it's treated as being the next working day. Public holidays aren't accounted for.)

From v1.4.0, it now includes _only those which have an `@review(interval)` indicator in the metadata_ at the start of the note. After all, this is about reviewing things.  (Previously, it defaulted to including all except those marked `#archive`, `@cancelled(date)` or `@completed(date)`.)

## Running the Reviewer
To run the review script at the command line type `ruby npReview.rb [filter]`. This reads notes in NotePlan's sub-folders too (excluding those beginning with an '@' symbol, including the built-in '@Archive' and '@Trash' folders). This was introduced in NotePlan v2.4 and made much more visible in v3.0.

If you supply an argument, it is treated as a **filter**. If this filter matches one or more NotePlan folder name, then only notes in that folder are used. Otherwise this argument will be used to find matching filenames (NB: not note names which can sometimes be different) in all folders (apart from the Archive and Trash).

### Possible actions
It shows a summary of the **projects ready for review**, grouped by active and then not active (archived or on-hold) projects. It then waits for user typed input to select one of the following options:

- **a**: list all notes -- this also re-reads all notes from storage ... useful if you're making other changes in NotePlan, which won't automatically be picked up if the script has started.
- **e**: open a note in NotePlan app, using fuzzy match to the remaining characters typed after the 'e'
- **h**: show summary of stats for tasks (this runs the separate **npStats.rb** script available from my [NotePlan-stats GitHub project](https://github.com/jgclark/NotePlan-stats/))
- **l**: list people @mentions in open todos
- **p**: list all projects
- **q**: quit the script
- **r**: review next note in the ready to review list in NotePlan. When you have finished editing, return to the command line and press any key. This then automatically updates the @reviewed(...) date in the note
- **s**: save summary to a file with today's date in the summaries/ subdirectory (it creates it on the first run of this summary)
- **t**: run tools script (this runs the separate **npTools.rb** script available from the related [NotePlan-tools GitHub project](https://github.com/jgclark/NotePlan-tools/))
- **v**: view those to review
- **w**: list all #waiting tasks

## Installation & Configuration
1. Check you have a working Ruby installation.
2. Install two ruby gems (libraries) (`gem install colorize optparse`)
3. Download and install the script to a place where it can be found on your filepath (perhaps `/usr/local/bin` or `/bin`)
4. Make the script executable (`chmod 755 npTools.rb`)
5. Change the following constants at the top of the script, as required:
   - <code>MENTIONS_TO_FIND</code>: list of @tags to list when found in open tasks
   - <code>TOOLS_SCRIPT_PATH</code>: full path and filename of optional <b><a href="https://github.com/jgclark/NotePlan-tools">npTools script</a></b> which can be run
   - <code>STATS_SCRIPT_PATH</code>: full path and filename of optional <b><a href="https://github.com/jgclark/NotePlan-stats">npStats script</a></b> which can be run
   - the various constants under the **Colours** section, using the palette given in the 'colorize' gem
- for completeness, `NP_BASE_DIR` automatically works out where NotePlan data files are located. (If there are multiple isntallations it selects using the priority CloudKit > iCloudDrive > DropBox.)
<!-- - `DATE_OFFSET_FORMAT`: date string format to use in date offset patterns -->

## Problems? Suggestions?
If you have any reports of problems, or suggestions for improvement, please open an issue in the [GitHub project](https://github.com/jgclark/NotePlan-review).
