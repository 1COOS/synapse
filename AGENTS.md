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

## Markdown Editor Rules

- Markdown markers are the storage format and must remain visible while a block is actively being edited.
- When a block loses focus and returns to preview rendering, Markdown markers should be hidden by the rendered Markdown view.
- Live editor formatting commands must update the Markdown source and the styled editor display together.
- Active editor `TextSpan.toPlainText()` must match the backing controller text exactly, so caret offsets cannot drift.
- Focusing, clicking, selecting, or opening context menus must not mutate note content or insert blank lines.
