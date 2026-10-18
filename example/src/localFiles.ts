export function fileUriToPath(uri: string): string {
  return uri.startsWith('file://') ? decodeURIComponent(uri.slice('file://'.length)) : uri;
}

export function filePathToUri(path: string): string {
  return path.startsWith('file://') ? path : `file://${path}`;
}
