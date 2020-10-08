#!/usr/bin/ruby
#----------------------------------------------------------------------------------
# NotePlan Review script
# by Jonathan Clark, v1.2.11, 8.10.2020
#----------------------------------------------------------------------------------
# Assumes first line of a NP project file is just a markdown-formatted title
# and second line contains metadata items:
# - any #hashtags, particularly #Pnn and #active
# - any @start(), @due(), @complete(), @reviewed() dates, of form YYYY-MM-DD,
#   but other forms can be parsed as well
# - a @review_interval() field, using terms like '2m', '1w'
#
# Shows a summary of the notes, grouped by active and then closed.
# The active ones also have a list of the number of open / waiting / closed tasks.
# From NotePlan v2.4 it also covers notes in sub-directories, but ignores notes
# in the special @Archive and @Trash sub-directories (or others beginning @).
#
# Can also show a list of projects, and run related npStats and npTools scripts
# from its related GitHub projects.
#
# Requires gems fuzzy_match and colorize (> gem install fuzzy_match colorize)
#----------------------------------------------------------------------------------
# For more details, including issues, see GitHub project https://github.com/jgclark/NotePlan-review/
#----------------------------------------------------------------------------------
# TODO: add back in non-active but not in archive directory
VERSION = '1.2.11'.freeze

require 'date'
require 'time'
require 'open-uri'
require 'etc' # for login lookup
require 'fuzzy_match'
require 'colorize'
require 'optparse' # more details at https://docs.ruby-lang.org/en/2.1.0/OptionParser.html

# Constants
DATE_FORMAT = '%d.%m.%y'.freeze
SORTING_DATE_FORMAT = '%y%m%d'.freeze
DATE_TIME_FORMAT = '%e %b %Y %H:%M'.freeze
timeNow = Time.now
TodaysDate = Date.today # can't work out why this needs to be a 'constant' to work -- something about visibility, I suppose
EarlyDate = Date.new(1970, 1, 1)
summaryFilename = Date.today.strftime('%Y%m%d') + ' Notes summary.md'

# Setting variables to tweak
USERNAME = 'jonathan'.freeze # set manually, as automated methods don't seek to work.
MENTIONS_TO_FIND = ['@admin', '@facilities', '@cws', '@cfl', '@email', '@secretary', '@jp', '@martha', '@church'].freeze
TOOLS_SCRIPT_PATH = '/Users/jonathan/bin/npTools'.freeze
STATS_SCRIPT_PATH = '/Users/jonathan/bin/npStats'.freeze
STORAGE_TYPE = 'CloudKit'.freeze # or Dropbox or CloudKit or iCloud
NP_BASE_DIR = if STORAGE_TYPE == 'Dropbox'
                "/Users/#{USERNAME}/Dropbox/Apps/NotePlan/Documents" # for Dropbox storage
              elsif STORAGE_TYPE == 'CloudKit'
                "/Users/#{USERNAME}/Library/Application Support/co.noteplan.NotePlan3" # for CloudKit storage
              else
                "/Users/#{USERNAME}/Library/Mobile Documents/iCloud~co~noteplan~NotePlan/Documents" # for iCloud storage (default)
              end
NP_NOTE_DIR = "#{NP_BASE_DIR}/Notes".freeze
NP_SUMMARIES_DIR = "#{NP_BASE_DIR}/Summaries".freeze

USER = Etc.getlogin # for debugging when running by launchctl

# Colours, using the colorization gem
# to show some possible combinations, run  String.color_samples
# to show list of possible modes, run   puts String.modes  (e.g. underline, bold, blink)
String.disable_colorization false
NormalColour = :default
CancelledColour = :light_magenta
CompletedColour = :green
ReviewNeededColour = :light_yellow
WarningColour = :light_red
InstructionColour = :light_cyan
GoalColour = :light_green
ProjectColour = :light_blue

