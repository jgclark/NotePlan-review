#!/usr/bin/ruby
# frozen_string_literal: true

#----------------------------------------------------------------------------------
# NotePlan project review
# (c) Jonathan Clark, v1.2, 15.3.2020
#----------------------------------------------------------------------------------
# Assumes first line of a NP project file is just a markdown-formatted title
# and second line contains metadata items:
# - any #hashtags, particularly #Pnn and #active
# - any @start(), @due(), @complete(), @reviewed() dates, of form YYYY-MM-DD,
#   but other forms can be parsed as well
# - a @reviewInterval() field, using terms like '2m', '1w'
#
# Shows a summary of the notes, grouped by active and then closed.
# The active ones also have a list of the number of open / waiting / closed tasks.
# From NP v2.5 reads notes in folders too.
#
# Can also show a list of projects.
#
# Requires gems fuzzy_match  (> gem install fuzzy_match)
#----------------------------------------------------------------------------------
# TODO:
# * [ ] summary outputs to distinguish archived from complete notes
# * [ ] try changing @start(date), @due(date) etc. to @start/date etc.
#----------------------------------------------------------------------------------
# DONE:
# * [x] add extra space before @reviewed when adding for first time
# * [x] order 'other active' by title
# * [x] fail gracefully when no npClean script available
# * [x] in file read operations in initialize, cope with EOF errors [useful info at https://www.studytonight.com/ruby/exception-handling-in-ruby]
# * [x] for summary strip out the colorizing and output CSV instead
# * [x] add a way to review in an order I want
# * [x] Make cancelled part of active not active (e.g. Home Battery)
# * [x] review the 'Articles & Publicity' seems to fire wrongly; escaping in the x-callback-url?
# * [x] put total of tasks to review as summary on 'v'
# * [x] see if colouration is possible (https://github.com/fazibear/colorize)
# * [x] in 'e' cope with no fuzzy match error
# * [x] Fix next (r)eview item opening wrong note
# * [x] Fix save summary makes all [x]
# * [x] Log stats to summary file
# * [x] Report some stats from all open things
# * [x] Fix next (r)eview item not coming in same order as listed
# * [x] Fix after pressing 'a' the list of Archived ones is wrong
# * [x] Run npClean after a review -- and then get this to run after each individual note edit
# * [x] Separate parts to a different 'npClean' script daily crawl to fix various things
#----------------------------------------------------------------------------------

require 'date'
require 'time'
require 'open-uri'
require 'etc' # for login lookup
require 'fuzzy_match' # gem install fuzzy_match
require 'colorize' # for coloured output using https://github.com/fazibear/colorize

# Constants
DateFormat = '%d.%m.%y'
DateTimeFormat = '%e %b %Y %H:%M'
timeNow = Time.now
TodaysDate = Date.today # can't work out why this needs to be a 'constant' to work -- something about visibility, I suppose
EarlyDate = Date.new(1970, 1, 1)
summaryFilename = Date.today.strftime('%Y%m%d') + ' Notes summary.md'

# Setting variables to tweak
Username = 'jonathan' # set manually, as automated methods don't seek to work.
StorageType = 'iCloud' # or Dropbox
TagsToFind = ['@admin', '@facilities', '@CWs', '@cfl', '@yfl', '@secretary', '@JP', '@martha', '@church'].freeze
NPCleanScriptPath = '/Users/jonathan/bin/npClean'
NPStatsScriptPath = '/Users/jonathan/bin/npStats'
NoteplanDir = if StorageType == 'iCloud'
                "/Users/#{Username}/Library/Mobile Documents/iCloud~co~noteplan~NotePlan/Documents" # for iCloud storage
              else
                "/Users/#{Username}/Dropbox/Apps/NotePlan/Documents" # for Dropbox storage
              end
User = Etc.getlogin # for debugging when running by launchctl

# Colours, using the colorization gem
# to show some possible combinations, run  String.color_samples
# to show list of possible modes, run   puts String.modes  (e.g. underline, bold, blink)
String.disable_colorization false
CancelledColour = :light_magenta
CompletedColour = :light_green
ReviewNeededColour = :light_red
ActiveColour = :light_yellow
WarningColour = :light_red
InstructionColour = :light_cyan

# other globals
notes = [] # to hold all our note objects

