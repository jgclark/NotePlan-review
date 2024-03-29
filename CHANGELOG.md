# CHANGELOG
## v1.4.4, 11.12.2021
- [Fix] fix edge case errors for (r)eview command

## v1.4.3, 10.12.2021
- [Add] you can now set a list of folders to ignore using constant FOLDERS_TO_IGNORE
- [Fix] when writing a (s)ummary output to CSV file, titles and filenames are quoted to hide any commas they contain
- [Fix] when writing a (s)ummary output to CSV file, titles are now given for otherwise empty notes
- [Change] when calling `npStats` script, it now uses the `-n` option to avoid writing output to its file

## [1.4.2] 2021-10-31
- [Change] Switch to using `#!/usr/bin/env ruby` at top of script to make it easier to use different ruby installations that the built-in one.
- [Fix] Working directory not reset after writing out Summary file

## [1.4.1] 2021-09-23
- [Fix] The business day options (e.g. `12b`) now work as a review interval (thanks @kumo).

## [v1.4.0] 2021-02-26
- [Change] To cope with an expanding number of non-project notes, I've changed how it decides which notes to include in the lists. Rather than defaulting to all and then excluding some, it now includes only those which have an `@review(...)` indicator in the metadata at the start of the note. After all, this is about reviewing things.
- [Add] The `@review(interval)` now understands `b`usiness days (ignores weekends) as well as `d`ays.

## v1.3.1, 1.1.2021
- [Fix] Couldn't open right note with a `&` in the title (issue 13)

## v1.3.0, 20.11.2020
- _time for a GitHub release, so arbitrarily bumping this to v1.3.0_
- [Change] When run npTools script now doesn't run quietly
- [Improve] Make configuration of data storage path automatic (prefering CloudKit > iCloud Drive > Dropbox if there are multiple of these set up)
- [Improve] Improve display of 'People List' function, including removing any future tasks

## 1.2.18, 30.10.2020
- [Change] Now default to using the sandbox location for CloudKit storage (change from NotePlan 3.0.15 beta)

## v1.2.17, 25.10.2020
- [Improve] Now better string matching used on 'e' and 'r' commands

## v1.2.16, 21.10.2020
- [Fix] Now better handle blank note file, or those with less than 2 lines

## v1.2.15, 16.10.2020
- [Change] Small improvements, and fix to presentation of completed and cancelled tasks

## v1.2.14, 15.10.2020
- [New] Ability to filter which notes are reviewed (issue 11)

## v1.2.13, 12.10.2020
- [Fix] Show updated 'Next Review' date after a Review for a note 

## v1.2.12, 9.10.2020
- [Change] Now show completed and cancelled notes in the lists again

## v1.2.11, 8.10.2020
- [Fix] Was wrongly counting cancelled tasks as open
- [Change] Improve the main task summary display to improve colouring, including highlighting overdue projects and project reviews
- [Change] Improve the main task summary display, by removing the review interval field, and presenting the due and review dates as relative dates

## v1.2.10, 20.9.2020
- [New] Pick up .md files, not just .txt files (issue 9)

## v1.2.9, 25.7.2020
- [Update] to use newer name of supporting script
- [Improve] Better installation documentation
- [New] Add --help option

## v1.2.8, 18.7.2020
- [Change] add support for CloudKit storage, now as a default, ready for NP 3.0 (issue 8)
- [Change] minor changes to @mentions

## v1.2.5, 9.5.2020
- [Improve] Documentation on commands

## v1.2.2-4, 18.4.2020
- [Change] Remove display of tag counts: now handled more fully in the separate npStats script
- [Fix] Wrong display of other notes (issue 3)

## v1.2.1, 19.3.2020
- [New] From NotePlan v2.4+ it also covers notes in sub-directories, but ignores notes in the special @Archive and @Trash sub-directories (or others beginning @) (issue 1)
- [New] Extend 'r' action to review particular notes specified by fuzzy match, not just the next in the list

## v1.2.0, 15.3.2020
- [Improve] error handling on file operations and external scripts
- [Change] order 'other active' by title

## v1.0.2, 29.2.2020
- [Change] summary file output now CSV formatted

## v1.0.0, 22.2.2020
- [New] Make the reviewing more flexible
- [New] Introduce colouring in output
- [Fix] Bug in handling & in note titles
