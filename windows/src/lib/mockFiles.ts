// Browser-only stand-in for the file system: maps fake Windows paths to URLs the page can load.
// Kept apart from mock.ts so `fileSrc` can resolve paths synchronously.
const urls = new Map<string, string>();

export function registerMockFile(path: string, url: string): void {
  urls.set(path, url);
}

export function mockFileUrl(path: string): string | undefined {
  return urls.get(path);
}
