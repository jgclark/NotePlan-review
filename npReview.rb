#!/usr/bin/ruby
#----------------------------------------------------------------------------------
# NotePlan project review
# (c) JGC, v0.9.8, 29.1.2020
# (Trying Ruby code for the first time, and going OO too!)
#----------------------------------------------------------------------------------
# Assumes first line of a NP project file is just a markdown-formatted title
# and second line contains metadata items:
# - any #hashtags, particularly #Pnn and #active
# - any @start(), @due(), @complete(), @reviewed() dates, of form YYYY-MM-DD,
#   but other forms can be parsed as well
# - a @reviewInterval() field, using terms like '2m', '1w'
# 
# Shows a summary of the notes, grouped by active and then closed.
# The active ones also have a list of the number of open / waiting / closed tasks
#
# Can also show a list of projects.
#
# Requires 'gem install fuzzy_match' 
#----------------------------------------------------------------------------------
# TODOs
# * [ ] Fail gracefully when no npClean script available
# * [ ] Try changing @start(date), @due(date) etc. to @start/date etc.
# * [ ] order 'other active' by due date [done] then title
# * [ ] in file read operations in initialize, cope with EOF errors
# * [ ] Make cancelled part of archive not active
# * [x] see if colouration is possible (https://github.com/fazibear/colorize)
# * [x] in 'e' cope with no fuzzy match error
# * [x] Fix next (r)eview item opening wrong note
# * [x] Save summary makes all [x]
# * [x] log stats to a file
# * [x] create some stats from all open things
# * [x] Fix next (r)eview item not coming in same order as listed
# * [x] after pressing 'a' the list of Archived ones is wrong
# * [x] run npClean after a review
# * [x] separate parts to a different script daily crawl to fix various things
#----------------------------------------------------------------------------------

require 'date'
require 'time'
require 'open-uri'
require 'etc' 		# for login lookup
require 'fuzzy_match'  # gem install fuzzy_match
require 'colorize'	# for coloured output using https://github.com/fazibear/colorize

# Constants 
DateFormat = "%d.%m.%y"
DateTimeFormat = "%e %b %Y %H:%M"
timeNow = Time.now
timeNowFmt = timeNow.strftime(DateTimeFormat)
TodaysDate = Date.today	# can't work out why this needs to be a 'constant' to work -- something about visibility, I suppose
EarlyDate = Date.new(1970,1,1)
summaryFilename = Date.today.strftime("%Y%m%d") + " Notes summary.md"

# Setting variables to tweak
Username = 'jonathan' # set manually, as automated methods don't seek to work.
StorageType = "iCloud"	# or Dropbox
TagsToFind = ["@admin", "@facilities", "@CWs", "@cfl", "@yfl", "@secretary", "@JP", "@martha", "@church"]
NPCleanScriptPath = "/Users/jonathan/Dropbox/m/npClean.rb"

# Colours
#String.color_samples	# to show some possible combinations
#puts String.modes		# returns list of colorization modes
CancelledColour = :magenta
CompletedColour = :light_green
ReviewNeededColour = :light_red
PGEffect = :underline
ActiveColour = :light_yellow
WarningColour = :red
String.disable_colorization false

User = Etc.getlogin		# for debugging when running by launchctl
if ( StorageType == "iCloud" )
	NoteplanDir = "/Users/#{Username}/Library/Mobile Documents/iCloud~co~noteplan~NotePlan/Documents" # for iCloud storage
else
	NoteplanDir = "/Users/#{Username}/Dropbox/Apps/NotePlan/Documents" # for Dropbox storage
end

# other globals
notes = Array.new	# to hold all our note objects

