# Synapse Agent Notes

## AI and OCR Rules

- For image-backed proposal generation, use `visionModel`; keep `chatModel` for text-only proposal generation.
- Image-only proposal generation must show OCR transcription directly; do not run a second summarization or outline-generation pass.
- OCR output must be a faithful transcription of visible image text only.
- Do not add OCR explanations, summaries, captions, prefixes, or image descriptions.
- Preserve the source layout as much as possible. For tree menus, outlines, tables, or indented lists, keep an equivalent Markdown structure.
- OCR/tree proposal display, copy, and Markdown preview must preserve line breaks.
- Proposal text must be fully viewable and selectable.
- Image thumbnails must avoid cropping important content and provide a full-image preview.
