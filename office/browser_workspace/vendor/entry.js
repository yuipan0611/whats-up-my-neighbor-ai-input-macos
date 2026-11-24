import { initLogging } from './node_modules/@novnc/novnc/core/util/logging.js';
// Never log remote keysyms, URLs or clipboard contents, including debug mode.
initLogging('none');
export { default } from '@novnc/novnc';
