#!/usr/bin/env python
# -*- coding: utf-8 -*-

import json
import sys

def build_yours_mapping(pdf_path, max_logical_page=500):
    """
    Your PDF has linear offset: Physical = Logical + offset
    Offset is dynamically detected from the first hyperlink (logical page 1)
    """
    import fitz

    doc = fitz.open(pdf_path)
    offset = None

    # Scan first 50 pages of TOC to find the first hyperlink to logical page 1
    for page_num in range(min(50, len(doc))):
        page = doc[page_num]
        links = page.get_links()

        for link in links:
            if link.get('kind') in [fitz.LINK_GOTO, fitz.LINK_NAMED]:
                rect = fitz.Rect(link['from'])
                link_text = page.get_text("text", clip=rect).strip()

                # Look for hyperlink with text "1" (logical page 1)
                if link_text == "1":
                    dest_page = -1
                    if link.get('kind') == fitz.LINK_GOTO:
                        dest_page = link.get('page', -1) + 1  # Convert to 1-indexed
                    elif link.get('kind') == fitz.LINK_NAMED:
                        page_val = link.get('page', -1)
                        try:
                            if isinstance(page_val, str):
                                dest_page = int(page_val) + 1
                            elif isinstance(page_val, int):
                                dest_page = page_val + 1
                        except:
                            pass

                    if dest_page > 0:
                        offset = dest_page - 1  # Physical page of logical 1, minus 1
                        break

        if offset is not None:
            break

    doc.close()

    if offset is None:
        print("  Warning: Could not detect offset from hyperlinks, using default 142")
        offset = 142

    print(f"  Detected offset: Physical = Logical + {offset}")

    mapping = {}
    for logical in range(1, max_logical_page + 1):
        mapping[logical] = logical + offset

    return mapping

def build_theirs_mapping_from_hyperlinks(pdf_path):
    """
    Their PDF needs actual hyperlink extraction
    """
    import fitz

    doc = fitz.open(pdf_path)
    hyperlinks = []

    print(f"Extracting hyperlinks from {pdf_path}...")

    # Scan first 30 pages for TOC
    for page_num in range(min(30, len(doc))):
        page = doc[page_num]
        links = page.get_links()

        goto_links = [link for link in links if link.get('kind') in [fitz.LINK_GOTO, fitz.LINK_NAMED]]

        for link in goto_links:
            rect = fitz.Rect(link['from'])
            link_text = page.get_text("text", clip=rect).strip()

            dest_page = -1
            if link.get('kind') == fitz.LINK_GOTO:
                dest_page = link.get('page', -1) + 1
            elif link.get('kind') == fitz.LINK_NAMED:
                page_val = link.get('page', -1)
                try:
                    if isinstance(page_val, str):
                        dest_page = int(page_val) + 1
                    elif isinstance(page_val, int):
                        dest_page = page_val + 1
                except:
                    dest_page = -1

            if dest_page > 0 and link_text:
                hyperlinks.append((link_text, dest_page))

    doc.close()

    # Build mapping from hyperlinks
    mapping = {}

    for link_text, physical_page in hyperlinks:
        link_text = link_text.strip()

        # Single page number
        if link_text.isdigit():
            logical = int(link_text)
            mapping[logical] = physical_page

        # Range start (e.g., "229-")
        elif link_text.endswith('-') and link_text[:-1].isdigit():
            logical = int(link_text[:-1])
            mapping[f"_range_start_{logical}"] = (logical, physical_page)

        # Try to extract just the number
        else:
            # Handle cases like "1," or other formats
            import re
            match = re.match(r'^(\d+)', link_text)
            if match:
                logical = int(match.group(1))
                mapping[logical] = physical_page

    # Handle ranges - find pairs and interpolate
    range_starts = {k: v for k, v in mapping.items() if isinstance(k, str) and k.startswith('_range_start_')}

    for key, (start_logical, start_physical) in range_starts.items():
        # Look for the next range or explicit page that could be the end
        # For now, just mark the start
        mapping[start_logical] = start_physical
        del mapping[key]

    # Filter to only numeric keys
    numeric_mapping = {k: v for k, v in mapping.items() if isinstance(k, int)}

    # Interpolate ONLY within continuous ranges
    sorted_logical = sorted(numeric_mapping.keys())
    complete_mapping = {}

    for i in range(len(sorted_logical) - 1):
        start_logical = sorted_logical[i]
        end_logical = sorted_logical[i + 1]
        start_physical = numeric_mapping[start_logical]
        end_physical = numeric_mapping[end_logical]

        # Add the start entry (from hyperlink)
        complete_mapping[start_logical] = start_physical

        # Only interpolate if:
        # 1. Logical pages are consecutive (end = start + 1)
        # 2. OR Physical pages form a continuous range (physical diff = logical diff)
        logical_diff = end_logical - start_logical
        physical_diff = end_physical - start_physical

        # Check if this is a continuous range
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
    import sys
    import os

    if len(sys.argv) != 4:
        print("Usage: build_complete_mappings.py <case_dir> <your_pdf> <their_pdf>")
        print("\nExample:")
        print("  build_complete_mappings.py ~/git/auditor/cases/Reyes_Isidro yours.pdf theirs.pdf")
        sys.exit(1)

    case_dir = sys.argv[1]
    your_pdf = sys.argv[2]
    their_pdf = sys.argv[3]

    your_basename = os.path.splitext(os.path.basename(your_pdf))[0]
    their_basename = os.path.splitext(os.path.basename(their_pdf))[0]

    print("="*80)
    print("BUILDING COMPLETE PAGE MAPPINGS")
    print("="*80)
    print()

    mappings_dir = os.path.join(case_dir, "mappings")
    os.makedirs(mappings_dir, exist_ok=True)

    # Build YOUR mapping (always rebuild - changes with TOC length)
    print(f"Building mapping for YOUR PDF ({your_basename})...")
    yours_mapping = build_yours_mapping(your_pdf, max_logical_page=500)
    print(f"  Created mapping for {len(yours_mapping)} logical pages")
    print(f"  Sample: Logical 219 -> Physical {yours_mapping[219]}")
    print()

    # Save YOUR mapping
    yours_mapping_file = os.path.join(mappings_dir, f"{your_basename}_hyperlink_mapping.json")
    with open(yours_mapping_file, "w") as f:
        json.dump(yours_mapping, f, indent=2)
    print(f"  Saved to: {yours_mapping_file}")
    print()

    # Build THEIR mapping (only if doesn't exist - their PDF doesn't change)
    theirs_mapping_file = os.path.join(mappings_dir, f"{their_basename}_hyperlink_mapping.json")

    if os.path.exists(theirs_mapping_file):
        print(f"Mapping for THEIR PDF ({their_basename}) already exists, skipping...")
        with open(theirs_mapping_file, "r") as f:
            theirs_mapping = json.load(f)
        print(f"  Loaded {len(theirs_mapping)} mappings from cache")
    else:
        print(f"Building mapping for THEIR PDF ({their_basename})...")
        theirs_mapping = build_theirs_mapping_from_hyperlinks(their_pdf)
        print(f"  Created mapping for {len(theirs_mapping)} logical pages")

        # Save THEIR mapping
        with open(theirs_mapping_file, "w") as f:
            json.dump(theirs_mapping, f, indent=2)
        print(f"  Saved to: {theirs_mapping_file}")

    print()

    print("="*80)
    print("DONE!")
    print("="*80)

if __name__ == "__main__":
    main()
