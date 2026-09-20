import { File } from 'expo-file-system';

export function fileUriToPath(uri: string): string {
  return uri.startsWith('file://') ? decodeURIComponent(uri.slice('file://'.length)) : uri;
}

export function filePathToUri(path: string): string {
  return path.startsWith('file://') ? path : `file://${path}`;
}

export function cleanupLocalFile(path: string | undefined, description: string) {
  if (path === undefined) return;
  try {
    const file = new File(filePathToUri(path));
    if (file.exists) file.delete();
  } catch (error) {
    console.warn(`Unable to retire ${description}`, path, error);
  }
}
