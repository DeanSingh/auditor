#!/usr/bin/env ruby
# frozen_string_literal: true

require 'date'
require 'csv'

# Parse headers from "yours" document (§ format)
class YoursParser
  HEADER_PATTERN = /^§\s*(.+)$/

  def self.parse(file_path)
    sections = []
    File.readlines(file_path, encoding: 'UTF-8', invalid: :replace, undef: :replace).each_with_index do |line, index|
      next unless line.match?(HEADER_PATTERN)

      header_text = line.match(HEADER_PATTERN)[1].strip

      # Skip non-date headers (Category, Sub-category)
      next if header_text.start_with?('Category:', 'Sub-category:')

      date_str, title = extract_date_and_title(header_text)

      sections << {
        date_str: date_str,
        normalized_date: normalize_date(date_str),
        title: title,
        full_header: header_text,
        line_number: index + 1
      }
    end
    sections
  end

  private

  def self.extract_date_and_title(header_text)
    # Check for date patterns FIRST before generic comma split
    # Pattern 1: "Unknown Date, Title"
    if header_text.match?(/^Unknown Date,\s*(.+)$/)
      date_str = "Unknown Date"
      title = header_text.match(/^Unknown Date,\s*(.+)$/)[1].strip
    # Pattern 2: "Month Day, Year, Title" (date with year, comma separator)
    # e.g., "February 26, 2019, Medical Report - Rose Lagar, MD"
    elsif header_text.match?(/^([A-Z][a-z]+\s+\d{1,2},\s+\d{4}),\s*(.+)$/)
      match = header_text.match(/^([A-Z][a-z]+\s+\d{1,2},\s+\d{4}),\s*(.+)$/)
      date_str = match[1]
      title = match[2]
    # Pattern 3: "Month Day, Year Title" (date with year, space separator, then title)
    # e.g., "January 9, 2017 Lumbar Spine, X-Ray"
    elsif header_text.match?(/^([A-Z][a-z]+\s+\d{1,2},\s+\d{4})\s+(.+)$/)
      match = header_text.match(/^([A-Z][a-z]+\s+\d{1,2},\s+\d{4})\s+(.+)$/)
      date_str = match[1]
      title = match[2]
    # Pattern 4: "MM/DD/YYYY, Title" (with comma)
    elsif header_text.match?(/^(\d{1,2}\/\d{1,2}\/\d{2,4}),\s*(.+)$/)
      match = header_text.match(/^(\d{1,2}\/\d{1,2}\/\d{2,4}),\s*(.+)$/)
      date_str = match[1]
      title = match[2]
    # Pattern 5: "MM/DD/YYYY Title" (space separator)
    elsif header_text.match?(/^(\d{1,2}\/\d{1,2}\/\d{2,4})\s+(.+)$/)
      match = header_text.match(/^(\d{1,2}\/\d{1,2}\/\d{2,4})\s+(.+)$/)
      date_str = match[1]
      title = match[2]
    # Pattern 6: Generic "Date, Title" with comma separator (fallback)
    elsif header_text.match?(/^([^,]+),\s*(.+)$/)
      parts = header_text.split(',', 2)
      date_str = parts[0].strip
      title = parts[1].strip
    else
      date_str = "Unknown Date"
      title = header_text
    end

    [date_str, title]
  end

  def self.normalize_date(date_str)
    return "UNKNOWN" if date_str == "Unknown Date"

    begin
      Date.parse(date_str).strftime("%Y-%m-%d")
    rescue ArgumentError
      "UNKNOWN"
    end
  end
end

# Parse headers from vendor document (prose format)
class TheirsParser
  # Medical record header pattern (without date on same line)
  HEADER_START_PATTERN = /^(.+?(?:,\s*Inc\.|,\s*LLC)?),\s+([^,]+(?:,\s*(?:MD|DO|PA|NP|DC|DDS|PhD|PsyD))?),\s+(.+),$/

  # Standalone date pattern
  DATE_PATTERN = /^(\d{1,2}\/\d{1,2}\/\d{2,4})$/

  # Cover letter pattern
  COVER_LETTER_PATTERN = /^Cover letter.+dated\s+(\d{1,2}\/\d{1,2}\/\d{4})/i

  # Simple entries with date on same line
  INLINE_DATE_PATTERN = /^(.+?),\s+(\d{1,2}\/\d{1,2}\/\d{2,4})$/

  def self.parse(file_path)
    sections = []
    lines = File.readlines(file_path, encoding: 'UTF-8', invalid: :replace, undef: :replace)

    i = 0
    while i < lines.length
      line = lines[i].strip
      i += 1
      next if line.empty?

      # Check for multi-line header (header on one line, date on next)
      if match = line.match(HEADER_START_PATTERN)
        next_line = i < lines.length ? lines[i].strip : ""
        if date_match = next_line.match(DATE_PATTERN)
          sections << {
            date_str: date_match[1],
            normalized_date: normalize_date(date_match[1]),
            title: "#{match[1]}, #{match[2]}, #{match[3]}",
            full_header: "#{line} #{next_line}",
            line_number: i # Original line number
          }
          i += 1 # Skip the date line
          next
        end
      end

      # Check for cover letter
      if match = line.match(COVER_LETTER_PATTERN)
        sections << {
          date_str: match[1],
          normalized_date: normalize_date(match[1]),
          title: line.split(',').first,
          full_header: line,
          line_number: i
        }
        next
      end

      # Check for inline date entries
      if match = line.match(INLINE_DATE_PATTERN)
        sections << {
          date_str: match[2],
          normalized_date: normalize_date(match[2]),
          title: match[1],
          full_header: line,
          line_number: i
        }
      end
    end

    sections
  end

  private

  def self.normalize_date(date_str)
    begin
      # Handle formats like 01/09/17 or 02/26/2019
      parts = date_str.split('/')
      month = parts[0].to_i
      day = parts[1].to_i
      year = parts[2].to_i

      # Convert 2-digit year to 4-digit
      year += 2000 if year < 100

      Date.new(year, month, day).strftime("%Y-%m-%d")
    rescue ArgumentError
      "UNKNOWN"
    end
  end
