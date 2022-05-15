#!/usr/bin/env ruby
#----------------------------------------------------------------------------------
# NotePlan Review script
# by Jonathan Clark, v1.4.5, 15.5.2022
#----------------------------------------------------------------------------------
# The script shows a summary of the notes, grouped by status, with option to easily
# open up each one that needs reviewing in turn in NotePlan.
# When continuing the script, it automatically updates the last @reviewed(date).
#
# It also provides basic statistics on the number of open / waiting / closed tasks.
#
# It assumes first line of a NP project file is just a markdown-formatted title
# and second line contains metadata items:
# - any #hashtags, particularly #active and #archive
# - any @start(), @due(), @complete(), @reviewed() dates, of form YYYY-MM-DD,
#   but other forms can be parsed as well
# - a @review_interval() field, using terms like '2m', '1w'
#
# These are the note categories:
# - inactive
#   - cancelled (noted with the #cancelled or #someday tag)
#   - completed (noted with the @completed(date) or @finished(date) mention)
# - active  =  any note that isn't inactive **and has a @review interval**!
#
# From NotePlan v2.4 it also covers notes in sub-directories, but ignores notes
# in the special @Archive and @Trash sub-directories (or others beginning @).
#
# Can also show a list of projects, and run related npStats and npTools scripts
# from its related GitHub projects.
#
# Requires gems colorize, optparse etc. (> gem install fuzzy_match colorize)
#----------------------------------------------------------------------------------
# For more details, including issues, see GitHub project https://github.com/jgclark/NotePlan-review/
#----------------------------------------------------------------------------------
VERSION = '1.4.5'.freeze

require 'date'
require 'time'
require 'colorize'
require 'optparse' # more details at https://docs.ruby-lang.org/en/2.1.0/OptionParser.html
require "erb" # for url_encode
include ERB::Util

#----------------------------------------------------------------------------------
# Setting variables for users to tweak
#----------------------------------------------------------------------------------
DATE_FORMAT_SCREEN = '%d.%m.%y'.freeze # use shorter form of years when writing to screen
DATE_FORMAT_FILE = '%d.%m.%Y'.freeze # use full years for writing out to file
SORTING_DATE_FORMAT = '%y%m%d'.freeze
MENTIONS_TO_FIND = ['@admin', '@facilities', '@rp', '@email', '@announce', '@oluo', '@jp', '@martha', '@church', '@liz', '@lizf'].freeze
USERNAME = ENV['LOGNAME'] # pull username from environment
USER_DIR = ENV['HOME'] # pull home directory from environment
TOOLS_SCRIPT_PATH = "#{USER_DIR}/bin/npTools".freeze
STATS_SCRIPT_PATH = "#{USER_DIR}/bin/npStats".freeze
NP_SUMMARIES_DIR = "#{USER_DIR}/Dropbox/NPSummaries".freeze
TODAYS_DATE = Date.today # defaults to %Y-%m-%d format. Can't work out why this needs to be a 'constant' to work -- something about visibility, I suppose
SUMMARY_FILENAME = TODAYS_DATE.strftime('%Y%m%d') + '_notes_summary.csv'
FOLDERS_TO_IGNORE = ['Reviews', 'Summaries', 'TEST']

#----------------------------------------------------------------------------------
# Constants & other settings
#----------------------------------------------------------------------------------
timeNow = Time.now
MAX_WIDTH = 93 # Max screen width to use
DROPBOX_DIR = "#{USER_DIR}/Dropbox/Apps/NotePlan/Documents".freeze
ICLOUDDRIVE_DIR = "#{USER_DIR}/Library/Mobile Documents/iCloud~co~noteplan~NotePlan/Documents".freeze
CLOUDKIT_DIR = "#{USER_DIR}/Library/Containers/co.noteplan.NotePlan3/Data/Library/Application Support/co.noteplan.NotePlan3".freeze
np_base_dir = DROPBOX_DIR if Dir.exist?(DROPBOX_DIR) && Dir[File.join(DROPBOX_DIR, '**', '*')].count { |file| File.file?(file) } > 1
np_base_dir = ICLOUDDRIVE_DIR if Dir.exist?(ICLOUDDRIVE_DIR) && Dir[File.join(ICLOUDDRIVE_DIR, '**', '*')].count { |file| File.file?(file) } > 1
np_base_dir = CLOUDKIT_DIR if Dir.exist?(CLOUDKIT_DIR) && Dir[File.join(CLOUDKIT_DIR, '**', '*')].count { |file| File.file?(file) } > 1
NP_CALENDAR_DIR = "#{np_base_dir}/Calendar".freeze
NP_NOTE_DIR = "#{np_base_dir}/Notes".freeze
HEADER_LINE = "\n    Title                                  Open Wait Done Due        Completed  Next Review".freeze

