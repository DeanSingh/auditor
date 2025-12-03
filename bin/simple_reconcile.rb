#!/usr/bin/env ruby
# frozen_string_literal: true

require 'date'
require 'json'

# Parse TOC entries from your indexed document (extracted text or docx)
class YoursTOCParser
  def self.parse(file_path)
    entries = []
    content = extract_text(file_path)
    lines = content.split("\n")

    i = 0
    while i < lines.length
      line = lines[i]

      # Pattern: MM/DD on one line, /YYYY on next line
      # Example: "| 10/06 | ..." followed by "| /2025 | ..."
      if line.match?(/^\|\s*(\d{1,2})\/(\d{1,2})\s*\|/)
        match = line.match(/^\|\s*(\d{1,2})\/(\d{1,2})\s*\|/)
        month = match[1]
        day = match[2]

        # Check next line for year
        next_line = i + 1 < lines.length ? lines[i + 1] : ""
        if next_line.match?(/^\|\s*\/(\d{2,4})\s*\|/)
          year = next_line.match(/^\|\s*\/(\d{2,4})\s*\|/)[1]
          date_str = "#{month}/#{day}/#{year}"

          # Extract header text (3rd column) and page numbers (4th column)
          header_lines = []
          page_nums = []

          (i..i+10).each do |idx|
            break if idx >= lines.length
            l = lines[idx]

            # Extract header text from 3rd column
            if l.match?(/\|\s*[^|]*\|\s*[^|]*\|\s*([^|]+)\|/)
              text = l.match(/\|\s*[^|]*\|\s*[^|]*\|\s*([^|]+)\|/)[1].strip
              header_lines << text unless text.empty?
            end

            # Extract page numbers from last column
            if l.match?(/\|\s*([\d,\s]+)\s*\|?\s*$/)
              pages_match = l.match(/\|\s*([\d,\s]+)\s*\|?\s*$/)
              page_nums.concat(pages_match[1].scan(/\d+/).map(&:to_i))
            end
          end

          normalized_date = normalize_date(date_str)
          header = header_lines.first(3).join(" ").strip

          entries << {
            date: normalized_date,
            date_str: date_str,
            pages: page_nums.uniq.sort,
            header: header
          }
        end
      # Pattern: Unknown date entries
      elsif line.match?(/^\|\s*Un\s*\|/) || line.match?(/^\|\s*unknown\s*\|/i)
        # Extract page numbers for unknown dates
        page_line = lines[i..i+5].find { |l| l.match?(/\|\s*([\d,\s]+)\s*\|?\s*$/) }
        if page_line
          pages_match = page_line.match(/\|\s*([\d,\s]+)\s*\|?\s*$/)
          if pages_match
            pages = pages_match[1].scan(/\d+/).map(&:to_i)

            # Try to extract header
            header_lines = []
            (i..i+5).each do |idx|
              break if idx >= lines.length
              l = lines[idx]
              if l.match?(/\|\s*[^|]*\|\s*[^|]*\|\s*([^|]+)\|/)
                text = l.match(/\|\s*[^|]*\|\s*[^|]*\|\s*([^|]+)\|/)[1].strip
                header_lines << text unless text.empty?
              end
            end

            entries << {
              date: "UNKNOWN",
              date_str: "Unknown",
              pages: pages.uniq.sort,
              header: header_lines.first(3).join(" ").strip
            }
          end
        end
      end

      i += 1
    end

    entries
  end

  private

  def self.extract_text(file_path)
    ext = File.extname(file_path).downcase

    case ext
    when '.txt'
      File.read(file_path, encoding: 'UTF-8', invalid: :replace, undef: :replace)
    when '.docx'
      output_file = file_path.gsub(/\.docx$/i, '_toc_extracted.txt')
      unless File.exist?(output_file)
        puts "  Converting #{File.basename(file_path)} to text..."
        system("pandoc", file_path, "-t", "plain", "-o", output_file)
      end
      File.read(output_file, encoding: 'UTF-8', invalid: :replace, undef: :replace)
    else
      puts "Error: Unsupported format for yours: #{ext}"
      exit 1
    end
  end

  def self.normalize_date(date_str)
    return "UNKNOWN" if date_str.nil? || date_str.empty?

    begin
      parts = date_str.split('/')
      month = parts[0].to_i
      day = parts[1].to_i
      year = parts[2].to_i

      year += 2000 if year < 100

      Date.new(year, month, day).strftime("%Y-%m-%d")
    rescue ArgumentError
      "UNKNOWN"
    end
  end
end