# other constants
HEADER_LINE = "\n    Title                                  Open Wait Done Due       Completed   NextReview".freeze

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
# - list_tag_mentions
# - list_waiting_tasks
#-------------------------------------------------------------------------
class NPNote
  # Define the attributes that need to be visible outside the class instances
  attr_reader :id
  attr_reader :title
  attr_reader :next_review_date
  attr_reader :review_interval
  attr_reader :is_active
  attr_reader :is_cancelled
  attr_reader :is_project
  attr_reader :is_goal
  attr_reader :to_review
  attr_reader :metadata_line
  attr_reader :due_date
  attr_reader :open
  attr_reader :waiting
  attr_reader :done
  attr_reader :filename

  def initialize(this_file, id)
    # initialise instance variables (that persist with the class instance)
    @filename = this_file
    @id = id
    @title = nil
    @is_active = true # assume note is active
    @is_cancelled = false
    @startDate = nil
    @completeDate = nil
    @review_interval = nil
    @lastReviewDate = nil
    @next_review_date_relative = nil
    # @codes = nil
    @open = @waiting = @done = 0
    @due_date = nil
    @next_review_date = nil
    @is_project = false
    @is_goal = false
    @to_review = false

    # initialise other variables (that don't need to persist with the class instance)
    headerLine = @metadata_line = nil

    # puts "  Initializing NPNote for #{this_file}"
    # Open file and read the first two lines, using a rescue block to catch file errors
    File.open(this_file) do |f|
      begin
        headerLine = f.readline
        @metadata_line = f.readline

        # Now make a title for this file from first line
        # (but take off any heading characters at the start and starting and ending whitespace)
        @title = headerLine.gsub!(/^#*\s*/, '')
        @title = @title.gsub(/\s+$/, '')

        # Now process line 2 (rest of metadata)
        # the following regex matches returns an array with one item, so make a string (by join), and then parse as a date
        @metadata_line.scan(%r{@start\(([0-9\-\./]{6,10})\)}) { |m|  @startDate = Date.parse(m.join) }
        @metadata_line.scan(%r{(@end|@due)\(([0-9\-\./]{6,10})\)}) { |m| @due_date = Date.parse(m.join) } # allow alternate form '@end(...)'
        @metadata_line.scan(%r{(@complete|@completed|@finish)\(([0-9\-\./]{6,10})\)}) { |m| @completeDate = Date.parse(m.join) }
        @metadata_line.scan(%r{@reviewed\(([0-9\-\./]{6,10})\)}) { |m| @lastReviewDate = Date.parse(m.join) }
        @metadata_line.scan(/@review\(([0-9]+[dDwWmMqQ])\)/) { |m| @review_interval = m.join.downcase }

        # make active if #active flag set
        @is_active = true    if @metadata_line =~ /#active/
        # but override if #archive set, or complete date set
        @is_active = false   if (@metadata_line =~ /#archive/) || @completeDate
        # make cancelled if #cancelled or #someday flag set
        @is_cancelled = true if (@metadata_line =~ /#cancelled/) || (@metadata_line =~ /#someday/)
        # make to_review if review date set and before today
        @to_review = true if @next_review_date && (nrd <= TodaysDate)

        # If an active task and review interval is set, calc next review date.
        # If no last review date set, assume we need to review today.
        if @review_interval && @is_active
          @next_review_date = if @lastReviewDate
                                calc_next_review(@lastReviewDate, @review_interval)
                              else
                                TodaysDate
                              end
        end

        # Note if this is a #project or #goal
        @is_project = true if @metadata_line =~ /#project/
        @is_goal    = true if @metadata_line =~ /#goal/
        # look for project etc codes (there might be several, so join with spaces), and make uppercase
        # @@@ something wrong with regex but I can't see what, so removing the logic
        # @metadata_line.scan(/[PpFfSsWwBb][0-9]+/)  { |m| @codes = m.join(' ').downcase }
        # If no codes given, but this is a goal or project, then use a basic code
        # if @codes.nil?
        #   @codes = 'P' if @is_project
        #   @codes = 'G' if @is_goal
        # end

        # Now read through rest of file, counting number of open, waiting, done tasks
        f.each_line do |line|
          if line =~ /\[x\]/ # a completed task
            @done += 1
          elsif line =~ /^\s*\*\s+/ && line !~ /\[-\]/ # a task, but (by implication) not completed or cancelled
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
    mark = '[ ]'
    title_colour = NormalColour
    title_colour = GoalColour if @is_goal
    title_colour = ProjectColour if @is_project
    if @is_completed
      mark = '[x]'
      title_colour = CompletedColour
    end
    if @is_cancelled
      mark = '[-]'
      title_colour = CancelledColour
    end
    title_trunc = @title[0..37]
    endDateFormatted = @due_date ? relative_date(@due_date) : ''
    completeDateFormatted = @completeDate ? @completeDate.strftime(DATE_FORMAT) : ''
    next_review_dateFormatted = @next_review_date ? relative_date(@next_review_date) : ''
    out_pt1 = format('%s %-38s', mark, title_trunc)
    out_pt2 = format(' %4d %4d %4d', @open, @waiting, @done)
    out_pt3 = format(' %-10s', endDateFormatted)
    out_pt4 = format(' %10s', completeDateFormatted)
    out_pt5 = format(' %-10s', next_review_dateFormatted)
    print out_pt1.colorize(title_colour)
    print out_pt2
    if @due_date && @due_date < TodaysDate
      print out_pt3.colorize(WarningColour)
    else
      print out_pt3
    end
    print out_pt4
    if @next_review_date && @next_review_date < TodaysDate
      print out_pt5.colorize(ReviewNeededColour)
    else
      print out_pt5
    end
    print "\n"
  end

  def print_summary_to_file
    # print summary of this note in one line as a CSV file line
    mark = '[x]'
    mark = '[ ]' if @is_active
    mark = '[-]' if @is_cancelled
    endDateFormatted = @due_date ? @due_date.strftime(DATE_FORMAT) : ''
    completeDateFormatted = @completeDate ? @completeDate.strftime(DATE_FORMAT) : ''
    next_review_dateFormatted = @next_review_date ? @next_review_date.strftime(DATE_FORMAT) : ''
    out = format('%s %s,%d,%d,%d,%s,%s,%s,%s', mark, @title, @open, @waiting, @done, endDateFormatted, completeDateFormatted, @review_interval, next_review_dateFormatted)
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
    # FIXME: probably here that emojis aren't working
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
      line_count = n
    rescue StandardError => e
      puts "ERROR: Hit #{e.exception.message} when updating last review date for file #{@filename}".colorize(WarningColour)
    end

    # in the metadata line, cut out the existing mention of lastReviewDate(...)
    metadata = lines[1]
    metadata.gsub!(%r{@reviewed\([0-9\.\-/]+\)\s*}, '') # needs gsub! to replace multiple copies, and in place
    # and add new lastReviewDate(<today>)
    metadata = "#{metadata.chomp} @reviewed(#{TodaysDate})"
    # then remove multiple consecutive spaces which seem to creep in, with just one
    metadata.gsub!(%r{\s{2,12}}, ' ')

    # in the rest of the lines, do some clean up:
    n = 2
    while n < line_count
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

    puts "    Updated review date for #{@filename}."
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

  def list_tag_mentions(tag)
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
end


def relative_date(date)
  # Return rough relative string version of difference between date and today.
  # Don't return all the detail, but just the most significant unit (year, month, week, day)
  # If date is in the past then add 'ago'.
  # e.g. today, 3w ago, 2m, 4y ago.
  # Accepts date in normal Ruby Date type
  is_past = false
  diff = (date - TodaysDate).to_i # need to cast to integer as otherwise it seems to be type rational
  if diff.negative? then 
    diff = diff.abs
    is_past = true
  end
  if diff == 0
    out = "today"
  elsif diff == 1
    out = "#{diff} day"
  elsif diff < 9
    out = "#{diff} days"
  elsif diff < 12
    out = "#{(diff/7.0).round} wk"
  elsif diff < 29
    out = "#{(diff/7.0).round} wks"
  elsif diff < 550
    out = "#{(diff/30.4).round} mon"
  else
    out = "#{(diff/365.0).round} yrs"
  end
  out += " ago" if is_past
  return out

  # # test cases for relative_date() for testing on 7.10.2020
  # relative_date(Date.today)
  # relative_date(Date.new(2020, 10, 5))
  # relative_date(Date.new(2020, 7, 20))
  # relative_date(Date.new(2020, 10, 10))
  # relative_date(Date.new(2020, 10, 20))
  # relative_date(Date.new(2020, 11, 10))
  # relative_date(Date.new(2021, 3, 10))
  # relative_date(Date.new(2021, 10, 7))
  # relative_date(Date.new(2022, 4, 7))
  # relative_date(Date.new(2022, 8, 7))
end

#-------------------------------------------------------------------------
# Setup program options
#-------------------------------------------------------------------------
options = {}
opt_parser = OptionParser.new do |opts|
  opts.banner = "NotePlan Reviewer v#{VERSION}. Details at https://github.com/jgclark/NotePlan-review/\nUsage: npReview.rb [options]"
  opts.separator ''
  opts.on('-h', '--help', 'Show this help') do
    puts opts
    exit
  end
end
opt_parser.parse! # parse out options, leaving file patterns to process

#=======================================================================================
# Main loop
#=======================================================================================
# Now start interactive loop offering a couple of actions:
# save summary file, open note in NP
#---------------------------------------------------------------------------
quit = false
verb = 'a' # get going by reading and summarising all notes
input = ''
searchString = best_match = nil
titleList = []
notesto_review = [] # list of ID of notes overdue for review
notesto_reviewOrdered = []
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
    best_match = fm.find(searchString)
  else
    best_match = nil
  end

  # Decide what Command to run ...
  case verb
  when 'p'
    # Show project summary
    puts HEADER_LINE.bold    
    puts '--------------------------------------- Projects List ---------------------------------------'
    notes.each do |n|
      n.print_summary  if n.is_project
    end
    puts "----------------------------------------- Goals List ----------------------------------------"
    notes.each do |n|
      n.print_summary  if n.is_goal
    end

  when 'a'
    # (Re)parse the data files
    i = 0
    notes.clear # clear if not already empty
    notesto_review.clear
    notesto_reviewOrdered.clear
    notesOtherActive.clear
    notesOtherActiveOrdered.clear
    notesArchived.clear
    notesAllOrdered.clear

    # Read metadata for all note files in the NotePlan directory
    # (and sub-directories from v2.5, ignoring special ones starting '@')
    begin
      Dir.chdir(NP_NOTE_DIR)
      Dir.glob('{[!@]**/*,*}.{txt,md}').each do |this_file|
        notes[i] = NPNote.new(this_file, i)
        next unless notes[i].is_active && !notes[i].is_cancelled

        nrd = notes[i].next_review_date
        # puts "#{i}: #{notes[i].title} #{notes[i].due_date}, #{notes[i].next_review_date}"
        if nrd && (nrd <= TodaysDate)
          notesto_review.push(notes[i].id) # Save list of ID of notes overdue for review
        else
          notesOtherActive.push(notes[i].id) # Save list of in-active notes
        end
        i += 1
      end
    rescue StandardError => e
      puts "ERROR: Hit #{e.exception.message} when reading note file #{this_file}".colorize(WarningColour)
    end

    # Order notes by different fields
    # Info: https://stackoverflow.com/questions/882070/sorting-an-array-of-objects-in-ruby-by-object-attribute
    # https://stackoverflow.com/questions/4610843/how-to-sort-an-array-of-objects-by-an-attribute-of-the-objects
    # https://stackoverflow.com/questions/827649/what-is-the-ruby-spaceship-operator
    notesAllOrdered = notes.sort_by(&:title) # simple comparison, as defaults to alphanum sort
    # Following are more complicated, as the array is of _id_s, not actual NPNote objects
    # NB: nil entries will break any comparison.
    notesto_reviewOrdered = notesto_review.sort_by { |s| notes[s].next_review_date }
    notesOtherActiveOrdered = notesOtherActive.sort_by { |s| notes[s].next_review_date ? notes[s].next_review_date.strftime(SORTING_DATE_FORMAT) + notes[s].title : notes[s].title }

    # Now output the notes with ones needing review first,
    # then ones which are active, then the rest
    puts HEADER_LINE.bold
    if notesArchived.count.positive?
      puts '-------------------------------- Not Active ----------------------------------------------------'
      notesArchived.each do |n|
        notes[n].print_summary
      end
    end
    puts '------------------------------- Other Active ---------------------------------------------------'
    notesOtherActiveOrdered.each do |n|
      notes[n].print_summary
    end
    puts '------------------------------ Ready to review -------------------------------------------------'
    notesto_reviewOrdered.each do |n|
      notes[n].print_summary
    end
    puts '------------------------------------------------------------------------------------------------'
    puts "     #{notesto_review.count + notesOtherActive.count} active, #{notesArchived.count} archived notes"

  when 'v'
    # Show all notes to review
    puts HEADER_LINE.bold
    puts '------------------------------ Ready to review -------------------------------------------------'
    notesto_reviewOrdered.each do |n|
      notes[n].print_summary
    end
    # show summary count
    puts "     (Total: #{notesto_review.count} notes)".colorize(ActiveColour)

  when 't'
    # go and run the tools script, npTools, which defaults to all files changed in last 24 hours
    begin
      success = system('ruby', TOOLS_SCRIPT_PATH)
    rescue StandardError
      puts '  Error trying to run npTools script -- please check it has been configured in TOOLS_SCRIPT_PATH'.colorize(WarningColour)
    end

  when 'h'
    # go and run the statistics script, npStats
    begin
      success = system('ruby', STATS_SCRIPT_PATH)
    rescue StandardError
      puts '  Error trying to run npStats script -- please check it has been configured in STATS_SCRIPT_PATH'.colorize(WarningColour)
    end

  when 'e'
    # edit the note
    # use title name fuzzy matching on the rest of the input string (i.e. 'eMatchstring')
    if best_match
      puts "   Opening closest match note '#{best_match}'"
      noteID = titleList.find_index(best_match)
      notes[noteID].open_note
    else
      puts "   Warning: Couldn't find a note matching '#{searchString}'".colorize(WarningColour)
    end

  when 'l'
    # Show @tags from those listed in atTags
    puts "\n--------------------------------- Tags Mentioned --------------------------------------"
    MENTIONS_TO_FIND.each do |p|
      puts
      puts "#{p} mentions:".bold

      notesto_reviewOrdered.each do |n|
        notes[n].list_tag_mentions(p)
      end
      notesOtherActiveOrdered.each do |n|
        notes[n].list_tag_mentions(p)
      end
    end

  when 'q'
    # quit the utility
    quit = true
    break

  when 'r'
    # If no extra characters given, then open the next note that needs reviewing
    if best_match
      noteID = titleList.find_index(best_match)
      notes[noteID].open_note
      # puts "       Reviewing closest match note '#{best_match}' ... press any key when finished."
      print '  Reviewing closest match note ' + best_match.to_s. bold + ' ... press any key when finished. '
      gets

      # update the @reviewed() date for the note just reviewed
      notes[noteID].update_last_review_date
      # Attempt to remove this from notesToReivewOrdered
      notesto_review.delete(noteID)
      notesto_reviewOrdered.delete(noteID)
      notesOtherActive.push(noteID)
      notesOtherActiveOrdered.push(noteID)
      # Run Tools on this file
      begin
        success = system('ruby', TOOLS_SCRIPT_PATH, notes[noteID].filename)
      rescue StandardError
        puts '  Error trying to run tools '.colorize(WarningColour) + notes[noteID].title.to_s.colorize(WarningColour).bold
      end
    elsif !notesto_reviewOrdered.empty?
      noteIDto_review = notesto_reviewOrdered.first
      notes[noteIDto_review].open_note
      # puts "       Press any key when finished reviewing '#{notes[noteIDto_review].title}' ..."
      print '  Reviewing ' + notes[noteIDto_review].title.to_s.bold + ' ... press any key when finished. '
      gets

      # update the @reviewed() date for the note just reviewed
      notes[noteIDto_review].update_last_review_date
      # move this from notesto_review to notesOtherActive
      notesto_review.delete(noteIDto_review)
      notesto_reviewOrdered.delete(noteIDto_review)
      notesOtherActive.push(noteIDto_review)
      notesOtherActiveOrdered.push(noteIDto_review)
      # Run Tools on this file
      begin
        success = system('ruby', TOOLS_SCRIPT_PATH, notes[noteIDto_review].filename)
      rescue StandardError
        puts '  Error trying to tools '.colorize(WarningColour) + notes[noteIDto_review].title.to_s.colorize(WarningColour).bold
      end
    else
      puts "       Way to go! You've no more notes to review :-)".colorize(CompletedColour)
    end

  when 's'
    # write out the unordered summary to summaryFilename, temporarily redirecting stdout
    # using 'w' mode which will truncate any existing file
    Dir.chdir(NP_SUMMARIES_DIR) # TODO: should check directory exists first
    sf = File.open(summaryFilename, 'w')
    old_stdout = $stdout
    $stdout = sf
    puts "# NotePlan Notes summary, #{timeNow}"
    notesAllOrdered.each(&:print_summary_to_file)

    puts
    puts "= #{notesto_review.count + notesOtherActive.count} active, #{notesArchived.count} archived notes."

    $stdout = old_stdout
    sf.close
    puts '    Written summary to ' + summaryFilename.to_s.bold

  when 'w'
    # list @waiting items in open notes
    puts "\n-------------------------------------- #Waiting Tasks -----------------------------------------"
    notesto_reviewOrdered.each do |n|
      notes[n].list_waiting_tasks
    end
    notesOtherActiveOrdered.each do |n|
      notes[n].list_waiting_tasks
    end

  else
    puts '   Invalid action! Please try again.'.colorize(WarningColour)
  end

  # now ask again
  print "\nCommands: re-read & show (a)ll, (e)dit note, s(h)ow stats, people (l)ist, (p)roject+goal lists,".colorize(InstructionColour)
  print "\n(q)uit, (r)eview next, (s)ave summary, (t) run tools, (v) review list, (w)aiting tasks  > ".colorize(InstructionColour)
  input = gets
  verb = input[0].downcase
end