#-------------------------------------------------------------------------
# Class definitions
#-------------------------------------------------------------------------
# NPNote Class reflects a stored NP note, and gives following methods:
# - initialize
# - calc_next_review
# - print_summary and print_summary_to_file
# - open_note
# - update_last_review_date
# - list_person_mentioned
# - list_waiting_tasks
#-------------------------------------------------------------------------
class NPNote
  # Define the attributes that need to be visible outside the class instances
  attr_reader :id
  attr_reader :title
  attr_reader :nextReviewDate
  attr_reader :reviewInterval
  attr_reader :isActive
  attr_reader :isCancelled
  attr_reader :isProject
  attr_reader :isGoal
  attr_reader :toReview
  attr_reader :metadataLine
  attr_reader :dueDate
  attr_reader :open
  attr_reader :waiting
  attr_reader :done
  attr_reader :filename

  def initialize(this_file, id)
    # initialise instance variables (that persist with the class instance)
    @filename = this_file
    @id = id
    @title = nil
    @isActive = true # assume note is active
    @isCancelled = false
    @startDate = nil
    @completeDate = nil
    @reviewInterval = nil
    @lastReviewDate = nil
    @nextReviewDateRelative = nil
    @codes = nil
    @open = @waiting = @done = 0
    @dueDate = nil
    @nextReviewDate = nil
    @isProject = false
    @isGoal = false
    @toReview = false

    # initialise other variables (that don't need to persist with the class instance)
    headerLine = @metadataLine = nil

    # puts "  Initializing NPNote for #{this_file}"
    # Open file and read the first two lines, using a rescue block to catch file errors
    File.open(this_file) do |f|
      begin
        headerLine = f.readline
        @metadataLine = f.readline

        # Now make a title for this file from first line
        # (but take off any heading characters at the start and starting and ending whitespace)
        @title = headerLine.gsub!(/^#*\s*/, '')
        @title = @title.gsub(/\s+$/, '')

        # Now process line 2 (rest of metadata)
        # the following regex matches returns an array with one item, so make a string (by join), and then parse as a date
        @metadataLine.scan(%r{@start\(([0-9\-\./]{6,10})\)}) { |m|  @startDate = Date.parse(m.join) }
        @metadataLine.scan(%r{(@end|@due)\(([0-9\-\./]{6,10})\)}) { |m| @dueDate = Date.parse(m.join) } # allow alternate form '@end(...)'
        @metadataLine.scan(%r{(@complete|@completed|@finish)\(([0-9\-\./]{6,10})\)}) { |m| @completeDate = Date.parse(m.join) }
        @metadataLine.scan(%r{@reviewed\(([0-9\-\./]{6,10})\)}) { |m| @lastReviewDate = Date.parse(m.join) }
        @metadataLine.scan(/@review\(([0-9]+[dDwWmMqQ])\)/) { |m| @reviewInterval = m.join.downcase }

        # make active if #active flag set
        @isActive = true    if @metadataLine =~ /#active/
        # but override if #archive set, or complete date set
        @isActive = false   if (@metadataLine =~ /#archive/) || @completeDate
        # make cancelled if #cancelled or #someday flag set
        @isCancelled = true if (@metadataLine =~ /#cancelled/) || (@metadataLine =~ /#someday/)
        # make toReview if review date set and before today
        @toReview = true if @nextReviewDate && (nrd <= TodaysDate)

        # If an active task and review interval is set, calc next review date.
        # If no last review date set, assume we need to review today.
        if @reviewInterval && @isActive
          @nextReviewDate = if @lastReviewDate
                              calc_next_review(@lastReviewDate, @reviewInterval)
                            else
                              TodaysDate
                            end
        end

        # Note if this is a #project or #goal
        @isProject = true if @metadataLine =~ /#project/
        @isGoal    = true if @metadataLine =~ /#goal/
        # look for project etc codes (there might be several, so join with spaces), and make uppercase
        # @@@ something wrong with regex but I can't see what, so removing the logic
        # @metadataLine.scan(/[PpFfSsWwBb][0-9]+/)  { |m| @codes = m.join(' ').downcase }
        # If no codes given, but this is a goal or project, then use a basic code
        if @codes.nil?
          @codes = 'P' if @isProject
          @codes = 'G' if @isGoal
        end

        # Now read through rest of file, counting number of open, waiting, done tasks
        f.each_line do |line|
          if line =~ /\[x\]/ # a completed task
            @done += 1
          elsif line =~ /^\s*\*\s+/ # a task, but (by implication) not completed
            if line =~ /#waiting/
              @waiting += 1 # count this as waiting not open
            else
              @open += 1
            end
          end
        end
      rescue EOFError # this file is empty so ignore it
        puts "  Error: note #{this_file} is empty, so ignoring it.".colorize(WarningColour)
        # @@@ actually need to reject the file and this object entirely
      rescue StandardError => e
        puts "ERROR: Hit #{e.exception.message} when initializing note file #{this_file}".colorize(WarningColour)
      end
    end
  end

  def calc_next_review(last, interval)
    # Calculate next review date, assuming interval is of form nn[dwmq]
    daysToAdd = 0
    unit = interval[-1]
    num = interval.chop.to_i
    case unit
    when 'd'
      daysToAdd = num
    when 'w'
      daysToAdd = num * 7
    when 'm'
      daysToAdd = num * 30
    when 'q'
      daysToAdd = num * 90
    else
      puts "Error in calc_next_review from #{last} by #{interval}".colorize(WarningColour)
    end
    newDate = last + daysToAdd
    newDate
  end

  def print_summary
    # Pretty print a summary for this NP note to screen
    mark = '[x] '
    colour = CompletedColour
    if @isActive
      mark = '[ ] '
      colour = ActiveColour
    end
    if @isCancelled
      mark = '[-] '
      colour = CancelledColour
    end
    colour = ReviewNeededColour if @toReview
    titleTrunc = @title[0..37]
    endDateFormatted = @dueDate ? @dueDate.strftime(DateFormat) : ''
    completeDateFormatted = @completeDate ? @completeDate.strftime(DateFormat) : ''
    nextReviewDateFormatted = @nextReviewDate ? @nextReviewDate.strftime(DateFormat) : ''
    out = format('%s %-38s %5s %3d %3d %3d  %8s %9s %-3s %10s', mark, titleTrunc, @codes, @open, @waiting, @done, endDateFormatted, completeDateFormatted, @reviewInterval, nextReviewDateFormatted)
    if @isProject || @isGoal # make P/G italic
      puts out.colorize(colour).italic
    else
      puts out.colorize(colour)
    end
  end

  def print_summary_to_file
    # print summary of this note in one line as a CSV file line
    mark = '[x]'
    mark = '[ ]' if @isActive
    mark = '[-]' if @isCancelled
    endDateFormatted = @dueDate ? @dueDate.strftime(DateFormat) : ''
    completeDateFormatted = @completeDate ? @completeDate.strftime(DateFormat) : ''
    nextReviewDateFormatted = @nextReviewDate ? @nextReviewDate.strftime(DateFormat) : ''
    out = format('%s %s,%s,%d,%d,%d,%s,%s,%s,%s', mark, @title, @codes, @open, @waiting, @done, endDateFormatted, completeDateFormatted, @reviewInterval, nextReviewDateFormatted)
    puts out
  end

  def open_note
    # Use x-callback scheme to open this note in NotePlan,
    # as defined at http://noteplan.co/faq/General/X-Callback-Url%20Scheme/
    #   noteplan://x-callback-url/openNote?noteTitle=...
    # Open a note identified by the title or date.
    # Parameters:
    # noteDate optional to identify the calendar note in the format YYYYMMDD like '20180122'.
    # noteTitle optional to identify the normal note by actual title.
    # fileName optional to identify a note by filename instead of title or date.
    #   Searches first general notes, then calendar notes for the filename.
    #   If its an absolute path outside NotePlan, it will copy the note into the database (only Mac).
    uri = "noteplan://x-callback-url/openNote?noteTitle=#{@title}"
    uriEncoded = URI.escape(uri, ' &') # by default & isn't escaped, so change that
    begin
      response = `open "#{uriEncoded}"`
    rescue StandardError
      puts "  Error trying to open note with #{uriEncoded}".colorize(WarningColour)
    end
    # Would prefer to use the following sorts of method, but can't get them to work.
    # Asked at https://stackoverflow.com/questions/57161971/how-to-make-x-callback-url-call-to-local-app-in-ruby but no response.
    #   uriEncoded = URI.escape(uri)
    #   response = open(uriEncoded).read  # TODO not yet working: no such file
    #   req = Net::HTTP::Get.new(uriEncoded)
    #   response = http.request(req)
  end

  def update_last_review_date
    # Set the note's last review date to today's date
    # Open the file for read-write
    begin
      f = File.open(@filename, 'r')
      lines = []
      n = 0
      f.each_line do |line|
        lines[n] = line
        n += 1
      end
      f.close
      lineCount = n
    rescue StandardError => e
      puts "ERROR: Hit #{e.exception.message} when updating last review date for file #{@filename}".colorize(WarningColour)
    end

    # in the metadata line, cut out the existing mention of lastReviewDate(...)
    metadata = lines[1]
    metadata.gsub!(%r{@reviewed\([0-9\.\-/]+\)\s*}, '') # needs gsub! to replace multiple copies, and in place
    # and add new lastReviewDate(<today>)
    metadata = "#{metadata.chomp} @reviewed(#{TodaysDate})" # feels like there ought to be a space between the items, but in practice not.

    # in the rest of the lines, do some clean up:
    n = 2
    while n < lineCount
      # remove any #waiting tags on complete tasks
      lines[n].gsub!(/ #waiting/, '') if (lines[n] =~ /#waiting/) && (lines[n] =~ /\[x\]/)
      # blank any lines which just have a * or -
      lines[n] = '' if lines[n] =~ /^\s*[\*\-]\s*$/
      n += 1
    end

    # open file and write all this data out
    begin
      File.open(@filename, 'w') do |ff|
        n = 0
        lines.each do |line|
          if n != 1
            ff.puts line
          else
            ff.puts metadata
          end
          n += 1
        end
      end
    rescue StandardError => e
      puts "ERROR: Hit #{e.exception.message} when initializing note file #{this_file}".colorize(WarningColour)
    end

    print "Updated review date.\n" # " for " + "#{@title}".bold
  end

  def list_waiting_tasks
    # List any tasks that are marked as #waiting and aren't [x] or @done
    f = File.open(@filename, 'r')
    lines = []
    n = 0
    f.each_line do |line|
      if (line =~ /#waiting/) && !((line =~ /@done/) || (line =~ /\[x\]/) || (line =~ /\[-\]/))
        lines[n] = line
        n = + 1
      end
    end
    f.close
    return unless n.positive?

    puts '# ' + @title
    lines.each do |line|
      puts '  ' + line.gsub(/#waiting/, '')
    end
  end

  def list_person_mentioned(tag)
    # List any lines that @-mention the parameter
    f = File.open(@filename, 'r')
    lines = []
    n = 0
    f.each_line do |line|
      if (line =~ /#{tag}/) && !((line =~ /@done/) || (line =~ /\[x\]/) || (line =~ /\[-\]/))
        lines[n] = line
        n = + 1
      end
    end
    f.close
    return unless n.positive?

    puts "  # #{@title}"
    lines.each do |line|
      puts '    ' + line
    end
  end

  # def inspect
  #   puts "#{@id}: nrd = #{@nextReviewDate}"
  # end
end

#=======================================================================================
# Main loop
#=======================================================================================
# Now start interactive loop offering a couple of actions:
# save summary file, open note in NP
#---------------------------------------------------------------------------
quit = false
verb = 'a' # get going by reading and summarising all notes
input = ''
searchString = bestMatch = nil
titleList = []
notesToReview = [] # list of ID of notes overdue for review
notesToReviewOrdered = []
notesOtherActive = [] # list of ID of other active notes
notesOtherActiveOrdered = []
notesArchived = []      # list of ID of archived notes
notesAllOrdered = []    # list of IDs of all notes (used for summary writer)

until quit
  # get title name fuzzy matching on the rest of the input string (i.e. 'eMatchstring') if present
  if !input.empty?
    searchString = input[1..(input.length - 2)]
    # from list of titles, try and match
    i = 0
    notes.each do |n|
      titleList[i] = n.title
      i += 1
    end
    fm = FuzzyMatch.new(titleList)
    bestMatch = fm.find(searchString)
  else
    bestMatch = nil
  end

  # Decide what Command to run ...
  case verb
  when 'p'
    # Show project summary
    puts "\n     Title                                        Opn Wat Don Due       Completed Int  NxtReview".bold
    puts '--------------------------------------- Projects List ------------------------------------------'
    notes.each do |n|
      n.print_summary  if n.isProject
    end
    puts "\n---------------------------------------- Goals List --------------------------------------------"
    notes.each do |n|
      n.print_summary  if n.isGoal
    end

  when 'a'
    # (Re)parse the data files
    i = 0
    notes.clear # clear if not already empty
    notesToReview.clear
    notesToReviewOrdered.clear
    notesOtherActive.clear
    notesOtherActiveOrdered.clear
    notesArchived.clear
    notesAllOrdered.clear

    # Read metadata for all note files in the NotePlan directory
    # (and sub-directories from v2.5)
    begin
      Dir.chdir(NoteplanDir + '/Notes/')
      Dir.glob('**/*.txt').each do |this_file|
        notes[i] = NPNote.new(this_file, i)
        nrd = notes[i].nextReviewDate
        if notes[i].isActive && !notes[i].isCancelled
          if nrd && (nrd <= TodaysDate)
            notesToReview.push(notes[i].id) # Save list of ID of notes overdue for review
          else
            notesOtherActive.push(notes[i].id) # Save list of other active notes
          end
        else
          notesArchived.push(notes[i].id) # Save list of in-active notes
        end
        i += 1
      end
    rescue StandardError => e
      puts "ERROR: Hit #{e.exception.message} when reading note file #{this_file}".colorize(WarningColour)
    end

    # Order notes by different fields
    # Info: https://stackoverflow.com/questions/882070/sorting-an-array-of-objects-in-ruby-by-object-attribute
    # https://stackoverflow.com/questions/4610843/how-to-sort-an-array-of-objects-by-an-attribute-of-the-objects
    # Can do multiples using [s.dueDate, s....]
    notesToReviewOrdered = notesToReview.sort_by { |s| notes[s].nextReviewDate }
    notesOtherActiveOrdered = notesOtherActive.sort_by { |s| notes[s].title } # to get around problem of nil entries breaking any comparison
    notesAllOrdered = notes.sort_by(&:title) # simpler, as defaults to alphanum sort

    # Now output the notes with ones needing review first,
    # then ones which are active, then the rest
    puts "\n     Title                                        Opn Wat Don Due       Completed Int  NxtReview".bold
    puts '-------------------------------- Not Active ----------------------------------------------------'
    notesArchived.each do |n|
      notes[n].print_summary
    end
    puts '------------------------------- Other Active ---------------------------------------------------'
    notesOtherActiveOrdered.each do |n|
      notes[n].print_summary
    end
    puts '------------------------------ Ready to review -------------------------------------------------'
    notesToReviewOrdered.each do |n|
      notes[n].print_summary
    end
    puts '------------------------------------------------------------------------------------------------'
    no = 0
    nw = 0
    nd = 0
    notesToReview.each do |n|
      nd += notes[n].done
      nw += notes[n].waiting
      no += notes[n].open
    end
    notesOtherActive.each do |n|
      nd += notes[n].done
      nw += notes[n].waiting
      no += notes[n].open
    end
    puts "     #{notesToReview.count + notesOtherActive.count} active notes with #{no} open, #{nw} waiting, #{nd} done tasks.   #{notesArchived.count} archived notes"

  when 'v'
    # Show all notes to review
    puts "\n     Title                                        Opn Wat Don Due       Completed Int  NxtReview".bold
    puts '------------------------------ Ready to review -------------------------------------------------'
    notesToReviewOrdered.each do |n|
      notes[n].print_summary
    end
    # show summary count
    puts "     (Total: #{notesToReview.count} notes)".colorize(ActiveColour)

  when 'c'
    # go and run the clean up script, npClean, which defaults to all files changed in last 24 hours
    begin
      success = system('ruby', NPCleanScriptPath)
    rescue StandardError
      puts '  Error trying to run npClean script'.colorize(WarningColour)
    end

  when 't'
    # go and run the statistics script, npStats
    begin
      success = system('ruby', NPStatsScriptPath)
    rescue StandardError
      puts '  Error trying to run npStats script'.colorize(WarningColour)
    end

  when 'e'
    # edit the note
    # use title name fuzzy matching on the rest of the input string (i.e. 'eMatchstring')
    if bestMatch
      puts "   Opening closest match note '#{bestMatch}'"
      noteID = titleList.find_index(bestMatch)
      notes[noteID].open_note
    else
      puts "   Warning: Couldn't find a note matching '#{searchString}'".colorize(WarningColour)
    end

  when 'l'
    # Show @people annotations for those listed in atTags
    puts "\n----------------------------- People Mentioned ----------------------------------------------"
    TagsToFind.each do |p|
      puts
      puts "#{p} mentions:".bold

      notesToReviewOrdered.each do |n|
        notes[n].list_person_mentioned(p)
      end
      notesOtherActiveOrdered.each do |n|
        notes[n].list_person_mentioned(p)
      end
    end

  when 'q'
    # quit the utility
    quit = true
    break

  when 'r'
    # If no extra characters given, then open the next note that needs reviewing
    if bestMatch
      noteID = titleList.find_index(bestMatch)
      notes[noteID].open_note
      # puts "       Reviewing closest match note '#{bestMatch}' ... press any key when finished."
      print '  Reviewing closest match note ' + bestMatch.to_s. bold + ' ... press any key when finished. '
      gets

      # update the @reviewed() date for the note just reviewed
      notes[noteID].update_last_review_date
      # Attempt to remove this from notesToReivewOrdered
      notesToReview.delete(noteID)
      notesToReviewOrdered.delete(noteID)
      notesOtherActive.push(noteID)
      notesOtherActiveOrdered.push(noteID)
      # Clean up this file
      begin
        success = system('ruby', NPCleanScriptPath, notes[noteID].filename)
      rescue StandardError
        puts '  Error trying to clean '.colorize(WarningColour) + notes[noteID].title.to_s.colorize(WarningColour).bold
      end
    else
      if !notesToReviewOrdered.empty?
        noteIDToReview = notesToReviewOrdered.first
        notes[noteIDToReview].open_note
        # puts "       Press any key when finished reviewing '#{notes[noteIDToReview].title}' ..."
        print '  Reviewing ' + notes[noteIDToReview].title.to_s.bold + ' ... press any key when finished. '
        gets

        # update the @reviewed() date for the note just reviewed
        notes[noteIDToReview].update_last_review_date
        # move this from notesToReview to notesOtherActive
        notesToReview.delete(noteIDToReview)
        notesToReviewOrdered.delete(noteIDToReview)
        notesOtherActive.push(noteIDToReview)
        notesOtherActiveOrdered.push(noteIDToReview)
        # Clean up this file
        begin
          success = system('ruby', NPCleanScriptPath, notes[noteIDToReview].filename)
        rescue StandardError
          puts '  Error trying to clean '.colorize(WarningColour) + notes[noteIDToReview].title.to_s.colorize(WarningColour).bold
        end
      else
        puts "       Way to go! You've no more notes to review :-)".colorize(CompletedColour)
      end
    end

  when 's'
    # write out the unordered summary to summaryFilename, temporarily redirecting stdout
    # using 'w' mode which will truncate any existing file
    Dir.chdir(NoteplanDir + '/Summaries/')
    sf = File.open(summaryFilename, 'w')
    old_stdout = $stdout
    $stdout = sf
    puts "# NotePlan Notes summary, #{timeNow}"
    notesAllOrdered.each(&:print_summary_to_file)

    no = 0
    nw = 0
    nd = 0
    notesOtherActive.each do |n| # WHY doesn't notesAllOrdered work here?
      nd += notes[n].done
      nw += notes[n].waiting
      no += notes[n].open
    end
    puts '# Totals'
    puts "Notes: #{notesToReview.count + notesOtherActive.count} active, #{notesArchived.count} archived"
    puts "Tasks: #{no} open, #{nw} waiting, #{nd} done"

    $stdout = old_stdout
    sf.close
    puts '    Written summary to ' + summaryFilename.to_s.bold

  when 'w'
    # list @waiting items in open notes
    puts "\n-------------------------------------- #Waiting Tasks -----------------------------------------"
    notesToReviewOrdered.each do |n|
      notes[n].list_waiting_tasks
    end
    notesOtherActiveOrdered.each do |n|
      notes[n].list_waiting_tasks
    end

  else
    puts '   Invalid action! Please try again.'.colorize(WarningColour)
  end

  # now ask again
  print "\nCommands: re-read & show (a)ll, (c)lean up, (e)dit note, people (l)ist, (p)roject list,".colorize(InstructionColour)
  print "\n(q)uit, (r)eview next, (s)ave summary, (t) show stats, (v) review list, (w)aiting tasks  > ".colorize(InstructionColour)
  input = gets
  verb = input[0].downcase
end
