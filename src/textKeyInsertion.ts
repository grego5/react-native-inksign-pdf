import { argumentError, validateTextInsertionByKeyOptions } from './publicArguments';

import type { FieldFocusOptions, TextInsertionByKeyOptions } from './InkSignView.nitro';

export function createFieldFocusCommand(
  invoke: (key: string, options?: FieldFocusOptions) => Promise<void>,
) {
  return (key: string, options?: FieldFocusOptions): Promise<void> => {
    try {
      if (typeof key !== 'string' || key.trim() === '') {
        throw argumentError('invalid_text_key', 'Text key must not be empty');
      }
      if (options !== undefined && (options === null || typeof options !== 'object' ||
        (options.occurrence !== undefined && options.occurrence !== 'first' && options.occurrence !== 'last') ||
        (options.direction !== undefined && options.direction !== 'auto' && options.direction !== 'ltr' && options.direction !== 'rtl') ||
        (options.zoom !== undefined && (!Number.isFinite(options.zoom) || options.zoom <= 0)) ||
        (options.enterEditMode !== undefined && typeof options.enterEditMode !== 'boolean'))) {
        throw argumentError('invalid_field_focus_options', 'Expected first/last occurrence, auto/ltr/rtl direction, positive zoom and optional edit-mode flag');
      }
      return invoke(key, options);
    } catch (error) {
      return Promise.reject(error);
    }
  };
}

export function createTextKeyInsertionCommand(
  invoke: (text: string, key: string, options?: TextInsertionByKeyOptions) => Promise<void>,
) {
  return (text: string, key: string, options?: TextInsertionByKeyOptions): Promise<void> => {
    try {
      if (typeof text !== 'string' || text.trim() === '') {
        throw argumentError('invalid_text', 'Text must not be empty');
      }
      if (typeof key !== 'string' || key.trim() === '') {
        throw argumentError('invalid_text_key', 'Text key must not be empty');
      }
      validateTextInsertionByKeyOptions(options);
      return invoke(text, key, options);
    } catch (error) {
      return Promise.reject(error);
    }
  };
}
