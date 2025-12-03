# Auditor

Medical records reconciliation tool for comparing indexed documents and identifying discrepancies.

## Overview

Auditor helps you compare two indexed medical record PDFs (yours vs vendor's) to identify:
- Records present in only one document
- Records with matching dates but different page counts
- Content similarity scores via OCR

## Installation

### Prerequisites

- Ruby 3.x
- Python 3.x with PyMuPDF (`pip install PyMuPDF`)
- Tesseract OCR (`brew install tesseract`)
- mutool (`brew install mupdf-tools`)
- pandoc (`brew install pandoc`)

For PDF conversion (optional):
- Microsoft Word for Mac, OR
- docx2pdf (`pip install docx2pdf`)

## Usage

### Basic Usage

```bash
bin/run_pipeline.rb /path/to/your_indexed.pdf /path/to/their_indexed.pdf
```

The case name will be auto-detected from the filename.

### With Explicit Case Name

```bash
bin/run_pipeline.rb --case "Reyes_Isidro" /path/to/your_indexed.pdf /path/to/their_indexed.pdf
```

### Case Structure

Each case is stored in `cases/<case_name>/`:

```
cases/Reyes_Isidro/
├── mappings/               # Logical → physical page mappings
│   ├── your_doc_hyperlink_mapping.json
│   └── their_doc_hyperlink_mapping.json
├── reports/                # Output reports
│   ├── reconciliation_data.json
│   └── discrepancy_report.csv
└── ocr_cache/              # Cached OCR results
```

## Pipeline Phases

1. **Phase 0**: Build page mappings from TOC hyperlinks
2. **Phase 1**: (Skipped) Compare document content
3. **Phase 2**: Reconcile table of contents entries
4. **Phase 3**: Convert DOCX to PDF if needed
5. **Phase 4**: Match pages via OCR content similarity

## Output

### reconciliation_data.json

Intermediate data showing:
- `yours_only`: Dates/pages in your TOC only
- `theirs_only`: Dates/pages in their TOC only
- `same_dates`: Dates appearing in both TOCs

### discrepancy_report.csv

Final report with:
- Status (YOURS ONLY, THEIRS ONLY, SAME DATE)
- Page numbers (logical pages from TOCs)
- Match confidence scores
- Recommended actions

## Development

### Project Structure

```
auditor/
├── bin/                    # Executable scripts
│   ├── run_pipeline.rb     # Main orchestrator
│   ├── simple_reconcile.rb # TOC comparison
│   ├── page_matcher.rb     # Page content matching
│   ├── build_complete_mappings.py
│   └── extract_hyperlinks.py
└── cases/                  # Case data (gitignored)
```

### Contributing

1. Make changes in `bin/` scripts
2. Test with a real case
3. Commit only code changes (cases/ is gitignored)

## License

Internal use only.
