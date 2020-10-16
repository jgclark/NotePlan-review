#!/usr/bin/ruby
#----------------------------------------------------------------------------------
# NotePlan Review script
# by Jonathan Clark, v1.2.15, 16.10.2020
#----------------------------------------------------------------------------------
# The script shows a summary of the notes, grouped by status, with option to easily
# open up each one that needs reviewing in turn in NotePlan. When continuing the
# script, it automatically updates the last @reviewed(date).
# It also provides basic statistics on the number of open / waiting / closed tasks.
#
# Assumes first line of a NP project file is just a markdown-formatted title
# and second line contains metadata items:
# - any #hashtags, particularly #Pnn and #active
# - any @start(), @due(), @complete(), @reviewed() dates, of form YYYY-MM-DD,
#   but other forms can be parsed as well
# - a @review_interval() field, using terms like '2m', '1w'
#
# These are the note categories:
# - inactive
#   - cancelled (noted with the #cancelled or #someday tag)
#   - completed (noted with the @completed(date) or @finished(date) mention)
# - active  =  any note that isn't inactive!
#
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
VERSION = '1.2.15'.freeze
# TODO: rationalise summary lines to fit better with npStats. So, 84 'active' tasks.
# TODO: this reports Goals: 86open + 5f + 2w / Stats->81 +2w +5f
#                 Projects: 104 + 6w / 76 + 20f + 7w

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
MENTIONS_TO_FIND = ['@admin', '@facilities', '@cws', '@cfl', '@email', '@secretary', '@jp', '@martha', '@church', '@liz'].freeze
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
ProjectColour = :yellow

