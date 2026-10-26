// Tools and their single-key shortcuts (ToolSettings.swift).
import type { AnnotationType } from './model';

export type Tool =
  | 'select'
  | 'rectangle'
  | 'ellipse'
  | 'arrow'
  | 'line'
  | 'pen'
  | 'highlighter'
  | 'text'
  | 'step'
  | 'redaction'
  | 'crop';

export const TOOL_INFO: Record<Tool, { title: string; key: string; type: AnnotationType | null }> = {
  select: { title: 'Select', key: 'v', type: null },
  rectangle: { title: 'Rectangle', key: 'r', type: 'rectangle' },
  ellipse: { title: 'Ellipse', key: 'o', type: 'ellipse' },
  arrow: { title: 'Arrow', key: 'a', type: 'arrow' },
  line: { title: 'Line', key: 'l', type: 'line' },
  pen: { title: 'Pen', key: 'p', type: 'pen' },
  highlighter: { title: 'Highlighter', key: 'h', type: 'highlighter' },
  text: { title: 'Text', key: 't', type: 'text' },
  step: { title: 'Step number', key: 'n', type: 'step' },
  redaction: { title: 'Redact', key: 'b', type: 'redaction' },
  crop: { title: 'Crop', key: 'c', type: null },
};

/** Visual groups in the header; a divider sits between groups. */
export const TOOL_GROUPS: Tool[][] = [
  ['select'],
  ['rectangle', 'ellipse', 'arrow', 'line'],
  ['pen', 'highlighter', 'text', 'step'],
  ['redaction', 'crop'],
];

export function toolForKey(key: string): Tool | null {
  const k = key.toLowerCase();
  return (Object.keys(TOOL_INFO) as Tool[]).find((t) => TOOL_INFO[t].key === k) ?? null;
}