#----------------------------------------------------------------------------------
# Regex Definitions. NB: These need to be enclosed in single quotes, not double quotes!
RE_DATES_FLEX_MATCH = '([0-9\.\-/]{6,10})' # matches dates of a number of forms
RE_REVIEW_INTERVALS = '[0-9]+[bBdDwWmMqQ]'
RE_REVIEW_WITH_INTERVALS_MATCH = '@review\((' + RE_REVIEW_INTERVALS + ')\)'
RE_COMPLETED_TASK_MARKER = '\s\[x\]\s'

#----------------------------------------------------------------------------------
# Colours, using the colorization gem
# to show some possible combinations, run  String.color_samples
# to show list of possible modes, run   puts String.modes  (e.g. underline, bold, blink)
# These are optimised for a dark background terminal
String.disable_colorization false
GoalColour = :light_green
ProjectColour = :yellow
NormalColour = :default
CancelledColour = :light_magenta
CompletedColour = :green
ReviewNeededColour = :default #:light_yellow
ReviewNotNeededColour = :light_black
WarningColour = :light_red
InstructionColour = :light_cyan

#----------------------------------------------------------------------------------
# Globals
notes = [] # to hold all our note objects

#-------------------------------------------------------------------------
# Class definitions
#-------------------------------------------------------------------------
# NPNote Class reflects a stored NP note, and gives following methods:
# - initialize
# - calc_offset_date
# - show_summary_line
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
  attr_reader :start_date
  attr_reader :due_date
  attr_reader :completed_date
  attr_reader :open
  attr_reader :waiting
  attr_reader :done
  attr_reader :filename

  def initialize(this_file, id)
    # initialise instance variables (that persist with the class instance)
    @filename = this_file
    @id = id
    @title = ''
    @is_active = false # assume note is not active
    @is_completed = false
    @is_cancelled = false
    @start_date = nil
    @completed_date = nil
    @review_interval = nil
    @last_review_date = nil
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
        # Make a title for this file from first line
        # (but take off any heading characters at the start and starting and ending whitespace)
        headerLine = f.readline
        @title = headerLine.gsub(/^#*\s*/, '').strip

        # Now read and process line 2 (rest of metadata)
        @metadata_line = f.readline
        # the following regex matches returns an array with one item, so make a string (by join), and then parse as a date
        @metadata_line.scan(/@start\(#{RE_DATES_FLEX_MATCH}\)/) { |m|  @start_date = Date.parse(m.join) }
        @metadata_line.scan(/(@end|@due)\(#{RE_DATES_FLEX_MATCH}\)/) { |m| @due_date = Date.parse(m.join) } # allow alternate form '@end(...)'
        @metadata_line.scan(/(@completed|@finished)\(#{RE_DATES_FLEX_MATCH}\)/) { |m| @completed_date = Date.parse(m.join) }
        @metadata_line.scan(/@reviewed\(#{RE_DATES_FLEX_MATCH}\)/) { |m| @last_review_date = Date.parse(m.join) }
        @metadata_line.scan(/#{RE_REVIEW_WITH_INTERVALS_MATCH}/) { |m| @review_interval = m.join.downcase }

        # make completed if @completed_date set
        @is_completed = true unless @completed_date.nil?
        # make cancelled if #cancelled or #someday flag set
        @is_cancelled = true if @metadata_line =~ /(#cancelled|#someday)/

        # OLDER LOGIC:
        # set note to non-active if #archive is set, or cancelled, completed.
        # @is_active = false if @metadata_line == /#archive/ || @is_completed || @is_cancelled
        # NEWER LOGIC:
        # set note to active if #active is set or a @review date found, and not complete/cancelled
        @is_active = true if (@metadata_line =~ /#active/ || !@review_interval.nil?) && !@is_cancelled && !@is_completed

        # if an active task, then work out reviews
        if @is_active
          # If an active task and review interval is set, calc next review date.
          # If no last review date set, assume we need to review today.
          unless @review_interval.nil?
            @next_review_date = !@last_review_date.nil? ? calc_offset_date(@last_review_date, @review_interval) : TODAYS_DATE
          end
          # make to_review if review date set and before today (and active)
          @to_review = true if @next_review_date && (@next_review_date <= TODAYS_DATE)
        end
        # puts "For #{@title}:  #{@is_active?'Active':''} #{@is_completed?'Completed':''} #{@is_cancelled?'Cancelled':''} #{@review_interval} #{@last_review_date} #{@next_review_date}"

        # Note if this is a #project or #goal
        @is_project = true if @metadata_line =~ /#project/
        @is_goal    = true if @metadata_line =~ /#goal/

        # Now read through rest of file, counting number of open, waiting, done tasks
        f.each_line do |line|
          if line =~ /#{RE_COMPLETED_TASK_MARKER}/ # a completed task
            @done += 1
          elsif line =~ /^\s*\*\s+/ && line !~ /\[-\]/ # a task, but (by implication) not completed or cancelled
            if line =~ /#waiting/
              @waiting += 1 # count this as waiting not open
            else
              @open += 1
            end
          end
        end
      rescue EOFError # this file has less than two lines, so treat as empty
        # TODO: Work on this as 1 line is valid (but not active)
        puts "  Note: note '#{this_file}' is empty, so setting to not active."
        @title = '<blank>' if @title.empty?
        @is_active = false

        # NOTE: Alternative approach to this blank-file problem:
        # Ideally turn the init into a self.fabricate function that first checks
        # that the file has enough details to go through init.
        # Then use return nil unless ...
        # def self.fabricate(a, b, c)
        #   aa = a if a.is_a? Integer
        #   bb = b if b.is_a? String
        #   cc = c if c.is_a? Integer || c.is_a? Float
        #   return nil unless aa && bb && cc
        #   new(aa, bb, cc)
        # end
      rescue StandardError => e
        puts "Exiting with ERROR: Hit #{e.exception.message} when initializing note file #{this_file}".colorize(WarningColour)
        exit
      end
    end
  end

  def show_summary_line
    # Pretty print a summary for this NP note to screen
    mark = '[ ]'
    title_trunc = !@title.empty? ? @title[0..37] : "[#{@filename[0..35]}]"
    title_colour = NormalColour
    title_colour = GoalColour if @is_goal
    title_colour = ProjectColour if @is_project
    due_date_fmtd = @due_date ? relative_date(@due_date) : ''
    completed_date_fmtd = @completed_date ? @completed_date.strftime(DATE_FORMAT_SCREEN) : ''
    # format next review to be relative (or blank if note is not active)
    next_review_date_fmtd = @next_review_date ? relative_date(@next_review_date) : ''
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
    if @due_date && @due_date < TODAYS_DATE
      print out_pt3.colorize(WarningColour)
    else
      print out_pt3
    end
    print out_pt4
    if @next_review_date && @next_review_date < TODAYS_DATE
      print out_pt5.colorize(ReviewNeededColour)
    else
      print out_pt5.colorize(ReviewNotNeededColour)
    end
    print "\n"
  end

  def open_note
    # Use x-callback scheme to open this note in NotePlan,
    # as defined at http://noteplan.co/faq/General/X-Callback-Url%20Scheme/
    #   noteplan://x-callback-url/openNote?noteTitle=...
    # Open a note identified by the title or date.
    # Parameters:
    # - noteDate optional to identify the calendar note in the format YYYYMMDD like '20180122'.
    # - noteTitle optional to identify the normal note by actual title.
    # - fileName optional to identify a note by filename instead of title or date.
    #     Searches first general notes, then calendar notes for the filename.
    #     If its an absolute path outside NotePlan, it will copy the note into the database (only Mac).
    # NB: need to URL encode the title to make sure & and emojis are handled OK.
    uriEncoded = "noteplan://x-callback-url/openNote?noteTitle=" + url_encode(@title)
    begin
      response = `open "#{uriEncoded}"`
    rescue StandardError
      puts "  Error trying to open note with #{uriEncoded}".colorize(WarningColour)
    end
  end

  def update_last_review_date
    # Set the note's last review date to today's date
    # Open the file for read-write
    begin
      f = File.open(@filename, 'r')
    rescue StandardError => e
      puts "ERROR: Hit #{e.exception.message} when updating last review date".colorize(WarningColour)
      puts "Please run command (a) again."
    else
      # no error raised, so carry on here
      lines = []
      n = 0
      f.each_line do |line|
        lines[n] = line
        n += 1
      end
      f.close

      # in the metadata line, cut out the existing mention of last_review_date(...)
      metadata = lines[1]
      metadata.gsub!(%r{@reviewed\([0-9\.\-/]+\)\s*}, '') # needs gsub! to replace multiple copies, and in place
      # and add new last_review_date(<today>)
      metadata = "#{metadata.chomp} @reviewed(#{TODAYS_DATE})"
      # then remove multiple consecutive spaces which seem to creep in, with just one
      metadata.gsub!(/\s{2,12}/, ' ')

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
        puts "ERROR: Hit #{e.exception.message} when initializing note file".colorize(WarningColour)
      else
        # if no error, then continue here ...
        # now update this date in the object, so the next display will be correct
        @next_review_date = if @last_review_date
                              calc_offset_date(TODAYS_DATE, @review_interval)
                            else
                              TODAYS_DATE
                            end
        puts "  Updated review date for '#{@filename}'."
      end
    end
  end

  def list_waiting_tasks
    # List any tasks that are marked as #waiting and aren't [x] or @done
    f = File.open(@filename, 'r')
    lines = []
    n = 0
    f.each_line do |line|
      if (line =~ /#waiting/) && !((line =~ /@done/) || (line =~ /#{RE_COMPLETED_TASK_MARKER}/) || (line =~ /\[-\]/))
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
    # List any lines that @-mention the parameter (unless tasks which are future, completed or cancelled)
    f = File.open(@filename, 'r')
    lines = []
    n = 0
    f.each_line do |line|
      scheduledDate = nil
      line.scan(/>(\d\d\d\d\-\d\d-\d\d)/) { |m| scheduledDate = Date.parse(m.join) }
      line_future = !scheduledDate.nil? && scheduledDate > TODAYS_DATE ? true : false
      if (line =~ /#{tag}/) && !((line =~ /@done/) || line_future || (line =~ /#{RE_COMPLETED_TASK_MARKER}/) || (line =~ /\[-\]/))
        lines[n] = line
        n = + 1
      end
    end
    f.close
    return unless n.positive?

    puts "  #{@title}"
    lines.each do |line|
      puts '  ' + line
    end
  end
end

#-------------------------------------------------------------------------
# Non-class functions
#-------------------------------------------------------------------------

def calc_offset_date(old_date, interval)
  # Calculate next review date, assuming:
  # - old_date is type
  # - interval is string of form nn[bdwmq]
  #   - where 'b' is weekday (i.e. Monday-Friday in English)
  # puts "    c_o_d: old #{old_date} interval #{interval} ..."
  days_to_add = 0
  unit = interval[-1] # i.e. get last characters
  num = interval.chop.to_i
  case unit
  when 'b' # week days
    # Method from Arjen at https://stackoverflow.com/questions/279296/adding-days-to-a-date-but-excluding-weekends
    # Avoids looping, and copes with negative intervals too
    current_day_of_week = old_date.strftime("%u").to_i  # = day of week with Monday = 0, .. Sunday = 6
    dayOfWeek = num.negative? ? (current_day_of_week - 12).modulo(7) : (current_day_of_week + 6).modulo(7)
    num -= 1 if dayOfWeek == 6
    num += 1 if dayOfWeek == -6
    days_to_add = num + (num + dayOfWeek).div(5) * 2
  when 'd'
    days_to_add = num
  when 'w'
    days_to_add = num * 7
  when 'm'
    days_to_add = num * 30 # on average. Better to use >> operator, but it only works for months
  when 'q'
    days_to_add = num * 91 # on average
  when 'y'
    days_to_add = num * 365 # on average
  else
    puts "    Error in calc_offset_date from #{old_date} by #{interval}".colorize(WarningColour)
  end
  # puts "    c_o_d: with #{old_date} interval #{interval} found #{days_to_add} days_to_add"
  return old_date + days_to_add
end

def relative_date(date)
  # Return rough relative string version of difference between date and today.
  # Don't return all the detail, but just the most significant unit (year, month, week, day)
  # If date is in the past then add 'ago'.
  # e.g. today, 3w ago, 2m, 4y ago.
  # Accepts date in normal Ruby Date type
  is_past = false
  diff = (date - TODAYS_DATE).to_i # need to cast to integer as otherwise it seems to be type rational
  if diff.negative?
    diff = diff.abs
    is_past = true
  end
  if diff == 1
    output = "#{diff} day"
  elsif diff < 9
    output = "#{diff} days"
  elsif diff < 12
    output = "#{(diff / 7.0).round} wk"
  elsif diff < 29
    output = "#{(diff / 7.0).round} wks"
  elsif diff < 550
    output = "#{(diff / 30.4).round} mon"
  else
    output = "#{(diff / 365.0).round} yrs"
  end
  if diff.zero?
    output = 'today'
  elsif is_past
    output += ' ago'
  else
    output = 'in ' + output
  end
  return output
end

def show_section_divider(title)
  # Print out a divider prefixed by section text, adapting to defined screen width
  puts title.bold + ' ' + '-' * (MAX_WIDTH - title.size - 1)
end

def show_simple_divider
  # Print out a very simple full-width divider
  puts '-' * MAX_WIDTH
end

def white_similarity(str1, str2)
  # Use Simon White's algorithm to calculate string similarity, that performs better
  # than standard libraries from fuzzy_match and amatch gems. For details see
  # https://stackoverflow.com/questions/653157/a-better-similarity-ranking-algorithm-for-variable-length-strings
  str1d = str1.downcase
  pairs1 = (0..str1d.length - 2).collect { |i| str1d[i, 2]}.reject { |pair| pair.include? ' ' }
  str2d = str2.downcase
  pairs2 = (0..str2d.length - 2).collect { |i| str2d[i, 2]}.reject { |pair| pair.include? ' ' }
  union = pairs1.size + pairs2.size
  intersection = 0
  pairs1.each do |p1|
    0.upto(pairs2.size - 1) do |i|
      next if p1 != pairs2[i]

      intersection += 1
      pairs2.slice!(i)
    end
  end
  (2.0 * intersection) / union # return implied
end

def white_match(needle, haystack_array)
  # Use the Simon White algorithm to compare the 'needle' with a set of strings in the 'haystack_array'
  # Returns the best match as the relevant array item
  puts 'ERROR: Trying to use white_match for an empty search term.'.colorize(WarningColour) if needle.empty?

  largest_result = best_match = 0
  haystack_array.each do |ai|
    r = white_similarity(needle, ai)
    if r > largest_result
      largest_result = r
      best_match = ai # the acual string
    end
  end
  best_match #  haystack_array[best_match] # return implied
end

#-------------------------------------------------------------------------
# Setup program options
#-------------------------------------------------------------------------
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
glob_folders_to_ignore = "@|" + FOLDERS_TO_IGNORE.join("|")
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
      #   puts "  Found matching folder #{path}"
      # end
      glob_to_use += '{' + paths.join(',').gsub('/', '') + '}/*.{md,txt}'
    else
      puts "Found no matching folders for #{glob_path_pattern}. Will match all filenames across folders instead."
      glob_to_use = '[!(' + glob_folders_to_ignore + ')]**/*' + ARGV[0] + '*.{md,txt}'
    end
  rescue StandardError => e
    puts "ERROR: #{e.exception.message} when reading in files matching pattern #{ARGV[0]}".colorize(WarningColour)
  end
else
  glob_to_use = '{[!(' + glob_folders_to_ignore + ')]**/*,*}.{txt,md}'
end
puts "Running npReview v#{VERSION} for files matching pattern(s) #{glob_to_use}."

#=======================================================================================
# Main loop
#=======================================================================================

# Now start interactive loop offering the various actions

quit = false
verb = 'a' # get going by reading and summarising all notes
input = ''
searchString = best_match = nil
titleList = [] # list of all note titles
notes_to_review = [] # list of ID of notes overdue for review
notes_to_review_ord = [] # ordered list of ID of notes overdue for review
notes_other_active = [] # list of ID of other active notes
notes_other_active_ord = [] # ordered list of ID of other active notes
notes_completed = [] # list of ID of archived notes
notes_cancelled = [] # list of ID of cancelled notes
notes_all_ordered = [] # list of IDs of all notes (used for summary writer)

until quit
  # get title name by approx string matching on the rest of the input string (i.e. 'eMatchstring') if present
  best_match = ''
  if input.length > 1
    searchString = input[1..(input.length - 2)]
    # From list of titles, try and match
    # (Deprecating this in favour of Simon White algorithm)
    # fm = FuzzyMatch.new(titleList)
    # best_match = fm.find(searchString)
    best_match = white_match(searchString, titleList)
    best_match = '' if best_match.is_a?(Integer)
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
      Dir.chdir(NP_NOTE_DIR)
      Dir.glob(glob_to_use).each do |this_file|
        notes[i] = NPNote.new(this_file, i)
        # next unless notes[i].is_active && !notes[i].is_cancelled

        # add to relevant lists (arrays) of categories of notes
        n = notes[i]
        notes_completed.push(n.id) if n.is_completed
        notes_cancelled.push(n.id) if n.is_cancelled
        if n.is_active
          if n.next_review_date && (n.next_review_date <= TODAYS_DATE)
            notes_to_review.push(n.id) # Save list of ID of notes overdue for review
          else
            notes_other_active.push(n.id) # Save list of other active notes
          end
        end
        i += 1
      end
    rescue StandardError => e
      puts "ERROR: Hit #{e.exception.message} when reading note file #{this_file}".colorize(WarningColour)
    end
    puts "-> #{i} notes"

    # (re)Create list of note titles
    titleList.clear
    i = 0
    notes.each do |n|
      titleList[i] = n.title
      i += 1
    end

    # Order notes by different fields
    # Info: https://stackoverflow.com/questions/882070/sorting-an-array-of-objects-in-ruby-by-object-attribute
    # https://stackoverflow.com/questions/4610843/how-to-sort-an-array-of-objects-by-an-attribute-of-the-objects
    # https://stackoverflow.com/questions/827649/what-is-the-ruby-spaceship-operator
    # notes_all_ordered = notes.sort_by(&:title) # simple comparison, as defaults to alphanum sort
    notes_all_ordered = notes.sort_by { |s| s.due_date ? s.due_date : TODAYS_DATE }

    # Following are more complicated, as the array is of _id_s, not actual NPNote objects
    # NB: nil entries will break any comparison.
    notes_to_review_ord = notes_to_review.sort_by { |s| notes[s].next_review_date ? notes[s].next_review_date : TODAYS_DATE }
    # # Here's an example of sorting by two fields:
    # notes_to_review_ord = notes_to_review.sort{ |a,b|
    #   if a.status == b.status
    #     a.created_time <=> b.created_time
    #   else
    #     status_order[a.status] <=> status_order[b.status]
    #   end
    # }
    # sort by next review date then title
    # notes_other_active_ord = notes_other_active.sort_by { |s| notes[s].next_review_date ? notes[s].next_review_date.strftime(SORTING_DATE_FORMAT) + notes[s].title : notes[s].title }
    notes_other_active_ord = notes_other_active.sort_by { |s| notes[s].title }

    # Now output the notes with ones needing review first,
    # then ones which are active, then the rest
    puts HEADER_LINE.bold
    if notes_completed.count.positive? || notes_cancelled.count.positive?
      show_section_divider('Not Active')
      notes_completed.each do |id|
        notes[id].show_summary_line
      end
      notes_cancelled.each do |id|
        notes[id].show_summary_line
      end
    end
    show_section_divider('Active and Reviewed')
    notes_other_active_ord.each do |n|
      notes[n].show_summary_line
    end
    show_section_divider('Ready to review')
    notes_to_review_ord.each do |n|
      notes[n].show_summary_line
    end
    show_simple_divider
    puts "     #{notes_to_review.count} notes to review, #{notes_other_active.count} active, #{notes_completed.count} completed, and #{notes_cancelled.count} cancelled"

  when 'e'
    # edit the note
    # use approx-string-matched title name (i.e. 'eMatchstring')
    if !best_match.empty?
      puts "   Opening closest match note '#{best_match}'"
      noteID = titleList.find_index(best_match)
      notes[noteID].open_note
    else
      puts "   Warning: Couldn't find a note matching '#{searchString}'".colorize(WarningColour)
    end

  when 'h'
    # go and run the statistics script, npStats
    begin
      success = system('ruby', STATS_SCRIPT_PATH, '-n')
    rescue StandardError
      puts '  Error trying to run npStats script: please check it has been configured in STATS_SCRIPT_PATH'.colorize(WarningColour)
    end

  when 'l'
    # Show @tags from those listed in atTags
    puts "\n----- Tags Mentioned ------------------------------------------------------------------"
    MENTIONS_TO_FIND.each do |p|
      puts
      puts "#{p} mentions:".bold.colorize(ProjectColour)

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
      n.show_summary_line  if n.is_project
    end
    puts '--- Goals -----------------------------------------------------------------------------------'
    notes_all_ordered.each do |n|
      n.show_summary_line  if n.is_goal
    end
    show_simple_divider
    puts "     #{notes_to_review.count} notes to review, #{notes_other_active.count} active, #{notes_completed.count} completed, and #{notes_cancelled.count} cancelled"

  when 'q'
    # quit the utility
    quit = true
    break

  when 'r'
    if !best_match.empty?
      # If extra characters given, then open the next title that best matches the characters
      noteID = titleList.find_index(best_match)
      print 'Reviewing closest match note ' + best_match.to_s.bold + '...when finished press any key > '
      notes[noteID].open_note
      gets

      # update the @reviewed() date for the note just reviewed
      notes[noteID].update_last_review_date
      # Attempt to remove this from notes_to_reivew_ord
      notes_to_review.delete(noteID)
      notes_to_review_ord.delete(noteID)
      notes_other_active.push(noteID)
      notes_other_active_ord.push(noteID)
      # Run npTools on this file
      begin
        success = system('ruby', TOOLS_SCRIPT_PATH, '-q', notes[noteID].filename)
      rescue StandardError
        puts '  Error trying to run tools '.colorize(WarningColour) + notes[noteID].title.to_s.colorize(WarningColour).bold
      end
    elsif !notes_to_review_ord.empty?
      # If no extra characters given, then open the next note that needs reviewing
      loop do
        noteID = notes_to_review_ord.first
        notes[noteID].open_note
        print 'Reviewing next note ' + notes[noteID].title.to_s.bold + "...when finished press any key (or press 'r' to review next one) > "
        input = gets
        input1 = input[0].downcase

        # update the @reviewed() date for the note just reviewed
        notes[noteID].update_last_review_date
        # move this from notes_to_review to notes_other_active
        notes_to_review.delete(noteID)
        notes_to_review_ord.delete(noteID)
        notes_other_active.push(noteID)
        notes_other_active_ord.push(noteID)
        # Run npTools on this file
        begin
          success = system('ruby', TOOLS_SCRIPT_PATH, '-q', notes[noteID].filename) # run quietly (-q flag)
        rescue StandardError
          puts '  Error trying to run tools: '.colorize(WarningColour) + notes[noteID].title.to_s.colorize(WarningColour).bold
        end
        # repeat this if user types 'r' as the any key
        break if input1 != 'r'
      end
    else
      puts "       Way to go! You've no more notes to review :-)".colorize(CompletedColour)
    end

  when 's'
    # write out a summary of all notes to SUMMARY_FILENAME, ordered by name
    notes_all_ordered_alpha = notes.sort_by(&:title) # simple comparison, as defaults to alphanum sort
    # using 'w' mode which will truncate any existing file
    begin
      Dir.chdir(NP_SUMMARIES_DIR)
      sf = File.open(SUMMARY_FILENAME, 'w')
      sf.puts "# NotePlan Notes summary, #{timeNow}"
      sf.puts 'Title, Open tasks, Waiting tasks, Done tasks, Start date, Due date, Completed date, Review interval, Next review date'
      notes_all_ordered_alpha.each do |n|
        # print summary of this note in one line as a CSV file line
        mark = '[x]'
        mark = '[ ]' if n.is_active
        mark = '[-]' if n.is_cancelled
        start_date_fmtd = n.start_date ? n.start_date.strftime(DATE_FORMAT_FILE) : ''
        due_date_fmtd = n.due_date ? n.due_date.strftime(DATE_FORMAT_FILE) : ''
        completed_date_fmtd = n.completed_date ? n.completed_date.strftime(DATE_FORMAT_FILE) : ''
        next_review_date_fmtd = n.next_review_date ? n.next_review_date.strftime(DATE_FORMAT_FILE) : ''
        # NB: quoting title and filename to hide any commas they contain
        out = format('"%s %s","%s",%d,%d,%d,%s,%s,%s,%s,%s', mark, n.title, n.filename, n.open, n.waiting, n.done, start_date_fmtd, due_date_fmtd, completed_date_fmtd, n.review_interval, next_review_date_fmtd)
        sf.puts out
      end
      sf.puts
      sf.puts "= #{notes_to_review.count} to review, #{notes_other_active.count} also active, and #{notes_completed.count} completed notes."
      sf.close
      puts '    Written summary to ' + SUMMARY_FILENAME.to_s.bold
      Dir.chdir(NP_NOTE_DIR)
    rescue StandardError => e
      puts "ERROR: Hit #{e.exception.message} when trying to write out summary file #{SUMMARY_FILENAME}".colorize(WarningColour)
    end

  when 't'
    # go and run the tools script, npTools, which defaults to all files changed in last 24 hours
    begin
      success = system('ruby', TOOLS_SCRIPT_PATH) # and don't run quietly (omit -q flag)
    rescue StandardError
      puts '  Error trying to run npTools script -- please check it has been configured in TOOLS_SCRIPT_PATH'.colorize(WarningColour)
    end

  when 'v'
    # Show all notes to review
    puts HEADER_LINE.bold
    puts 'Ready to review'.bold + ' -----------------------------------------------------------------------------'
    notes_to_review_ord.each do |n|
      notes[n].show_summary_line
    end
    # show summary count
    show_simple_divider
    puts "     #{notes_to_review.count} notes to review"

  when 'w'
    # list @waiting items in open notes
    puts "\n-------------------------------------- #Waiting Tasks ---------------------------------------"
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
  print "\n(q)uit, (r)eview next, (s)ave summary, run (t)ools, re(v)iew list, (w)aiting tasks > ".colorize(InstructionColour)
  ARGV.clear # required for 'gets' in the next line not to barf if an ARGV was supplied
  loop do
    input = gets.chomp # get input from command line, and take off LF
    break unless input.empty?
  end
  verb = input[0].downcase
end
