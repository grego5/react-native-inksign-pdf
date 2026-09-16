const path = require('path');
const {getDefaultConfig, mergeConfig} = require('@react-native/metro-config');

const projectRoot = __dirname;
const workspaceRoot = path.resolve(projectRoot, '..');
const defaultConfig = getDefaultConfig(projectRoot);

module.exports = mergeConfig(defaultConfig, {
  watchFolders: [workspaceRoot],
    resolver: {
      disableHierarchicalLookup: true,
      unstable_enableSymlinks: true,
      assetExts: [...new Set([...defaultConfig.resolver.assetExts, 'ttf'])],
    nodeModulesPaths: [
      path.resolve(projectRoot, 'node_modules'),
      path.resolve(workspaceRoot, 'node_modules'),
    ],
  },
});
