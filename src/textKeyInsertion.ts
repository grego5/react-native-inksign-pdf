import { argumentError, validateTextInsertionByKeyOptions } from './publicArguments';

import type { TextInsertionByKeyOptions } from './InkSignView.nitro';

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