# other constants
HEADER_LINE = "\n    Title                                  Open Wait Done Due        Completed  Next Review".freeze

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
  attr_reader :is_completed
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
    @is_completed = false
    @is_cancelled = false
    @startDate = nil
    @completed_date = nil
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
        @metadata_line.scan(%r{(@completed|@finished)\(([0-9\-\./]{6,10})\)}) { |m| @completed_date = Date.parse(m.join) }
        @metadata_line.scan(%r{@reviewed\(([0-9\-\./]{6,10})\)}) { |m| @lastReviewDate = Date.parse(m.join) }
        @metadata_line.scan(/@review\(([0-9]+[dDwWmMqQ])\)/) { |m| @review_interval = m.join.downcase }

        # make completed if @completed_date set
        @is_completed = true unless @completed_date.nil?
        # make cancelled if #cancelled or #someday flag set
        @is_cancelled = true if @metadata_line =~ /(#cancelled|#someday)/
        # set note to non-active if #archive is set, or cancelled, completed.
        @is_active = false if (@metadata_line == /#archive/ || @is_completed || @is_cancelled)
        # puts "For #{@title} #{@is_active?'Active':''} #{@is_completed?'Completed':''} #{@is_cancelled?'Cancelled':''}"

        # if an active task, then work out reviews
        if @is_active
          # make to_review if review date set and before today (and active)
          @to_review = true if @next_review_date && (nrd <= TodaysDate)
          # If an active task and review interval is set, calc next review date.
          # If no last review date set, assume we need to review today.
          if @review_interval
            @next_review_date = !@lastReviewDate.nil? ? calc_next_review(@lastReviewDate, @review_interval) : TodaysDate
          end
        end

        # Note if this is a #project or #goal
        @is_project = true if @metadata_line =~ /#project/
        @is_goal    = true if @metadata_line =~ /#goal/

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
        # @@@ actually need to reject the file and this object entirely. Not sure how as this is in the constructor!
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
    title_trunc = @title[0..37]
    title_colour = NormalColour
    title_colour = GoalColour if @is_goal
    title_colour = ProjectColour if @is_project
    due_date_fmtd = @due_date ? relative_date(@due_date) : ''
    completed_date_fmtd = @completed_date ? @completed_date.strftime(DATE_FORMAT) : ''
    # format next review to be relative (or blank if note is complete)
    next_review_date_fmtd = @next_review_date && !@is_completed ? relative_date(@next_review_date) : ''
    if @is_completed
      mark = '[x]'
      title_colour = CompletedColour
      due_date_fmtd = '-'
      next_review_date_fmtd = '-'
    end
    if @is_cancelled
      mark = '[-]'
      title_colour = CancelledColour
      due_date_fmtd = '-'
      next_review_date_fmtd = '-'
    end
    out_pt1 = format('%s %-38s', mark, title_trunc)
    out_pt2 = format(' %4d %4d %4d', @open, @waiting, @done)
    out_pt3 = format(' %-10s', due_date_fmtd)
    out_pt4 = format(' %-10s', completed_date_fmtd)
    out_pt5 = format(' %-10s', next_review_date_fmtd)
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
    due_date_fmtd = @due_date ? @due_date.strftime(DATE_FORMAT) : ''
    completed_date_fmtd = @completed_date ? @completed_date.strftime(DATE_FORMAT) : ''
    next_review_date_fmtd = @next_review_date ? @next_review_date.strftime(DATE_FORMAT) : ''
    out = format('%s %s,%d,%d,%d,%s,%s,%s,%s', mark, @title, @open, @waiting, @done, due_date_fmtd, completed_date_fmtd, @review_interval, next_review_date_fmtd)
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

    # now update this date in the object, so the next display will be correct
    @next_review_date = if @lastReviewDate
                          calc_next_review(TodaysDate, @review_interval)
                        else
                          TodaysDate
                        end
    puts "  Updated review date for '#{@filename}'."
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
  if diff.negative?
    diff = diff.abs
    is_past = true
  end
  if diff.zero?
    out = 'today'
  elsif diff == 1
    out = "#{diff} day"
  elsif diff < 9
    out = "#{diff} days"
  elsif diff < 12
    out = "#{(diff / 7.0).round} wk"
  elsif diff < 29
    out = "#{(diff / 7.0).round} wks"
  elsif diff < 550
    out = "#{(diff / 30.4).round} mon"
  else
    out = "#{(diff / 365.0).round} yrs"
  end
  out += ' ago' if is_past
  # return out # this is implied
end

#-------------------------------------------------------------------------
# Setup program options
#-------------------------------------------------------------------------
options = {}
opt_parser = OptionParser.new do |opts|
  opts.banner = "NotePlan Reviewer v#{VERSION}\nDetails at https://github.com/jgclark/NotePlan-review/\nUsage: npReview.rb [options] [file-pattern]"
  opts.separator ''
  opts.on('-h', '--help', 'Show this help') do
    puts opts
    exit
  end
end
opt_parser.parse! # parse out options, leaving file patterns to process

# Define the set of files that we're going to review.
Dir.chdir(NP_NOTE_DIR)
if ARGV.count.positive?
  # We have a file pattern given, so restrict file globbing to use it
  glob_to_use = '' # holds the glob_pattern to use
  begin
    # First see if this pattern matches a directory name
    glob_path_pattern = '*' + ARGV[0] + '*/'
    paths = Dir.glob(glob_path_pattern)
    if paths.count.positive?
      # paths.each do |path|
      #   # puts " Found matching folder #{path}"
      # end
      glob_to_use += '{' + paths.join(',').gsub('/', '') + '}/*.{md,txt}'
    else
      # puts " Found no matching folders for #{glob_path pattern}. Will match all filenames across folders instead."
      glob_to_use = '[!@]**/*' + ARGV[0] + '*.{md,txt}'
    end
  rescue StandardError => e
    puts "ERROR: #{e.exception.message} when reading in files matching pattern #{ARGV[0]}".colorize(WarningColour)
  end
else
  glob_to_use = '{[!@]**/*,*}.{txt,md}'
end
puts "Starting npReview for files matching pattern(s) #{glob_to_use}."

#=======================================================================================
# Main loop
#=======================================================================================

# Now start interactive loop offering a couple of actions:
# save summary file, open note in NP
quit = false
verb = 'a' # get going by reading and summarising all notes
input = ''
searchString = best_match = nil
titleList = []
notes_to_review = [] # list of ID of notes overdue for review
notes_to_review_ord = []
notes_other_active = [] # list of ID of other active notes
notes_other_active_ord = []
notes_completed = [] # list of ID of archived notes
notes_cancelled = [] # list of ID of cancelled notes
notes_all_ordered = [] # list of IDs of all notes (used for summary writer)

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
  when 'a'
    # (Re)parse the data files
    i = 0
    notes.clear # clear if not already empty
    notes_to_review.clear
    notes_to_review_ord.clear
    notes_other_active.clear
    notes_other_active_ord.clear
    notes_completed.clear
    notes_cancelled.clear
    notes_all_ordered.clear

    # Read metadata for all note files in the NotePlan directory
    # (and sub-directories from v2.5, ignoring special ones starting '@')
    begin
      Dir.glob(glob_to_use).each do |this_file|
        notes[i] = NPNote.new(this_file, i)
        # next unless notes[i].is_active && !notes[i].is_cancelled

        # add to relevant lists (arrays) of categories of notes
        # TODO: review the logic here. "Friends 2020" landed in Not Active and ActiveReviewed lists
        n = notes[i]
        notes_completed.push(n.id) if n.is_completed
        notes_cancelled.push(n.id) if n.is_cancelled
        if n.is_active
          if n.next_review_date && (n.next_review_date <= TodaysDate)
            notes_to_review.push(n.id) # Save list of ID of notes overdue for review
          else
            notes_other_active.push(n.id) # Save list of in-active notes
          end
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
    # notes_all_ordered = notes.sort_by(&:title) # simple comparison, as defaults to alphanum sort
    notes_all_ordered = notes.sort_by { |s| s.due_date ? s.due_date : TodaysDate }

    # Following are more complicated, as the array is of _id_s, not actual NPNote objects
    # NB: nil entries will break any comparison.
    notes_to_review_ord = notes_to_review.sort_by { |s| notes[s].next_review_date ? notes[s].next_review_date : TodaysDate }
    # # Here's an example of sorting by two fields:
    # notes_to_review_ord = notes_to_review.sort{ |a,b|
    #   if a.status == b.status
    #     a.created_time <=> b.created_time
    #   else
    #     status_order[a.status] <=> status_order[b.status]
    #   end
    # }
    notes_other_active_ord = notes_other_active.sort_by { |s| notes[s].next_review_date ? notes[s].next_review_date.strftime(SORTING_DATE_FORMAT) + notes[s].title : notes[s].title }

    # Now output the notes with ones needing review first,
    # then ones which are active, then the rest
    puts HEADER_LINE.bold
    if notes_completed.count.positive? || notes_cancelled.count.positive?
      puts 'Not Active'.bold + ' -------------------------------------------------------------------------------------'
      notes_completed.each do |id|
        notes[id].print_summary
      end
      notes_cancelled.each do |id|
        notes[id].print_summary
      end
    end
    puts 'Active and Reviewed'.bold + ' ----------------------------------------------------------------------------'
    notes_other_active_ord.each do |n|
      notes[n].print_summary
    end
    puts 'Ready to review'.bold + ' --------------------------------------------------------------------------------'
    notes_to_review_ord.each do |n|
      notes[n].print_summary
    end
    puts '------------------------------------------------------------------------------------------------'
    puts "     #{notes_to_review.count} notes to review, #{notes_other_active.count} active, #{notes_completed.count} completed, and #{notes_cancelled.count} cancelled"

  when 'v'
    # Show all notes to review
    puts HEADER_LINE.bold
    puts '--- Ready to review ----------------------------------------------------------------------------'
    notes_to_review_ord.each do |n|
      notes[n].print_summary
    end
    # show summary count
    puts '------------------------------------------------------------------------------------------------'
    puts "     #{notes_to_review.count} notes to review"

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
    puts "\n----- Tags Mentioned ------------------------------------------------------------------"
    MENTIONS_TO_FIND.each do |p|
      puts
      puts "#{p} mentions:".bold

      notes_to_review_ord.each do |n|
        notes[n].list_tag_mentions(p)
      end
      notes_other_active_ord.each do |n|
        notes[n].list_tag_mentions(p)
      end
    end

  when 'p'
    # Show project then goal summaries, ordered by due date
    puts HEADER_LINE.bold    
    puts '--- Projects --------------------------------------------------------------------------------'
    notes_all_ordered.each do |n|
      n.print_summary  if n.is_project
    end
    puts '--- Goals -----------------------------------------------------------------------------------'
    notes_all_ordered.each do |n|
      n.print_summary  if n.is_goal
    end

  when 'q'
    # quit the utility
    quit = true
    break

  when 'r'
    if best_match
      # If extra characters given, then open the next title that best matches the characters
      noteID = titleList.find_index(best_match)
      print 'Reviewing closest match note ' + best_match.to_s.bold + ' ...when finished press any key.'
      notes[noteID].open_note
      gets

      # update the @reviewed() date for the note just reviewed
      notes[noteID].update_last_review_date
      # Attempt to remove this from notes_to_reivew_ord
      notes_to_review.delete(noteID)
      notes_to_review_ord.delete(noteID)
      notes_other_active.push(noteID)
      notes_other_active_ord.push(noteID)
      # Run Tools on this file
      begin
        success = system('ruby', TOOLS_SCRIPT_PATH, notes[noteID].filename)
      rescue StandardError
        puts '  Error trying to run tools '.colorize(WarningColour) + notes[noteID].title.to_s.colorize(WarningColour).bold
      end
    elsif !notes_to_review_ord.empty?
      # If no extra characters given, then open the next note that needs reviewing
      loop do
        noteID = notes_to_review_ord.first
        notes[noteID].open_note
        print 'Reviewing ' + notes[noteID].title.to_s.bold + " ...when finished press any key (or press 'r' to review next one)."
        input = gets
        input1 = input[0].downcase

        # update the @reviewed() date for the note just reviewed
        notes[noteID].update_last_review_date
        # move this from notes_to_review to notes_other_active
        notes_to_review.delete(noteID)
        notes_to_review_ord.delete(noteID)
        notes_other_active.push(noteID)
        notes_other_active_ord.push(noteID)
        # Run Tools on this file
        begin
          success = system('ruby', TOOLS_SCRIPT_PATH, notes[noteID].filename)
        rescue StandardError
          puts '  Error trying to tools '.colorize(WarningColour) + notes[noteID].title.to_s.colorize(WarningColour).bold
        end
        # repeat this if user types 'r' as the any key
        break if input1 != 'r' 
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
    notes_all_ordered.each(&:print_summary_to_file)

    puts
    puts "= #{notes_to_review.count} to review, #{notes_other_active.count} also active, and #{notes_completed.count} archived notes."

    $stdout = old_stdout
    sf.close
    puts '    Written summary to ' + summaryFilename.to_s.bold

  when 't'
    # go and run the tools script, npTools, which defaults to all files changed in last 24 hours
    begin
      success = system('ruby', TOOLS_SCRIPT_PATH)
    rescue StandardError
      puts '  Error trying to run npTools script -- please check it has been configured in TOOLS_SCRIPT_PATH'.colorize(WarningColour)
    end

  when 'w'
    # list @waiting items in open notes
    puts "\n------------------------------------ #Waiting Tasks ---------------------------------------"
    notes_to_review_ord.each do |n|
      notes[n].list_waiting_tasks
    end
    notes_other_active_ord.each do |n|
      notes[n].list_waiting_tasks
    end

  else
    puts '   Invalid action! Please try again.'.colorize(WarningColour)
  end

  # now ask what to do
  print "\nCommands: re-read & show (a)ll, (e)dit note, s(h)ow stats, people (l)ist, (p)roject+goal lists,".colorize(InstructionColour)
  print "\n(q)uit, (r)eview next, (s)ave summary, run (t)ools, (v) review list, (w)aiting tasks > ".colorize(InstructionColour)
  ARGV.clear # required for 'gets' in the next line not to barf if an ARGV was supplied
  input = gets
  verb = input[0].downcase
end
