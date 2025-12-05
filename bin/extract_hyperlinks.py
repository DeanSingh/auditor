#!/usr/bin/env python
# -*- coding: utf-8 -*-

import fitz  # PyMuPDF
import sys
import re

def extract_hyperlinks_from_toc(pdf_path):
    """
    Extract all hyperlinks from TOC pages until we stop finding them.
    Returns a list of (link_text, destination_page) tuples.
    """
    doc = fitz.open(pdf_path)
    hyperlinks = []

    print(f"Scanning {pdf_path} for TOC hyperlinks...")
    print(f"Total pages in PDF: {len(doc)}")
    print()

    # Scan all pages for hyperlinks
    # TOCs can have gaps (pages without links), so we scan the entire document
    for page_num in range(len(doc)):
        page = doc[page_num]
        links = page.get_links()

        # Filter for internal goto links (kind 1) or named links (kind 4)
        goto_links = [link for link in links if link.get('kind') in [fitz.LINK_GOTO, fitz.LINK_NAMED]]

        if goto_links:
            print(f"Page {page_num + 1}: Found {len(goto_links)} hyperlinks")

            for link in goto_links:
                # Get the rectangle of the clickable area
                rect = fitz.Rect(link['from'])

                # Extract text from that rectangle
                link_text = page.get_text("text", clip=rect).strip()

                # Get destination page
                dest_page = -1

                if link.get('kind') == fitz.LINK_GOTO:
                    # Direct page reference (0-indexed, convert to 1-indexed)
                    dest_page = link.get('page', -1) + 1
                elif link.get('kind') == fitz.LINK_NAMED:
                    # Named destination - page might be a string or int
                    page_val = link.get('page', -1)
                    try:
                        if isinstance(page_val, str):
                            dest_page = int(page_val) + 1  # Convert string to int, then add 1
                        elif isinstance(page_val, int):
                            dest_page = page_val + 1
                    except:
                        dest_page = -1

                if dest_page > 0:
                    hyperlinks.append((link_text, dest_page))

    doc.close()
    return hyperlinks

def build_page_mapping(hyperlinks):
    """
    Build a mapping from logical page numbers to physical page numbers.
    Handles both single pages and ranges (e.g., "229-235").
    """
    mapping = {}

    for link_text, physical_page in hyperlinks:
        # Clean up the link text
        link_text = link_text.strip()

        # Check if it's a range (e.g., "229-235")
        range_match = re.match(r'^(\d+)\s*-\s*(\d+)$', link_text)

        if range_match:
            # It's a range - we only have the first page's hyperlink
            # Need to find the corresponding end hyperlink
            start_logical = int(range_match.group(1))
            end_logical = int(range_match.group(2))

            # Store the start
            mapping[start_logical] = physical_page

            # We'll handle interpolation after we have all ranges
            # Mark this as a range start
            mapping[f"_range_{start_logical}"] = (start_logical, end_logical, physical_page)

        elif link_text.isdigit():
            # Single page number
            logical_page = int(link_text)
            mapping[logical_page] = physical_page
        elif link_text.endswith('-') and link_text[:-1].strip().isdigit():
            # Range start marker (e.g., "229-") - just store the start page
            logical_page = int(link_text[:-1].strip())
            mapping[logical_page] = physical_page
        elif link_text.endswith(',') and link_text[:-1].strip().isdigit():
            # Single page with trailing comma (e.g., "304,")
            logical_page = int(link_text[:-1].strip())
            mapping[logical_page] = physical_page
        elif ',' in link_text:
            # Multiple individual pages like "1, 2, 3"
            page_nums = [int(p.strip()) for p in link_text.split(',') if p.strip().isdigit()]
            if len(page_nums) == 1:
                # Actually just one page with formatting quirks
                mapping[page_nums[0]] = physical_page
            else:
                # Multiple pages pointing to same physical location - needs verification
                print(f"  Warning: Multiple pages in one link: {link_text} -> {physical_page}")

    # Now handle range interpolation
    # Find pairs of range starts and ends
    range_keys = [k for k in mapping.keys() if isinstance(k, str) and k.startswith('_range_')]

    for key in range_keys:
        start_logical, end_logical, start_physical = mapping[key]

        # Try to find the end of this range
        # Look for a hyperlink to the end_logical page
        if end_logical in mapping:
            end_physical = mapping[end_logical]

            # Interpolate middle pages
            range_size = end_logical - start_logical + 1
            physical_range_size = end_physical - start_physical + 1

            if range_size == physical_range_size:
                # Perfect 1-to-1 mapping
                for i in range(range_size):
                    logical = start_logical + i
                    physical = start_physical + i
                    mapping[logical] = physical
                    print(f"  Interpolated range: {start_logical}-{end_logical} -> {start_physical}-{end_physical}")
            else:
                print(f"  Warning: Range size mismatch: {start_logical}-{end_logical} ({range_size} pages) -> {start_physical}-{end_physical} ({physical_range_size} pages)")

        # Clean up temporary range marker
        del mapping[key]

    # Additional interpolation: Fill in gaps between consecutive hyperlinks
    # if they form a linear progression (old build_complete_mappings.py approach)
    numeric_mapping = {k: v for k, v in mapping.items() if isinstance(k, int)}
    sorted_logical = sorted(numeric_mapping.keys())
    complete_mapping = {}

    for i in range(len(sorted_logical) - 1):
        start_logical = sorted_logical[i]
        end_logical = sorted_logical[i + 1]
        start_physical = numeric_mapping[start_logical]
        end_physical = numeric_mapping[end_logical]

        # Add the start entry
        complete_mapping[start_logical] = start_physical

        # Only interpolate if physical pages form a continuous range matching logical progression
        logical_diff = end_logical - start_logical
        physical_diff = end_physical - start_physical

        if physical_diff == logical_diff and logical_diff > 1:
            # Interpolate between start and end
            for logical in range(start_logical + 1, end_logical):
                physical = start_physical + (logical - start_logical)
                complete_mapping[logical] = physical

    # Add the last entry
    if sorted_logical:
        last_logical = sorted_logical[-1]
        complete_mapping[last_logical] = numeric_mapping[last_logical]

    return complete_mapping