#-------------------------------------------------------------------------
# Class definitions
#-------------------------------------------------------------------------
# NPNote Class reflects a stored NP note, and gives following methods:
# - initialize
# - calc_next_review
# - print_summary
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
	attr_reader :dueDate
	attr_reader :metadataLine
	attr_reader :isProject
	attr_reader :isGoal
	attr_reader :toReview
	attr_reader :open
	attr_reader :waiting
	attr_reader :done
	
	
	def initialize(this_file, id)
		# initialise instance variables (that persist with the class instance)
		@filename = this_file
		@id = id
		@title = nil
		@isActive = true	# assume note is active
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
		otherLines = []

		# puts "  Initializing NPNote for #{this_file}"
		# Open file and read the first two lines
		File.open(this_file) do |f|
			headerLine = f.readline
			@metadataLine = f.readline

			# Now make a title for this file from first line
			# (but take off any heading characters at the start and starting and ending whitespace)
			@title = headerLine.gsub!(/^#*\s*/, "")
			@title = @title.gsub(/\s+$/,"")

			# Now process line 2 (rest of metadata)
			# the following regex matches returns an array with one item, so make a string (by join), and then parse as a date
			@metadataLine.scan(/@start\(([0-9\-\.\/]{6,10})\)/)	{ |m|  @startDate = Date.parse( m.join() ) }
			@metadataLine.scan(/(@end|@due)\(([0-9\-\.\/]{6,10})\)/)	{ |m|  @dueDate = Date.parse( m.join() ) }  # allow alternate form '@end(...)'
			@metadataLine.scan(/(@complete|@completed|@finish)\(([0-9\-\.\/]{6,10})\)/)	{ |m|  @completeDate = Date.parse( m.join() ) }
			@metadataLine.scan(/@reviewed\(([0-9\-\.\/]{6,10})\)/)	{ |m|  @lastReviewDate = Date.parse( m.join() ) }
			@metadataLine.scan(/@review\(([0-9]+[dDwWmMqQ])\)/)	{ |m| @reviewInterval = m.join().downcase }

			# make active if #active flag set
			@isActive = true    if (@metadataLine =~ /#active/) 
			# but override if #archive set, or complete date set
			@isActive = false   if ((@metadataLine =~ /#archive/) or (@completeDate))
			# make cancelled if #cancelled or #someday flag set
			@isCancelled = true if ((@metadataLine =~ /#cancelled/) or (@metadataLine =~ /#someday/))
			# make toReview if review date set and before today
			@toReview = true	if ((@nextReviewDate) and (nrd <= TodaysDate))
			
			# If an active task and review interval is set, calc next review date.
			# If no last review date set, assume we need to review today.
			if (@reviewInterval and @isActive) then
				if @lastReviewDate then
					@nextReviewDate = calc_next_review(@lastReviewDate, @reviewInterval)
				else
					@nextReviewDate = TodaysDate
				end
			end

			# Note if this is a #project or #goal
			@isProject = true if (@metadataLine =~ /#project/)
			@isGoal    = true if (@metadataLine =~ /#goal/)
			# look for project ect codes (there might be several, so join with spaces), and make uppercase
			# @@@ something wrong with regex but I can't see what, so removing the logic
			# @metadataLine.scan(/[PpFfSsWwBb][0-9]+/)	{ |m| @codes = m.join(' ').downcase }
			# If no codes given, but this is a goal or project, then use a basic code
			if (@codes == nil)
				@codes = 'P' if (@isProject)
				@codes = 'G' if (@isGoal)
			end

			# Now read through rest of file, counting number of open, waiting, done tasks
			f.each_line { |line|
				if ( line =~ /\[x\]/ ) # a completed task 
					@done += 1
				elsif ( line =~ /^\s*\*\s+/ )  # a task, but (by implication) not completed
					if( line =~ /#waiting/ )
						@waiting += 1 # count this as waiting not open
					else
						@open += 1
					end
				end
			}
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
			daysToAdd = num*7
		when 'm'
			daysToAdd = num*30
		when 'q'
			daysToAdd = num*90
		else
			puts "Error in calc_next_review from #{last} by #{interval}"
		end
		newDate = last + daysToAdd
		return newDate
	end

	def print_summary
		# print summary of this note in one line
		endDateFormatted = completeDateFormatted = nextReviewDateFormatted = ""
		# Pretty print a summary for this NP note
		mark="[x] "
		colour = CompletedColour 
		effect = nil
		if (@isActive)
			mark="[ ] "
			colour = ActiveColour
		end
		if (@isCancelled)
			mark = "[-] "
			colour = CancelledColour
		end
		if (@toReview)
			colour = ReviewNeededColour
		end
		titleTrunc = @title[0..37]
		endDateFormatted = @dueDate ? @dueDate.strftime(DateFormat) : ""
		completeDateFormatted = @completeDate ? @completeDate.strftime(DateFormat) : ""
		nextReviewDateFormatted = @nextReviewDate ? @nextReviewDate.strftime(DateFormat) : ""
		out = sprintf("%s %-38s %5s %3d %3d %3d  %8s %9s %-3s %10s", mark, titleTrunc, @codes, @open, @waiting, @done, endDateFormatted, completeDateFormatted, @reviewInterval, nextReviewDateFormatted)
		if (@isProject or @isGoal)	# make P/G italic
			puts out.colorize(colour).italic
		else
			puts out.colorize(colour)
		end
	end
	
	def open_note
		# Use x-callback scheme to open this note in NotePlan
		# noteplan://x-callback-url/openNote?noteTitle=...
		# Open a note identified by the title or date.
		# Parameters:
		# noteDate optional to identify the calendar note in the format YYYYMMDD like '20180122'.
		# noteTitle optional to identify the normal note by actual title.
		# fileName optional to identify a note by filename instead of title or date. 
		#   Searches first general notes, then calendar notes for the filename.
		#   If its an absolute path outside NotePlan, it will copy the note into the database (only Mac).
		uri = "noteplan://x-callback-url/openNote?noteTitle=#{@title}"
		response = %x[open "#{uri}"]
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
		f = File.open(@filename, "r")
		lines = Array.new
		n = 0
		f.each_line { |line|
			  lines[n] = line
			  n += 1
		}
		f.close
		lineCount = n

		# in the metadata line, cut out the existing mention of lastReviewDate(...) 			
		metadata = lines[1]
		metadata.gsub!(/@reviewed\([0-9\.\-\/]+\)\s*/, "")	# needs gsub! to replace multiple copies, and in place
		# and add new lastReviewDate(<today>)
		metadata = "#{metadata.chomp}@reviewed(#{TodaysDate})" # feels like there ought to be a space between the items, but in practice not.

		# in the rest of the lines, do some clean up:
		n = 2
		while (n < lineCount)
			# remove any #waiting tags on complete tasks
			if ( ( lines[n] =~ /#waiting/ ) && ( lines[n] =~ /\[x\]/ ) )
				lines[n].gsub!(/ #waiting/, "")
			end
			# blank any lines which just have a * or -
			if ( lines[n] =~ /^\s*[\*\-]\s*$/ )
				lines[n] = ""
			end
			n += 1
		end

		# open file and write all this data out
 		File.open(@filename, 'w') { |f|
			n = 0
			lines.each do |line| 
				if (n != 1) 
					f.puts line	
				else 
					f.puts metadata
				end
				n += 1
			end
		}

		puts "       ... Updated \"#{@title}\" note."
	end

	def list_waiting_tasks
		# List any tasks that are marked as #waiting and aren't [x] or @done
		f = File.open(@filename, "r")
		lines = Array.new
		n = 0
		f.each_line { |line|
				if ( (line =~ /#waiting/) and not ( (line =~ /@done/) or (line =~ /\[x\]/) or (line =~ /\[-\]/) ) )
					lines[n] = line
					n =+ 1
			  end
		}
		f.close
		if ( n>0 )
			puts '# ' + @title
			lines.each do |line| 
				puts "  " + line.gsub(/#waiting/, "")
			end
		end
	end

	def list_person_mentioned(tag)
		# List any lines that @-mention the parameter
		f = File.open(@filename, "r")
		lines = Array.new
		n = 0
		f.each_line { |line|
			if ( (line =~ /#{tag}/) and not ( (line =~ /@done/) or (line =~ /\[x\]/) or (line =~ /\[-\]/) ) )
				lines[n] = line
				n =+ 1
		  end
		}
		f.close
		if ( n>0 )
			puts "  # #{@title}"
			lines.each do |line| 
				puts "    " + line
			end
		end
	end
	
	# def inspect
	# 	puts "#{@id}: nrd = #{@nextReviewDate}"
	# end

end


#=======================================================================================
# Main loop
#=======================================================================================
# Now start interactive loop offering a couple of actions:
# save summary file, open note in NP
#---------------------------------------------------------------------------
quit = false
verb = "v"	# get going with this first list reviews action automatically
reviewNumber = 0
input = searchString = ''
titleList = Array.new
notesToReview = Array.new
notesToReviewOrdered = Array.new
notesActive = Array.new 
notesActiveOrdered = Array.new
notesArchived = Array.new
notesAllOrdered = Array.new

while !quit
	case verb
	when 'p'
		# Show project summary
		puts "\n--------------------------------------- Projects List ------------------------------------------"
		notes.each do |n|
			n.print_summary	if (n.isProject)
		end
		puts "\n---------------------------------------- Goals List -------------------------------------------"
		notes.each do |n|
			n.print_summary	if (n.isGoal)
		end


	when 'a'
		# (Re)parse the data files
		Dir::chdir(NoteplanDir+'/Notes/')
		i = 0
		notes.clear()  # clear if not already empty
		notesToReview.clear()
		notesToReviewOrdered.clear()
		notesActive.clear() 
		notesActiveOrdered.clear()
		notesArchived.clear()
		notesAllOrdered.clear()

		# Read metadata for all note files in the NotePlan directory
		Dir.glob("*.txt").each do |this_file|
			notes[i] = NPNote.new(this_file,i)
			# nrd = notes[i].nextReviewDate 
			if (notes[i].isActive)
				if (notes[i].toReview) 
					notesToReview.push(notes[i].id) # Save list of notes overdue for review
				else
					notesActive.push(notes[i].id) # Save list of other active notes
				end
			else
				notesArchived.push(notes[i].id) # Save list of archived (completed or cancelled) notes
			end
			i += 1
		end

		# Reset list of reviewed notes, as re-parsed list
		reviewNumber = 0

		# Order notes by different fields
		# Info: https://stackoverflow.com/questions/882070/sorting-an-array-of-objects-in-ruby-by-object-attribute
		# https://stackoverflow.com/questions/4610843/how-to-sort-an-array-of-objects-by-an-attribute-of-the-objects
		# Can do multiples using [s.dueDate, s....]
		notesToReviewOrdered = notesToReview.sort_by { |s| notes[s].nextReviewDate }
		notesActiveOrdered = notesActive.sort_by { |s| notes[s].nextReviewDate ? notes[s].nextReviewDate : EarlyDate }	# to get around problem of nil entries breaking any comparison
		notesAllOrdered = notes.sort_by { |s| s.title }	# simpler, as defaults to alphanum sort

		# Now output the notes with ones needing review first,
		# then ones which are active, then the rest
		puts "     Title                                        Opn Wat Don Due       Completed Int  NxtReview"
		puts "------------------------------ Ready to review -------------------------------------------------"
		notesToReviewOrdered.each do |n| 
			notes[n].print_summary
		end
		puts "------------------------------- Other Active ---------------------------------------------------"
		notesActiveOrdered.each do |n| 
			notes[n].print_summary
		end
		puts "-------------------------------- Not Active ----------------------------------------------------"
		notesArchived.each do |n| 
			notes[n].print_summary
		end
		puts "---------------------------- ACTIVE NOTE TOTALS ------------------------------------------------"
		no = 0
		nw = 0
		nd = 0
		notesActive.each do |n|
			nd += notes[n].done
			nw += notes[n].waiting
			no += notes[n].open
		end
		puts "    #{notesActive.count} active notes with #{no} open, #{nw} waiting, #{nd} done tasks."
		puts "    + #{notesArchived.count} archived notes"


	when 'v'
		# Show all notes to review
		# First, (re)parse the data files
		Dir::chdir(NoteplanDir+'/Notes/')
		notes.clear()  # clear if not already empty
		notesToReview.clear()
		notesToReviewOrdered.clear()
		notesActive.clear()
		notesActiveOrdered.clear()
		notesArchived.clear()
		notesAllOrdered.clear()
		i = 0
		
		# Read metadata for all note files in the NotePlan directory
		Dir.glob("*.txt").each do |this_file|
			notes[i] = NPNote.new(this_file,i)
			nrd = notes[i].nextReviewDate 
			if (notes[i].isActive)
				if ((nrd) and (nrd <= TodaysDate)) 
					notesToReview.push(notes[i].id) # Save list of notes overdue for review
				else
					notesActive.push(notes[i].id) # Save list of other active notes
				end
			else
				notesArchived.push(notes[i].id) # Save list of in-active notes
			end
			i += 1
		end

		# Order notes by different fields
		# Info: https://stackoverflow.com/questions/882070/sorting-an-array-of-objects-in-ruby-by-object-attribute
		# https://stackoverflow.com/questions/4610843/how-to-sort-an-array-of-objects-by-an-attribute-of-the-objects
		# Can do multiples using [s.dueDate, s....]
		notesToReviewOrdered = notesToReview.sort_by { |s| notes[s].nextReviewDate }	
		notesActiveOrdered = notesActive.sort_by { |s| notes[s].nextReviewDate ? notes[s].nextReviewDate : EarlyDate }	# to get around problem of nil entries breaking any comparison
		notesAllOrdered = notes.sort_by { |s| s.title }	# note simpler, as defaults to alphanum sort

		# Now output the notes with ones needing review first,
		# then ones which are active, then the rest
		puts "     Title                                        Opn Wat Don Due       Completed Int  NxtReview"
		puts "------------------------- Ready to review ------------------------------------------------------"
		notesToReviewOrdered.each do |n| 
			notes[n].print_summary
		end
		# reset review count as we have re-parsed
		reviewNumber = 0

	
	when 'c'
		# go and run the clean up script, npClean
		success = system("ruby",NPCleanScriptPath)
	

	when 'e'
		# edit the note
		# use title name fuzzy matching on the rest of the input string (i.e. 'eMatchstring')
		searchString = input[1..(input.length-2)]
		# from list of titles, try and match
		i = 0
		notes.each do |n|
			titleList[i] = n.title
			i += 1
		end
		fm = FuzzyMatch.new(titleList)
		bestMatch = fm.find(searchString)
		if (bestMatch) then
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
			puts "#{p} mentions ---------------------------------"

			notesToReviewOrdered.each do |n| 
				notes[n].list_person_mentioned(p)
			end
			notesActiveOrdered.each do |n| 
				notes[n].list_person_mentioned(p)
			end
		end


	when 'q'
		# quit the utility
		quit = true
		break


	when 'r'
		# Open the next note that needs reviewing
		if ( reviewNumber < notesToReviewOrdered.length )
			noteIDToReview = notesToReviewOrdered[reviewNumber]
			notes[noteIDToReview].open_note

			puts "       Press any key when finished reviewing '#{notes[noteIDToReview].title}' ..."
			gets

			# Update the note just reviewed and update its @reviewed() date
			notes[noteIDToReview].update_last_review_date
			reviewNumber += 1
		else
			puts "       Sorry; no more notes to review."
		end
	

	when 's' 
		# write out the unordered summary to summaryFilename, temporarily redirecting stdout
		# using 'w' mode which will truncate any existing file
		Dir::chdir(NoteplanDir+'/Summaries/')
		sf = File.open(summaryFilename, 'w')
		old_stdout = $stdout
		$stdout = sf
		puts "# NotePlan Notes summary, #{timeNow.to_s}"
		notesAllOrdered.each do |n| 
			n.print_summary
		end

		puts "----------------------------------- NOTE TOTALS ------------------------------------------------"
		no = 0
		nw = 0
		nd = 0
		notesActive.each do |n| # @@@ WHY doesn't notesAllOrdered work here?
			nd += notes[n].done
			nw += notes[n].waiting
			no += notes[n].open
		end
		puts "    #{notesActive.count} active notes with #{no} open, #{nw} waiting, #{nd} done tasks."
		puts "    + #{notesArchived.count} archived notes"

		$stdout = old_stdout
		sf.close
		puts "    Written summary to #{summaryFilename}"


	when 'w'
		# list @waiting items in open notes
		puts "\n---------------------------- #Waiting Tasks ----------------------------------------------"
		notesToReviewOrdered.each do |n| 
			notes[n].list_waiting_tasks
		end
		notesActiveOrdered.each do |n| 
			notes[n].list_waiting_tasks
		end

	else
		puts "   ** Invalid action! Please try again."
	end

	# now ask again
	print "\nview (a)ll, (c)lean up, (e)dit note, people (l)ist, (p)roject list, (r)eview next, (s)ave summary,\n(v)iew those to review, (q)uit, list (w)aiting tasks  > "
	input = gets
	verb = input[0].downcase
end

# Run Clean up script
success = system("ruby",NPCleanScriptPath)
