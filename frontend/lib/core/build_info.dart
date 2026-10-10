/// Supplied by the release scripts. A normal local/debug build deliberately
/// keeps the checked-in version, so it never mistakes itself for a release.
const appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '1.0.29',
);

const appReleaseManifest = String.fromEnvironment(
  'UPDATE_MANIFEST_URL',
  defaultValue: 'https://github.com/ISanjuAi2/avtar-cooks-releases/releases/latest/download/latest.json',
);