# Parse TOC entries from vendor's indexed PDF
class TheirsTOCParser
  def self.parse(pdf_path)
    entries = []
    text = `mutool draw -F txt "#{pdf_path}" 2>&1`.force_encoding('UTF-8')
    lines = text.split("\n")

    i = 0
    while i < lines.length
      line = lines[i].strip

      # Look for date pattern
      if line.match?(/^(\d{1,2}\/\d{1,2}\/\d{2,4})$/)
        date_str = line
        normalized = normalize_date(date_str)

        # Next line should have pages and provider
        next_line = i + 1 < lines.length ? lines[i + 1] : ""

        # Extract page numbers (format: "229-235" or "306" or "209-210, 227")
        pages = []
        if next_line.match?(/^([\d\-,\s]+)/)
          pages_str = next_line.match(/^([\d\-,\s]+)/)[1]
          pages = parse_page_numbers(pages_str)
        end

        # Extract header (provider info, typically 2-3 lines down)
        header_lines = []
        (i+1..i+5).each do |idx|
          break if idx >= lines.length
          l = lines[idx].strip
          next if l.match?(/^[\d\-,\s]+$/) # Skip page number lines
          next if l.empty?
          header_lines << l
          break if header_lines.size >= 2
        end

        entries << {
          date: normalized,
          date_str: date_str,
          pages: pages,
          header: header_lines.join(", ")
        }
      elsif line.match?(/^Undated$/)
        normalized = "UNKNOWN"

        next_line = i + 1 < lines.length ? lines[i + 1] : ""
        pages = []
        if next_line.match?(/^([\d\-,\s]+)/)
          pages_str = next_line.match(/^([\d\-,\s]+)/)[1]
          pages = parse_page_numbers(pages_str)
        end

        # Extract header
        header_lines = []
        (i+1..i+5).each do |idx|
          break if idx >= lines.length
          l = lines[idx].strip
          next if l.match?(/^[\d\-,\s]+$/)
          next if l.empty?
          header_lines << l
          break if header_lines.size >= 2
        end

        entries << {
          date: normalized,
          date_str: "Undated",
          pages: pages,
          header: header_lines.join(", ")
        }
      end

      i += 1
    end

    entries
  end

  private

  def self.parse_page_numbers(pages_str)
    pages = []

    pages_str.split(',').each do |part|
      part = part.strip
      if part.match?(/^(\d+)-(\d+)$/)
        match = part.match(/^(\d+)-(\d+)$/)
        start_page = match[1].to_i
        end_page = match[2].to_i
        (start_page..end_page).each { |p| pages << p }
      elsif part.match?(/^\d+$/)
        pages << part.to_i
      end
    end

    pages.uniq.sort
  end

  def self.normalize_date(date_str)
    return "UNKNOWN" if date_str == "Undated" || date_str.nil? || date_str.empty?

    begin
      parts = date_str.split('/')
      month = parts[0].to_i
      day = parts[1].to_i
      year = parts[2].to_i

      year += 2000 if year < 100

      Date.new(year, month, day).strftime("%Y-%m-%d")
    rescue ArgumentError
      "UNKNOWN"
    end
  end
end

# Compare TOC entries and generate reconciliation data
class TOCComparator
  def self.compare(yours_entries, theirs_entries)
    yours_by_date = yours_entries.group_by { |e| e[:date] }
    theirs_by_date = theirs_entries.group_by { |e| e[:date] }

    all_dates = (yours_by_date.keys + theirs_by_date.keys).uniq.sort

    yours_only = []
    theirs_only = []
    date_mismatches = []

    all_dates.each do |date|
      yours_list = yours_by_date[date] || []
      theirs_list = theirs_by_date[date] || []

      if !yours_list.empty? && theirs_list.empty?
        # Date only in yours
        yours_list.each do |entry|
          # Skip entries with no pages (invalid TOC entries)
          next if entry[:pages].nil? || entry[:pages].empty?

          yours_only << {
            date: entry[:date],
            pages: entry[:pages],
            header: entry[:header]
          }
        end
      elsif yours_list.empty? && !theirs_list.empty?
        # Date only in theirs
        theirs_list.each do |entry|
          # Skip entries with no pages (invalid TOC entries)
          next if entry[:pages].nil? || entry[:pages].empty?

          theirs_only << {
            date: entry[:date],
            pages: entry[:pages],
            header: entry[:header]
          }
        end
      else
        # Date exists in both - check if pages match
        yours_list.each do |y_entry|
          theirs_list.each do |t_entry|
            # If pages overlap, both TOCs have the same date
            if (y_entry[:pages] & t_entry[:pages]).any?
              date_mismatches << {
                date: y_entry[:date],  # Same date in both
                your_pages: y_entry[:pages],
                their_pages: t_entry[:pages],
                your_header: y_entry[:header],
                their_header: t_entry[:header]
              }
            end
          end
        end
      end
    end

    {
      yours_only: yours_only,
      theirs_only: theirs_only,
      same_dates: date_mismatches  # Renamed from date_mismatches
    }
  end
end

# Main execution
if __FILE__ == $0
  if ARGV.length != 3
    puts "Usage: #{$0} <case_dir> <your_indexed.docx|txt> <their_indexed.pdf>"
    puts "\nExample:"
    puts "  #{$0} ~/git/auditor/cases/Reyes_Isidro ~/Downloads/yours.docx ~/Downloads/theirs.pdf"
    exit 1
  end

  case_dir = ARGV[0]
  yours_input = ARGV[1]
  theirs_pdf = ARGV[2]

  unless File.exist?(yours_input)
    puts "Error: Your document not found: #{yours_input}"
    exit 1
  end

  unless File.exist?(theirs_pdf)
    puts "Error: Their PDF not found: #{theirs_pdf}"
    exit 1
  end

  puts "Parsing your TOC: #{File.basename(yours_input)}..."
  yours_entries = YoursTOCParser.parse(yours_input)
  puts "Found #{yours_entries.size} entries"

  puts "\nParsing vendor TOC: #{File.basename(theirs_pdf)}..."
  theirs_entries = TheirsTOCParser.parse(theirs_pdf)
  puts "Found #{theirs_entries.size} entries"

  puts "\nComparing TOCs..."
  results = TOCComparator.compare(yours_entries, theirs_entries)

  # Output JSON for Phase 4 to consume
  json_path = File.join(case_dir, "reports", "reconciliation_data.json")
  File.write(json_path, JSON.pretty_generate(results))

  puts "\nResults:"
  puts "  Yours only: #{results[:yours_only].size}"
  puts "  Theirs only: #{results[:theirs_only].size}"
  puts "  Same dates: #{results[:same_dates].size}"
  puts "\nReconciliation data saved to: #{json_path}"
end