def main():
    import argparse
    import json

    parser = argparse.ArgumentParser(description='Extract hyperlinks from PDF TOC and build page mapping')
    parser.add_argument('pdf_path', help='Path to PDF file')
    parser.add_argument('--output', '-o', help='Output JSON file (if not specified, prints detailed report)')
    args = parser.parse_args()

    pdf_path = args.pdf_path

    # Extract hyperlinks
    hyperlinks = extract_hyperlinks_from_toc(pdf_path)

    # Build mapping
    mapping = build_page_mapping(hyperlinks)

    # Filter to only numeric keys
    numeric_mapping = {k: v for k, v in mapping.items() if isinstance(k, int)}

    if args.output:
        # Output mode: Write JSON and minimal status
        with open(args.output, 'w') as f:
            json.dump(numeric_mapping, f, indent=2)
        print(f"  Created mapping for {len(numeric_mapping)} logical pages")
        if 1 in numeric_mapping:
            print(f"  Sample: Logical 1 -> Physical {numeric_mapping[1]}")
    else:
        # Report mode: Detailed output
        print("="*80)
        print("HYPERLINK EXTRACTION REPORT")
        print("="*80)
        print()
        print(f"Total hyperlinks found: {len(hyperlinks)}")
        print()

        # Show first 20
        print("Sample links (first 20):")
        for link_text, dest_page in hyperlinks[:20]:
            print(f"  Link '{link_text}' -> Physical page {dest_page}")

        if len(hyperlinks) > 20:
            print(f"  ... and {len(hyperlinks) - 20} more")

        print()
        print("-"*80)
        print("BUILDING PAGE MAPPING")
        print("-"*80)
        print()
        print(f"Built mapping for {len(numeric_mapping)} logical pages")
        print()

        # Show sample mappings from start, middle, and end
        sorted_pages = sorted(numeric_mapping.keys())
        if sorted_pages:
            sample_count = min(10, len(sorted_pages))
            # Get evenly distributed samples
            step = max(1, len(sorted_pages) // sample_count)
            sample_pages = [sorted_pages[i * step] for i in range(sample_count)]

            print("Sample mappings:")
            for logical in sample_pages:
                print(f"  Logical {logical} -> Physical {numeric_mapping[logical]}")

        print()
        print("="*80)

if __name__ == "__main__":
    main()
