import RNFS from 'react-native-fs';

export function fileUriToPath(uri: string): string {
  return uri.startsWith('file://') ? decodeURIComponent(uri.slice('file://'.length)) : uri;
}

export function filePathToUri(path: string): string {
  return path.startsWith('file://') ? path : `file://${path}`;
}

export function cleanupLocalFile(path: string | undefined, description: string) {
  if (path === undefined) return;
  void RNFS.unlink(path).catch(error => {
    console.warn(`Unable to retire ${description}`, path, error);
  });
}