end

# Compare two sets of sections
class Comparator
  def self.compare(yours, theirs)
    yours_by_date = yours.group_by { |s| s[:normalized_date] }
    theirs_by_date = theirs.group_by { |s| s[:normalized_date] }

    all_dates = (yours_by_date.keys + theirs_by_date.keys).uniq.sort

    results = {
      matched: [],
      yours_only: [],
      theirs_only: []
    }

    all_dates.each do |date|
      yours_sections = yours_by_date[date] || []
      theirs_sections = theirs_by_date[date] || []

      if !yours_sections.empty? && !theirs_sections.empty?
        yours_sections.each do |y|
          theirs_sections.each do |t|
            results[:matched] << {
              date: date,
              yours: y,
              theirs: t
            }
          end
        end
      elsif !yours_sections.empty?
        yours_sections.each do |y|
          results[:yours_only] << { date: date, section: y }
        end
      else
        theirs_sections.each do |t|
          results[:theirs_only] << { date: date, section: t }
        end
      end
    end

    results
  end
end

# Convert Word/PDF to text if needed
def convert_to_text(input_file)
  ext = File.extname(input_file).downcase

  case ext
  when '.txt'
    return input_file
  when '.docx'
    output_file = input_file.gsub(/\.docx$/i, '_extracted.txt')
    puts "Converting #{File.basename(input_file)} to text..."
    system("pandoc", input_file, "-t", "plain", "-o", output_file)
    return output_file
  when '.pdf'
    output_file = input_file.gsub(/\.pdf$/i, '_extracted.txt')
    puts "Converting #{File.basename(input_file)} to text..."
    system("mutool", "draw", "-F", "txt", input_file, "-o", output_file)
    return output_file
  else
    puts "Error: Unsupported file format: #{ext}"
    puts "Supported formats: .txt, .docx, .pdf"
    exit 1
  end
end

# Main execution
if __FILE__ == $0
  if ARGV.length != 2
    puts "Usage: #{$0} <your_document> <their_document>"
    puts "\nSupported formats: .txt, .docx, .pdf"
    puts "\nExample:"
    puts "  #{$0} medical_summary.docx vendor_narrative.docx"
    puts "  #{$0} yours.txt theirs.txt"
    exit 1
  end

  yours_input = ARGV[0]
  theirs_input = ARGV[1]

  unless File.exist?(yours_input)
    puts "Error: Your document not found: #{yours_input}"
    exit 1
  end

  unless File.exist?(theirs_input)
    puts "Error: Their document not found: #{theirs_input}"
    exit 1
  end

  base_path = File.dirname(yours_input)

  # Convert to text if needed
  yours_txt = convert_to_text(yours_input)
  theirs_txt = convert_to_text(theirs_input)

  puts "\nParsing your document: #{File.basename(yours_txt)}..."
  yours = YoursParser.parse(yours_txt)
  puts "Found #{yours.size} sections"

  puts "\nParsing vendor document: #{File.basename(theirs_txt)}..."
  theirs = TheirsParser.parse(theirs_txt)
  puts "Found #{theirs.size} sections"

  puts "\nComparing documents..."
  results = Comparator.compare(yours, theirs)

  # Generate CSV report
  csv_path = "#{base_path}/comparison_report.csv"
  CSV.open(csv_path, "wb") do |csv|
    csv << ["Status", "Date", "Your Header (Line)", "Their Header (Line)"]

    results[:matched].each do |m|
      csv << [
        "MATCH",
        m[:date],
        "#{m[:yours][:full_header]} (L#{m[:yours][:line_number]})",
        "#{m[:theirs][:full_header]} (L#{m[:theirs][:line_number]})"
      ]
    end

    results[:yours_only].each do |y|
      csv << [
        "YOURS ONLY",
        y[:date],
        "#{y[:section][:full_header]} (L#{y[:section][:line_number]})",
        "—"
      ]
    end

    results[:theirs_only].each do |t|
      csv << [
        "THEIRS ONLY",
        t[:date],
        "—",
        "#{t[:section][:full_header]} (L#{t[:section][:line_number]})"
      ]
    end
  end

  puts "\nResults:"
  puts "  Matched: #{results[:matched].size}"
  puts "  Yours only: #{results[:yours_only].size}"
  puts "  Theirs only: #{results[:theirs_only].size}"
  puts "\nReport saved to: #{csv_path}"
end
