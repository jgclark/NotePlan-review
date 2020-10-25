# CHANGELOG

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
